--- SQL Dataset buffer — bottom horizontal split with cell-based navigation.
--- Column header rendered as a floating window anchored to the dataset window top.
--- Winbar shows static status info (row count, timing, connection, tab indicator).
local state = require("poste.state")
local sql_format = require("poste.sql.format")
local sql_highlights = require("poste.sql.highlights")

local M = {}

local dataset_buffer = nil
local dataset_window = nil

local LEFT_PADDING = 2
local PADDING_SPACES = string.rep(" ", LEFT_PADDING)

--------------------------------------------------------------------------------
-- Tab system
--------------------------------------------------------------------------------

--- Each tab stores isolated state for one result set.
--- @class DatasetTab
--- @field meta table|nil
--- @field lines string[]|nil  raw lines from format.lua
--- @field padded string[]|nil rendered lines in buffer
--- @field header_text string|nil  plain header with sort indicator baked in
--- @field header_index table|nil  build_header_index result
--- @field sort table|nil { col = number, ascending = boolean }
--- @field original_rows table|nil  deep copy for sort reset
--- @field is_sorting boolean
--- @field data table|nil  decoded response body
--- @field cursor table { row, col }
--- @field leftcol number  horizontal scroll position

local tabs = {}
local active_tab_idx = 0

local function tab_count()
  return #tabs
end

function M.tab_count()
  return #tabs
end

--- Get active tab or nil.
local function T()
  return tabs[active_tab_idx]
end

--- Ensure tab at idx exists, return it.
local function alloc_tab(idx)
  if not tabs[idx] then
    tabs[idx] = {
      meta = nil, lines = nil, padded = nil,
      header_text = nil, header_index = nil,
      sort = nil, original_rows = nil, is_sorting = false,
      data = nil,
      cursor = { row = 1, col = 1 },
      leftcol = 0,
    }
  end
  return tabs[idx]
end

--------------------------------------------------------------------------------
-- Buffer creation
--------------------------------------------------------------------------------

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
  vim.bo[dataset_buffer].filetype = "poste_dataset"

  local opts = { buffer = dataset_buffer, noremap = true, silent = true }

  vim.keymap.set("n", "q", function() M.close() end, opts)
  vim.keymap.set("n", "h", function() M.move_cell(0, -1) end, opts)
  vim.keymap.set("n", "l", function() M.move_cell(0, 1) end, opts)
  vim.keymap.set("n", "j", function() M.move_cell(1, 0) end, opts)
  vim.keymap.set("n", "k", function() M.move_cell(-1, 0) end, opts)
  vim.keymap.set("n", "0", function() M.goto_first_col() end, opts)
  vim.keymap.set("n", "$", function() M.goto_last_col() end, opts)
  vim.keymap.set("n", "H", function() M.goto_header() end, opts)
  vim.keymap.set("n", "gg", function() M.goto_first_row() end, opts)
  vim.keymap.set("n", "G", function() M.goto_last_row() end, opts)
  vim.keymap.set("n", "K", function() M.preview_cell() end, opts)
  vim.keymap.set("n", "yy", function() M.yank_cell() end, opts)
  vim.keymap.set("n", "yc", function() M.yank_column() end, opts)
  vim.keymap.set("n", "s", function() M.sort_by_current_col() end, opts)
  vim.keymap.set("n", "zh", function() M.toggle_cell_highlight() end, opts)
  vim.keymap.set("n", "<Tab>", function() M.next_tab() end, opts)
  vim.keymap.set("n", "<S-Tab>", function() M.prev_tab() end, opts)
  vim.keymap.set("n", "R", function()
    vim.schedule(function()
      require("poste.sql.init").run_sql_request()
    end)
  end, opts)

  return dataset_buffer
end

--------------------------------------------------------------------------------
-- Tab switching
--------------------------------------------------------------------------------

--- Save active tab's transient state (scroll, cursor) before switching away.
local function save_active_tab_state()
  local tab = T()
  if not tab then return end
  tab.cursor = { row = state.sql.cell.row, col = state.sql.cell.col }
  if dataset_window and vim.api.nvim_win_is_valid(dataset_window) then
    tab.leftcol = vim.api.nvim_win_call(dataset_window, function()
      return vim.fn.winsaveview().leftcol
    end)
  end
end

local function apply_tab_state(tab)
  state.sql.cell.row = tab.cursor.row
  state.sql.cell.col = tab.cursor.col
  if tab.data then
    state.sql.last_dataset = tab.data
  end
end

--- Switch to a given tab index. Called after tab creation or on user switch.
local function switch_tab(idx)
  if not tabs[idx] then return end
  save_active_tab_state()
  close_header_float()
  active_tab_idx = idx
  local tab = tabs[idx]
  apply_tab_state(tab)

  if not dataset_window or not vim.api.nvim_win_is_valid(dataset_window) then return end

  -- Swap buffer content
  if tab.padded then
    vim.api.nvim_set_option_value("modifiable", true, { buf = dataset_buffer })
    vim.api.nvim_buf_set_lines(dataset_buffer, 0, -1, false, tab.padded)
    vim.api.nvim_set_option_value("modifiable", false, { buf = dataset_buffer })
    sql_highlights.apply_dataset_highlights(dataset_buffer, tab.padded, tab.meta)
  end

  vim.api.nvim_win_set_buf(dataset_window, dataset_buffer)

  -- Restore scroll
  pcall(vim.api.nvim_win_call, dataset_window, function()
    vim.fn.winrestview({ leftcol = tab.leftcol or 0 })
  end)

  -- Restore cursor
  local meta = tab.meta
  if meta and meta.type == "resultset" and meta.row_count > 0 then
    local line_idx = (meta.data_start_line or 1) + tab.cursor.row - 1
    pcall(vim.api.nvim_win_set_cursor, dataset_window, { line_idx, 0 })
    sql_highlights.highlight_cell(dataset_buffer, tab.cursor.row, tab.cursor.col, meta)
  end

  -- Recreate header float if there's header data
  if tab.header_text then
    M.update_header_float()
  end

  -- Update winbar
  local winbar_text = build_status_winbar(meta)
  pcall(vim.api.nvim_set_option_value, "winbar", winbar_text or "", { win = dataset_window })
end

function M.next_tab()
  if #tabs < 2 then return end
  local idx = active_tab_idx + 1
  if idx > #tabs then idx = 1 end
  switch_tab(idx)
end

function M.prev_tab()
  if #tabs < 2 then return end
  local idx = active_tab_idx - 1
  if idx < 1 then idx = #tabs end
  switch_tab(idx)
end

--------------------------------------------------------------------------------
-- Cell navigation
--------------------------------------------------------------------------------

function M.move_cell(drow, dcol)
  local tab = T()
  if not tab or not tab.meta or tab.meta.type ~= "resultset" then return end

  local row = state.sql.cell.row + drow
  local col = state.sql.cell.col + dcol

  row = math.max(1, math.min(row, tab.meta.row_count or 0))
  col = math.max(1, math.min(col, tab.meta.col_count or 0))

  state.sql.cell.row = row
  state.sql.cell.col = col

  local line = M.position_cursor(row, col)
  sql_highlights.highlight_cell(dataset_buffer, row, col, tab.meta, line)
  if dcol ~= 0 then
    M.update_header_float()
  end
end

function M.goto_first_col()
  local tab = T()
  if not tab or not tab.meta then return end
  state.sql.cell.col = 1
  local line = M.position_cursor(state.sql.cell.row, 1)
  sql_highlights.highlight_cell(dataset_buffer, state.sql.cell.row, 1, tab.meta, line)
  M.update_header_float()
end

function M.goto_last_col()
  local tab = T()
  if not tab or not tab.meta then return end
  local last = tab.meta.col_count or 1
  state.sql.cell.col = last
  local line = M.position_cursor(state.sql.cell.row, last)
  sql_highlights.highlight_cell(dataset_buffer, state.sql.cell.row, last, tab.meta, line)
  M.update_header_float()
end

function M.goto_header()
  M.goto_first_row()
end

function M.goto_first_row()
  local tab = T()
  if not tab or not tab.meta then return end
  state.sql.cell.row = 1
  local line = M.position_cursor(1, state.sql.cell.col)
  sql_highlights.highlight_cell(dataset_buffer, 1, state.sql.cell.col, tab.meta, line)
end

function M.goto_last_row()
  local tab = T()
  if not tab or not tab.meta then return end
  local last = tab.meta.row_count or 1
  state.sql.cell.row = last
  local line = M.position_cursor(last, state.sql.cell.col)
  sql_highlights.highlight_cell(dataset_buffer, last, state.sql.cell.col, tab.meta, line)
end

function M.position_cursor(row, col)
  local tab = T()
  if not tab or not tab.meta or not dataset_window then return "" end
  if not vim.api.nvim_win_is_valid(dataset_window) then return "" end

  local line_idx = (tab.meta.data_start_line or 1) + row - 1
  local buf = vim.api.nvim_win_get_buf(dataset_window)

  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  local range = sql_highlights.find_cell_range(line, col + 1)
  local target_col = range and range.cursor_col or 0
  local target_disp = vim.fn.strdisplaywidth(line:sub(1, target_col))

  local saved_leftcol = vim.api.nvim_win_call(dataset_window, function()
    return vim.fn.winsaveview().leftcol
  end)
  local win_width = vim.api.nvim_win_get_width(dataset_window)

  local left_margin = 2
  local right_margin = 3
  local target_on_screen = target_disp >= math.max(0, saved_leftcol - left_margin)
    and target_disp < saved_leftcol + win_width - right_margin

  local last_col = tab.meta.col_count or 0
  local last_col_fits = true
  if last_col > 0 then
    local last_range = sql_highlights.find_cell_range(line, last_col + 1)
    if last_range then
      local last_right_disp = vim.fn.strdisplaywidth(line:sub(1, last_range.ext_end + 3))
      last_col_fits = last_right_disp <= saved_leftcol + win_width
    end
  end

  if target_on_screen then
    local saved_sso = vim.api.nvim_get_option_value("sidescrolloff", { win = dataset_window })
    if saved_sso > 0 then
      vim.api.nvim_set_option_value("sidescrolloff", 0, { win = dataset_window })
    end
    pcall(vim.api.nvim_win_set_cursor, dataset_window, { line_idx, target_col })
    pcall(vim.api.nvim_win_call, dataset_window, function()
      local v = vim.fn.winsaveview()
      v.leftcol = saved_leftcol
      vim.fn.winrestview(v)
    end)
    if saved_sso > 0 then
      vim.api.nvim_set_option_value("sidescrolloff", saved_sso, { win = dataset_window })
    end
  else
    pcall(vim.api.nvim_win_set_cursor, dataset_window, { line_idx, target_col })
    if not last_col_fits then
      pcall(vim.api.nvim_win_call, dataset_window, function()
        vim.cmd("normal! zs")
      end)
    end
  end

  return line
end

--------------------------------------------------------------------------------
-- Float header management
--------------------------------------------------------------------------------

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

local function slice_header_to_win(leftcol, win_width, padded_header, index)
  if not padded_header or not index then return PADDING_SPACES end
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

  if #parts == 0 then return PADDING_SPACES end
  return table.concat(parts)
end

local float_buf = nil
local float_win = nil
local scroll_autocmd_id = nil

local function close_header_float()
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    pcall(vim.api.nvim_win_close, float_win, true)
  end
  if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
    pcall(vim.api.nvim_buf_delete, float_buf, { force = true })
  end
  float_win = nil
  float_buf = nil
end

function M.update_header_float()
  local tab = T()
  if not tab or not tab.header_text or not dataset_window then return end
  if not vim.api.nvim_win_is_valid(dataset_window) then return end

  local win_width = vim.api.nvim_win_get_width(dataset_window)
  if win_width <= 0 then return end

  local leftcol = vim.api.nvim_win_call(dataset_window, function()
    return vim.fn.winsaveview().leftcol
  end)

  local padded = "  " .. tab.header_text
  local index = tab.header_index or build_header_index(padded)
  local text = slice_header_to_win(leftcol, win_width, padded, index)

  if float_win and vim.api.nvim_win_is_valid(float_win) then
    vim.bo[float_buf].modifiable = true
    pcall(vim.api.nvim_buf_set_lines, float_buf, 0, -1, false, { text })
    vim.bo[float_buf].modifiable = false
  else
    close_header_float()
    float_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { text })
    vim.bo[float_buf].modifiable = false

    float_win = vim.api.nvim_open_win(float_buf, false, {
      relative = "win",
      win = dataset_window,
      row = 0,
      col = 0,
      width = win_width,
      height = 1,
      style = "minimal",
      border = "none",
      focusable = false,
      zindex = 60,
    })
    vim.wo[float_win].winhighlight = "Normal:PosteSqlHeader"
  end
end

--------------------------------------------------------------------------------
-- Winbar (status info)
--------------------------------------------------------------------------------

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

  -- Tab indicator
  if #tabs > 1 then
    left = left .. string.format(" [%d/%d]", active_tab_idx, #tabs)
  end

  -- Sort state
  local tab = T()
  if tab and tab.sort then
    local col_name = meta.columns and meta.columns[tab.sort.col] and meta.columns[tab.sort.col].name
    if col_name then
      local arrow = tab.sort.ascending and " ↑" or " ↓"
      left = left .. "    │    " .. col_name .. arrow
    end
  end

  -- Right: connection info
  local right = format_conn_short(meta.connection) or ""

  local text = left .. "%=" .. right
  return "%#PosteSqlMeta#" .. text
end

--------------------------------------------------------------------------------
-- Cell preview (K key)
--------------------------------------------------------------------------------

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
  local tab = T()
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
  local border_label = string.format(" %s ", col_name)

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].filetype = ft
  vim.bo[float_buf].modifiable = false

  local win_opts = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height, style = "minimal",
    border = "rounded", title = border_label, title_pos = "left",
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
  end
  vim.keymap.set("n", "q", close_fn, sopts)
  vim.keymap.set("n", "<Esc>", close_fn, sopts)
end

--------------------------------------------------------------------------------
-- Yank
--------------------------------------------------------------------------------

function M.yank_cell()
  local tab = T()
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
  local tab = T()
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

--------------------------------------------------------------------------------
-- Sort
--------------------------------------------------------------------------------

function M.sort_by_current_col()
  local tab = T()
  if not tab or not tab.data or not tab.meta or tab.meta.type ~= "resultset" then return end
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
    res.rows = tab.original_rows; tab.sort = nil
  else
    tab.sort = { col = col, ascending = ascending }
    if not tab.original_rows then
      tab.original_rows = {}
      for i, row in ipairs(res.rows) do tab.original_rows[i] = row end
    end
    table.sort(res.rows, function(a, b)
      local va, vb = a[col], b[col]
      if va == nil or va == vim.NIL then return false end
      if vb == nil or vb == vim.NIL then return true end
      local ta, tb = type(va), type(vb)
      if ta == "number" and tb == "number" then
        if ascending then return va < vb else return va > vb end
      end
      if ta == "boolean" and tb == "boolean" then
        if ascending then return not va and vb else return va and not vb end
      end
      local sa, sb = tostring(va), tostring(vb)
      if ascending then return sa < sb else return sa > sb end
    end)
  end

  tab.is_sorting = true
  local new_data = vim.deepcopy(data)
  local lines, meta = sql_format.format_resultset(new_data)
  M.render_dataset(lines, meta)
  tab.is_sorting = false
  M.move_cell(0, 0)
end

--------------------------------------------------------------------------------
-- Render / Close
--------------------------------------------------------------------------------

function M.render_dataset(lines, meta, opts)
  opts = opts or {}
  local tab_idx = opts.tab_index or 1
  local tab = alloc_tab(tab_idx)

  local buf = get_dataset_buffer()

  sql_highlights.invalidate_sep_cache()

  if tab.is_sorting then
    -- keep sort state during sorting
  else
    tab.sort = nil
    tab.original_rows = nil
  end

  if meta and meta.type == "resultset" then
    local ok, data = pcall(vim.json.decode, state.last_response and state.last_response.body or "{}")
    if ok then
      tab.data = data
      state.sql.last_dataset = data
    end
  end

  -- Reset cursor when not sorting
  if not tab.is_sorting then
    tab.cursor = { row = 1, col = 1 }
  end

  local clean = {}
  for i, line in ipairs(lines) do
    if type(line) ~= "string" then line = tostring(line or "") end
    for seg in (line .. "\n"):gmatch("(.-)\n") do
      clean[#clean + 1] = seg
    end
  end

  -- Extract header from buffer, show in float
  local removed_lines = 0
  local has_header = meta and meta.type == "resultset" and meta.header_line
  if has_header then
    local header_line = clean[meta.header_line]
    if header_line then
      tab.header_text = header_line
      -- Bake sort indicator
      if tab.sort then
        local range = sql_highlights.find_cell_range(tab.header_text, tab.sort.col + 1)
        if range then
          local text_end = range.ext_end
          while text_end > range.ext_start + 1 do
            if tab.header_text:byte(text_end) ~= 0x20 then break end
            text_end = text_end - 1
          end
          if text_end > range.ext_start then
            local indicator = (tab.sort.ascending and " ↑" or " ↓")
            local before = tab.header_text:sub(1, text_end)
            local after = tab.header_text:sub(text_end + 3)
            tab.header_text = before .. indicator .. after
          end
        end
      end
      local padded = "  " .. tab.header_text
      tab.header_index = build_header_index(padded)

      table.remove(clean, meta.header_line + 1)
      table.remove(clean, meta.header_line)
      table.remove(clean, meta.header_line - 1)
      removed_lines = 3
      meta.header_line = nil
      meta.data_start_line = meta.data_start_line - removed_lines
      meta.data_end_line = meta.data_end_line - removed_lines
    end
  end

  -- Apply left padding, then prepend a blank line as spacer for the header float
  local padded = {}
  for _, line in ipairs(clean) do
    if line == "" then
      padded[#padded + 1] = ""
    else
      padded[#padded + 1] = PADDING_SPACES .. line
    end
  end
  if has_header then
    table.insert(padded, 1, "")
    meta.data_start_line = meta.data_start_line + 1
    meta.data_end_line = meta.data_end_line + 1
  end
  tab.padded = padded
  tab.meta = meta
  tab.lines = lines

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, padded)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  sql_highlights.apply_dataset_highlights(buf, padded, meta)

  -- Open bottom horizontal split
  if not dataset_window or not vim.api.nvim_win_is_valid(dataset_window) then
    local saved_win = vim.api.nvim_get_current_win()
    local height = math.floor(vim.o.lines * 0.4)
    vim.cmd("botright " .. height .. "split")
    dataset_window = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(saved_win)
  end

  vim.api.nvim_win_set_buf(dataset_window, buf)
  pcall(vim.api.nvim_win_call, dataset_window, function()
    vim.fn.winrestview({ leftcol = 0 })
  end)

  vim.api.nvim_set_option_value("wrap", false, { win = dataset_window })
  vim.api.nvim_set_option_value("sidescrolloff", 0, { win = dataset_window })
  vim.api.nvim_set_option_value("cursorline", false, { win = dataset_window })
  vim.api.nvim_set_option_value("cursorcolumn", false, { win = dataset_window })
  vim.api.nvim_set_option_value("conceallevel", 0, { win = dataset_window })
  vim.api.nvim_set_option_value("number", false, { win = dataset_window })
  vim.api.nvim_set_option_value("relativenumber", false, { win = dataset_window })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = dataset_window })
  pcall(vim.api.nvim_set_option_value, "statuscolumn", "", { win = dataset_window })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = dataset_window })
  vim.api.nvim_set_option_value("foldenable", false, { win = dataset_window })

  -- Switch to this tab
  active_tab_idx = tab_idx

  -- Set static winbar
  local winbar_text = build_status_winbar(meta)
  pcall(vim.api.nvim_set_option_value, "winbar", winbar_text or "", { win = dataset_window })

  -- Close previous float, create header float
  close_header_float()
  if tab.header_text then
    M.update_header_float()
  end

  -- Register WinScrolled autocmd for horizontal scroll sync
  if scroll_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, scroll_autocmd_id)
    scroll_autocmd_id = nil
  end
  if dataset_buffer then
    scroll_autocmd_id = vim.api.nvim_create_autocmd("WinScrolled", {
      buffer = dataset_buffer,
      callback = function()
        M.update_header_float()
      end,
    })
  end

  -- Position cursor
  if not tab.is_sorting then
    if meta and meta.type == "resultset" and meta.row_count > 0 then
      state.sql.cell.row = 1
      state.sql.cell.col = 1
      pcall(vim.api.nvim_win_set_cursor, dataset_window, { meta.data_start_line, 0 })
      sql_highlights.highlight_cell(buf, 1, 1, meta)
    else
      pcall(vim.api.nvim_win_set_cursor, dataset_window, { 1, 0 })
    end
  end

  vim.api.nvim_set_option_value("sidescrolloff", 5, { win = dataset_window })
end

function M.toggle_cell_highlight()
  local tab = T()
  state.sql.highlight_cell = not state.sql.highlight_cell
  if state.sql.highlight_cell then
    sql_highlights.highlight_cell(dataset_buffer, state.sql.cell.row, state.sql.cell.col, tab and tab.meta)
  else
    sql_highlights.clear_cell_highlight(dataset_buffer)
  end
  vim.notify(string.format("Cell highlight: %s", state.sql.highlight_cell and "ON" or "OFF"),
    vim.log.levels.INFO, { title = "Poste SQL" })
end

function M.close()
  if scroll_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, scroll_autocmd_id)
    scroll_autocmd_id = nil
  end
  close_header_float()
  if dataset_window and vim.api.nvim_win_is_valid(dataset_window) then
    vim.api.nvim_win_close(dataset_window, true)
    dataset_window = nil
  end
  sql_highlights.clear_cell_highlight(dataset_buffer)
  tabs = {}
  active_tab_idx = 0
end

function M.is_open()
  return dataset_window and vim.api.nvim_win_is_valid(dataset_window)
end

M._test = {
  set_header = function(header)
    local tab = alloc_tab(1)
    tab.header_text = header
    tab.header_index = header and build_header_index("  " .. header) or nil
  end,
  slice_header_to_win = slice_header_to_win,
}

return M
