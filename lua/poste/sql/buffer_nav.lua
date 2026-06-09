local D = require("poste.sql.dataset")
local state = require("poste.state")
local sql_highlights = require("poste.sql.highlights")
local M = {}

local preview_win = nil



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

function M.update_header_float()
  local tab = D.T()
  if not tab or not tab.header_text or not D.dataset_window then return end
  if not vim.api.nvim_win_is_valid(D.dataset_window) then return end

  local win_width = vim.api.nvim_win_get_width(D.dataset_window)
  if win_width <= 0 then return end

  local leftcol = vim.api.nvim_win_call(D.dataset_window, function()
    return vim.fn.winsaveview().leftcol
  end)

  if leftcol == D._float_cache_leftcol and win_width == D._float_cache_width
     and tab.header_text == D._float_cache_header then return end

  D._float_cache_leftcol = leftcol
  D._float_cache_width = win_width
  D._float_cache_header = tab.header_text

  local padded = "  " .. tab.header_text
  local index = tab.header_index or build_header_index(padded)
  local text = slice_header_to_win(leftcol, win_width, padded, index)

  local float_buf = D.float_buf
  local float_win = D.float_win

  if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = float_buf })
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { text })
    vim.api.nvim_set_option_value("modifiable", false, { buf = float_buf })
    if float_win and vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_set_config(float_win, { width = win_width })
      return
    end
  end

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
end

function M.move_cell(drow, dcol)
  local tab = D.T()
  if not tab or not tab.meta or tab.meta.type ~= "resultset" then return end

  local row = state.sql.cell.row + drow
  local col = state.sql.cell.col + dcol

  row = math.max(1, math.min(row, tab.meta.row_count or 0))
  col = math.max(1, math.min(col, tab.meta.col_count or 0))

  state.sql.cell.row = row
  state.sql.cell.col = col

  local line = M.position_cursor(row, col)
  sql_highlights.highlight_cell(D.dataset_buffer, row, col, tab.meta, line)
  if dcol ~= 0 then
    M.update_header_float()
  end
end

function M.goto_first_col()
  local tab = D.T()
  if not tab or not tab.meta then return end
  state.sql.cell.col = 1
  local line = M.position_cursor(state.sql.cell.row, 1)
  sql_highlights.highlight_cell(D.dataset_buffer, state.sql.cell.row, 1, tab.meta, line)
  M.update_header_float()
end

function M.goto_last_col()
  local tab = D.T()
  if not tab or not tab.meta then return end
  local last = tab.meta.col_count or 1
  state.sql.cell.col = last
  local line = M.position_cursor(state.sql.cell.row, last)
  sql_highlights.highlight_cell(D.dataset_buffer, state.sql.cell.row, last, tab.meta, line)
  M.update_header_float()
end

function M.goto_first_row()
  local tab = D.T()
  if not tab or not tab.meta then return end
  state.sql.cell.row = 1
  local line = M.position_cursor(1, state.sql.cell.col)
  sql_highlights.highlight_cell(D.dataset_buffer, 1, state.sql.cell.col, tab.meta, line)
end

function M.goto_last_row()
  local tab = D.T()
  if not tab or not tab.meta then return end
  local last = tab.meta.row_count or 1
  state.sql.cell.row = last
  local line = M.position_cursor(last, state.sql.cell.col)
  sql_highlights.highlight_cell(D.dataset_buffer, last, state.sql.cell.col, tab.meta, line)
end

function M.position_cursor(row, col)
  local tab = D.T()
  if not tab or not tab.meta or not D.dataset_window then return "" end
  if not vim.api.nvim_win_is_valid(D.dataset_window) then return "" end

  local line_idx = (tab.meta.data_start_line or 1) + row - 1
  local buf = vim.api.nvim_win_get_buf(D.dataset_window)

  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  local last_col = tab.meta.col_count or 0
  local ranges = sql_highlights.find_cell_ranges(line, col + 1, last_col + 1)

  local target_col = ranges and ranges.target.cursor_col or 0
  local target_disp = vim.fn.strdisplaywidth(line:sub(1, target_col))

  local saved_leftcol = vim.api.nvim_win_call(D.dataset_window, function()
    return vim.fn.winsaveview().leftcol
  end)
  local win_width = vim.api.nvim_win_get_width(D.dataset_window)

  local left_margin = 2
  local right_margin = 3
  local target_on_screen = target_disp >= math.max(0, saved_leftcol - left_margin)
    and target_disp < saved_leftcol + win_width - right_margin

  local last_col_fits = true
  if last_col > 0 and ranges and ranges.last then
    local last_right_disp = vim.fn.strdisplaywidth(line:sub(1, ranges.last.ext_end + 3))
    last_col_fits = last_right_disp <= saved_leftcol + win_width
  end

  if target_on_screen then
    local saved_sso = vim.api.nvim_get_option_value("sidescrolloff", { win = D.dataset_window })
    if saved_sso > 0 then
      vim.api.nvim_set_option_value("sidescrolloff", 0, { win = D.dataset_window })
    end
    pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { line_idx, target_col })
    pcall(vim.api.nvim_win_call, D.dataset_window, function()
      local v = vim.fn.winsaveview()
      v.leftcol = saved_leftcol
      vim.fn.winrestview(v)
    end)
    if saved_sso > 0 then
      vim.api.nvim_set_option_value("sidescrolloff", saved_sso, { win = D.dataset_window })
    end
  else
    pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { line_idx, target_col })
    if not last_col_fits then
      pcall(vim.api.nvim_win_call, D.dataset_window, function()
        vim.cmd("normal! zs")
      end)
    end
  end

  return line
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
  local sql_format = require("poste.sql.format")
  local lines, meta = sql_format.format_resultset(new_data)
  local buffer = require("poste.sql.buffer")
  buffer.render_dataset(lines, meta, { keep_tabs = true, tab_index = D.active_tab_idx })
  tab.is_sorting = false
  M.move_cell(0, 0)
end

function M.toggle_cell_highlight()
  local tab = D.T()
  state.sql.highlight_cell = not state.sql.highlight_cell
  if state.sql.highlight_cell then
    sql_highlights.highlight_cell(D.dataset_buffer, state.sql.cell.row, state.sql.cell.col, tab and tab.meta)
  else
    sql_highlights.clear_cell_highlight(D.dataset_buffer)
  end
  vim.notify(string.format("Cell highlight: %s", state.sql.highlight_cell and "ON" or "OFF"),
    vim.log.levels.INFO, { title = "Poste SQL" })
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
  if #D.tabs > 1 then
    local label = meta.table_name or ("result " .. D.active_tab_idx)
    right = string.format("[%d/%d: %s] ", D.active_tab_idx, #D.tabs, label)
  elseif meta.table_name then
    right = string.format("[%s] ", meta.table_name)
  end
  right = right .. (format_conn_short(meta.connection) or "")

  local text = left .. "%=" .. right
  return "%#PosteSqlMeta#" .. text
end
M.build_status_winbar = build_status_winbar

return M
