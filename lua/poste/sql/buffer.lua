--- SQL Dataset buffer — bottom horizontal split with cell-based navigation.
--- Inspired by JetBrains DataGrip's result grid, adapted for Vim motions.
local state = require("poste.state")
local sql_format = require("poste.sql.format")
local sql_highlights = require("poste.sql.highlights")

local M = {}

local dataset_buffer = nil
local dataset_window = nil

--- Current dataset state
local current_meta = nil
local current_lines = nil

---------------------------------------------------------------------------
-- Buffer creation
---------------------------------------------------------------------------

local function get_dataset_buffer()
  if dataset_buffer and vim.api.nvim_buf_is_valid(dataset_buffer) then
    return dataset_buffer
  end

  dataset_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = dataset_buffer })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = dataset_buffer })
  vim.api.nvim_set_option_value("swapfile", false, { buf = dataset_buffer })
  vim.api.nvim_set_option_value("modifiable", false, { buf = dataset_buffer })
  vim.api.nvim_buf_set_name(dataset_buffer, "poste://dataset")

  -- Dataset filetype for conceal and syntax
  vim.bo[dataset_buffer].filetype = "poste_dataset"

  local opts = { buffer = dataset_buffer, noremap = true, silent = true }

  -- ─── Close ───────────────────────────────────────
  vim.keymap.set("n", "q", function()
    M.close()
  end, opts)

  -- ─── Cell navigation (Vim-style) ────────────────
  vim.keymap.set("n", "h", function() M.move_cell(0, -1) end, opts)
  vim.keymap.set("n", "l", function() M.move_cell(0, 1) end, opts)
  vim.keymap.set("n", "j", function() M.move_cell(1, 0) end, opts)
  vim.keymap.set("n", "k", function() M.move_cell(-1, 0) end, opts)
  vim.keymap.set("n", "0", function() M.goto_first_col() end, opts)
  vim.keymap.set("n", "$", function() M.goto_last_col() end, opts)
  vim.keymap.set("n", "H", function() M.goto_header() end, opts)
  vim.keymap.set("n", "gg", function() M.goto_first_row() end, opts)
  vim.keymap.set("n", "G", function() M.goto_last_row() end, opts)

  -- ─── Cell preview ───────────────────────────────
  vim.keymap.set("n", "K", function() M.preview_cell() end, opts)

  -- ─── Yank cell value ───────────────────────────
  vim.keymap.set("n", "yy", function() M.yank_cell() end, opts)

  -- ─── Refresh ───────────────────────────────────
  vim.keymap.set("n", "R", function()
    -- Re-run the last SQL query
    vim.schedule(function()
      local init = require("poste.sql.init")
      init.run_sql_request()
    end)
  end, opts)

  return dataset_buffer
end

---------------------------------------------------------------------------
-- Cell navigation
---------------------------------------------------------------------------

--- Move cell by row/col delta.
--- @param drow number Row delta (+1 = down, -1 = up)
--- @param dcol number Column delta (+1 = right, -1 = left)
function M.move_cell(drow, dcol)
  if not current_meta or current_meta.type ~= "resultset" then return end

  local row = state.sql.cell.row + drow
  local col = state.sql.cell.col + dcol

  -- Clamp to valid range
  row = math.max(1, math.min(row, current_meta.row_count or 0))
  col = math.max(1, math.min(col, current_meta.col_count or 0))

  state.sql.cell.row = row
  state.sql.cell.col = col

  M.position_cursor(row, col)
  sql_highlights.highlight_cell(dataset_buffer, row, col, current_meta)
end

--- Jump to first column.
function M.goto_first_col()
  if not current_meta then return end
  state.sql.cell.col = 1
  M.position_cursor(state.sql.cell.row, 1)
  sql_highlights.highlight_cell(dataset_buffer, state.sql.cell.row, 1, current_meta)
end

--- Jump to last column.
function M.goto_last_col()
  if not current_meta then return end
  local last = current_meta.col_count or 1
  state.sql.cell.col = last
  M.position_cursor(state.sql.cell.row, last)
  sql_highlights.highlight_cell(dataset_buffer, state.sql.cell.row, last, current_meta)
end

--- Jump to header row (for column name visibility).
function M.goto_header()
  if not current_meta or not current_meta.header_line then return end
  if dataset_window and vim.api.nvim_win_is_valid(dataset_window) then
    pcall(vim.api.nvim_win_set_cursor, dataset_window, { current_meta.header_line, 0 })
  end
end

--- Jump to first data row.
function M.goto_first_row()
  if not current_meta then return end
  state.sql.cell.row = 1
  M.position_cursor(1, state.sql.cell.col)
  sql_highlights.highlight_cell(dataset_buffer, 1, state.sql.cell.col, current_meta)
end

--- Jump to last data row.
function M.goto_last_row()
  if not current_meta then return end
  local last = current_meta.row_count or 1
  state.sql.cell.row = last
  M.position_cursor(last, state.sql.cell.col)
  sql_highlights.highlight_cell(dataset_buffer, last, state.sql.cell.col, current_meta)
end

--- Position the cursor at the given data row and column.
--- @param row number 1-based data row index
--- @param col number 1-based column index
function M.position_cursor(row, col)
  if not current_meta or not dataset_window then return end
  if not vim.api.nvim_win_is_valid(dataset_window) then return end

  local line_idx = (current_meta.data_start_line or 1) + row - 1
  local col_pos = current_meta.col_positions and current_meta.col_positions[col] or 0

  pcall(vim.api.nvim_win_set_cursor, dataset_window, { line_idx, col_pos })
end

---------------------------------------------------------------------------
-- Cell preview (K key)
---------------------------------------------------------------------------

--- Show a floating window with the full cell value.
function M.preview_cell()
  if not current_meta or current_meta.type ~= "resultset" then return end

  local data = state.sql.last_dataset
  if not data or not data.results or #data.results == 0 then return end

  local res = data.results[1]
  local row = state.sql.cell.row
  local col = state.sql.cell.col

  if not res.rows or not res.rows[row] then return end
  local val = res.rows[row][col]

  if val == nil or val == vim.NIL then
    val = "(NULL)"
  elseif type(val) == "table" then
    local ok, encoded = pcall(vim.json.encode, val)
    val = ok and encoded or vim.inspect(val)
  else
    val = tostring(val)
  end

  -- Determine filetype for syntax highlighting
  local ft = "text"
  if type(res.rows[row][col]) == "table" then
    -- Try to detect JSON
    local ok, _ = pcall(vim.json.decode, val)
    if ok then ft = "json" end
  end

  -- Show floating preview
  local lines = {}
  for line in (val .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  width = math.min(width + 2, 80)
  local height = math.min(#lines, 20)

  local col_name = res.columns[col] and res.columns[col].name or "?"
  local border_label = string.format(" %s ", col_name)

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].filetype = ft
  vim.bo[float_buf].modifiable = false

  local win = vim.api.nvim_open_win(float_buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = border_label,
    title_pos = "center",
  })

  -- Close on q or Esc
  local close_opts = { buffer = float_buf, noremap = true, silent = true }
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, close_opts)
  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, close_opts)
end

---------------------------------------------------------------------------
-- Yank cell value
---------------------------------------------------------------------------

--- Yank the current cell value to the default register.
function M.yank_cell()
  if not current_meta or current_meta.type ~= "resultset" then return end

  local data = state.sql.last_dataset
  if not data or not data.results or #data.results == 0 then return end

  local res = data.results[1]
  local row = state.sql.cell.row
  local col = state.sql.cell.col

  if not res.rows or not res.rows[row] then return end
  local val = res.rows[row][col]

  if val == nil or val == vim.NIL then
    val = ""
  elseif type(val) == "table" then
    local ok, encoded = pcall(vim.json.encode, val)
    val = ok and encoded or vim.inspect(val)
  else
    val = tostring(val)
  end

  vim.fn.setreg('"', val)
  vim.notify(string.format('Yanked: %s', val:sub(1, 50)), vim.log.levels.INFO, { title = "Poste SQL" })
end

---------------------------------------------------------------------------
-- Render / Close
---------------------------------------------------------------------------

--- Render dataset lines in the bottom split.
--- @param lines string[] Lines to display
--- @param meta table Dataset metadata from format.lua
function M.render_dataset(lines, meta)
  local buf = get_dataset_buffer()
  current_meta = meta
  current_lines = lines

  -- Store dataset JSON in state for cell access
  if meta and meta.type == "resultset" then
    local ok, data = pcall(vim.json.decode, state.last_response and state.last_response.body or "{}")
    if ok then
      state.sql.last_dataset = data
    end
  end

  -- Write lines
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Conceal │ separators for clean grid look
  vim.wo.conceallevel = 2
  vim.wo.concealcursor = "nc"

  -- Apply highlights
  sql_highlights.apply_dataset_highlights(buf, lines, meta)

  -- Open bottom horizontal split
  if not dataset_window or not vim.api.nvim_win_is_valid(dataset_window) then
    local saved_win = vim.api.nvim_get_current_win()

    -- Bottom split: 40% of screen height
    local height = math.floor(vim.o.lines * 0.4)
    vim.cmd("botright " .. height .. "split")
    dataset_window = vim.api.nvim_get_current_win()

    vim.api.nvim_set_current_win(saved_win)
  end

  vim.api.nvim_win_set_buf(dataset_window, buf)

  -- Position cursor at first data cell
  if meta and meta.type == "resultset" and meta.row_count > 0 then
    state.sql.cell.row = 1
    state.sql.cell.col = 1
    M.position_cursor(1, 1)
    sql_highlights.highlight_cell(buf, 1, 1, meta)
  else
    pcall(vim.api.nvim_win_set_cursor, dataset_window, { 1, 0 })
  end

  -- Focus the dataset window
  vim.api.nvim_set_current_win(dataset_window)
end

--- Close the dataset split.
function M.close()
  if dataset_window and vim.api.nvim_win_is_valid(dataset_window) then
    vim.api.nvim_win_close(dataset_window, true)
    dataset_window = nil
  end
  sql_highlights.clear_cell_highlight(dataset_buffer)
end

--- Check if the dataset window is open.
function M.is_open()
  return dataset_window and vim.api.nvim_win_is_valid(dataset_window)
end

return M
