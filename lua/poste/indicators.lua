--- Request line detection and virtual-text status indicators (spinner/✓/✘).
local uv = vim.uv or vim.loop

local M = {}

local indicator_ns = vim.api.nvim_create_namespace("poste_indicator")
local indicator_mark = nil
local spinner_timer = nil
local spinner_gen = 0  -- generation counter to invalidate stale spinner callbacks

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---------------------------------------------------------------------------
-- Request block extraction
---------------------------------------------------------------------------

--- Extract the full request block from the buffer at the given line.
--- Returns { request_line = "GET ...", headers = { { "Key", "Value" }, ... } }.
function M.extract_request_block(buf, start_line)
  -- Walk backward to find ### separator
  local header_line = nil
  for i = start_line, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      header_line = i
      break
    end
  end
  if not header_line then return { request_line = "", headers = {} } end

  local total = vim.api.nvim_buf_line_count(buf)
  local request_line = nil
  local headers = {}

  for i = header_line + 1, total do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then break end  -- next block

    -- Skip comments (lines starting with # or --)
    if text:match("^%s*#") or text:match("^%s*%-%-") then
      -- skip
    elseif not request_line and text:match("%S") then
      -- First non-empty non-comment line is the request line
      request_line = text
    elseif request_line then
      -- After request line: headers until empty line, then body
      if text:match("^%s*$") then
        break  -- empty line = end of headers
      end
      local key, val = text:match("^([^:]+):%s*(.*)")
      if key then
        table.insert(headers, { vim.trim(key), vim.trim(val) })
      end
    end
  end

  return { request_line = request_line or "", headers = headers }
end

--- Find the request definition line: walk backward from `start_line` to
--- find the ### separator, then return the first non-empty, non-comment
--- line after it (the GET/POST/SET/etc line).
--- Returns (line_number_0indexed, nil) or (nil, nil) if not found.
function M.find_request_line(buf, start_line)
  -- Walk backward to find ### separator
  local header_line = nil
  for i = start_line, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      header_line = i
      break
    end
  end

  if not header_line then return nil end

  local total = vim.api.nvim_buf_line_count(buf)
  for i = header_line + 1, total do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then break end  -- next block
    if text:match("%S") and not text:match("^%s*#") and not text:match("^%s*%-%-") then
      return i - 1  -- 0-indexed for extmark
    end
  end

  return nil
end

--- Find the request block boundaries for a given cursor line.
--- Returns (start_line, end_line) as 1-indexed inclusive ranges.
--- A request block starts at ### and ends before the next ### or EOF.
function M.find_request_block_bounds(buf, cursor_line)
  local total = vim.api.nvim_buf_line_count(buf)

  -- Walk backward to find ###
  local start_line = nil
  for i = cursor_line, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      start_line = i
      break
    end
  end

  if not start_line then return nil, nil end

  -- Walk forward to find end of block (next ### or EOF)
  local end_line = total
  for i = start_line + 1, total do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      end_line = i - 1
      break
    end
  end

  return start_line, end_line
end

---------------------------------------------------------------------------
-- Status indicator (virtual text on the request line)
---------------------------------------------------------------------------

--- Place or update a virtual-text indicator on the request line.
--- status: "running" | "success" | "error"
--- latency_ms: optional, shown after ✓ on success
function M.set_indicator(buf, line_0, status, latency_ms, assertion_results)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if not line_0 then return end

  -- Invalidate any in-flight spinner callbacks
  spinner_gen = spinner_gen + 1
  local my_gen = spinner_gen

  -- Stop any running spinner
  if spinner_timer then
    pcall(function() spinner_timer:stop() end)
    spinner_timer:close()
    spinner_timer = nil
  end

  -- Clear all extmarks in this namespace on this buffer (clean slate)
  vim.api.nvim_buf_clear_namespace(buf, indicator_ns, 0, -1)
  indicator_mark = nil

  if status == "running" then
    local frame = 1
    local function update_spinner()
      if my_gen ~= spinner_gen then return end  -- stale callback
      if not vim.api.nvim_buf_is_valid(buf) then return end
      vim.api.nvim_buf_clear_namespace(buf, indicator_ns, 0, -1)
      indicator_mark = vim.api.nvim_buf_set_extmark(buf, indicator_ns, line_0, 0, {
        virt_text = { { " " .. spinner_frames[frame] .. " ", "PosteSpinner" } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
      frame = (frame % #spinner_frames) + 1
    end
    update_spinner()
    spinner_timer = uv.new_timer()
    spinner_timer:start(100, 100, vim.schedule_wrap(update_spinner))

  elseif status == "success" then
    local virt_text = { { " ✓ ", "PosteSuccess" } }
    if latency_ms and latency_ms > 0 then
      table.insert(virt_text, { string.format("%.2f ms", latency_ms), "PosteLatency" })
    end
    -- Add assertion results if present
    if assertion_results and assertion_results.total > 0 then
      if assertion_results.failed > 0 then
        table.insert(virt_text, {
          string.format("  ✘ %d/%d tests", assertion_results.failed, assertion_results.total),
          "PosteError",
        })
      else
        table.insert(virt_text, {
          string.format("  ✓ %d/%d tests", assertion_results.passed, assertion_results.total),
          "PosteSuccess",
        })
      end
    end
    indicator_mark = vim.api.nvim_buf_set_extmark(buf, indicator_ns, line_0, 0, {
      virt_text = virt_text,
      virt_text_pos = "eol",
      hl_mode = "combine",
    })

  elseif status == "error" then
    indicator_mark = vim.api.nvim_buf_set_extmark(buf, indicator_ns, line_0, 0, {
      virt_text = { { " ✘ ", "PosteError" } },
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
  end
end

return M
