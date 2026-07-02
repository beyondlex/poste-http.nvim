local D = require("poste.sql.dataset")
local state = require("poste.state")
local sql_highlights = require("poste.sql.highlights")
local M = {}

local preview_win = nil
local raw_buffer = nil  -- scratch buffer for raw mode

-- Helper: get pre-computed column positions for a data row
local function get_col_starts(tab, row)
  if not tab or not tab.buffer_col_starts or not tab.meta then return nil end
  local line_idx = (tab.meta.data_start_line or 1) + row - 1
  return tab.buffer_col_starts[line_idx]
end

------------------------------------------------------------------------------
-- Trace helpers (opt-in via state.sql._trace)
------------------------------------------------------------------------------
local T_items = {}
local function T_clear() T_items = {} end
local function T_mark(label)
  if not state.sql._trace then return end
  T_items[#T_items + 1] = { label = label, t = vim.fn.reltime() }
end
local function T_report()
  if not state.sql._trace or #T_items == 0 then return end
  local t0 = T_items[1].t
  local total = vim.fn.reltimefloat(vim.fn.reltime(t0)) * 1000
  local lines = {}
  for i, ti in ipairs(T_items) do
    local step = i == 1 and 0 or vim.fn.reltimefloat(vim.fn.reltime(T_items[i - 1].t, ti.t)) * 1000
    local cum  = vim.fn.reltimefloat(vim.fn.reltime(t0, ti.t)) * 1000
    lines[#lines + 1] = string.format("  %s: %7.3fms (+%.3f)", ti.label, cum, step)
  end
  lines[#lines + 1] = string.format("  total: %7.3fms", total)
  local msg = table.concat(lines, "\n")
  T_clear()
  state.log("TRACE", "move_cell trace:\n" .. msg)
end

--- Truncate a string to fit within a given display width, preserving UTF-8 validity.
local function trunc_disp(s, max_dw)
  local dw = 0
  local i = 1
  while i <= #s do
    local b = s:byte(i)
    local char_byte_len = b < 128 and 1 or b < 224 and 2 or b < 240 and 3 or 4
    local char = s:sub(i, i + char_byte_len - 1)
    local char_dw = vim.fn.strdisplaywidth(char)
    if dw + char_dw > max_dw then break end
    dw = dw + char_dw
    i = i + char_byte_len
  end
  return s:sub(1, i - 1)
end

local function build_header_index(line)
  local sep = "│"
  local sep_len = #sep
  local index = {}
  local disp_pos = 0
  local byte_idx = 1
  while byte_idx <= #line do
    local char_bytes, char_width, is_sep
    if line:sub(byte_idx, byte_idx + sep_len - 1) == sep then
      char_bytes, char_width, is_sep = sep_len, 1, true
    else
      local b = line:byte(byte_idx)
      if b < 0x80 then char_bytes = 1
      elseif b < 0xE0 then char_bytes = 2
      elseif b < 0xF0 then char_bytes = 3
      else char_bytes = 4
      end
      if byte_idx + char_bytes - 1 > #line then char_bytes = #line - byte_idx + 1 end
      char_width = char_bytes == 1 and 1
        or vim.fn.strdisplaywidth(line:sub(byte_idx, byte_idx + char_bytes - 1))
      if char_width == 0 then char_width = 1 end
      is_sep = false
    end
    index[#index + 1] = { bs=byte_idx, be=byte_idx+char_bytes-1,
                          ds=disp_pos, de=disp_pos+char_width, sep=is_sep }
    disp_pos = disp_pos + char_width
    byte_idx = byte_idx + char_bytes
  end
  return index
end
M.build_header_index = build_header_index

local function slice_header_to_win(leftcol, win_width, padded_header, index)
  if not padded_header or not index then return D.PADDING_SPACES end
  local right_edge = leftcol + win_width

  local parts = {}
  for _, c in ipairs(index) do
    if c.de <= leftcol then goto continue end
    if c.ds >= right_edge then break end

    local text
    if c.ds < leftcol then
      text = string.rep(" ", math.min(c.de, right_edge) - leftcol)
    elseif c.de > right_edge then
      text = string.rep(" ", right_edge - c.ds)
    else
      text = padded_header:sub(c.bs, c.be)
    end
    parts[#parts + 1] = text

    ::continue::
  end

  if #parts == 0 then return D.PADDING_SPACES end
  return table.concat(parts)
end

--- Slice header using pre-computed column positions (O(#visible_cols), no strdisplaywidth).
--- @param leftcol number Display-width offset of viewport left edge
--- @param win_width number Viewport width in display columns
--- @param padded_header string Header line with padding (includes D.LEFT_PADDING)
--- @param header_col_starts table[] Pre-computed column positions with disp_start/disp_end
--- @return string Sliced header text
function M.slice_header_by_col_starts(leftcol, win_width, padded_header, header_col_starts)
  if not padded_header or not header_col_starts then return D.PADDING_SPACES end
  local right_edge = leftcol + win_width

  -- Handle the 2-space left padding (display positions 0-1) before first │
  local parts = {}
  if leftcol < D.LEFT_PADDING then
    local pad_start = math.max(leftcol, 0)
    local pad_end = math.min(D.LEFT_PADDING, right_edge)
    local pad_width = pad_end - pad_start
    if pad_width > 0 then
      parts[#parts + 1] = string.rep(" ", pad_width)
    end
  end

  local last_fully_visible_idx
  local has_partial_right = false

  for i, cell in ipairs(header_col_starts) do
    if cell.disp_end <= leftcol then goto continue end
    if cell.disp_start > right_edge then break end

    local text
    if cell.disp_start < leftcol then
      text = string.rep(" ", math.min(cell.disp_end, right_edge) - leftcol)
    elseif cell.disp_end > right_edge then
      -- Partially visible on right: show │ + as much content as fits
      local seg_start
      if i == 1 then
        seg_start = D.LEFT_PADDING
      else
        seg_start = header_col_starts[i - 1].ext_end
      end
      local full_cell = padded_header:sub(seg_start + 1, cell.ext_end)
      local visible_dw = right_edge - cell.disp_start + 1
      if visible_dw > 0 then
        text = trunc_disp(full_cell, visible_dw)
        has_partial_right = true
      end
    else
      -- Fully visible: extract │ before this cell + content (no trailing │)
      local seg_start
      if i == 1 then
        seg_start = D.LEFT_PADDING  -- first │ at byte 2
      else
        seg_start = header_col_starts[i - 1].ext_end  -- byte of │ between cols
      end
      text = padded_header:sub(seg_start + 1, cell.ext_end)
      last_fully_visible_idx = i
    end
    if text then
      parts[#parts + 1] = text
    end

    ::continue::
  end

  -- Add trailing │ when last visible column is fully visible (no partial-right column)
  if last_fully_visible_idx and not has_partial_right then
    local last_cell = header_col_starts[last_fully_visible_idx]
    parts[#parts + 1] = padded_header:sub(last_cell.ext_end + 1, last_cell.ext_end + 3)
  end

  if #parts == 0 then return D.PADDING_SPACES end
  return table.concat(parts)
end

function M.update_header_float()
  local tab = D.T()
  if not tab or not tab.header_text or not D.dataset_window then T_mark("  hdr:early_exit"); return end
  if not vim.api.nvim_win_is_valid(D.dataset_window) then T_mark("  hdr:early_exit"); return end
  if state.sql._hide_header_float then D.close_header_float(); return end

  T_mark("  hdr:win_width")
  local win_width = vim.api.nvim_win_get_width(D.dataset_window)
  if win_width <= 0 then return end

  T_mark("  hdr:winsaveview")
  local leftcol
  if vim.api.nvim_get_current_win() == D.dataset_window then
    leftcol = vim.fn.winsaveview().leftcol
  else
    leftcol = vim.api.nvim_win_call(D.dataset_window, function()
      return vim.fn.winsaveview().leftcol
    end)
  end

  T_mark("  hdr:cache_check")
  if leftcol == D._float_cache_leftcol and win_width == D._float_cache_width
     and tab.header_text == D._float_cache_header then
    T_mark("  hdr:cached")
    return
  end

  D._float_cache_leftcol = leftcol
  D._float_cache_width = win_width
  D._float_cache_header = tab.header_text

  T_mark("  hdr:slice_to_win")
  local padded = "  " .. tab.header_text
  local text
  if tab.header_col_starts then
    text = M.slice_header_by_col_starts(leftcol, win_width, padded, tab.header_col_starts)
  else
    local index = tab.header_index or build_header_index(padded)
    text = slice_header_to_win(leftcol, win_width, padded, index)
  end

  local float_buf = D.float_buf
  local float_win = D.float_win

  if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
    T_mark("  hdr:set_lines")
    vim.api.nvim_set_option_value("modifiable", true, { buf = float_buf })
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { text })
    vim.api.nvim_set_option_value("modifiable", false, { buf = float_buf })
    T_mark("  hdr:set_config")
    if float_win and vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_set_config(float_win, { width = win_width })
      T_mark("  hdr:done")
      return
    end
  end

  T_mark("  hdr:create_float")
  D.close_header_float()
  D.float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[D.float_buf].buftype = "nofile"
  vim.bo[D.float_buf].bufhidden = "wipe"
  vim.bo[D.float_buf].swapfile = false
  vim.api.nvim_buf_set_lines(D.float_buf, 0, -1, false, { text })
  vim.bo[D.float_buf].modifiable = false

  D.float_win = vim.api.nvim_open_win(D.float_buf, false, {
    relative = "win",
    win = D.dataset_window,
    row = 0,
    col = 0,
    width = win_width,
    height = 1,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 40,
  })
  vim.wo[D.float_win].winhighlight = "Normal:PosteSqlHeader"
  T_mark("  hdr:done")
end

function M.move_cell(drow, dcol)
  local tab = D.T()
  if not tab or not tab.meta or tab.meta.type ~= "resultset" then return end

  if state.sql._trace then T_clear() end
  T_mark("move_cell")

  local row = state.sql.cell.row + drow
  local col = state.sql.cell.col + dcol

  row = math.max(1, math.min(row, tab.meta.row_count or 0))
  col = math.max(1, math.min(col, tab.meta.col_count or 0))

  state.sql.cell.row = row
  state.sql.cell.col = col

  T_mark("position_cursor")
  local line = M.position_cursor(row, col)
  T_mark("highlight_cell")
  sql_highlights.highlight_cell(D.dataset_buffer, row, col, tab.meta, line, get_col_starts(tab, row))
  T_mark("update_header_float")
  if dcol ~= 0 then
    M.update_header_float()
  end
  T_mark("done")
  T_report()
end

function M.goto_first_col()
  local tab = D.T()
  if not tab or not tab.meta then return end
  state.sql.cell.col = 1
  local line = M.position_cursor(state.sql.cell.row, 1)
  sql_highlights.highlight_cell(D.dataset_buffer, state.sql.cell.row, 1, tab.meta, line, get_col_starts(tab, state.sql.cell.row))
  M.update_header_float()
end

function M.goto_last_col()
  local tab = D.T()
  if not tab or not tab.meta then return end
  local last = tab.meta.col_count or 1
  state.sql.cell.col = last
  local line = M.position_cursor(state.sql.cell.row, last)
  sql_highlights.highlight_cell(D.dataset_buffer, state.sql.cell.row, last, tab.meta, line, get_col_starts(tab, state.sql.cell.row))
  M.update_header_float()
end

function M.goto_first_row()
  local tab = D.T()
  if not tab or not tab.meta then return end
  state.sql.cell.row = 1
  local line = M.position_cursor(1, state.sql.cell.col)
  sql_highlights.highlight_cell(D.dataset_buffer, 1, state.sql.cell.col, tab.meta, line, get_col_starts(tab, 1))
end

function M.goto_last_row()
  local tab = D.T()
  if not tab or not tab.meta then return end
  local last = tab.meta.row_count or 1
  state.sql.cell.row = last
  local line = M.position_cursor(last, state.sql.cell.col)
  sql_highlights.highlight_cell(D.dataset_buffer, last, state.sql.cell.col, tab.meta, line, get_col_starts(tab, last))
end

function M.position_cursor(row, col)
  local tab = D.T()
  if not tab or not tab.meta or not D.dataset_window then return "" end
  if not vim.api.nvim_win_is_valid(D.dataset_window) then return "" end

  local line_idx = (tab.meta.data_start_line or 1) + row - 1
  local buf = vim.api.nvim_win_get_buf(D.dataset_window)
  local last_col = tab.meta.col_count or 0

  -- Use pre-computed column byte/display offsets when available (O(1), no │ scan)
  local col_starts = tab.buffer_col_starts and tab.buffer_col_starts[line_idx]
  local target_col, target_disp, line, ranges
  if col_starts then
    local tc = col_starts[col + 1]
    if tc then
      target_col = tc.ext_start
      target_disp = tc.disp_start
    end
    T_mark("  pos:col_starts_lookup")
  else
    T_mark("  pos:get_line_fallback")
    line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
    T_mark("  pos:find_cell_ranges")
    ranges = sql_highlights.find_cell_ranges(line, col + 1, last_col + 1)
    target_col = ranges and ranges.target.cursor_col or 0
    target_disp = vim.fn.strdisplaywidth(line:sub(1, target_col))
    T_mark("  pos:strdisp_fallback")
  end

  T_mark("  pos:winsaveview")
  local saved = vim.fn.winsaveview()
  local saved_leftcol = saved.leftcol
  local win_width = vim.api.nvim_win_get_width(D.dataset_window)

  local left_margin = 2
  local right_margin = 3
  local target_on_screen = target_disp >= math.max(0, saved_leftcol - left_margin)
    and target_disp < saved_leftcol + win_width - right_margin

  local last_col_fits = true
  if last_col > 0 then
    if col_starts then
      local lc = col_starts[last_col + 1]
      if lc then
        local last_right_disp = lc.disp_end + 1  -- display pos after trailing │
        last_col_fits = last_right_disp <= saved_leftcol + win_width
      end
    elseif ranges and ranges.last then
      T_mark("  pos:strdisp_last")
      local last_right_disp = vim.fn.strdisplaywidth(line:sub(1, ranges.last.ext_end + 3))
      last_col_fits = last_right_disp <= saved_leftcol + win_width
    end
  end

  T_mark("  pos:cursor_set")
  if target_on_screen then
    local saved_sso = vim.api.nvim_get_option_value("sidescrolloff", { win = D.dataset_window })
    if saved_sso > 0 then
      vim.api.nvim_set_option_value("sidescrolloff", 0, { win = D.dataset_window })
    end
    pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { line_idx, target_col })
    if saved_sso > 0 then
      vim.api.nvim_set_option_value("sidescrolloff", saved_sso, { win = D.dataset_window })
    end
  else
    pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { line_idx, target_col })
    if not last_col_fits then
      T_mark("  pos:zs_via_api")
      local v = vim.fn.winsaveview()
      v.leftcol = target_disp
      vim.fn.winrestview(v)
    end
  end

  T_mark("  pos:done")
  return line or ""
end

local function json_pretty(val, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  local pad1 = string.rep("  ", indent + 1)
  if type(val) == "table" then
    local is_array = #val > 0
    if is_array then
      local items = {}
      for _, v in ipairs(val) do
        items[#items + 1] = pad1 .. json_pretty(v, indent + 1)
      end
      return "[\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "]"
    else
      local items = {}
      for k, v in pairs(val) do
        items[#items + 1] = pad1 .. '"' .. tostring(k) .. '": ' .. json_pretty(v, indent + 1)
      end
      table.sort(items)
      return "{\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "}"
    end
  elseif val == vim.NIL or val == nil then
    return "null"
  elseif type(val) == "boolean" then
    return tostring(val)
  elseif type(val) == "number" then
    return tostring(val)
  else
    local ok, encoded = pcall(vim.json.encode, val)
    return ok and encoded or ('"' .. tostring(val) .. '"')
  end
end

local function try_pretty_json(s)
  local ok, decoded = pcall(vim.json.decode, s)
  if ok and type(decoded) == "table" then
    return json_pretty(decoded)
  end
  if ok and type(decoded) == "string" then
    local ok2, decoded2 = pcall(vim.json.decode, decoded)
    if ok2 and type(decoded2) == "table" then
      return json_pretty(decoded2)
    end
  end
  return nil
end

local function pretty_print(val)
  if val == nil or val == vim.NIL then
    return "(NULL)", "text"
  end
  if type(val) == "table" then
    return json_pretty(val), "json"
  end
  local s = tostring(val)
  if type(val) == "string" then
    local pretty = try_pretty_json(s)
    if pretty then return pretty, "json" end
    local trimmed = s:match("^%s*(.*)")
    if trimmed ~= s then
      pretty = try_pretty_json(trimmed)
      if pretty then return pretty, "json" end
    end
  end
  return s, "text"
end

function M.preview_cell()
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_win_close(preview_win, true)
    preview_win = nil
    return
  end

  local tab = D.T()
  if not tab or not tab.data or not tab.meta or tab.meta.type ~= "resultset" then return end
  local data = tab.data
  if not data or not data.results or #data.results == 0 then return end

  local res = data.results[1]
  local row = state.sql.cell.row
  local col = state.sql.cell.col

  if not res.rows or not res.rows[row] then return end
  local raw_val = res.rows[row][col]
  local text, ft = pretty_print(raw_val)

  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  local max_width = math.min(math.floor(vim.o.columns * 0.7), 120)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, max_width)

  local max_height = math.floor(vim.o.lines * 0.6)
  local height = math.max(3, math.min(#lines + 1, max_height))

  local col_name = res.columns[col] and res.columns[col].name or "?"

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].filetype = ft
  vim.bo[float_buf].modifiable = false

  local win_opts = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height, style = "minimal",
    border = "rounded", title = col_name, title_pos = "left",
  }
  local ok, win = pcall(vim.api.nvim_open_win, float_buf, true, win_opts)
  if not ok then
    win_opts.title = nil; win_opts.title_pos = nil
    win = vim.api.nvim_open_win(float_buf, true, win_opts)
  end

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].scrolloff = 1
  vim.wo[win].cursorline = true

  preview_win = win

  local sopts = { buffer = float_buf, noremap = true, silent = true }
  vim.keymap.set("n", "j", "<C-e>", sopts)
  vim.keymap.set("n", "k", "<C-y>", sopts)
  vim.keymap.set("n", "d", "<C-d>", sopts)
  vim.keymap.set("n", "u", "<C-u>", sopts)
  vim.keymap.set("n", "g", "gg", sopts)
  vim.keymap.set("n", "G", "G", sopts)
  vim.keymap.set("n", "<Space>", "<C-f>", sopts)
  vim.keymap.set("n", "<BS>", "<C-b>", sopts)
  local close_fn = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    preview_win = nil
  end
  vim.keymap.set("n", "q", close_fn, sopts)
  vim.keymap.set("n", "<Esc>", close_fn, sopts)
end

function M.yank_cell()
  local tab = D.T()
  if not tab or not tab.data or not tab.meta or tab.meta.type ~= "resultset" then return end
  local data = tab.data
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

function M.yank_column()
  local tab = D.T()
  if not tab or not tab.data or not tab.meta or tab.meta.type ~= "resultset" then return end
  local data = tab.data
  if not data or not data.results or #data.results == 0 then return end

  local res = data.results[1]
  local col = state.sql.cell.col
  if not res.rows or #res.rows == 0 then return end

  local values = {}
  for _, row in ipairs(res.rows) do
    local v = row[col]
    if v == nil or v == vim.NIL then
      values[#values + 1] = "NULL"
    elseif type(v) == "table" then
      local ok, encoded = pcall(vim.json.encode, v)
      values[#values + 1] = ok and encoded or vim.inspect(v)
    else
      values[#values + 1] = tostring(v)
    end
  end

  local result = table.concat(values, ", ")
  vim.fn.setreg('"', result)
  vim.fn.setreg('+', result)
  local col_name = res.columns and res.columns[col] and res.columns[col].name or tostring(col)
  vim.notify(string.format('Yanked %d values from "%s"', #values, col_name), vim.log.levels.INFO, { title = "Poste SQL" })
end

function M.sort_by_current_col()
  local tab = D.T()
  if not tab or not tab.data or not tab.meta or tab.meta.type ~= "resultset" then return end
  if tab.edit_state and tab.edit_state.dirty then
    vim.notify("Unsaved changes, commit (<leader>w) or revert (R) first", vim.log.levels.WARN)
    return
  end
  local data = tab.data
  if not data or not data.results or #data.results == 0 then return end

  local res = data.results[1]
  if not res.rows or #res.rows == 0 then return end

  local col = state.sql.cell.col
  local ascending, is_reset
  if not tab.sort or tab.sort.col ~= col then
    ascending = true; is_reset = false
  elseif tab.sort.ascending then
    ascending = false; is_reset = false
  else
    is_reset = true
  end

  if is_reset then
    tab.sort = nil
  else
    tab.sort = { col = col, ascending = ascending }
  end

  tab.rows_source = tab.rows_source or res.rows
  D.compute_view_indices(tab)

  tab.is_sorting = true
  local sql_format = require("poste.sql.format")
  local layout = tab.layout
  if layout then
    local lines, meta = sql_format.render_view(
      layout, tab.view_indices, tab.page, tab.page_size,
      { row_number_mode = tab.row_number_mode or "source" }
    )
    local buffer = require("poste.sql.buffer")
    buffer.render_dataset(lines, meta, {
      keep_tabs = true,
      tab_index = D.active_tab_idx,
      layout = layout,
      view_indices = tab.view_indices,
    })
  else
    local new_data = vim.deepcopy(data)
    local lines, meta = sql_format.format_resultset(new_data)
    local buffer = require("poste.sql.buffer")
    buffer.render_dataset(lines, meta, { keep_tabs = true, tab_index = D.active_tab_idx })
  end
  tab.is_sorting = false
  M.move_cell(0, 0)
end

function M.toggle_cell_highlight()
  local tab = D.T()
  state.sql.highlight_cell = not state.sql.highlight_cell
  if state.sql.highlight_cell then
    sql_highlights.highlight_cell(D.dataset_buffer, state.sql.cell.row, state.sql.cell.col, tab and tab.meta, nil, get_col_starts(tab, state.sql.cell.row))
  else
    sql_highlights.clear_cell_highlight(D.dataset_buffer)
  end
  vim.notify(string.format("Cell highlight: %s", state.sql.highlight_cell and "ON" or "OFF"),
    vim.log.levels.INFO, { title = "Poste SQL" })
end

function M.toggle_header_float()
  state.sql._hide_header_float = not state.sql._hide_header_float
  if state.sql._hide_header_float then
    D.close_header_float()
  else
    M.update_header_float()
  end
  vim.notify(string.format("Header float: %s", state.sql._hide_header_float and "OFF" or "ON"),
    vim.log.levels.INFO, { title = "Poste SQL" })
end

function M.toggle_row_numbers()
  state.sql._hide_row_numbers = not state.sql._hide_row_numbers
  local tab = D.T()
  if tab and tab.padded and tab.meta then
    sql_highlights.apply_dataset_highlights(D.dataset_buffer, tab.padded, tab.meta)
  end
  vim.notify(string.format("Row numbers: %s", state.sql._hide_row_numbers and "OFF" or "ON"),
    vim.log.levels.INFO, { title = "Poste SQL" })
end

function M.restore_from_raw_mode()
  if not state.sql._raw_mode then return end
  local buf = D.dataset_buffer and vim.api.nvim_buf_is_valid(D.dataset_buffer) and D.dataset_buffer
  local win = D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) and D.dataset_window
  -- Switch window back to dataset buffer BEFORE deleting raw buffer,
  -- so the window isn't closed by force-deleting the displayed buffer.
  if win and buf then
    pcall(vim.api.nvim_win_set_buf, win, buf)
  end
  if raw_buffer and vim.api.nvim_buf_is_valid(raw_buffer) then
    pcall(vim.api.nvim_buf_delete, raw_buffer, { force = true })
  end
  raw_buffer = nil
  state.sql._raw_mode = false
end

function M.toggle_raw_mode()
  if state.sql._raw_mode then
    M.restore_from_raw_mode()
    require("poste.sql.buffer_page").refresh_page()
    return
  end

  local tab = D.T()
  local win = D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) and D.dataset_window

  if not tab or not tab.layout then
    vim.notify("No dataset to display in raw mode", vim.log.levels.WARN, { title = "Poste SQL" })
    return
  end
  if not win then
    vim.notify("No dataset window", vim.log.levels.WARN, { title = "Poste SQL" })
    return
  end

  D.close_header_float()

  local fmt = require("poste.sql.format")
  local lines, _ = fmt.render_page(tab.layout, 1, #tab.layout.rows)

  raw_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = raw_buffer })
  vim.api.nvim_set_option_value("swapfile", false, { buf = raw_buffer })
  vim.api.nvim_set_option_value("modifiable", true, { buf = raw_buffer })
  vim.api.nvim_buf_set_lines(raw_buffer, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = raw_buffer })
  local rk = state.get_keymap("sql_dataset", "toggle_raw_mode", "<leader>gp")
  if rk then
    vim.keymap.set("n", rk, function() M.toggle_raw_mode() end, { buffer = raw_buffer, noremap = true, silent = true })
  end
  state.sql._raw_mode = true

  vim.api.nvim_win_set_buf(win, raw_buffer)
  pcall(vim.api.nvim_set_option_value, "winbar", " Raw mode — toggle to exit ", { win = win })
  pcall(vim.api.nvim_buf_set_name, raw_buffer, "poste://raw-mode")

  vim.notify("Raw mode: ON (browse table)", vim.log.levels.INFO, { title = "Poste SQL" })
end

function M.goto_header()
  M.goto_first_row()
end

local function format_conn_short(conn)
  if not conn or conn == "" then return nil end
  local host, port, db = conn:match("^%w+://[^@]*@([^:]+):(%d+)/([^?]+)")
  if host then return string.format("%s:%s/%s", host, port, db) end
  return conn:match("/([^/]+)$") or conn
end

local function build_status_winbar(meta)
  if not meta or meta.type ~= "resultset" then return nil end

  local rows = meta.total_rows or meta.row_count or 0
  local ms = meta.total_execution_time_ms or 0

  local left = string.format("  %d row%s · %dms", rows, rows == 1 and "" or "s", ms)

  local tab = D.T()
  if tab and tab.sort then
    local col_name = meta.columns and meta.columns[tab.sort.col] and meta.columns[tab.sort.col].name
    if col_name then
      local arrow = tab.sort.ascending and " ↑" or " ↓"
      left = left .. "   " .. col_name .. arrow
    end
  end

  if tab and tab.num_pages and tab.num_pages > 1 and (tab.padded_full or tab.layout) then
    if tab.pagination_enabled then
      left = left .. string.format("  %sPage %d/%d%s",
        "%#PosteSqlMetaDim#", tab.page, tab.num_pages, "%#PosteSqlMeta#")
    else
      left = left .. "  %#PosteSqlMetaDim#All%#PosteSqlMeta#"
    end
  end

  if tab and tab.filter_active and tab.filter_col_name then
    local fv = tab.filter_val
    local fvs = (fv == nil or fv == vim.NIL) and "NULL" or tostring(fv)
    left = left .. string.format("  %sfilter: %s=%s%s",
      "%#PosteFilterActive#", tab.filter_col_name, fvs, "%#PosteSqlMeta#")
  end

  if tab and tab.search_text and #tab.search_matches > 0 then
    local cnt = string.format("%d/%d", tab.search_idx or 0, #tab.search_matches)
    local info = tab.search_text .. " (" .. cnt .. ")"
    left = left .. string.format("  %ssearch: %s%s",
      "%#PosteSearchActive#", info, "%#PosteSqlMeta#")
  elseif tab and tab.search_text then
    left = left .. string.format("  %ssearch: %s (0)%s",
      "%#PosteSearchActive#", tab.search_text, "%#PosteSqlMeta#")
  end

  local right = ""
  local current_tab = D.T()
  local pending = current_tab and current_tab.edit_state and current_tab.edit_state.dirty
    and require("poste.sql.editor").pending_changes_text(current_tab.edit_state)
  if pending then
    right = right .. pending .. "  "
  end
  if #D.tabs > 1 then
    local label = meta.table_name or ("result " .. D.active_tab_idx)
    right = right .. string.format("[%d/%d: %s] ", D.active_tab_idx, #D.tabs, label)
  elseif meta.table_name then
    right = right .. string.format("[%s] ", meta.table_name)
  end
  right = right .. (format_conn_short(meta.connection) or "")

  local text = left .. "%=" .. right
  return "%#PosteSqlMeta#" .. text
end
M.build_status_winbar = build_status_winbar

return M
