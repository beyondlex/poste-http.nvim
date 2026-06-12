--- Visual statement boundary indicator.
--- Highlights the current SQL statement with a background extmark
--- as the cursor moves, giving clear visual feedback of execution scope.
local state = require("poste.state")

local M = {}

local ns = vim.api.nvim_create_namespace("poste_sql_stmt_boundary")
local _debounce_timer = nil
local _prev_mark_id = nil
local _prev_buf = nil

local DEBOUNCE_MS = 50

local function clear_prev()
  if _prev_buf and vim.api.nvim_buf_is_valid(_prev_buf) and _prev_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, _prev_buf, ns, _prev_mark_id)
  end
  _prev_mark_id = nil
  _prev_buf = nil
end

local function apply_range(buf, start_line, end_line)
  clear_prev()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local total = vim.api.nvim_buf_line_count(buf)
  local s = math.max(0, start_line)
  local e = math.min(end_line, total - 1)
  if s > e then return end
  local end_col = #((vim.api.nvim_buf_get_lines(buf, e, e + 1, false) or {""})[1] or "")
  local mark_id = vim.api.nvim_buf_set_extmark(buf, ns, s, 0, {
    end_row = e,
    end_col = end_col,
    hl_group = "PosteSqlBoundary",
    priority = 50,
  })
  _prev_mark_id = mark_id
  _prev_buf = buf
end

--- Find the ###-block containing cursor_line (1-based).
local function find_block(lines, cursor_line)
  local start = 1
  for i = cursor_line, 1, -1 do
    if (lines[i] or ""):match("^###") then
      start = i + 1
      break
    end
  end
  local stop = #lines
  for i = cursor_line, #lines do
    if (lines[i] or ""):match("^###") and i > cursor_line then
      stop = i - 1
      break
    end
  end
  return start, stop
end

--- Try to get statement boundaries from the Rust binary.
--- Returns (start_line, end_line) as 1-based buffer line numbers, or nil.
local function try_rust_span(lines, cursor_line)
  local binary = state.find_poste_binary()
  if not binary then return nil end

  local block_start, block_end = find_block(lines, cursor_line)
  local block_lines = {}
  for i = block_start, block_end do
    block_lines[#block_lines + 1] = lines[i] or ""
  end
  local rel_cursor = cursor_line - block_start -- 0-based within block

  local cmd = string.format("%s context stmt %d", vim.fn.shellescape(binary), rel_cursor)
  local input = table.concat(block_lines, "\n")
  local output = vim.fn.system(cmd, input)
  if vim.v.shell_error ~= 0 then return nil end

  local ok, parsed = pcall(vim.json.decode, output)
  if not ok or type(parsed) ~= "table" then return nil end

  local rs = parsed.start_line
  local re = parsed.end_line
  if type(rs) ~= "number" or type(re) ~= "number" then return nil end

  return block_start + rs, block_start + re -- convert 0-based → 1-based
end

local function fetch_and_highlight(buf, cursor_line)
  if not vim.api.nvim_buf_is_valid(buf) then return end

  local total = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, total, false)

  -- Primary: Rust semantic boundary detection
  local s, e = try_rust_span(lines, cursor_line)
  if s and e then
    -- If the span is a single blank line, don't highlight
    if s == e then
      local line_text = lines[s] or ""
      if line_text:match("^%s*$") then
        clear_prev()
        return
      end
    end
    -- If the span contains only blanks and comments, don't highlight
    local has_content = false
    for i = s, e do
      local trimmed = (lines[i] or ""):match("^%s*(.*)$")
      if trimmed ~= "" and not trimmed:match("^%-%-") then
        has_content = true
        break
      end
    end
    if not has_content then
      clear_prev()
      return
    end
    apply_range(buf, s - 1, e - 1)
    return
  end

  -- Fallback: nothing — if the binary isn't available, just don't highlight
end

--- Update the statement indicator for a buffer and cursor line.
--- Debounced: repeated calls within DEBOUNCE_MS reset the timer.
--- @param buf number Buffer handle
--- @param cursor_line number 1-based cursor line
function M.update(buf, cursor_line)
  if _debounce_timer then
    _debounce_timer:stop()
    _debounce_timer:close()
    _debounce_timer = nil
  end

  _debounce_timer = vim.defer_fn(function()
    _debounce_timer = nil
    fetch_and_highlight(buf, cursor_line)
  end, DEBOUNCE_MS)
end

--- Clear the statement indicator for a buffer.
--- @param buf number|nil Buffer handle (nil = any)
function M.clear(buf)
  if _debounce_timer then
    _debounce_timer:stop()
    _debounce_timer:close()
    _debounce_timer = nil
  end
  if buf then
    clear_prev()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  else
    clear_prev()
  end
end

return M
