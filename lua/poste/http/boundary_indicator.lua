local M = {}

local GROUP = "PosteHttpBoundary"
local _disabled = false
local _prev_buf = nil
local _prev_ids = {}
local _debug = false

local function log(fmt, ...)
  if not _debug then return end
  local msg = string.format("[PosteBoundary] " .. fmt, ...)
  vim.notify(msg, vim.log.levels.DEBUG, { title = "PosteBoundary" })
end

local function signs_on(buf)
  local ok, placed = pcall(vim.fn.sign_getplaced, buf, { group = GROUP })
  if not ok or not placed or not placed[1] or not placed[1].signs then return {} end
  return placed[1].signs
end

local function def_signs()
  pcall(vim.fn.sign_define, GROUP .. "_T", { text = "┌", texthl = "PosteHttpBoundaryBorder" })
  pcall(vim.fn.sign_define, GROUP .. "_B", { text = "└", texthl = "PosteHttpBoundaryBorder" })
  pcall(vim.fn.sign_define, GROUP .. "_M", { text = "│", texthl = "PosteHttpBoundaryBorder" })
  pcall(vim.fn.sign_define, GROUP .. "_S", { text = "─", texthl = "PosteHttpBoundaryBorder" })
end

local function sign_name(line, start, stop)
  if start == stop then return GROUP .. "_S" end
  if line == start then return GROUP .. "_T" end
  if line == stop  then return GROUP .. "_B" end
  return GROUP .. "_M"
end

local function clear_prev()
  if _prev_buf and vim.api.nvim_buf_is_valid(_prev_buf) then
    local before = #signs_on(_prev_buf)
    vim.fn.sign_unplace(GROUP, { buffer = _prev_buf })
    local after = #signs_on(_prev_buf)
    log("clear_prev: buf=%d signs %d->%d ids=%d", _prev_buf, before, after, #_prev_ids)
  else
    log("clear_prev: no prev_buf or invalid (buf=%s)", tostring(_prev_buf))
  end
  _prev_ids = {}
  _prev_buf = nil
end

local function apply_range(buf, start, stop)
  log("apply_range: buf=%d start=%d stop=%d", buf, start, stop)
  clear_prev()
  if not vim.api.nvim_buf_is_valid(buf) then
    log("apply_range: buf %d invalid, skip", buf)
    return
  end
  local before = #signs_on(buf)
  for line = start, stop do
    local id = vim.fn.sign_place(0, GROUP, sign_name(line, start, stop), buf,
      { lnum = line + 1, priority = 55 })
    log("  sign_place: line=%d type=%s id=%d", line, sign_name(line, start, stop), id)
    table.insert(_prev_ids, id)
  end
  local after = #signs_on(buf)
  log("apply_range: buf=%d signs %d->%d after placement", buf, before, after)
  _prev_buf = buf
  vim.cmd("redraw")
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
  log("update: buf=%d cursor=%d find_block=(%s,%s)", buf, cursor, tostring(start), tostring(stop))
  if not start then
    log("update: no block found, clearing")
    clear_prev()
    return
  end
  apply_range(buf, start - 1, stop - 1)
end

function M.refresh(buf, cursor)
  if _disabled then return end
  update(buf, cursor)
end

function M.clear(buf)
  if buf then
    local before = #signs_on(buf)
    vim.fn.sign_unplace(GROUP, { buffer = buf })
    local after = #signs_on(buf)
    log("clear: buf=%d signs %d->%d", buf, before, after)
  end
  _prev_ids = {}
  _prev_buf = nil
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

function M.enable_debug(enabled)
  _debug = enabled
  vim.notify("PosteBoundary debug: " .. (enabled and "ON" or "OFF"), vim.log.levels.INFO, { title = "PosteBoundary" })
end

def_signs()

vim.api.nvim_create_user_command("PosteHttpBoundary", function()
  require("poste.http.boundary_indicator").toggle()
end, { desc = "Toggle HTTP request block boundary highlight" })

return M