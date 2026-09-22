--- Pure helpers over `.http` block text for the AI integration — list, slice
--- and describe request blocks from content strings, plus the one stateful
--- seam `focus()` every consumer (mentions, auto_context, ask prefill) funnels
--- through. Block parsing mirrors request_deps.collect_requests_from_content;
--- keep the two in sync.

local M = {}

--- `### name` header lines → { name, start_line, end_line } (1-indexed,
--- inclusive; start_line is the header line itself).
local function list_block_bounds(lines)
  local blocks = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^%s*###%s+(%S.*)$")
    if name then
      local end_line = #lines
      for j = i + 1, #lines do
        if lines[j]:match("^%s*###") then
          end_line = j - 1
          break
        end
      end
      blocks[#blocks + 1] = { name = vim.trim(name), start_line = i, end_line = end_line }
    end
    i = i + 1
  end
  return blocks
end

--- First line of a block that looks like a request line (skips the `###`
--- header, comments, script markers and blank lines).
local function request_line_of(lines, start_line, end_line)
  for i = start_line, end_line do
    local t = vim.trim(lines[i] or "")
    if t ~= "" and not t:match("^#") and not t:match("^<") and not t:match("^>")
      and not t:match("^//") then
      return t
    end
  end
  return nil
end

--- method, path of a block's request line; path is nil for headerless lines
--- like `SCRIPT`. Returns nils when the block has no request line.
--- @param lines string[]
--- @param start_line number
--- @param end_line number
--- @return string|nil method, string|nil path
function M.method_path(lines, start_line, end_line)
  local t = request_line_of(lines, start_line, end_line)
  if not t then return nil, nil end
  local method, path = t:match("^(%S+)%s+(%S+)")
  if method then return method:upper(), path end
  return t:match("^(%S+)"), nil
end

--- method (uppercased) of the first request line in raw block text.
--- @param text string
--- @return string|nil
function M.method_of_text(text)
  if type(text) ~= "string" then return nil end
  local lines = vim.split(text, "\n", { plain = true })
  local method = M.method_path(lines, 1, #lines)
  return method
end

--- Human title for raw block text: "METHOD path", bare method, or a fallback.
--- @param text string
--- @param fallback string|nil
--- @return string
function M.title_of_text(text, fallback)
  local lines = vim.split(text or "", "\n", { plain = true })
  local method, path = M.method_path(lines, 1, #lines)
  if method and path then return method .. " " .. path end
  if method then return method end
  return fallback or "AI request"
end

--- All named request blocks in content:
--- { { name, start_line, end_line, method, path } }
--- @param content string
--- @return table[]
function M.list_requests(content)
  local lines = vim.split(content or "", "\n", { plain = true })
  local out = {}
  for _, b in ipairs(list_block_bounds(lines)) do
    local method, path = M.method_path(lines, b.start_line, b.end_line)
    out[#out + 1] = {
      name = b.name,
      start_line = b.start_line,
      end_line = b.end_line,
      method = method,
      path = path,
    }
  end
  return out
end

--- Raw text (header line included) of a block. Trailing blank separator
--- lines (part of the block's bounds) are excluded.
--- @param lines string[]
--- @param block table { start_line, end_line }
--- @return string
function M.block_text(lines, block)
  local end_line = block.end_line
  while end_line > block.start_line and vim.trim(lines[end_line] or "") == "" do
    end_line = end_line - 1
  end
  return table.concat(lines, "\n", block.start_line, end_line)
end

--- The block containing a 1-indexed line, or nil.
--- @param blocks table[]
--- @param line number|nil
--- @return table|nil
function M.block_at_line(blocks, line)
  if not line then return nil end
  for _, b in ipairs(blocks or {}) do
    if line >= b.start_line and line <= b.end_line then return b end
  end
  return nil
end

--- Exact-name lookup.
--- @param blocks table[]
--- @param name string
--- @return table|nil
function M.find_block(blocks, name)
  for _, b in ipairs(blocks or {}) do
    if b.name == name then return b end
  end
  return nil
end

--- Raw text of the block containing a 1-indexed line, or nil.
--- @param content string
--- @param line number|nil
--- @return string|nil
function M.block_text_at_line(content, line)
  local lines = vim.split(content or "", "\n", { plain = true })
  local block = M.block_at_line(M.list_requests(content), line)
  if not block then return nil end
  return M.block_text(lines, block)
end

--- Request names referenced via {{Name.response.*}} / {{Name.request.*}},
--- sorted, deduplicated. Mirrors request_deps.split_request_ref's grammar:
--- the name is EVERYTHING before `.response.`/`.request.` (block names may
--- carry spaces or dots), and `.res.` normalizes to `.response.` — a
--- divergence here would drop deps from the chat context the executor
--- still runs.
--- @param text string
--- @return string[]
function M.dep_names(text)
  local seen = {}
  if type(text) == "string" then
    for inner in text:gmatch("{{(.-)}}") do
      local ref = (inner:gsub("%.res%.", ".response."))
      local rpos = ref:find(".response.", 1, true)
      local qpos = ref:find(".request.", 1, true)
      local pos = math.max(rpos or 0, qpos or 0)
      if pos > 1 then
        local name = vim.trim(ref:sub(1, pos - 1))
        if name ~= "" then seen[name] = true end
      end
    end
  end
  local names = {}
  for n in pairs(seen) do names[#names + 1] = n end
  table.sort(names)
  return names
end

--- Cap text at max_chars bytes with an ellipsis note. The cut backs off an
--- incomplete trailing UTF-8 sequence (CJK bodies are the norm here) so the
--- prompt never carries an invalid byte.
--- @param text string
--- @param max_chars number
--- @return string
function M.truncate(text, max_chars)
  if #text <= max_chars then return text end
  local head = text:sub(1, max_chars)
  -- Walk back over continuation bytes (10xxxxxx) to the last lead byte and
  -- keep it only when its whole sequence fits inside head; ASCII tails and
  -- complete sequences stay untouched.
  local i = #head
  while i > 0 and i > #head - 4 do
    local b = head:byte(i)
    if b < 0x80 then
      break -- ends on an ASCII byte: valid cut
    elseif b >= 0xC0 then
      local seq_len = (b >= 0xF0) and 4 or (b >= 0xE0) and 3 or 2
      if #head - i + 1 < seq_len then
        head = head:sub(1, i - 1) -- lead whose continuations were cut off
      end
      break
    end
    i = i - 1
  end
  return head .. "\n… (truncated)"
end

--- Resolve what the chat is talking about — the single stateful seam for
--- mentions / auto_context / ask prefill. Priority: scope `request` inside
--- scope `file`, then `state.last_request`'s block, then the current
--- poste_http buffer, then the scope file alone.
--- @param scope table|nil chat scope snapshot (keys: file, request, env)
--- @return table|nil focus { file, buf, line, content, lines, blocks, block, env }
function M.focus(scope)
  local state = require("poste-http.state")
  local file = scope and scope.file or nil
  local buf, line

  if not file then
    local lr = state.last_request
    if lr and lr.buf and vim.api.nvim_buf_is_valid(lr.buf) then
      buf = lr.buf
      line = lr.line
      file = vim.api.nvim_buf_get_name(lr.buf)
    end
  end
  if not file then
    local cur = vim.api.nvim_get_current_buf()
    if vim.bo[cur].filetype == "poste_http" then
      buf = cur
      line = vim.fn.line(".")
      file = vim.api.nvim_buf_get_name(cur)
    end
  end
  if not file then return nil end
  if file == "" then
    -- unnamed buffer (e.g. a scratch); content still comes from the buffer
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
    file = "(scratch)"
  end

  local content
  if buf then
    content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  else
    local ok, read = pcall(vim.fn.readfile, file)
    if not ok or type(read) ~= "table" then return nil end
    content = table.concat(read, "\n")
  end

  local lines = vim.split(content, "\n", { plain = true })
  local blocks = M.list_requests(content)
  local block = nil
  if scope and scope.request then
    block = M.find_block(blocks, scope.request)
  end
  if not block then
    block = M.block_at_line(blocks, line)
  end
  return {
    file = file,
    buf = buf,
    line = line,
    content = content,
    lines = lines,
    blocks = blocks,
    block = block,
    env = state.current_env,
  }
end

M._test = {
  list_requests = M.list_requests,
  block_text = M.block_text,
  block_at_line = M.block_at_line,
  find_block = M.find_block,
  block_text_at_line = M.block_text_at_line,
  method_path = M.method_path,
  method_of_text = M.method_of_text,
  title_of_text = M.title_of_text,
  dep_names = M.dep_names,
  truncate = M.truncate,
}

return M
