--- Visual statement boundary indicator.
--- Highlights the current SQL statement with a background extmark
--- as the cursor moves, giving clear visual feedback of execution scope.
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

local function fetch_and_highlight(buf, cursor_line)
  if not vim.api.nvim_buf_is_valid(buf) then return end

  local total = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, total, false)
  local cursor_line_0 = cursor_line - 1

  local stmt_start = 0
  local stmt_end = total - 1
  for i = cursor_line_0 - 1, 0, -1 do
    local line = lines[i + 1] or ""
    if line:find(";") then
      stmt_start = i + 1
      break
    end
  end
  for i = cursor_line_0 + 1, total - 1 do
    local line = lines[i + 1] or ""
    if line:find(";") then
      stmt_end = i
      break
    end
  end

  apply_range(buf, stmt_start, stmt_end)
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
