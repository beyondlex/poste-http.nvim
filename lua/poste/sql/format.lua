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
    end
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
--- @field col_positions number[] 0-based byte offset of each column's content start (excl. leading space)
--- @field col_byte_lens number[] Byte length of each column's content string (may differ from display width for CJK)
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
      if #results > 1 then
        table.insert(lines, string.format("  Statement %d: %d row(s) affected · %dms", i, affected, ms))
      else
        table.insert(lines, string.format("  %d row(s) affected · %dms", affected, ms))
      end
    end
    table.insert(lines, "")
    table.insert(lines, string.format("  Connection: %s%s",
      data.connection or "",
      data.database and (" / " .. data.database) or ""
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

  -- Calculate column widths (cap at 200 total width for readability)
  local col_widths = calc_column_widths(columns, rows, 200)

  -- Determine which columns are numeric (for right-alignment)
  local numeric_cols = {}
  for i = 1, #columns do
    numeric_cols[i] = is_numeric_column(rows, i)
  end

  -- col_positions and col_byte_lens will be computed from the actual rendered
  -- header line below, for accurate byte offsets (display width ≠ byte length
  -- for CJK characters and multi-byte box-drawing chars like │).

  -- Build lines
  local lines = {}
  local line_num = 0

  -- Top border
  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "┌", "┬", "┐", "─")

  -- Header row
  line_num = line_num + 1
  local header_cells = {}
  for i, col in ipairs(columns) do
    header_cells[i] = col.name
  end
  lines[line_num] = data_row(header_cells, col_widths, {})

  -- Compute col_positions and col_byte_lens from the actual rendered header.
  -- │ is 3 bytes in UTF-8, display width ≠ byte length for CJK content.
  -- Each cell in the rendered line: │<space><content><space>
  -- col_positions[i] = 0-based byte offset of the first byte of cell content
  -- col_byte_lens[i] = byte length of the cell content (padded to col_width)
  local header_line_str = lines[line_num]
  local col_positions = {}
  local col_byte_lens = {}
  local sep = "│"  -- 3 bytes
  local sep_len = #sep
  local scan = 1   -- 1-based scan position
  for i = 1, #columns do
    -- Find the next │ separator (or end of line for last cell's trailing │)
    local next_sep = header_line_str:find(sep, scan, true)
    if not next_sep then break end
    -- Content starts after │ + space
    local content_start = next_sep + sep_len + 1
    -- Find the closing │
    local close_sep = header_line_str:find(sep, content_start, true)
    if not close_sep then break end
    -- Content ends before the closing │ - space
    local content_end = close_sep - 2  -- -1 for space, -1 for inclusive→exclusive
    col_positions[i] = content_start - 1  -- 0-based byte offset
    col_byte_lens[i] = content_end - content_start + 2  -- inclusive byte length
    scan = close_sep + sep_len
  end

  local header_line = line_num

  -- Header-data separator
  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "├", "┼", "┤", "─")

  -- Data rows
  local data_start = line_num + 1
  for _, row in ipairs(rows) do
    line_num = line_num + 1
    local cells = {}
    for i = 1, #columns do
      cells[i] = cell_to_string(row[i])
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
  local total_rows = data.total_rows or #rows
  local total_ms = data.total_execution_time_ms or 0
  local conn = data.connection or ""
  if conn == vim.NIL then conn = "" end
  local db = data.database
  if db == vim.NIL then db = nil end
  local dialect = data.dialect or ""
  if dialect == vim.NIL then dialect = "" end

  line_num = line_num + 1
  local meta_line = string.format("%d row%s returned · %dms · %s%s (%s)",
    total_rows,
    total_rows == 1 and "" or "s",
    total_ms,
    conn,
    db and (" / " .. db) or "",
    dialect
  )
  lines[line_num] = meta_line

  local meta = {
    type = "resultset",
    columns = columns,
    col_widths = col_widths,
    col_positions = col_positions,
    col_byte_lens = col_byte_lens,
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
