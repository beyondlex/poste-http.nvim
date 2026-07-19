--- Dataset UI Header Mode Prototype.
--- Three modes:
---   "winbar"  (default) — sticky header via winbar, header removed from buffer
---   "extmark" — header stays in buffer; virt_lines_above sticks it to window top
---   "float"   — floating window anchored to dataset window top
---
--- Usage:  :lua require('poste.sql.prototype').set_mode("extmark")
---         :lua require('poste.sql.prototype').set_mode("float")
---         :lua require('poste.sql.prototype').cycle()

local state = require("poste.state")

local M = {}

----------------------------------------------------------------------------
-- Mode switching
----------------------------------------------------------------------------

function M.set_mode(mode)
  assert(mode == "winbar" or mode == "extmark" or mode == "float",
    "mode must be winbar, extmark, or float")
  state.sql.header_mode = mode
  vim.notify("Dataset header mode: " .. mode, vim.log.levels.INFO, { title = "Poste Proto" })
end

function M.get_mode()
  return state.sql.header_mode or "winbar"
end

function M.cycle()
  local modes = { "winbar", "extmark", "float" }
  local cur = M.get_mode()
  local next_idx = 1
  for i, m in ipairs(modes) do
    if m == cur then next_idx = i % #modes + 1; break end
  end
  M.set_mode(modes[next_idx])
end

----------------------------------------------------------------------------
-- Extmark-based sticky header
----------------------------------------------------------------------------

local sticky_ns = vim.api.nvim_create_namespace("poste_sql_sticky_header")

local function clear_sticky_header()
  -- Clear sticky header from any buffer that has it
  pcall(vim.api.nvim_buf_clear_namespace, -1, sticky_ns, 0, -1)
end

--- On WinScrolled for extmark mode: place virt_lines_above on w0 when
--- the real header has scrolled off-screen. With extmark mode the header
--- stays in the buffer; virt_lines scroll with the buffer horizontally,
--- so no horizontal scroll sync is needed.
local function update_sticky_header(win, meta, header_text)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  if not header_text then clear_sticky_header(); return end
  if not meta or meta.type ~= "resultset" then return end

  local buf = vim.api.nvim_win_get_buf(win)

  local w0 = vim.api.nvim_win_call(win, function()
    return vim.fn.line("w0")
  end)

  local real_header_line = meta.real_header_line or 1

  if w0 <= real_header_line then
    clear_sticky_header()
    return
  end

  local text = header_text
  -- virt_lines expects list of rows, each row is list of {text, hl_group} chunks
  local row_parts = {}
  row_parts[#row_parts + 1] = { text, "PosteSqlHeader" }

  vim.api.nvim_buf_clear_namespace(buf, sticky_ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, sticky_ns, w0 - 1, 0, {
    virt_lines = { row_parts },
    virt_lines_above = true,
    priority = 250,
  })
end

----------------------------------------------------------------------------
-- Float-based header
----------------------------------------------------------------------------

local float_state = { buf = nil, win = nil }

local function close_header_float()
  if float_state.win and vim.api.nvim_win_is_valid(float_state.win) then
    pcall(vim.api.nvim_win_close, float_state.win, true)
  end
  if float_state.buf and vim.api.nvim_buf_is_valid(float_state.buf) then
    pcall(vim.api.nvim_buf_delete, float_state.buf, { force = true })
  end
  float_state.win = nil
  float_state.buf = nil
end

--- Build a window-width slice of the header text, aligned with data rows.
--- The data buffer has LEFT_PADDING spaces prepended to every line; we
--- do the same to the header so float content matches buffer content exactly.
--- The index maps display positions of the padded_header (padding + plain).
local function slice_header_to_win(header_leftcol, win_width, padded_header, header_index)
  if not padded_header or not header_index then return " " end
  local right_edge = header_leftcol + win_width

  local parts = {}
  for _, c in ipairs(header_index) do
    if c.de <= header_leftcol then goto continue end
    if c.ds >= right_edge then break end

    local text
    if c.ds < header_leftcol then
      text = string.rep(" ", math.min(c.de, right_edge) - header_leftcol)
    elseif c.de > right_edge then
      text = string.rep(" ", right_edge - c.ds)
    else
      text = padded_header:sub(c.bs, c.be)
    end
    parts[#parts + 1] = text

    ::continue::
  end

  if #parts == 0 then return " " end
  return table.concat(parts)
end

function M._create_header_float(dataset_win, plain_header)
  close_header_float()

  if not dataset_win or not vim.api.nvim_win_is_valid(dataset_win) then return end
  if not plain_header then return end

  local win_width = vim.api.nvim_win_get_width(dataset_win)
  if win_width <= 0 then return end

  local leftcol = vim.api.nvim_win_call(dataset_win, function()
    return vim.fn.winsaveview().leftcol
  end)

  -- Build an index from the padded header (padding + plain) so that leftcol
  -- from the window maps directly (buffer lines have the same padding).
  local padded_header = "  " .. plain_header
  local buffer_sql = require("poste.sql.buffer")
  local index = buffer_sql._build_header_index(padded_header)
  local text = slice_header_to_win(leftcol, win_width, padded_header, index)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = dataset_win,
    row = 0,
    col = 0,
    width = win_width,
    height = 1,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 60,
  })

  vim.wo[win].winhighlight = "Normal:PosteSqlHeader"

  float_state.buf = buf
  float_state.win = win
end

function M._update_header_float(dataset_win, plain_header)
  if not float_state.win or not vim.api.nvim_win_is_valid(float_state.win) then
    M._create_header_float(dataset_win, plain_header)
    return
  end
  if not plain_header then return end
  if not dataset_win or not vim.api.nvim_win_is_valid(dataset_win) then return end

  local win_width = vim.api.nvim_win_get_width(dataset_win)
  local leftcol = vim.api.nvim_win_call(dataset_win, function()
    return vim.fn.winsaveview().leftcol
  end)

  local padded_header = "  " .. plain_header
  local buffer_sql = require("poste.sql.buffer")
  local index = buffer_sql._build_header_index(padded_header)
  local text = slice_header_to_win(leftcol, win_width, padded_header, index)

  vim.bo[float_state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(float_state.buf, 0, -1, false, { text })
  vim.bo[float_state.buf].modifiable = false
end

----------------------------------------------------------------------------
-- Exposed hooks (called from buffer.lua)
----------------------------------------------------------------------------

function M._on_win_scrolled(win, meta, header_text)
  local mode = M.get_mode()
  if mode == "extmark" then
    update_sticky_header(win, meta, header_text)
  elseif mode == "float" then
    M._update_header_float(win, header_text)
  end
end

function M._on_close()
  clear_sticky_header()
  close_header_float()
end

-- Init default
if state.sql.header_mode == nil then
  state.sql.header_mode = "winbar"
end

return M
