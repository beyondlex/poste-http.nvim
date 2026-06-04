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

  -- ─── Sort by current column ────────────────────
  vim.keymap.set("n", "s", function() M.sort_by_current_col() end, opts)

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

--- Jump to header row. With sticky header (winbar), the header is always
--- visible at the top; this scrolls the data view to the first row.
function M.goto_header()
  M.goto_first_row()
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
--- Uses lazy horizontal scrolling: only scrolls when the cursor approaches
--- the window edge, and stops scrolling when the last column is fully visible.
--- @param row number 1-based data row index
--- @param col number 1-based column index
function M.position_cursor(row, col)
  if not current_meta or not dataset_window then return end
  if not vim.api.nvim_win_is_valid(dataset_window) then return end

  local line_idx = (current_meta.data_start_line or 1) + row - 1
  local buf = vim.api.nvim_win_get_buf(dataset_window)

  -- Compute target byte offset from the actual buffer line
  -- +1 offset: visual column 1 is the row number column
  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  local range = sql_highlights.find_cell_range(line, col + 1)
  local target_col = range and range.cursor_col or 0

  -- Read current view state BEFORE touching cursor/scroll
  local saved_leftcol = vim.api.nvim_win_call(dataset_window, function()
    return vim.fn.winsaveview().leftcol
  end)
  local win_width = vim.api.nvim_win_get_width(dataset_window)

  -- Check if target byte offset is within the currently visible range.
  -- A right margin triggers scrolling slightly before the cursor leaves
  -- the window, giving a smoother experience.
  local left_margin = 2
  local right_margin = 3
  local target_on_screen = target_col >= math.max(0, saved_leftcol - left_margin)
    and target_col < saved_leftcol + win_width - right_margin

  -- Check if the last column is fully visible in the CURRENT view.
  -- If so, there's no more data to the right — scrolling is pointless.
  -- +1 offset: visual column includes row number column
  local last_col = current_meta.col_count or 0
  local last_col_fits = true
  if last_col > 0 then
    local last_range = sql_highlights.find_cell_range(line, last_col + 1)
    if last_range then
      -- Screen position of the last column's right edge
      local last_right_screen = last_range.ext_end - saved_leftcol
      last_col_fits = last_right_screen <= win_width
    end
  end

  -- Set cursor (may trigger Neovim auto-scroll if target is off-screen)
  pcall(vim.api.nvim_win_set_cursor, dataset_window, { line_idx, target_col })

  -- Decide whether to adjust horizontal scroll
  if target_on_screen then
    -- Target cell was already visible — restore original scroll position.
    -- This prevents the "jump to left edge" behavior on every l press.
    -- Temporarily disable sidescrolloff to prevent it from re-scrolling
    -- after we restore the view.
    local saved_sso = vim.api.nvim_get_option_value("sidescrolloff", { win = dataset_window })
    vim.api.nvim_set_option_value("sidescrolloff", 0, { win = dataset_window })
    pcall(vim.api.nvim_win_call, dataset_window, function()
      local v = vim.fn.winsaveview()
      v.leftcol = saved_leftcol
      vim.fn.winrestview(v)
    end)
    vim.api.nvim_set_option_value("sidescrolloff", saved_sso, { win = dataset_window })
  else
    -- Target is off-screen, need to scroll
    if last_col_fits then
      -- Last column is fully visible: no more data to reveal.
      -- Keep Neovim's auto-scroll (minimal shift to show the cell).
      -- Do NOT use zs — that would create empty space on the right.
    else
      -- More columns exist beyond the window: scroll with zs to bring
      -- the target cell to the left portion of the window.
      pcall(vim.api.nvim_win_call, dataset_window, function()
        vim.cmd("normal! zs")
      end)
    end
  end
end

---------------------------------------------------------------------------
-- Cell preview (K key)
---------------------------------------------------------------------------

--- Try to decode a string as JSON and pretty-print it.
--- Handles double-encoded JSON (string inside string).
--- @param s string
--- @return string|nil Pretty-printed text, or nil if not JSON
local function try_pretty_json(s)
  local ok, decoded = pcall(vim.json.decode, s)
  if ok and type(decoded) == "table" then
    return vim.inspect(decoded)
  end
  -- Handle double-encoded JSON: decoded result is itself a JSON string
  if ok and type(decoded) == "string" then
    local ok2, decoded2 = pcall(vim.json.decode, decoded)
    if ok2 and type(decoded2) == "table" then
      return vim.inspect(decoded2)
    end
  end
  return nil
end

--- Pretty-print a value for the preview popup.
--- Tables and JSON strings are expanded with vim.inspect for full readability.
--- @param val any The raw cell value
--- @return string text Pretty-printed text
--- @return string ft Filetype for syntax highlighting
local function pretty_print(val)
  -- NULL
  if val == nil or val == vim.NIL then
    return "(NULL)", "text"
  end

  -- Lua table (JSON/JSONB column decoded as nested object)
  if type(val) == "table" then
    return vim.inspect(val), "lua"
  end

  local s = tostring(val)

  -- String values: attempt JSON decode (handles JSONB stored as text,
  -- double-encoded JSON, or values with leading whitespace)
  if type(val) == "string" then
    local pretty = try_pretty_json(s)
    if pretty then
      return pretty, "lua"
    end
    -- Try after stripping leading whitespace
    local trimmed = s:match("^%s*(.*)")
    if trimmed ~= s then
      pretty = try_pretty_json(trimmed)
      if pretty then
        return pretty, "lua"
      end
    end
  end

  return s, "text"
end

--- Show a floating window with the full cell value.
--- Content is word-wrapped and scrollable for long values.
function M.preview_cell()
  if not current_meta or current_meta.type ~= "resultset" then return end

  local data = state.sql.last_dataset
  if not data or not data.results or #data.results == 0 then return end

  local res = data.results[1]
  local row = state.sql.cell.row
  local col = state.sql.cell.col

  if not res.rows or not res.rows[row] then return end
  local raw_val = res.rows[row][col]

  local text, ft = pretty_print(raw_val)

  -- Split into lines
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  -- Calculate dimensions: cap width, let wrap handle the rest
  local max_width = math.min(math.floor(vim.o.columns * 0.7), 120)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, max_width)

  -- Height: show up to 60% of screen, minimum 3 lines
  local max_height = math.floor(vim.o.lines * 0.6)
  local height = math.max(3, math.min(#lines + 1, max_height))

  local col_name = res.columns[col] and res.columns[col].name or "?"
  local border_label = string.format(" %s ", col_name)
  local row_info = string.format(" R%d ", row)

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].filetype = ft
  vim.bo[float_buf].modifiable = false

  local win_opts = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = border_label,
    title_pos = "left",
    footer = row_info,       -- Neovim 0.10+
    footer_pos = "right",    -- Neovim 0.10+
  }
  -- Try with title/footer; fall back to plain if unsupported (< 0.10)
  local ok, win = pcall(vim.api.nvim_open_win, float_buf, true, win_opts)
  if not ok then
    win_opts.title = nil
    win_opts.title_pos = nil
    win_opts.footer = nil
    win_opts.footer_pos = nil
    win = vim.api.nvim_open_win(float_buf, true, win_opts)
  end

  -- Enable wrapping and scrolling inside the float
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = false
  vim.wo[win].scrolloff = 1
  vim.wo[win].sidescrolloff = 0
  vim.wo[win].cursorline = true

  -- Scroll keymaps: j/k, d/u (half-page), g/G (top/bottom), space/bs (page)
  local scroll_opts = { buffer = float_buf, noremap = true, silent = true }
  vim.keymap.set("n", "j", "<C-e>", scroll_opts)
  vim.keymap.set("n", "k", "<C-y>", scroll_opts)
  vim.keymap.set("n", "d", "<C-d>", scroll_opts)
  vim.keymap.set("n", "u", "<C-u>", scroll_opts)
  vim.keymap.set("n", "g", "gg", scroll_opts)
  vim.keymap.set("n", "G", "G", scroll_opts)
  vim.keymap.set("n", "<Space>", "<C-f>", scroll_opts)
  vim.keymap.set("n", "<BS>", "<C-b>", scroll_opts)

  -- Close on q or Esc
  local close_fn = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close_fn, scroll_opts)
  vim.keymap.set("n", "<Esc>", close_fn, scroll_opts)
end

---------------------------------------------------------------------------
-- Yank cell value
---------------------------------------------------------------------------

--- Yank the current cell value to the default register and system clipboard.
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
  vim.fn.setreg('+', val)
  vim.notify(string.format('Yanked to clipboard: %s', val:sub(1, 50)), vim.log.levels.INFO, { title = "Poste SQL" })
end

---------------------------------------------------------------------------
-- Sort
---------------------------------------------------------------------------

--- Sort state: { col, ascending } or nil (unsorted)
local sort_state = nil

--- Original row order for resetting sort
local original_rows = nil

--- Flag: true when render_dataset is called from sort (preserves sort state)
local is_sorting = false

--- Sort the dataset by the current column.
--- Cycle: ascending -> descending -> reset (original order) -> ascending ...
function M.sort_by_current_col()
  if not current_meta or current_meta.type ~= "resultset" then return end

  local data = state.sql.last_dataset
  if not data or not data.results or #data.results == 0 then return end

  local res = data.results[1]
  if not res.rows or #res.rows == 0 then return end

  local col = state.sql.cell.col

  -- Determine next sort state: asc -> desc -> reset -> asc
  local ascending, is_reset
  if not sort_state or sort_state.col ~= col then
    -- New column: start ascending
    ascending = true
    is_reset = false
  elseif sort_state.ascending then
    -- Same column, was ascending: go descending
    ascending = false
    is_reset = false
  else
    -- Same column, was descending: reset to original order
    is_reset = true
  end

  if is_reset then
    -- Restore original order
    res.rows = original_rows
    sort_state = nil
  else
    sort_state = { col = col, ascending = ascending }

    -- Save original rows on first sort
    if not original_rows then
      original_rows = {}
      for i, row in ipairs(res.rows) do
        original_rows[i] = row
      end
    end

    -- Sort rows in place (preserves references)
    table.sort(res.rows, function(a, b)
      local va = a[col]
      local vb = b[col]

      -- Handle NULLs: always at the end
      local a_nil = (va == nil or va == vim.NIL)
      local b_nil = (vb == nil or vb == vim.NIL)
      if a_nil and b_nil then return false end
      if a_nil then return false end
      if b_nil then return true end

      -- Compare by type
      local ta = type(va)
      local tb = type(vb)

      -- Numbers: numeric comparison
      if ta == "number" and tb == "number" then
        if ascending then
          return va < vb
        else
          return va > vb
        end
      end

      -- Booleans
      if ta == "boolean" and tb == "boolean" then
        if ascending then
          return not va and vb  -- false < true
        else
          return va and not vb  -- true > false
        end
      end

      -- Fallback: string comparison
      local sa = tostring(va)
      local sb = tostring(vb)
      if ascending then
        return sa < sb
      else
        return sa > sb
      end
    end)
  end

  -- Re-render (set is_sorting to preserve sort state)
  is_sorting = true
  local new_data = vim.deepcopy(data)
  local lines, meta = sql_format.format_resultset(new_data)
  M.render_dataset(lines, meta)
  is_sorting = false

  -- Keep cursor at the same (row, col) position
  -- The data in this cell may have changed, but the position stays the same
  M.move_cell(0, 0)
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

  -- Reset sort state when loading a new dataset (not from sort re-render)
  if not is_sorting then
    original_rows = nil
    sort_state = nil
  end

  -- Store dataset JSON in state for cell access
  if meta and meta.type == "resultset" then
    local ok, data = pcall(vim.json.decode, state.last_response and state.last_response.body or "{}")
    if ok then
      state.sql.last_dataset = data
    end
  end

  -- Write lines (sanitize: nvim_buf_set_lines rejects items containing \n)
  local clean = {}
  for i, line in ipairs(lines) do
    if type(line) ~= "string" then line = tostring(line or "") end
    for seg in (line .. "\n"):gmatch("(.-)\n") do
      clean[#clean + 1] = seg
    end
  end

  -- Sticky header: extract header line for winbar, remove top border + header + separator from buffer.
  -- This keeps column names visible at the top while data rows scroll.
  local removed_lines = 0
  local winbar_text = nil
  if meta and meta.type == "resultset" and meta.header_line then
    local header_line = clean[meta.header_line]
    if header_line then
      -- Build winbar with sort indicators
      -- Split header by │, add ↑/↓ to sorted column, keep space in others
      local parts = vim.split(header_line, "│", { plain = true })
      local indicator = ""
      if sort_state and sort_state.col then
        indicator = sort_state.ascending and "↑" or "↓"
      end
      local winbar_parts = {}
      for i, part in ipairs(parts) do
        if part == "" then
          -- First/last empty parts (before first │ and after last │)
          winbar_parts[i] = part
        else
          -- Escape % in original column name for winbar
          local escaped_part = part:gsub("%%", "%%%%")
          -- Data cell: check if this is the sorted column
          -- parts[1] is empty, parts[2] is row number col, parts[3] is data col 1, etc.
          -- col_idx maps to data column index (1-based), row number col gets 0
          local col_idx = i - 2
          if sort_state and sort_state.col == col_idx and indicator ~= "" then
            -- Replace last space with indicator using different highlight group.
            -- In Lua gsub replacement, % is a special char (backreference),
            -- so use string concatenation instead of gsub for the marker.
            local trimmed = escaped_part:gsub(" $", "")
            winbar_parts[i] = trimmed .. "%#PosteSqlSortIndicator#" .. indicator .. "%#PosteSqlHeader#"
          else
            winbar_parts[i] = escaped_part
          end
        end
      end
      winbar_text = "%#PosteSqlHeader#" .. table.concat(winbar_parts, "│")

      -- Remove lines: top border (header_line - 1), header (header_line), separator (header_line + 1)
      table.remove(clean, meta.header_line + 1)  -- separator first (highest index)
      table.remove(clean, meta.header_line)       -- header
      table.remove(clean, meta.header_line - 1)   -- top border
      removed_lines = 3
      -- Adjust meta line numbers
      meta.header_line = nil  -- header is no longer in buffer
      meta.data_start_line = meta.data_start_line - removed_lines
      meta.data_end_line = meta.data_end_line - removed_lines
      if meta.meta_line then
        meta.meta_line = meta.meta_line - removed_lines
      end
    end
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, clean)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Apply highlights
  sql_highlights.apply_dataset_highlights(buf, clean, meta)

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

  -- Dataset window options: no wrapping, horizontal scroll
  vim.api.nvim_set_option_value("wrap", false, { win = dataset_window })
  vim.api.nvim_set_option_value("sidescrolloff", 5, { win = dataset_window })
  vim.api.nvim_set_option_value("cursorline", false, { win = dataset_window })
  vim.api.nvim_set_option_value("cursorcolumn", false, { win = dataset_window })
  vim.api.nvim_set_option_value("conceallevel", 0, { win = dataset_window })
  vim.api.nvim_set_option_value("number", false, { win = dataset_window })
  vim.api.nvim_set_option_value("relativenumber", false, { win = dataset_window })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = dataset_window })

  -- Set sticky header via winbar (Neovim 0.8+)
  if winbar_text then
    local ok, _ = pcall(vim.api.nvim_set_option_value, "winbar", winbar_text, { win = dataset_window })
    if not ok then
      -- Fallback: winbar not supported, header already removed from buffer — put it back
      -- This shouldn't happen on modern Neovim but just in case
      vim.api.nvim_set_option_value("winbar", "", { win = dataset_window })
    end
  else
    pcall(vim.api.nvim_set_option_value, "winbar", "", { win = dataset_window })
  end

  -- NOTE: Cell text color is handled by syntax group PosteDatasetCellText
  -- in syntax/poste_dataset.vim, NOT by extmarks. Extmarks always override
  -- syntax highlighting's fg, regardless of priority or hl_mode.

  -- Position cursor: only reset to (1,1) on fresh dataset load,
  -- not during sort re-render (sort handles its own cursor position)
  if not is_sorting then
    if meta and meta.type == "resultset" and meta.row_count > 0 then
      state.sql.cell.row = 1
      state.sql.cell.col = 1
      M.position_cursor(1, 1)
      sql_highlights.highlight_cell(buf, 1, 1, meta)
    else
      pcall(vim.api.nvim_win_set_cursor, dataset_window, { 1, 0 })
    end
  end

  -- Keep focus in the SQL file buffer (do NOT switch to dataset window)
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
