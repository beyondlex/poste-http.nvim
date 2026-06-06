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

--- Pad a string to a given display width (right-pad with spaces).
local function pad_right(s, width)
  local dw = displaywidth(s)
  if dw >= width then return s end
  return s .. string.rep(" ", width - dw)
end

--- Parse connection URL to extract host:port/database for display.
--- Examples:
---   mysql://user:pass@localhost:13306/blog → localhost:13306/blog
---   postgres://user@host:5432/db → host:5432/db
---   sqlite:/path/to/db.sqlite → db.sqlite
--- @param conn string Connection URL
--- @return string Short display format
local function parse_connection_short(conn)
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
local function cell_to_string(val)
  if val == vim.NIL or val == nil then
    return "(NULL)"
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
        local s = cell_to_string(val)
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
  local parts = {}
  for i, cell in ipairs(cells) do
    if i > #widths then break end
    local w = widths[i]
    local s = displaywidth(cell) > w
      and (cell:sub(1, w - 1) .. "…")  -- truncate with ellipsis
      or cell
    if numeric_cols[i] then
      parts[#parts + 1] = " " .. pad_left(s, w) .. " "
    else
      parts[#parts + 1] = " " .. pad_right(s, w) .. " "
    end
  end
  return "│" .. table.concat(parts, "│") .. "│"
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
    local results = data.results or {}
    for i, res in ipairs(results) do
      local affected = res.affected_rows or 0
      local ms = res.execution_time_ms or 0
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
    return M.format_resultset(data)
  end

  -- Fallback: raw JSON
  return split_lines(vim.json.encode(data)), { type = "raw" }
end

--- Render a resultset response as a Unicode table.
--- @param data table Parsed JSON with results, columns, rows
--- @return string[] lines
--- @return DatasetMeta meta
function M.format_resultset(data)
  local results = data.results or {}
  if #results == 0 then
    return { "", "  (no results)", "" }, { type = "empty" }
  end

  -- For now, render only the first result set.
  -- Multi-result tabs will be implemented in Phase 6.
  local res = results[1]
  local columns = res.columns or {}
  local rows = res.rows or {}

  if #columns == 0 then
    return { "", "  (empty result set)", "" }, { type = "empty" }
  end

  -- Row number column width (based on total row count for consistent width)
  local total_rows = data.total_rows or #rows
  local row_num_width = math.max(1, math.floor(math.log10(math.max(1, total_rows))) + 1)

  -- Calculate column widths (cap at 200 total width for readability)
  local col_widths = calc_column_widths(columns, rows, 200)

  -- Prepend row number column (always right-aligned)
  table.insert(col_widths, 1, row_num_width)

  -- Determine which columns are numeric (for right-alignment)
  local numeric_cols = { true }  -- row number column
  for i = 1, #columns do
    numeric_cols[i + 1] = is_numeric_column(rows, i)
  end

  -- Build lines
  local lines = {}
  local line_num = 0

  -- Top border
  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "┌", "┬", "┐", "─")

  -- Header row
  line_num = line_num + 1
  local header_cells = { "" }  -- empty header for row number column
  for i, col in ipairs(columns) do
    header_cells[i + 1] = col.name
  end
  lines[line_num] = data_row(header_cells, col_widths, {})

  local header_line = line_num

  -- Header-data separator
  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "├", "┼", "┤", "─")

  -- Data rows
  local data_start = line_num + 1
  for row_idx, row in ipairs(rows) do
    line_num = line_num + 1
    local cells = { tostring(row_idx) }  -- row number
    for i = 1, #columns do
      cells[i + 1] = cell_to_string(row[i])
    end
    lines[line_num] = data_row(cells, col_widths, numeric_cols)
  end
  local data_end = line_num

  -- Bottom border
  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "└", "┴", "┘", "─")

  -- Blank line before meta
  line_num = line_num + 1
  lines[line_num] = ""

  -- Meta footer
  local total_ms = data.total_execution_time_ms or 0
  local conn = data.connection or ""
  if conn == vim.NIL then conn = "" end
  local db = data.database
  if db == vim.NIL then db = nil end
  local dialect = data.dialect or ""
  if dialect == vim.NIL then dialect = "" end

  line_num = line_num + 1
  -- Extract short connection format (host:port/database) from full URL
  local conn_short = parse_connection_short(conn)

  -- Try to get table name from response metadata, fallback to database or dialect
  local table_name = data.table or db or dialect or "query"
  if table_name == vim.NIL then table_name = "query" end

  local meta_line = string.format("%d row%s returned · %dms · %s (%s)",
    total_rows,
    total_rows == 1 and "" or "s",
    total_ms,
    conn_short,
    table_name
  )
  lines[line_num] = meta_line

  local meta = {
    type = "resultset",
    columns = columns,
    col_widths = col_widths,
    numeric_cols = numeric_cols,
    header_line = header_line,
    data_start_line = data_start,
    data_end_line = data_end,
    meta_line = line_num,
    row_count = #rows,
    col_count = #columns,
    total_rows = total_rows,
    connection = conn,
    database = db,
    dialect = dialect,
  }

  return lines, meta
end

--- Format a SQL error response.
--- @param err string Error message
--- @param connection string Connection info
--- @return string[] lines
function M.format_error(err, connection)
  return {
    "",
    "  ✗ SQL Error",
    "",
    "  " .. err,
    "",
    "  Connection: " .. (connection or "unknown"),
    "",
  }
end

return M
