--- `@req/<Name>` mention support for the AI chat — resolves to the raw request
--- block ({{var}} placeholders intact, never resolved values) from the focus
--- file or any open `.http` buffer.

local M = {}

local TOKEN = "^req/([%w%-_%.]+)$"
local MAX_CANDIDATES = 50

--- Classify a @token. Non-matches return nil so the generic chat falls back
--- to file mentions.
--- @param token string text after the @
--- @return table|nil { request = name }
function M.match(token)
  -- A non-match reads as "not a request mention" (the generic chat falls
  -- back to file mentions), so a non-string token degrades the same way
  -- instead of raising inside the :match.
  if type(token) ~= "string" then return nil end
  local name = token:match(TOKEN)
  if not name then return nil end
  return { request = name }
end

--- The chat scope snapshot, when poste-ai is loaded.
local function current_scope()
  local ok, poste_ai = pcall(require, "poste-ai")
  if ok and poste_ai.scope then return poste_ai.scope() end
  return nil
end

--- Content sources to search: the focus file first, then other loaded
--- `.http` buffers. Returns { { file, content } }.
--- @param scope table|nil chat scope snapshot
--- @return table[]
function M.sources(scope)
  local blocks_mod = require("poste-http.ai.blocks")
  local out = {}
  local seen = {}
  local focus = blocks_mod.focus(scope)
  if focus then
    out[#out + 1] = { file = focus.file, content = focus.content }
    seen[focus.file] = true
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].filetype == "poste_http" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and not seen[name] then
        local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
        if ok then
          out[#out + 1] = { file = name, content = table.concat(lines, "\n") }
          seen[name] = true
        end
      end
    end
  end
  return out
end

--- Pure seam: render a named block from content as markdown (nil + err when
--- the name is unknown).
--- @param name string
--- @param content string
--- @param file string
--- @return string|nil md, string|nil err
function M.resolve_from_content(name, content, file)
  local blocks_mod = require("poste-http.ai.blocks")
  local block = blocks_mod.find_block(blocks_mod.list_requests(content), name)
  if not block then return nil, ("request %q not found"):format(name) end
  local text = blocks_mod.block_text(vim.split(content, "\n", { plain = true }), block)
  return ("`%s:%d` — request `%s`:\n```http\n%s\n```"):format(file, block.start_line, block.name, text)
end

--- Completion candidates "req/<Name>" with "METHOD path" descriptions.
--- @param prefix string
--- @param cb function(candidates)
function M.complete(prefix, cb)
  local blocks_mod = require("poste-http.ai.blocks")
  local items = {}
  local seen = {}
  for _, src in ipairs(M.sources(current_scope())) do
    for _, b in ipairs(blocks_mod.list_requests(src.content)) do
      local label = "req/" .. b.name
      if not seen[label] and label:sub(1, #prefix) == prefix then
        seen[label] = true
        local desc = vim.trim(((b.method or "?") .. " " .. (b.path or "")))
        items[#items + 1] = { label = label, description = desc }
        if #items >= MAX_CANDIDATES then cb(items) return end
      end
    end
  end
  cb(items)
end

--- Resolve a mention ref into a markdown block (async per the contract).
--- @param ref table { request = name }
--- @param cb function(md, err)
function M.resolve(ref, cb)
  if not (type(ref) == "table" and type(ref.request) == "string") then
    cb(nil, "malformed request mention")
    return
  end
  for _, src in ipairs(M.sources(current_scope())) do
    local md = M.resolve_from_content(ref.request, src.content, src.file)
    if md then
      cb(md, nil)
      return
    end
  end
  cb(nil, ("request %q not found in open .http buffers — open its file or use /requests")
    :format(ref.request))
end

M._test = {
  match = M.match,
  resolve_from_content = M.resolve_from_content,
  sources = M.sources,
}

return M
