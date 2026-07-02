--- SQL Dataset formatter — renders query results as Unicode tables.
--- Used by the Dataset buffer (bottom horizontal split).
local M = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function split_lines(s)
  local lines = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

--- Calculate display width of a string (handles wide CJK characters).
--- Uses Neovim's built-in strdisplaywidth() which correctly handles CJK, emoji, etc.
local function displaywidth(s)
  if not s then return 0 end
  return vim.fn.strdisplaywidth(s)
end

--- Truncate a string to fit within a given display width, preserving UTF-8 validity.
--- Walks character-by-character so multi-byte chars like CJK are never split.
local function truncate_to_displaywidth(s, max_dw)
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

--- Pad a string to a given display width (right-pad with spaces).
local function pad_right(s, width)
  local dw = displaywidth(s)
  if dw >= width then return s end
  return s .. string.rep(" ", width - dw)
end

--- Wrap a long line to fit within a given display width, splitting at word boundaries.
local function wrap_line(text, width)
  if displaywidth(text) <= width then return { text } end
  local lines = {}
  local current = ""
  for word in text:gmatch("%S+") do
    local sep = #current > 0 and " " or ""
    if displaywidth(current .. sep .. word) > width then
      table.insert(lines, current)
      current = word
    else
      current = current .. sep .. word
    end
  end
  if #current > 0 then table.insert(lines, current) end
  if #lines == 0 then lines = { "" } end
  return lines
end
--- Examples:
---   mysql://user:pass@localhost:13306/blog → localhost:13306/blog
---   postgres://user@host:5432/db → host:5432/db
---   sqlite:/path/to/db.sqlite → db.sqlite
--- @param conn string Connection URL
--- @return string Short display format
local function parse_connection_short(conn)  -- luacheck: ignore 211
  if not conn or conn == "" then return "unknown" end

  -- Handle SQLite: extract filename from path
  if conn:match("^sqlite:") then
    local path = conn:match("^sqlite:(.*)$") or conn
    local filename = path:match("([^/\\]+)$") or path
    return filename
  end

  -- Handle standard URLs: protocol://user:pass@host:port/db
  local host, port, db = conn:match("^%w+://[^@]*@([^:]+):(%d+)/([^?]+)")
  if host and port and db then
    -- Remove query parameters from db name
    db = db:match("^[^?]+") or db
    return string.format("%s:%s/%s", host, port, db)
  end

  -- Handle URLs without port: protocol://user:pass@host/db
  host, db = conn:match("^%w+://[^@]*@([^/]+)/([^?]+)")
  if host and db then
    db = db:match("^[^?]+") or db
    return string.format("%s/%s", host, db)
  end

  -- Fallback: return original connection string
  return conn
end

--- Pad a string to a given display width (left-pad with spaces).
local function pad_left(s, width)
  local dw = displaywidth(s)
  if dw >= width then return s end
  return string.rep(" ", width - dw) .. s
end

--- Convert a cell value to display string.
--- Newlines are replaced with ⏎ to keep table layout intact.
local function cell_to_string(val, col)
  if val == "[Auto]" then
    return "<auto>"
  end
  if type(val) == "string" and val:match("^__expr:") then
    return val:match("^__expr:(.*)$")
  end
  if val == vim.NIL or val == nil then
    if col and col.default then
      return "<default>"
    end
    return "<null>"
  end
  if type(val) == "boolean" then
    return tostring(val)
  end
  if type(val) == "number" then
    -- Avoid scientific notation for large numbers
    if val == math.floor(val) and math.abs(val) < 1e15 then
      return tostring(math.floor(val))
    end
    return tostring(val)
  end
  local s
  if type(val) == "table" then
    -- JSON/JSONB values — compact encode
    local ok, encoded = pcall(vim.json.encode, val)
    s = ok and encoded or vim.inspect(val)
  else
    s = tostring(val)
  end
  -- Replace newlines with a visual indicator so nvim_buf_set_lines doesn't break
  s = s:gsub("\r\n", "⏎"):gsub("\n", "⏎"):gsub("\r", "⏎")
  return s
end

--- Check if a column contains only numeric values (for right-alignment).
local function is_numeric_column(rows, col_idx)
  for _, row in ipairs(rows) do
    local val = row[col_idx]
    if val ~= nil and val ~= vim.NIL and type(val) ~= "number" then
      return false
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Unicode table rendering
---------------------------------------------------------------------------

--- Calculate optimal column widths for a result set.
--- @param columns table[] Column metadata
--- @param rows table[][] Row data
--- @param max_width number Maximum total table width (0 = unlimited)
--- @return number[] widths Array of column display widths
local function calc_column_widths(columns, rows, max_width)
  local widths = {}
  for i, col in ipairs(columns) do
    -- Minimum width = header name length
    widths[i] = displaywidth(col.name)
  end

  -- Expand to fit data
  for _, row in ipairs(rows) do
    for i, val in ipairs(row) do
      if i <= #widths then
        local s = cell_to_string(val, columns[i])
        widths[i] = math.max(widths[i], displaywidth(s))
      end
    end
  end

  -- Cap column widths if total exceeds max_width
  if max_width and max_width > 0 then
    -- Each column has 2 padding spaces + 1 separator = 3 extra chars
    -- Total = sum(widths) + (ncols * 3) + 1 (leading │)
    local overhead = #widths * 3 + 1
    local available = max_width - overhead
    if available < #widths then
      available = #widths -- minimum 1 char per column
    end

    local total = 0
    for _, w in ipairs(widths) do total = total + w end

    if total > available then
      -- Proportionally shrink columns, minimum 4 chars each
      local scale = available / total
      for i = 1, #widths do
        widths[i] = math.max(4, math.floor(widths[i] * scale))
      end
      -- Ensure column names are never truncated: each column must be at
      -- least as wide as its header name, even if that exceeds the cap.
      for i, col in ipairs(columns) do
        local name_w = displaywidth(col.name or "")
        if name_w > widths[i] then
          widths[i] = name_w
        end
      end
    end
  end

  -- Reserve 2 display columns per data column for sort indicator
  -- This prevents header jitter when indicator appears/disappears
  for i = 1, #widths do
    widths[i] = widths[i] + 2
  end

  return widths
end

--- Build a horizontal border line.
--- @param widths number[] Column widths
--- @param left string Left junction character
--- @param mid string Middle junction character
--- @param right string Right junction character
--- @param fill string Fill character (usually ─)
local function border_line(widths, left, mid, right, fill)
  local parts = {}
  for _, w in ipairs(widths) do
    parts[#parts + 1] = string.rep(fill, w + 2) -- +2 for padding spaces
  end
  return left .. table.concat(parts, mid) .. right
end

--- Build a data row line.
--- @param cells string[] Cell display strings
--- @param widths number[] Column widths
--- @param numeric_cols boolean[] Which columns are numeric (right-align)
local function data_row(cells, widths, numeric_cols)
  local line_buf = { "│" }
  local col_starts = {}
  local byte_pos = 3
  for i, cell in ipairs(cells) do
    if i > #widths then break end
    local w = widths[i]
    local s = displaywidth(cell) > w
      and (truncate_to_displaywidth(cell, w - 1) .. "…")
      or cell
    if numeric_cols[i] then
      s = " " .. pad_left(s, w) .. " "
    else
      s = " " .. pad_right(s, w) .. " "
    end
    line_buf[#line_buf + 1] = s
    col_starts[i] = { ext_start = byte_pos, ext_end = byte_pos + #s }
    byte_pos = byte_pos + #s
    line_buf[#line_buf + 1] = "│"
    byte_pos = byte_pos + 3
  end
  return table.concat(line_buf), col_starts
end

---------------------------------------------------------------------------
-- Dataset rendering result
---------------------------------------------------------------------------

--- Metadata about the rendered dataset, used by buffer.lua for cell navigation.
--- @class DatasetMeta
--- @field columns table[] Column metadata from the response
--- @field col_widths number[] Display width of each column
--- @field header_line number Line number of the header row
--- @field data_start_line number First line of data rows
--- @field data_end_line number Last line of data rows
--- @field row_count number Number of data rows
--- @field is_numeric boolean[] Whether each column is numeric

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Format a SQL response as a dataset table.
--- @param r table Response object (with .body as JSON string)
--- @return string[] lines Lines to display in the buffer
--- @return DatasetMeta meta Metadata for cell navigation
function M.format_dataset(r)
  local ok, data = pcall(vim.json.decode, r.body)
  if not ok or type(data) ~= "table" then
    return split_lines(r.body or "(empty)"), {}
  end

  local rtype = data.type or "unknown"

  -- USE statement: context switch
  if rtype == "use" then
    local lines = {
      "",
      "  Context switched to: " .. (data.database_name or "???"),
      "",
      string.format("  Connection: %s", data.connection or ""),
      string.format("  Dialect:    %s", data.dialect or ""),
      "",
    }
    return lines, { type = "use" }
  end

  -- Affected rows (INSERT/UPDATE/DELETE)
  if rtype == "affected" then
    local lines = { "" }
    local has_err = false
    local results = data.results or {}
    for i, res in ipairs(results) do
      if res.error then
        has_err = true
        local ms = tonumber(res.execution_time_ms) or 0
        local err_text = type(res.error) == "string" and res.error or vim.inspect(res.error)
        local msg
        if #results > 1 then
          msg = string.format("  Statement %d: ERROR · %s · %dms", i, err_text, ms)
        else
          msg = string.format("  ERROR: %s · %dms", err_text, ms)
        end
        table.insert(lines, msg)
      else
        local affected = tonumber(res.affected_rows) or 0
        local ms = tonumber(res.execution_time_ms) or 0
        local msg
        if #results > 1 then
          msg = string.format("  Statement %d: %s · %dms", i,
            affected > 0 and string.format("%d row(s) affected", affected) or "Query OK", ms)
        else
          msg = string.format("  %s · %dms",
            affected > 0 and string.format("%d row(s) affected", affected) or "Query OK", ms)
        end
        table.insert(lines, msg)
      end
    end
    if has_err then
      table.insert(lines, "")
      return lines, { type = "error" }
    end
    table.insert(lines, "")
    local db = data.database
    if type(db) ~= "string" then db = nil end
    table.insert(lines, string.format("  Connection: %s%s",
      data.connection or "",
      db and (" / " .. db) or ""
    ))
    table.insert(lines, "")
    return lines, { type = "affected" }
  end

  -- Resultset: render table
  if rtype == "resultset" then
    local layout = M.plan_resultset_layout(data)
    if not layout or #layout.columns == 0 then
      return { "", "  (no results)", "" }, { type = "empty" }, layout
    end
    local lines, meta = M.render_page(layout, 1, 50)
    meta.total_rows = layout.total_rows
    meta.table_name = data.table_name
    if layout.translated_sql then
      local footnote_width = math.max(40, (vim.o.columns or 80) - 4)
      lines[#lines + 1] = "  -- " .. (layout.original_sql or "")
      lines[#lines + 1] = ""
      local wrapped = wrap_line("  ⚡ " .. layout.translated_sql, footnote_width)
      lines[#lines + 1] = wrapped[1]
      for i = 2, #wrapped do
        lines[#lines + 1] = "     " .. wrapped[i]
      end
    end
    return lines, meta, layout
  end

  -- Fallback: raw JSON
  return split_lines(vim.json.encode(data)), { type = "raw" }
end

----------------------------------------------------------------------
-- Layout: full-table metadata (scans all rows once)
----------------------------------------------------------------------

--- Normalize raw DB type name to ctype for editor type-checking.
--- Maps database-specific type names (INT4, VARCHAR, etc.) to
--- the normalized forms used in editor.lua's type tables.
--- @param raw string Raw type name from DB (e.g. "INT4", "VARCHAR", "BOOL")
--- @return string Normalized type name (e.g. "integer", "varchar", "boolean")
function M.normalize_type(raw)
  if not raw then return "" end
  local t = raw:lower()
  local map = {
    -- PostgreSQL / generic integer
    int4 = "integer", int8 = "bigint", int2 = "smallint",
    integer = "integer", bigint = "bigint", smallint = "smallint",
    serial = "serial", bigserial = "bigserial", smallserial = "smallserial",
    tinyint = "integer",
    -- PostgreSQL/Oracle-style numeric
    numeric = "numeric", decimal = "decimal",
    float4 = "real", float8 = "float", real = "real", float = "float",
    double = "float", ["double precision"] = "float", money = "numeric",
    -- Boolean
    bool = "boolean", boolean = "boolean",
    -- Text
    text = "text", varchar = "varchar", char = "char", character = "char",
    ["character varying"] = "varchar",
    nvarchar = "nvarchar", nchar = "nchar",
    longtext = "longtext", mediumtext = "mediumtext", tinytext = "tinytext",
    citext = "text", name = "varchar",
    -- Date/time
    date = "date", timestamp = "timestamp", timestamptz = "timestamptz",
    datetime = "datetime", datetime2 = "datetime",
    time = "date", timetz = "timestamp", interval = "interval",
    -- JSON
    json = "json", jsonb = "jsonb",
    -- UUID
    uuid = "uuid",
    -- Binary / ineditable
    bytea = "bytea", blob = "blob", binary = "binary", varbinary = "varbinary",
    tinyblob = "blob", mediumblob = "blob", longblob = "blob",
    geometry = "geometry", geography = "geography",
    point = "point", polygon = "polygon", linestring = "linestring",
    multipolygon = "multipolygon",
    inet = "inet", cidr = "cidr", macaddr = "macaddr", macaddr8 = "macaddr8",
    bit = "bit", varbit = "varbit",
    tsvector = "tsvector", tsquery = "tsquery",
    xml = "xml", hstore = "hstore",
  }
  return map[t] or t
end

--- Compute layout metadata for a result set. Scans all rows for
--- column widths and numeric detection, but produces no rendered strings.
--- @param data table Parsed JSON with results, columns, rows
--- @return table|nil Layout object (nil if no results/columns)
function M.plan_resultset_layout(data)
  local results = data.results or {}
  if #results == 0 then return nil end
  local res = results[1]
  local columns = res.columns or {}
  local rows = res.rows or {}

  if #columns == 0 then return nil end

  local total_rows = tonumber(data.total_rows) or #rows
  local row_num_width = math.max(1, math.floor(math.log10(math.max(1, total_rows))) + 1)

  local col_widths = calc_column_widths(columns, rows, 200)
  table.insert(col_widths, 1, row_num_width)

  local numeric_cols = { true }
  for i = 1, #columns do
    numeric_cols[i + 1] = is_numeric_column(rows, i)
  end

  -- Normalize raw DB type names to ctype for editor type-checking
  for _, col in ipairs(columns) do
    local raw = col.type
    if raw then
      col.ctype = M.normalize_type(raw)
    end
  end

  local conn = data.connection or ""
  if conn == vim.NIL then conn = "" end
  local db = data.database
  if db == vim.NIL then db = nil end
  local dialect = data.dialect or ""
  if dialect == vim.NIL then dialect = "" end

  return {
    columns = columns,
    col_widths = col_widths,
    numeric_cols = numeric_cols,
    row_num_width = row_num_width,
    total_rows = total_rows,
    original_row_count = #rows,
    data = data,
    res = res,
    rows = rows,
    translated_sql = res.translated_sql,
    original_sql = res.original_sql,
    execution_time_ms = data.total_execution_time_ms or 0,
    connection = conn,
    database = db,
    dialect = dialect,
    table_name = data.table_name,
  }
end

--- Render a single page from a Layout. Produces a bordered table with
--- only `page_size` data rows. Column widths come from Layout (stable).
--- @param layout table Layout from plan_resultset_layout()
--- @param page number 1-based page number
--- @param page_size number Rows per page
--- @return string[] lines
--- @return DatasetMeta meta
function M.render_page(layout, page, page_size)
  local col_widths = layout.col_widths
  local columns = layout.columns
  local numeric_cols = layout.numeric_cols
  local rows = layout.rows
  local total_rows = layout.total_rows or #rows
  local total_pages = math.ceil(#rows / page_size)
  page = math.min(page, total_pages)
  if page < 1 then page = 1 end
  local start_idx = (page - 1) * page_size + 1
  local end_idx = math.min(start_idx + page_size - 1, #rows)
  local page_rows = end_idx - start_idx + 1

  local lines = {}
  local line_num = 0

  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "┌", "┬", "┐", "─")

  line_num = line_num + 1
  local header_cells = { "" }
  for i, col in ipairs(columns) do
    header_cells[i + 1] = col.name
  end
  local header_line_str, header_col_starts = data_row(header_cells, col_widths, {})
  lines[line_num] = header_line_str
  local header_line = line_num

  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "├", "┼", "┤", "─")

  local row_col_starts = {}
  local data_start = line_num + 1
  for row_idx = start_idx, end_idx do
    line_num = line_num + 1
    local cells = { tostring(row_idx) }
    for i = 1, #columns do
      cells[i + 1] = cell_to_string(rows[row_idx][i], columns[i])
    end
    local line, starts = data_row(cells, col_widths, numeric_cols)
    lines[line_num] = line
    row_col_starts[#row_col_starts + 1] = starts
  end
  if page_rows == 0 then
    line_num = line_num + 1
    local empty_cells = { "" }
    for i = 1, #columns do
      empty_cells[i + 1] = ""
    end
    lines[line_num] = data_row(empty_cells, col_widths, {})
    row_col_starts[#row_col_starts + 1] = {}
    line_num = line_num + 1
    lines[line_num] = "  (empty)"
  end
  local data_end = line_num

  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "└", "┴", "┘", "─")

  local meta = {
    type = "resultset",
    columns = columns,
    col_widths = col_widths,
    numeric_cols = numeric_cols,
    header_line = header_line,
    data_start_line = data_start,
    data_end_line = data_end,
    row_count = page_rows,
    col_count = #columns,
    total_rows = total_rows,
    total_execution_time_ms = layout.execution_time_ms,
    connection = layout.connection,
    database = layout.database,
    dialect = layout.dialect,
    table_name = layout.table_name,
    col_starts = row_col_starts,
    header_col_starts = header_col_starts,
  }

  return lines, meta
end

--- Render an arbitrary row view (filtered/sorted) from a Layout.
--- `view_indices` are 1-based indices into `layout.rows`.
--- @param layout table Layout from plan_resultset_layout()
--- @param view_indices number[] 1-based indices into layout.rows
--- @param page number 1-based page number over view_indices
--- @param page_size number Rows per page
--- @param opts? table Options: { row_number_mode = "source"|"view" }
--- @return string[] lines
--- @return DatasetMeta meta
function M.render_view(layout, view_indices, page, page_size, opts)
  opts = opts or {}
  local row_number_mode = opts.row_number_mode or "source"
  local col_widths = layout.col_widths
  local columns = layout.columns
  local numeric_cols = layout.numeric_cols
  local rows = layout.rows
  local total_view_rows = #view_indices
  local total_pages = math.ceil(total_view_rows / page_size)
  page = math.min(page, total_pages)
  if page < 1 then page = 1 end
  local start_pos = (page - 1) * page_size + 1
  local end_pos = math.min(start_pos + page_size - 1, total_view_rows)
  local page_rows = end_pos - start_pos + 1

  local lines = {}
  local line_num = 0

  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "┌", "┬", "┐", "─")

  line_num = line_num + 1
  local header_cells = { "" }
  for i, col in ipairs(columns) do
    header_cells[i + 1] = col.name
  end
  local header_line_str, header_col_starts = data_row(header_cells, col_widths, {})
  lines[line_num] = header_line_str
  local header_line = line_num

  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "├", "┼", "┤", "─")

  local row_col_starts = {}
  local data_start = line_num + 1
  for view_pos = start_pos, end_pos do
    line_num = line_num + 1
    local src_idx = view_indices[view_pos]
    local row_num = (row_number_mode == "view") and view_pos or src_idx
    local cells = { tostring(row_num) }
    for i = 1, #columns do
      cells[i + 1] = cell_to_string(rows[src_idx][i], columns[i])

    end
    local line, starts = data_row(cells, col_widths, numeric_cols)
    lines[line_num] = line
    row_col_starts[#row_col_starts + 1] = starts
  end
  local data_end = line_num
  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "└", "┴", "┘", "─")

  local meta = {
    type = "resultset",
    columns = columns,
    col_widths = col_widths,
    numeric_cols = numeric_cols,
    header_line = header_line,
    data_start_line = data_start,
    data_end_line = data_end,
    row_count = page_rows,
    col_count = #columns,
    total_rows = total_view_rows,
    total_execution_time_ms = layout.execution_time_ms,
    connection = layout.connection,
    database = layout.database,
    dialect = layout.dialect,
    table_name = layout.table_name,
    col_starts = row_col_starts,
    header_col_starts = header_col_starts,
  }

  return lines, meta
end

--- Render a resultset response as a Unicode table (legacy: all rows).
--- Used by the old path and callers still expecting full render.
--- @param data table Parsed JSON with results, columns, rows
--- @return string[] lines
--- @return DatasetMeta meta
function M.format_resultset(data)
  local layout = M.plan_resultset_layout(data)
  if not layout then
    return { "", "  (no results)", "" }, { type = "empty" }
  end
  if #layout.columns == 0 then
    return { "", "  (empty result set)", "" }, { type = "empty" }
  end

  local page_size = #layout.rows
  local lines, meta = M.render_page(layout, 1, page_size)

  if layout.translated_sql then
    local footnote_width = math.max(40, (vim.o.columns or 80) - 4)
    lines[#lines + 1] = "  -- " .. (layout.original_sql or "")
    lines[#lines + 1] = ""
    local wrapped = wrap_line("  ⚡ " .. layout.translated_sql, footnote_width)
    lines[#lines + 1] = wrapped[1]
    for i = 2, #wrapped do
      lines[#lines + 1] = "     " .. wrapped[i]
    end
  end

  meta.total_rows = layout.total_rows

  return lines, meta
end

--- Format a SQL error response.
--- @param err string Error message
--- @param connection string Connection info
--- @return string[] lines
--- Render a single data row as a formatted line.
--- @param row table Row data array
--- @param layout table Layout with columns, col_widths, numeric_cols
--- @param row_number number Row number to display
--- @return string Formatted line with │ separators
function M.render_row(row, layout, row_number)
  local cells = { tostring(row_number) }
  for i = 1, #layout.columns do
    cells[i + 1] = cell_to_string(row[i], layout.columns[i])
  end
  return data_row(cells, layout.col_widths, layout.numeric_cols)
end

--- Returns both line and col_starts (for editor.lua to update single-row cache).
--- @return string line, table col_starts
function M.render_row_with_starts(row, layout, row_number)
  local cells = { tostring(row_number) }
  for i = 1, #layout.columns do
    cells[i + 1] = cell_to_string(row[i], layout.columns[i])
  end
  return data_row(cells, layout.col_widths, layout.numeric_cols)
end

local function wrap_text(text, width)
  if not text or #text == 0 then return {} end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    while #line > width do
      local split = line:sub(1, width)
      line = line:sub(width + 1)
      table.insert(lines, split)
    end
    table.insert(lines, line)
  end
  return lines
end

function M.format_error(err, connection)
  local wrapped = wrap_text(err, 78)
  local lines = { "", "  ✗ SQL Error", "" }
  for _, l in ipairs(wrapped) do
    table.insert(lines, "  " .. l)
  end
  table.insert(lines, "")
  table.insert(lines, "  Connection: " .. (connection or "unknown"))
  table.insert(lines, "")
  return lines
end

return M
