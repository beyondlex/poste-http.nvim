local cli = require("poste.cli")
local state = require("poste.state")

local M = {}

local ns = vim.api.nvim_create_namespace("poste_sql_stmt_boundary")
local _debounce_timer = nil
local _prev_buf = nil
local _disabled = false
local _job_id = nil

local DEBOUNCE_MS = 50

local function clear_all(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

local function apply_range(buf, start, stop)
  clear_all(_prev_buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    _prev_buf = nil
    return
  end
  clear_all(buf)
  for line = start, stop do
    local text
    if start == stop then text = "──"
    elseif line == start then text = "─┐"
    elseif line == stop then  text = "─┘"
    else text = " │"
    end
    vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
      virt_text = {{text, "PosteSqlBoundaryBorder"}},
      virt_text_pos = "right_align",
      priority = 100,
    })
  end
  _prev_buf = buf
end

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

local function try_rust_span(lines, cursor_line, callback)
  local block_start, block_end = find_block(lines, cursor_line)

  -- If cursor is on a separator line between blocks, bail out
  local last_content = nil
  for i = block_end, block_start, -1 do
    local trimmed = (lines[i] or ""):match("^%s*(.-)%s*$")
    if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%-%-") then
      last_content = i
      break
    end
  end
  if cursor_line > (last_content or block_start) then
    callback(nil)
    return
  end
  local block_lines = {}
  for i = block_start, block_end do
    block_lines[#block_lines + 1] = lines[i] or ""
  end
  local rel_cursor = cursor_line - block_start

  local input = table.concat(block_lines, "\n")
  local stdout = {}

  cli.run_async({ "context", "stmt", tostring(rel_cursor) }, {
    stdin = input,
    on_stdout = function(data)
      if data then
        for _, line in ipairs(data) do stdout[#stdout + 1] = line end
      end
    end,
    on_exit = function(exit_code)
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
        clear_all(_prev_buf)
        _prev_buf = nil
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
      clear_all(_prev_buf)
      _prev_buf = nil
      return
    end
    apply_range(buf, s - 1, e - 1)
  end)
end

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
  clear_all(buf)
  _prev_buf = nil
end

function M.toggle()
  _disabled = not _disabled
  if _disabled then
    M.clear(vim.api.nvim_get_current_buf())
    vim.notify("SQL boundary highlight: OFF", vim.log.levels.INFO, { title = "Poste" })
  else
    M.update(vim.api.nvim_get_current_buf(), vim.fn.line("."))
    vim.notify("SQL boundary highlight: ON", vim.log.levels.INFO, { title = "Poste" })
  end
end

vim.api.nvim_create_user_command("PosteSQLBoundary", function()
  require("poste.sql.statement_indicator").toggle()
end, { desc = "Toggle SQL statement boundary highlight" })

return M