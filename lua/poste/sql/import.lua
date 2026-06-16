--- SQL Data Import — CSV, TSV, JSON → INSERT.
--- Entry from DB Browser context menu on BASE TABLE nodes.
--- Async flow: columns → source → parse → map → validate → preview → execute.

local state = require("poste.state")
local async = require("poste.sql.db_browser.async")
local edit_commit = require("poste.sql.edit_commit")

local M = {}

local INTEGER_TYPES = {
  integer = true, int = true, int2 = true, int4 = true, int8 = true,
  smallint = true, bigint = true, serial = true, bigserial = true,
  tinyint = true, mediumint = true,
}

--- Extract column metadata from an expanded table node's children.
local function get_columns_from_node(table_node)
  if not table_node.children or #table_node.children == 0 then return nil end
  local cols = {}
  for _, child in ipairs(table_node.children) do
    if child.node_type == "column" then
      table.insert(cols, {
        name = child.name,
        col_type = child.meta and child.meta.col_type or "TEXT",
        is_pk = child.meta and child.meta.is_pk or false,
        nullable = child.meta and child.meta.nullable ~= false,
        default = child.meta and child.meta.default or nil,
        extra = child.meta and child.meta.extra or "",
      })
    end
  end
  if #cols == 0 then return nil end
  return cols
end

--- Fetch column info via introspect (async). Fires callback(cols) when done.
local function fetch_columns_async(node, context, callback)
  local conn = node.meta and node.meta.connection or state.sql.db_browser.connection
  local dir = vim.fn.getcwd()
  if context.source_buf and vim.api.nvim_buf_is_valid(context.source_buf) then
    local buf_name = vim.api.nvim_buf_get_name(context.source_buf)
    if buf_name ~= "" then dir = vim.fn.fnamemodify(buf_name, ":p:h") end
  end

  vim.notify("Loading column info for " .. node.name .. "...", vim.log.levels.INFO)

  async.run_introspect(conn, "columns", node.meta and node.meta.schema, node.name,
    node.meta and node.meta.database, function(result)
    if not result or not result.items then
      vim.notify("Failed to load column info for " .. node.name, vim.log.levels.ERROR)
      callback(nil)
      return
    end
    local cols = {}
    for _, item in ipairs(result.items) do
      table.insert(cols, {
        name = item.name,
        col_type = item.type or "TEXT",
        is_pk = item.pk or false,
        nullable = item.nullable ~= false,
        default = item.default,
        extra = item.extra or "",
      })
    end
    callback(cols)
  end, dir)
end

--- Get columns from node (sync if expanded, async if not).
local function get_or_fetch_columns(node, context, callback)
  local cols = get_columns_from_node(node)
  if cols then
    callback(cols)
    return
  end
  fetch_columns_async(node, context, callback)
end

--- Get search directory for connections.json discovery.
local function get_search_dir(context)
  if context.source_buf and vim.api.nvim_buf_is_valid(context.source_buf) then
    local buf_name = vim.api.nvim_buf_get_name(context.source_buf)
    if buf_name ~= "" then return vim.fn.fnamemodify(buf_name, ":p:h") end
  end
  return vim.fn.getcwd()
end

--- Build table_info from node + context.
local function build_table_info(node, context)
  local dialect = "postgres"
  if node.meta and node.meta.dialect then
    dialect = node.meta.dialect
  else
    local conn_name = node.meta and node.meta.connection
    for _, root in ipairs(context.root_nodes) do
      if root.name == conn_name then dialect = root.meta and root.meta.dialect or "postgres"; break end
    end
  end
  return {
    name = node.name,
    schema = node.meta and node.meta.schema,
    database = node.meta and node.meta.database,
    connection = node.meta and node.meta.connection,
    dialect = dialect,
    search_dir = get_search_dir(context),
  }
end

--- Strip BOM and normalize line endings.
local function normalize_text(text)
  -- Strip UTF-8 BOM
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
  -- Normalize \r\n → \n
  text = text:gsub("\r\n", "\n")
  -- Strip trailing \r (old Mac style)
  text = text:gsub("\r", "\n")
  return text
end

--- Parse CSV text. Returns { columns = {name,...}, rows = {{val,...},...} } or nil,err.
--- @return {columns={string,...}, rows={{string,...},...}}|nil, err
local function parse_csv(text)
  text = normalize_text(text)
  local raw_lines = vim.split(text, "\n")
  local parsed_rows = {}
  for _, raw in ipairs(raw_lines) do
    local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then
      local row = {}
      local i = 1
      while i <= #trimmed do
        if trimmed:sub(i, i) == '"' then
          local val = {}
          i = i + 1
          while i <= #trimmed do
            local ch = trimmed:sub(i, i)
            if ch == '"' then
              if trimmed:sub(i + 1, i + 1) == '"' then
                table.insert(val, '"')
                i = i + 2
              else
                i = i + 1
                break
              end
            else
              table.insert(val, ch)
              i = i + 1
            end
          end
          table.insert(row, table.concat(val))
          local next = trimmed:sub(i, i)
          if next == "," then i = i + 1 end
        else
          local comma = trimmed:find(",", i)
          if comma then
            table.insert(row, trimmed:sub(i, comma - 1))
            i = comma + 1
          else
            table.insert(row, trimmed:sub(i))
            break
          end
        end
      end
      table.insert(parsed_rows, row)
    end
  end

  if #parsed_rows == 0 then
    return nil, "No data rows found"
  end

  local header = parsed_rows[1]
  local num_cols = #header
  local data_rows = {}
  for i = 2, #parsed_rows do
    local row = parsed_rows[i]
    if #row ~= num_cols then
      return nil, string.format("Row %d: expected %d columns, got %d", i, num_cols, #row)
    end
    table.insert(data_rows, row)
  end

  return { columns = header, rows = data_rows }
end

--- Parse TSV text.
local function parse_tsv(text)
  text = normalize_text(text)
  local raw_lines = vim.split(text, "\n")
  local rows = {}
  for _, raw in ipairs(raw_lines) do
    local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then
      local row = vim.split(trimmed, "\t")
      table.insert(rows, row)
    end
  end

  if #rows == 0 then
    return nil, "No data rows found"
  end

  local header = rows[1]
  local num_cols = #header
  local data_rows = {}
  for i = 2, #rows do
    local row = rows[i]
    if #row ~= num_cols then
      return nil, string.format("Row %d: expected %d columns, got %d", i, num_cols, #row)
    end
    table.insert(data_rows, row)
  end

  return { columns = header, rows = data_rows }
end

--- Parse JSON text (array of objects).
local function parse_json(text)
  text = normalize_text(text)
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" then
    return nil, "Invalid JSON: " .. tostring(ok)
  end
  if #data == 0 then
    return nil, "JSON array is empty"
  end

  -- Collect all unique keys, sorted alphabetically (deterministic)
  local seen = {}
  for _, obj in ipairs(data) do
    if type(obj) == "table" then
      for k, _ in pairs(obj) do
        seen[k] = true
      end
    end
  end
  local keys = {}
  for k, _ in pairs(seen) do
    table.insert(keys, k)
  end
  table.sort(keys)

  if #keys == 0 then
    return nil, "No keys found in JSON objects"
  end

  local rows = {}
  for _, obj in ipairs(data) do
    if type(obj) ~= "table" then
      return nil, "Expected array of objects"
    end
    local row = {}
    for _, k in ipairs(keys) do
      local v = obj[k]
      if v == nil or v == vim.NIL then
        table.insert(row, vim.NIL)
      else
        table.insert(row, tostring(v))
      end
    end
    table.insert(rows, row)
  end

  return { columns = keys, rows = rows }
end

--- Detect import format from file path or content heuristic.
--- @return string "csv"|"tsv"|"json"|nil
local function detect_format(content, filepath)
  if filepath then
    local ext = filepath:lower():match("%.([^%.]+)$")
    if ext == "csv" then return "csv" end
    if ext == "tsv" then return "tsv" end
    if ext == "json" then return "json" end
  end

  -- Content heuristic
  local trimmed = content:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed:sub(1, 1) == "[" or trimmed:sub(1, 1) == "{" then
    local ok, _ = pcall(vim.json.decode, trimmed)
    if ok then return "json" end
  end

  local first_line = content:match("^[^\n]+")
  if first_line then
    local tab_count = select(2, first_line:gsub("\t", ""))
    local comma_count = select(2, first_line:gsub(",", ""))
    if tab_count > comma_count and tab_count > 0 then
      return "tsv"
    end
    if comma_count > 0 then
      return "csv"
    end
  end

  return nil
end

--- Type-aware string-to-value coercion (subset of editor.parse_value).
local function coerce_value(str, col_type)
  if str == nil or str == vim.NIL then return vim.NIL end
  local s = tostring(str):gsub("^%s+", ""):gsub("%s+$", "")

  -- Empty string → nil (will use DB default)
  if s == "" then return nil end

  -- Explicit NULL
  if s == "NULL" or s == "(NULL)" then return vim.NIL end

  -- Boolean (text forms always; numeric "1"/"0" only for boolean columns)
  local ctype = (col_type or ""):lower()
  if s == "true" or s == "TRUE" then return true end
  if s == "false" or s == "FALSE" then return false end
  if ctype == "boolean" or ctype == "bool" then
    if s == "1" then return true end
    if s == "0" then return false end
  end

  -- Numeric
  local num = tonumber(s)
  if num and s:match("^%-?%d+%.?%d*$") then
    if INTEGER_TYPES[ctype] and num ~= math.floor(num) then
      -- not an integer, let it pass as string
    else
      return num
    end
  end

  -- Default: string
  return s
end

--- Build column mapping between import columns and table columns.
--- @return table col_map: array of {import_idx, import_name, table_col, table_idx}
--- @return table unmatched_import: import column names not found in table
--- @return table unmatched_table: table columns not present in import
local function build_column_map(parsed_cols, table_cols)
  local col_map = {}
  local unmatched_import = {}
  local matched_table = {}
  local unmatched_table = {}

  for ii, name in ipairs(parsed_cols) do
    local found = false
    for ti, tc in ipairs(table_cols) do
      if tc.name:lower() == name:lower() then
        table.insert(col_map, {
          import_idx = ii,
          import_name = name,
          table_col = tc,
          table_idx = ti,
        })
        matched_table[ti] = true
        found = true
        break
      end
    end
    if not found then
      table.insert(unmatched_import, name)
    end
  end

  for ti, tc in ipairs(table_cols) do
    if not matched_table[ti] then
      table.insert(unmatched_table, tc)
    end
  end

  return col_map, unmatched_import, unmatched_table
end

--- Build a row_values array aligned with table columns.
--- @param import_row table Array of string values from parsed import file
--- @param col_map table Column mapping from build_column_map
--- @param num_table_cols number Number of columns in the table
--- @return table row_values aligned to table column positions (nil for missing)
local function build_row_values(import_row, col_map, num_table_cols)
  local row_values = {}
  for i = 1, num_table_cols do
    row_values[i] = nil
  end
  for _, mc in ipairs(col_map) do
    row_values[mc.table_idx] = import_row[mc.import_idx]
  end
  return row_values
end

--- Normalize column metadata: convert is_pk → primary_key for edit_commit.generate_insert.
local function normalize_columns(table_cols)
  local cols = {}
  for _, tc in ipairs(table_cols) do
    table.insert(cols, {
      name = tc.name,
      type = tc.col_type,
      primary_key = tc.is_pk,
    })
  end
  return cols
end

--- Validate and type-coerce all rows.
--- @return table valid_rows array of row_values (positional, aligned to table cols)
--- @return table bad_rows array of {row_idx, import_row, errors}
local function validate_and_type(import_rows, col_map, table_cols, unmatched_table)
  local norm_cols = normalize_columns(table_cols)
  local valid = {}
  local bad = {}

  for ri, import_row in ipairs(import_rows) do
    local row_vals = build_row_values(import_row, col_map, #table_cols)
    local row_errors = {}

    for _, mc in ipairs(col_map) do
      local raw_val = import_row[mc.import_idx]
      local coerced = coerce_value(raw_val, mc.table_col.col_type)
      row_vals[mc.table_idx] = coerced

      -- PK column present but null
      if mc.table_col.is_pk and (coerced == nil or coerced == vim.NIL) then
        if not (mc.table_col.extra and mc.table_col.extra:find("auto", 1, true)) then
          table.insert(row_errors, string.format("  %s: primary key column '%s' cannot be null",
            ri + 1, mc.table_col.name))
        end
      end
    end

    if #row_errors > 0 then
      table.insert(bad, { row_idx = ri + 1, import_row = import_row, errors = row_errors })
    else
      table.insert(valid, row_vals)
    end
  end

  return valid, bad
end

--- Build preview lines for the float window.
local function build_preview_lines(table_info, total_rows, valid_count, bad_rows,
    col_map, unmatched_import, unmatched_table, parsed_cols, parsed_rows, max_preview_cols)
  local lines = {}
  local function add(l) table.insert(lines, l) end

  add(string.format("Table: %s.%s    Connection: %s (%s)",
    table_info.schema or "(default)", table_info.name,
    table_info.connection, table_info.dialect))
  add("")
  add(string.format("Parsed: %d rows total, %d valid, %d with errors",
    total_rows, valid_count, #bad_rows))

  if parsed_rows and #parsed_rows > 0 then
    add("")
    add("Data preview (first rows):")

    local num_preview_cols = math.min(max_preview_cols, #parsed_cols)
    local has_more_cols = num_preview_cols < #parsed_cols
    local num_preview_rows = math.min(3, #parsed_rows)

    local col_vals = {}
    for ci = 1, num_preview_cols do
      local vals = { parsed_cols[ci] }
      for ri = 1, num_preview_rows do
        local v = parsed_rows[ri][ci]
        local display
        if v == nil or v == vim.NIL then display = "NULL"
        elseif type(v) == "string" then display = v
        else display = tostring(v) end
        table.insert(vals, display)
      end
      table.insert(col_vals, vals)
    end

    local col_widths = {}
    for ci = 1, num_preview_cols do
      local max_w = 0
      for _, val in ipairs(col_vals[ci]) do
        max_w = math.max(max_w, vim.fn.strdisplaywidth(val))
      end
      col_widths[ci] = max_w
    end

    local function pad_val(vals, ri, cw)
      local val = vals[ri]
      local pad = cw - vim.fn.strdisplaywidth(val)
      if pad > 0 then val = val .. string.rep(" ", pad) end
      return val
    end

    local sep_parts = {}
    for ci = 1, num_preview_cols do
      sep_parts[ci] = string.rep("-", col_widths[ci])
    end

    local ext_suffix = ""
    if has_more_cols then ext_suffix = " | ..." end

    -- Header row
    local header_cells = {}
    for ci = 1, num_preview_cols do
      table.insert(header_cells, pad_val(col_vals[ci], 1, col_widths[ci]))
    end
    add("  " .. table.concat(header_cells, " | ") .. ext_suffix)

    -- Separator
    add("  " .. table.concat(sep_parts, "-|-") .. ext_suffix)

    -- Data rows
    for ri = 1, num_preview_rows do
      local data_cells = {}
      for ci = 1, num_preview_cols do
        table.insert(data_cells, pad_val(col_vals[ci], ri + 1, col_widths[ci]))
      end
      add("  " .. table.concat(data_cells, " | ") .. ext_suffix)
    end

    if #parsed_rows > 3 then
      add("  ... (" .. (#parsed_rows - 3) .. " more row(s))")
    end
  end

  add("")
  add("Column mapping:")
  local col_lines = {}
  local max_import_w = math.max(4, 0)  -- "file" = 4
  local max_table_w = math.max(5, 0)   -- "table" = 5
  for _, mc in ipairs(col_map) do
    local iw = vim.fn.strdisplaywidth(mc.import_name)
    local tw = vim.fn.strdisplaywidth(mc.table_col.name .. " (" .. mc.table_col.col_type .. ")")
    if iw > max_import_w then max_import_w = iw end
    if tw > max_table_w then max_table_w = tw end
  end
  local sep = "  " .. string.rep("-", max_import_w) .. "-+-" .. string.rep("-", max_table_w)
  local function fmt_row(left, right)
    local l = left .. string.rep(" ", max_import_w - vim.fn.strdisplaywidth(left))
    local r = right .. string.rep(" ", max_table_w - vim.fn.strdisplaywidth(right))
    return "  " .. l .. " | " .. r
  end
  add(sep)
  add(fmt_row("file", "table"))
  add(sep)
  local orange_rows = {}
  for i, mc in ipairs(col_map) do
    local tc = mc.table_col
    local right = tc.name .. " (" .. tc.col_type .. ")"
    add(fmt_row(mc.import_name, right))
    if tc and not tc.nullable and not tc.is_pk and (tc.default == nil or tc.default == vim.NIL) then
      table.insert(orange_rows, #lines)
    end
  end

  if #unmatched_import > 0 then
    add(string.format("  (unmatched: %s)", table.concat(unmatched_import, ", ")))
  end
  if #unmatched_table > 0 then
    local names = {}
    for _, tc in ipairs(unmatched_table) do
      table.insert(names, tc.name)
    end
    add(string.format("  (missing: %s <- DEFAULT)", table.concat(names, ", ")))
  end

  if #bad_rows > 0 then
    add("")
    add("Validation errors:")
    for i = 1, math.min(#bad_rows, 5) do
      for _, err in ipairs(bad_rows[i].errors) do
        add(err)
      end
    end
    if #bad_rows > 5 then
      add(string.format("  ... and %d more row(s) with errors", #bad_rows - 5))
    end
  end

  return lines, orange_rows
end

--- Show preview in a float window with action keymaps.
local function show_preview(table_info, total_rows, valid_count, bad_rows,
    col_map, unmatched_import, unmatched_table, parsed_cols, parsed_rows, callback)
  local max_preview_cols = 6
  local content, orange_rows = build_preview_lines(table_info, total_rows, valid_count, bad_rows,
    col_map, unmatched_import, unmatched_table, parsed_cols, parsed_rows, max_preview_cols)

  local content_width = 0
  for _, l in ipairs(content) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(l))
  end
  local min_width = 60
  local text_area = math.max(content_width, min_width)
  width = math.min(text_area + 4, math.floor(vim.o.columns * 0.8))
  text_area = width - 4

  local lines = content
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.6))

  -- Build border title: left "Import Preview", right action prompt, ── fill
  local right_title = " [P]roceed  [A]bort "
  if #bad_rows > 0 then
    right_title = " [P]roceed  [S]kip bad  [A]bort "
  end
  local left_title = " Import Preview "
  local interior = width - 2
  local left_w = vim.fn.strdisplaywidth(left_title)
  local right_w = vim.fn.strdisplaywidth(right_title)
  local middle_w = interior - left_w - right_w
  local title
  if middle_w >= 1 then
    title = left_title .. string.rep("─", middle_w) .. right_title
  else
    title = " Import Preview "
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win_opts = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height, style = "minimal",
    border = "rounded", title = title, title_pos = "left",
  }
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, win_opts)
  if not ok then
    win_opts.title = nil
    win = vim.api.nvim_open_win(buf, true, win_opts)
  end

  vim.wo[win].cursorline = false
  vim.wo[win].cursorcolumn = false

  local ns = vim.api.nvim_create_namespace("poste_import_preview")

  -- Highlight "Parsed:" line (index 2, 0-indexed)
  local parsed_li = 2
  local parsed_text = lines[parsed_li + 1]
  if parsed_text then
    local s1, e1 = parsed_text:find("%d+", 9)
    local s2, e2 = parsed_text:find("%d+", e1 + 1)
    local s3, e3 = parsed_text:find("%d+", e2 + 1)
    if s1 then vim.api.nvim_buf_add_highlight(buf, ns, "Number", parsed_li, s1 - 1, e1) end
    if s2 then vim.api.nvim_buf_add_highlight(buf, ns, "String", parsed_li, s2 - 1, e2) end
    if s3 then vim.api.nvim_buf_add_highlight(buf, ns, "DiagnosticError", parsed_li, s3 - 1, e3) end
  end

  -- Highlight columns that are NOT NULL, no default, and not PK
  for _, li in ipairs(orange_rows) do
    vim.api.nvim_buf_add_highlight(buf, ns, "DiagnosticWarn", li - 1, 0, -1)
  end

  local closed = false
  local function close()
    if closed then return end
    closed = true
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local sopts = { buffer = buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "q", close, sopts)
  vim.keymap.set("n", "<Esc>", close, sopts)
  vim.keymap.set("n", "a", function() close(); callback(nil) end, sopts)
  vim.keymap.set("n", "A", function() close(); callback(nil) end, sopts)
  vim.keymap.set("n", "p", function() close(); callback("proceed") end, sopts)
  vim.keymap.set("n", "P", function() close(); callback("proceed") end, sopts)
  if #bad_rows > 0 then
    vim.keymap.set("n", "s", function() close(); callback("skip") end, sopts)
    vim.keymap.set("n", "S", function() close(); callback("skip") end, sopts)
  end
end

--- Deduplicate doubled error messages like "X: X" -> "X".
local function dedup_error(msg)
  local s = msg:match("^error returned from database: (.*)")
  if not s then s = msg end
  -- Check for duplication pattern: body ends with ": " .. prefix
  local n = #s
  for i = 1, math.floor((n - 2) / 2) do
    local left = s:sub(1, i)
    local sep = s:sub(i + 1, i + 2)
    if sep == ": " and s:sub(i + 3) == left then
      return left
    end
  end
  return s
end

--- Group identical errors and show in a floating window.
local function show_import_errors(errors)
  if #errors == 0 then return end
  local groups = {}
  local order = {}
  for _, err in ipairs(errors) do
    local text = dedup_error(err.error)
    if groups[text] then
      groups[text].count = groups[text].count + 1
    else
      groups[text] = { count = 1, row = err.row, chunk_start = err.chunk_start, chunk_end = err.chunk_end }
      table.insert(order, text)
    end
  end

  local lines = {}
  local function add(l) table.insert(lines, l) end
  for _, text in ipairs(order) do
    local g = groups[text]
    add("")
    local suffix = g.count > 1 and string.format(" (%dx)", g.count) or ""
    local r = g.row or g.chunk_start
    local label = g.row and string.format("Row %d", r) or string.format("Row %d-%d", g.chunk_start, g.chunk_end)
    add(label .. suffix .. ":")
    for _, eline in ipairs(vim.split(text, "\n")) do
      add("  " .. eline)
    end
  end

  if #lines == 0 then return end

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 4, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "log"

  local win_opts = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height, style = "minimal",
    border = "rounded", title = "Import Errors", title_pos = "left",
  }
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, win_opts)
  if not ok then
    win_opts.title = nil
    win = vim.api.nvim_open_win(buf, true, win_opts)
  end
  vim.wo[win].wrap = true
  local sopts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, sopts)
  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, sopts)
end

--- Execute import: chunked INSERTs via --stdin.
--- @param callback function(result) where result = {imported, errors} or nil on failure
local function execute_import(table_info, valid_rows, col_map, table_cols, callback)
  if #valid_rows == 0 then
    vim.notify("No valid rows to import", vim.log.levels.WARN)
    if callback then callback(nil) end
    return
  end

  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found", vim.log.levels.ERROR)
    if callback then callback(nil) end
    return
  end

  local norm_cols = normalize_columns(table_cols)
  local chunk_size = state.config.import_chunk_size or 100
  local total_imported = 0
  local all_errors = {}

  -- We need a file path for connections.json discovery; create in search_dir
  local src_file = table_info.search_dir .. "/.__poste_import_temp.sql"

  -- Build @connection prefix
  local conn_prefix = ""
  if table_info.connection and table_info.connection ~= "" then
    conn_prefix = "-- @connection " .. table_info.connection .. "\n"
  end
  local db_prefix = ""
  if table_info.database and table_info.database ~= "" then
    db_prefix = "-- @database " .. table_info.database .. "\n"
  end

  local function send_chunk(start_idx)
    if start_idx > #valid_rows then
      vim.schedule(function()
        local msg = string.format("Imported %d rows into %s%s",
          total_imported,
          table_info.schema and (table_info.schema .. ".") or "",
          table_info.name)
        if #all_errors > 0 then
          vim.notify(msg .. string.format(" (%d chunk(s) with errors)", #all_errors), vim.log.levels.WARN)
          show_import_errors(all_errors)
        else
          vim.notify(msg, vim.log.levels.INFO)
        end
        if callback then callback({ imported = total_imported, errors = all_errors }) end
      end)
      return
    end

    local end_idx = math.min(start_idx + chunk_size - 1, #valid_rows)
    local sql_parts = {}
    for i = start_idx, end_idx do
      local row_vals = valid_rows[i]
      local stmt = edit_commit.generate_insert(
        table_info.schema, table_info.name, norm_cols, row_vals, table_info.dialect)
      table.insert(sql_parts, stmt)
    end
    local sql_content = conn_prefix .. db_prefix .. table.concat(sql_parts, "\n")

    state.log("INFO", string.format("Import chunk: rows %d-%d (%d rows, target=%s.%s)",
      start_idx, end_idx, end_idx - start_idx + 1,
      table_info.schema or "(default)", table_info.name))

    local cmd = { binary, "run", "--stdin", "--line", "2", "--json", src_file }
    local stderr_buf = {}
    local job_id = vim.fn.jobstart(cmd, {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        if not data or #data == 0 then
          send_chunk(end_idx + 1)
          return
        end
        local output = table.concat(data, "\n")
        local ok_r, resp = pcall(vim.json.decode, output)
        if not ok_r or not resp then
          table.insert(all_errors, {
            chunk_start = start_idx, chunk_end = end_idx,
            error = "JSON parse error:\n" .. output,
          })
          send_chunk(end_idx + 1)
          return
        end

        local ok_body, body = pcall(vim.json.decode, resp.body or "{}")
        if not ok_body or type(body) ~= "table" then body = {} end

        if body.has_error and body.results then
          for ri, result in ipairs(body.results) do
            if result.error and result.error ~= "" then
              table.insert(all_errors, {
                row = start_idx + ri - 1,
                chunk_start = start_idx, chunk_end = end_idx,
                error = result.error,
              })
            end
          end
        end

        local affected = 0
        if body.results then
          for _, result in ipairs(body.results) do
            local ar = result.affected_rows
            if type(ar) == "number" then affected = affected + ar end
          end
        end
        total_imported = total_imported + affected
        send_chunk(end_idx + 1)
      end,
      on_stderr = function(_, data)
        if not data then return end
        for _, l in ipairs(data) do
          if l ~= "" then table.insert(stderr_buf, l) end
        end
      end,
      on_exit = function(_, code)
        if code ~= 0 then
          local s = table.concat(stderr_buf, "\n")
          if s ~= "" then
            table.insert(all_errors, {
              chunk_start = start_idx, chunk_end = end_idx,
              error = "Process error (code " .. code .. "):\n" .. s,
            })
            state.log("WARN", "Import chunk stderr: " .. s)
          end
        end
      end,
    })

    if job_id > 0 then
      vim.fn.chansend(job_id, sql_content)
      vim.fn.chanclose(job_id, "stdin")
    else
      vim.schedule(function()
        vim.notify("Failed to start poste job for import chunk", vim.log.levels.ERROR)
      end)
    end
  end

  send_chunk(1)
end

--- Pick import source: file or clipboard.
local function pick_source(callback)
  vim.ui.select({
    "From File...",
    "From Clipboard",
  }, {
    prompt = "Import source:",
  }, function(choice)
    if not choice then
      callback(nil)
      return
    end
    if choice == "From Clipboard" then
      callback("clipboard", nil)
    else
      callback("file", nil)
    end
  end)
end

--- Read source content: file or clipboard.
--- @param source_type "file"|"clipboard"
--- @param path string|nil File path (nil for clipboard)
--- @return string|nil content, string|nil error
local function read_source(source_type, path)
  if source_type == "clipboard" then
    local content = vim.fn.getreg("+")
    if not content or content == "" then
      return nil, "Clipboard is empty"
    end
    -- Strip trailing newline that getreg may add
    content = content:gsub("\n$", "")
    return content, nil
  end

  if not path then
    return nil, "No file selected"
  end

  local f, err = io.open(path, "r")
  if not f then
    return nil, "Cannot open file: " .. tostring(err)
  end
  local content = f:read("*a")
  f:close()

  if not content or content == "" then
    return nil, "File is empty"
  end

  return content, nil
end

--- Process parsed data: map, validate, preview, execute.
local function process_import(content, filepath, table_info, table_cols)
  local format = detect_format(content, filepath)
  if not format then
    vim.notify("Could not detect data format (supported: CSV, TSV, JSON)", vim.log.levels.ERROR)
    return
  end

  -- Simplified source label for display
  local source_label = filepath or "clipboard"

  local parsed, err
  if format == "csv" then
    parsed, err = parse_csv(content)
  elseif format == "tsv" then
    parsed, err = parse_tsv(content)
  elseif format == "json" then
    parsed, err = parse_json(content)
  end

  if not parsed then
    vim.notify(string.format("Parse error (%s): %s", source_label, err or "unknown"),
      vim.log.levels.ERROR)
    return
  end

  if #parsed.rows == 0 then
    vim.notify("No data rows found in " .. source_label, vim.log.levels.WARN)
    return
  end

  -- Build column mapping
  local col_map, unmatched_import, unmatched_table = build_column_map(parsed.columns, table_cols)

  if #col_map == 0 then
    vim.notify("No columns matched between import data and table " .. table_info.name
      .. " (import columns: " .. table.concat(parsed.columns, ", ") .. ")",
      vim.log.levels.ERROR)
    return
  end

  if #unmatched_import > 0 then
    vim.notify("Import blocked: file has columns not in table " .. table_info.name
      .. ": " .. table.concat(unmatched_import, ", ")
      .. " (matched: " .. table.concat(parsed.columns, ", ") .. ")",
      vim.log.levels.ERROR)
    return
  end

  -- Validate
  local valid_rows, bad_rows = validate_and_type(parsed.rows, col_map, table_cols, unmatched_table)

  -- Preview and confirm
  show_preview(table_info, #parsed.rows, #valid_rows, bad_rows,
    col_map, unmatched_import, unmatched_table, parsed.columns, parsed.rows, function(action)
    if not action then
      vim.notify("Import cancelled", vim.log.levels.INFO)
      return
    end

    local rows_to_import = valid_rows
    if action == "skip" and #bad_rows > 0 then
      rows_to_import = valid_rows
      vim.notify(string.format("Skipping %d row(s) with validation errors", #bad_rows),
        vim.log.levels.WARN)
    end

    execute_import(table_info, rows_to_import, col_map, table_cols, function(result)
      if result and result.imported > 0 then
        -- Refresh the DB Browser table node
        -- Find the table node in the browser context and re-fetch its children
        -- This is tricky since we don't have a reference to the browser state.
        -- For now, the user can press 'r' on the table to refresh.
      end
    end)
  end)
end

--- Main import entry. Called from operations.lua.
function M.run(table_node, context)
  if table_node.meta and table_node.meta.table_type == "VIEW" then
    vim.notify("Cannot import data into a view", vim.log.levels.WARN)
    return
  end

  local table_info = build_table_info(table_node, context)

  get_or_fetch_columns(table_node, context, function(table_cols)
    if not table_cols or #table_cols == 0 then
      vim.notify("Could not determine table columns for " .. table_node.name, vim.log.levels.ERROR)
      return
    end

    pick_source(function(source_type, _)
      if not source_type then return end

      if source_type == "file" then
        local ok, finder = pcall(require, "finder")
        if not ok then
          vim.notify("beyondlex/finder plugin required for file selection", vim.log.levels.ERROR)
          return
        end
        finder.open({
          mode = "both",
          initial_path = (vim.fn.has("mac") == 1 and vim.fn.expand("~/Downloads"))
            or (vim.fn.has("unix") == 1 and vim.fn.expand("~"))
            or vim.fn.expand("~/Desktop"),
          extensions = { "csv", "tsv", "json" },
          on_confirm = function(path)
            if not path then return end
            local content, err = read_source("file", path)
            if not content then
              vim.notify("Import error: " .. tostring(err), vim.log.levels.ERROR)
              return
            end
            process_import(content, path, table_info, table_cols)
          end,
          on_cancel = function() end,
        })
      else
        local content, err = read_source("clipboard")
        if not content then
          vim.notify("Import error: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        process_import(content, nil, table_info, table_cols)
      end
    end)
  end)
end

--- Test-only exports (used by tests/sql_import_spec.lua).
if _G._TEST then
  M._parse_csv_for_test = parse_csv
  M._parse_tsv_for_test = parse_tsv
  M._parse_json_for_test = parse_json
  M._detect_format_for_test = detect_format
  M._build_column_map_for_test = build_column_map
  M._coerce_value_for_test = coerce_value
  M._validate_and_type_for_test = validate_and_type
end

return M
