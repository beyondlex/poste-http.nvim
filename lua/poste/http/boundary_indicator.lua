local M = {}

local ns = vim.api.nvim_create_namespace("poste_http_boundary")
local _marks = {}
local _prev_buf = nil
local _timer = nil
local _gen = 0
local _disabled = false

local DEBOUNCE_MS = 50

local function clear_prev()
  if _prev_buf and vim.api.nvim_buf_is_valid(_prev_buf) then
    for _, id in ipairs(_marks) do
      pcall(vim.api.nvim_buf_del_extmark, _prev_buf, ns, id)
    end
  end
  _marks = {}
  _prev_buf = nil
end

local function apply_range(buf, start, stop)
  clear_prev()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for line = start, stop do
    local char
    if start == stop then char = "─"
    elseif line == start then char = "┌"
    elseif line == stop then  char = "└"
    else char = "│"
    end
    local id = vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
      sign_text = char,
      sign_hl_group = "PosteHttpBoundaryBorder",
      priority = 55,
    })
    table.insert(_marks, id)
  end
  _prev_buf = buf
end

local function find_block(lines, cursor)
  local start = nil
  for i = cursor, 1, -1 do
    if (lines[i] or ""):match("^###") then
      start = i
      break
    end
  end
  if not start then return nil, nil end

  local next_sep = #lines + 1
  for i = cursor + 1, #lines do
    if (lines[i] or ""):match("^###") then
      next_sep = i
      break
    end
  end

  local stop = nil
  for i = next_sep - 1, start, -1 do
    local trimmed = (lines[i] or ""):match("^%s*(.-)%s*$")
    if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%-%-") then
      stop = i
      break
    end
  end
  if not stop then stop = start end

  return start, stop
end

local function update(buf, cursor)
  if _disabled then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local total = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, total, false)
  local start, stop = find_block(lines, cursor)
  if not start then clear_prev(); return end
  apply_range(buf, start - 1, stop - 1)
end

function M.refresh(buf, cursor)
  if _disabled then return end
  _gen = _gen + 1
  local my_gen = _gen
  if _timer then _timer:stop(); _timer:close(); _timer = nil end
  _timer = vim.defer_fn(function()
    if my_gen ~= _gen then return end
    _timer = nil
    update(buf, cursor)
  end, DEBOUNCE_MS)
end

function M.clear(buf)
  if _timer then _timer:stop(); _timer:close(); _timer = nil end
  if buf then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
  clear_prev()
end

function M.toggle()
  _disabled = not _disabled
  if _disabled then
    M.clear()
    vim.notify("HTTP boundary highlight: OFF", vim.log.levels.INFO, { title = "Poste" })
  else
    vim.notify("HTTP boundary highlight: ON", vim.log.levels.INFO, { title = "Poste" })
  end
end

vim.api.nvim_create_user_command("PosteHttpBoundary", function()
  require("poste.http.boundary_indicator").toggle()
end, { desc = "Toggle HTTP request block boundary highlight" })

return M
