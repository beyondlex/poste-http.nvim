--- Visual statement boundary indicator.
--- Highlights the current SQL statement with a background extmark
--- as the cursor moves, giving clear visual feedback of execution scope.
local state = require("poste.state")

local M = {}

local ns = vim.api.nvim_create_namespace("poste_sql_stmt_boundary")
local _debounce_timer = nil
local _prev_mark_ids = nil
local _prev_buf = nil
local _disabled = false
local _job_id = nil

local DEBOUNCE_MS = 50

local function clear_prev()
  if _prev_buf and vim.api.nvim_buf_is_valid(_prev_buf) and _prev_mark_ids then
    for _, id in ipairs(_prev_mark_ids) do
      pcall(vim.api.nvim_buf_del_extmark, _prev_buf, ns, id)
    end
  end
  _prev_mark_ids = nil
  _prev_buf = nil
end

local function apply_range(buf, start_line, end_line)
  clear_prev()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local marks = {}
  for line = start_line, end_line do
    local char
    if start_line == end_line then
      char = "─"
    elseif line == start_line then
      char = "┌"
    elseif line == end_line then
      char = "└"
    else
      char = "│"
    end
    local id = vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
      sign_text = char,
      sign_hl_group = "PosteSqlBoundaryBorder",
      priority = 55,
    })
    table.insert(marks, id)
  end
  _prev_mark_ids = marks
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

--- Try to get statement boundaries from the Rust binary (async).
--- Calls callback with (start_line, end_line) as 1-based buffer line numbers, or nil.
local function try_rust_span(lines, cursor_line, callback)
  local binary = state.find_poste_binary()
  if not binary then callback(nil); return end

  local block_start, block_end = find_block(lines, cursor_line)
  local block_lines = {}
  for i = block_start, block_end do
    block_lines[#block_lines + 1] = lines[i] or ""
  end
  local rel_cursor = cursor_line - block_start -- 0-based within block

  local cmd = string.format("%s context stmt %d", vim.fn.shellescape(binary), rel_cursor)
  local input = table.concat(block_lines, "\n")

  local stdout = {}
  local job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do stdout[#stdout + 1] = line end
      end
    end,
    on_exit = function(_, exit_code)
      _job_id = nil
      if exit_code ~= 0 then callback(nil); return end
      local output = table.concat(stdout, "\n")
      local ok, parsed = pcall(vim.json.decode, output)
      if not ok or type(parsed) ~= "table" then callback(nil); return end
      local rs = parsed.start_line
      local re = parsed.end_line
      if type(rs) ~= "number" or type(re) ~= "number" then callback(nil); return end
      callback(block_start + rs, block_start + re)
    end,
  })

  if job_id > 0 then
    _job_id = job_id
    vim.fn.chansend(job_id, input)
    vim.fn.chanclose(job_id, "stdin")
  else
    callback(nil)
  end
end

local function fetch_and_highlight(buf, cursor_line)
  if not vim.api.nvim_buf_is_valid(buf) then return end

  local total = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, total, false)

  if _job_id then
    pcall(vim.fn.jobstop, _job_id)
    _job_id = nil
  end

  try_rust_span(lines, cursor_line, function(s, e)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if not s or not e then return end

    if s == e then
      local line_text = lines[s] or ""
      if line_text:match("^%s*$") then
        clear_prev()
        return
      end
    end

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
  end)
end

--- Update the statement indicator for a buffer and cursor line.
--- Debounced: repeated calls within DEBOUNCE_MS reset the timer.
--- @param buf number Buffer handle
--- @param cursor_line number 1-based cursor line
function M.update(buf, cursor_line)
  if _disabled then return end
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
  if _job_id then
    pcall(vim.fn.jobstop, _job_id)
    _job_id = nil
  end
  if buf then
    clear_prev()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  else
    clear_prev()
  end
end

function M.toggle()
  _disabled = not _disabled
  if _disabled then
    M.clear()
    vim.notify("SQL boundary highlight: OFF", vim.log.levels.INFO, { title = "Poste" })
  else
    vim.notify("SQL boundary highlight: ON", vim.log.levels.INFO, { title = "Poste" })
  end
end

vim.api.nvim_create_user_command("PosteSQLBoundary", function()
  require("poste.sql.statement_indicator").toggle()
end, { desc = "Toggle SQL statement boundary highlight" })

return M
