--- Dataset cell editor — pure functions for value conversion, validation,
--- edit state tracking. No vim.ui calls (those are in edit_cell() which
--- lives here but depends on vim runtime).

local M = {}

---------------------------------------------------------------------------
-- Type classification helpers
---------------------------------------------------------------------------

local NUMERIC_TYPES = {
  integer = true, int = true, bigint = true, smallint = true,
  numeric = true, decimal = true, real = true, float = true,
  serial = true, bigserial = true, smallserial = true,
}

local INTEGER_TYPES = {
  integer = true, int = true, bigint = true, smallint = true,
  serial = true, bigserial = true, smallserial = true,
}

local BOOLEAN_TYPES = {
  boolean = true, bool = true,
}

local DATE_TYPES = {
  date = true, timestamp = true, timestamptz = true,
  datetime = true, datetime2 = true, time = true,
}

local JSON_TYPES = {
  json = true, jsonb = true,
}

local UUID_TYPE = { uuid = true }

local TEXT_TYPES = {
  text = true, varchar = true, char = true, character = true,
  character_varying = true, nvarchar = true, nchar = true,
  longtext = true, mediumtext = true, tinytext = true,
}

local INEDITABLE_TYPES = {
  binary = true, bytea = true, blob = true, varbinary = true,
  geometry = true, geography = true, point = true, polygon = true,
  linestring = true, multipolygon = true,
  inet = true, cidr = true, macaddr = true, macaddr8 = true,
  bit = true, varbit = true,
  interval = true,
  tsvector = true, tsquery = true,
  xml = true, hstore = true,
  array = true, range = true, multirange = true,
}

---------------------------------------------------------------------------
-- Type classification public API
---------------------------------------------------------------------------

function M.is_numeric_type(ctype)
  if not ctype then return false end
  return NUMERIC_TYPES[ctype:lower()] or false
end

function M.is_integer_type(ctype)
  if not ctype then return false end
  return INTEGER_TYPES[ctype:lower()] or false
end

function M.is_boolean_type(ctype)
  if not ctype then return false end
  return BOOLEAN_TYPES[ctype:lower()] or false
end

function M.is_date_type(ctype)
  if not ctype then return false end
  return DATE_TYPES[ctype:lower()] or false
end

function M.is_json_column(col_meta)
  if not col_meta or not col_meta.ctype then return false end
  return JSON_TYPES[col_meta.ctype:lower()] or false
end

function M.is_boolean_column(col_meta)
  if not col_meta or not col_meta.ctype then return false end
  return BOOLEAN_TYPES[col_meta.ctype:lower()] or false
end

function M.is_datetime_column(col_meta)
  if not col_meta or not col_meta.ctype then return false end
  return DATE_TYPES[col_meta.ctype:lower()] or false
end

function M.is_enum_column(col_meta)
  if not col_meta then return false end
  if col_meta.ctype and col_meta.ctype:lower() == "user-defined" and col_meta.enum_values then
    return #col_meta.enum_values > 0
  end
  return false
end

function M.is_uuid_type(ctype)
  if not ctype then return false end
  return UUID_TYPE[ctype:lower()] or false
end

function M.is_text_type(ctype)
  if not ctype then return false end
  return TEXT_TYPES[ctype:lower()] or false
end

---------------------------------------------------------------------------
-- UT3: is_editable_field
---------------------------------------------------------------------------

--- Check if a column type supports editing.
--- @param col_meta table Column metadata with .ctype and optionally .user_defined
--- @return boolean
function M.is_editable_field(col_meta)
  if not col_meta then return false end
  if col_meta.user_defined then return false end
  local ctype = col_meta.ctype
  if not ctype then return true end
  ctype = ctype:lower()
  if INEDITABLE_TYPES[ctype] then return false end
  return true
end

---------------------------------------------------------------------------
-- UT1: parse_value — convert user input string to typed value
---------------------------------------------------------------------------

--- Parse user input string into a typed Lua value.
--- @param input string The raw string from user input
--- @param old_val any The original cell value (for NULL detection)
--- @return any The parsed value, or nil if no change
function M.parse_value(input, old_val)
  if input == nil then return nil end

  -- Empty input
  if input == "" then
    -- If old value was already nil/NIL, cancel
    if old_val == nil or old_val == vim.NIL then
      return nil
    end
    -- Otherwise set to NULL
    return vim.NIL
  end

  -- Explicit NULL markers
  if input == "(NULL)" or input == "NULL" then
    return vim.NIL
  end

  -- Empty string literal '' → ""
  if input == "''" then
    return ""
  end

  -- Boolean
  if input == "true" then return true end
  if input == "false" then return false end

  -- Number (pure numeric, possibly with decimal point and leading minus)
  local num = tonumber(input)
  if num then
    -- Check if input looks like a pure number (no trailing non-numeric chars)
    if input:match("^%-?%d+%.?%d*$") or input:match("^%-?%.%d+$") then
      return num
    end
  end

  -- JSON object or array
  if input:sub(1, 1) == "{" or input:sub(1, 1) == "[" then
    local ok, decoded = pcall(vim.json.decode, input)
    if ok and decoded ~= nil then
      return decoded
    end
  end

  -- Default: string passthrough
  return input
end

---------------------------------------------------------------------------
-- UT2: validate_value — type-aware validation
---------------------------------------------------------------------------

--- Validate a value against column type constraints.
--- @param value any The parsed value
--- @param col_meta table Column metadata with .ctype
--- @return boolean ok, string|nil error_msg
function M.validate_value(value, col_meta)
  if value == nil or value == vim.NIL then
    return true, nil
  end

  if not col_meta or not col_meta.ctype then
    return true, nil
  end

  local ctype = col_meta.ctype:lower()

  -- Integer types
  if INTEGER_TYPES[ctype] then
    if type(value) ~= "number" then
      return false, "Expected integer, got " .. type(value)
    end
    if value ~= math.floor(value) then
      return false, "Expected integer, got decimal: " .. tostring(value)
    end
    return true, nil
  end

  -- Numeric/float types
  if NUMERIC_TYPES[ctype] then
    if type(value) ~= "number" then
      return false, "Expected number, got " .. type(value)
    end
    return true, nil
  end

  -- Boolean types
  if BOOLEAN_TYPES[ctype] then
    if type(value) == "boolean" then
      return true, nil
    end
    if type(value) == "number" and (value == 0 or value == 1) then
      return true, nil
    end
    return false, "Expected boolean (true/false/1/0), got: " .. tostring(value)
  end

  -- Date/timestamp types
  if DATE_TYPES[ctype] then
    if type(value) == "string" then
      -- Check common date formats
      if value:match("^%d%d%d%d%-%d%d%-%d%d") then
        return true, nil
      end
      if value:match("^%d%d%d%d/%d%d/%d%d") then
        return true, nil
      end
      -- Try os.date parse for common formats
      local patterns = {
        "(%d%d%d%d%-[^ ]+)",
        "(%d%d%d%d/%d%d/%d%d)",
      }
      for _, pat in ipairs(patterns) do
        if value:match(pat) then
          return true, nil
        end
      end
      return false, "Invalid date format: " .. value
    end
    if type(value) == "number" then
      return true, nil
    end
    return false, "Expected date string, got: " .. type(value)
  end

  -- JSON types
  if JSON_TYPES[ctype] then
    if type(value) == "table" then
      return true, nil
    end
    if type(value) == "string" then
      local ok = pcall(vim.json.decode, value)
      if ok then return true, nil end
      return false, "Invalid JSON: " .. value
    end
    return false, "Expected JSON value, got: " .. type(value)
  end

  -- UUID type
  if UUID_TYPE[ctype] then
    if type(value) ~= "string" then
      return false, "Expected UUID string, got: " .. type(value)
    end
    if not value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
      return false, "Invalid UUID format: " .. value
    end
    return true, nil
  end

  -- text/varchar/char: anything goes
  if TEXT_TYPES[ctype] then
    return true, nil
  end

  -- Unknown type: allow
  return true, nil
end

---------------------------------------------------------------------------
-- UT4/UT5: edit_state tracking
---------------------------------------------------------------------------

--- Create a fresh edit_state table.
function M.create_edit_state()
  return {
    dirty = false,
    modified_cells = {},
    deleted_rows = {},
    added_rows = {},
    original_rows_snapshot = {},
    cell_errors = {},
  }
end

--- Track a cell modification.
--- @param es table edit_state
--- @param row_key string Row key (e.g. "3:2" for row 3 col 2)
--- @param col number Column index
--- @param old_val any Original value
--- @param new_val any New value
function M.track_cell_edit(es, row_key, col, old_val, new_val)
  -- If row is deleted, don't track
  local row_idx = tonumber(row_key:match("^(%d+):"))
  if row_idx and es.deleted_rows[row_idx] then
    return
  end

  -- If new_val equals old_val, remove from tracking
  if new_val == old_val then
    es.modified_cells[row_key] = nil
  else
    -- Keep the first old_val (original value) even on re-edit
    local existing = es.modified_cells[row_key]
    local orig_old = existing and existing.old_val or old_val
    es.modified_cells[row_key] = {
      col = col,
      old_val = orig_old,
      new_val = new_val,
    }
  end

  -- Update dirty flag
  es.dirty = not vim.tbl_isempty(es.modified_cells)
    or not vim.tbl_isempty(es.deleted_rows)
    or #es.added_rows > 0
end

--- Track a row deletion.
--- @param es table edit_state
--- @param row_idx number 1-based source row index
function M.track_row_delete(es, row_idx)
  es.deleted_rows[row_idx] = true

  -- Remove any modified_cells for this row
  local prefix = tostring(row_idx) .. ":"
  for key, _ in pairs(es.modified_cells) do
    if key:sub(1, #prefix) == prefix then
      es.modified_cells[key] = nil
    end
  end

  es.dirty = true
end

--- Track a row addition.
--- @param es table edit_state
--- @param row_data table Array of cell values
function M.track_row_add(es, row_data, row_idx)
  table.insert(es.added_rows, { data = row_data, row_idx = row_idx })
  es.dirty = true
end

--- Check if there are pending changes.
--- @param es table edit_state
--- @return boolean
function M.has_pending_changes(es)
  return es.dirty
end

--- Get summary counts of pending changes.
--- @param es table edit_state
--- @return table { updates = N, inserts = N, deletes = N }
function M.get_edit_summary(es)
  return {
    updates = vim.tbl_count(es.modified_cells),
    inserts = #es.added_rows,
    deletes = vim.tbl_count(es.deleted_rows),
  }
end

--- Count pending changes (for winbar display).
--- @param es table edit_state
--- @return table { modified = N, deleted = N, added = N }
function M.count_pending_changes(es)
  return {
    modified = vim.tbl_count(es.modified_cells),
    deleted = vim.tbl_count(es.deleted_rows),
    added = #es.added_rows,
  }
end

--- Format pending changes text for winbar, e.g. "[+1 ~2 -1]".
--- @param es table edit_state
--- @return string|nil
function M.pending_changes_text(es)
  local counts = M.count_pending_changes(es)
  if counts.modified == 0 and counts.deleted == 0 and counts.added == 0 then
    return nil
  end
  return string.format("[+%d ~%d -%d]",
    counts.added, counts.modified, counts.deleted)
end

--- Reset edit state to clean.
function M.reset_edit_state(es)
  es.dirty = false
  es.modified_cells = {}
  es.deleted_rows = {}
  es.added_rows = {}
  es.original_rows_snapshot = {}
  es.cell_errors = {}
end

--- Remove a specific cell error.
function M.clear_cell_error(es, row_key)
  es.cell_errors[row_key] = nil
end

--- Set a cell error.
function M.set_cell_error(es, row_key, msg)
  es.cell_errors[row_key] = msg
end

---------------------------------------------------------------------------
-- JSON formatting helpers
---------------------------------------------------------------------------

--- Format a value for JSON input display.
--- @param val any Current cell value
--- @return string
function M.format_json_input(val)
  if type(val) == "table" then
    local ok, encoded = pcall(vim.json.encode, val, { indent = 2 })
    if ok then return encoded end
    return tostring(val)
  end
  return tostring(val)
end

--- Parse a JSON input string.
--- @param input string
--- @return table|nil
function M.parse_json_input(input)
  local ok, decoded = pcall(vim.json.decode, input)
  if ok then return decoded end
  return nil
end

---------------------------------------------------------------------------
-- Internal helpers (used by both PK introspection and interactive edits)
---------------------------------------------------------------------------

local D = nil
local function get_dataset()
  if not D then D = require("poste.sql.dataset") end
  return D
end

local function get_state()
  return require("poste.state")
end

---------------------------------------------------------------------------
-- Primary key introspection
---------------------------------------------------------------------------

-- Cache: { ["connection:database:table"] = true }
local pk_cache = {}

--- Check if the original SQL contains JOIN (multi-table query).
--- @param sql string Original SQL text
--- @return boolean has_join
function M.has_join(sql)
  if not sql or sql == "" then return false end
  local upper = sql:upper()
  -- Count JOIN keywords (simple heuristic)
  local count = 0
  local idx = 1
  while true do
    local pos = upper:find("JOIN", idx, true)
    if not pos then break end
    local before = pos > 1 and upper:sub(pos - 1, pos - 1) or " "
    if before == " " or before == "\n" or before == "\t" or before == "" then
      count = count + 1
    end
    idx = pos + 4
  end
  return count >= 1
end

--- Fetch primary key info for a table via SQL query.
--- Sets primary_key=true on matching columns in layout.
--- @param tab table Tab state with layout
function M.ensure_primary_key(tab)
  if not tab or not tab.layout then
    vim.notify("[PK debug] no tab or layout", vim.log.levels.INFO)
    return
  end
  local layout = tab.layout
  local table_name = layout.table_name
  if not table_name or table_name == "" then
    vim.notify("[PK debug] no table_name", vim.log.levels.INFO)
    return
  end

  -- Check if already introspected for this table
  local connection = layout._conn_name or get_state().sql.context.connection or ""
  local database = layout.database or get_state().sql.context.database or ""
  local cache_key = connection .. ":" .. database .. ":" .. table_name
  if pk_cache[cache_key] then
    vim.notify("[PK debug] cached for " .. cache_key, vim.log.levels.INFO)
    return
  end

  -- Check if any column already has primary_key set
  for _, col in ipairs(layout.columns) do
    if col.primary_key then
      pk_cache[cache_key] = true
      vim.notify("[PK debug] already has PK on " .. col.name, vim.log.levels.INFO)
      return
    end
  end

  vim.notify(string.format("[PK debug] table=%s conn=%s db=%s dialect=%s cols=%d",
    table_name, connection, database, layout.dialect or "?", #layout.columns), vim.log.levels.INFO)

  -- Query the database for primary key columns
  local dialect = layout.dialect or ""
  -- Fallback: extract database from connection string if not set
  local db = database
  if (not db or db == "") and layout.connection then
    db = layout.connection:match("/([^/?]+)$")
  end
  local meta_query
  if dialect == "mysql" then
    meta_query = string.format(
      "SELECT c.COLUMN_NAME, c.COLUMN_DEFAULT, c.EXTRA, "
      .. "CASE WHEN k.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS IS_PK "
      .. "FROM INFORMATION_SCHEMA.COLUMNS c "
      .. "LEFT JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE k "
      .. "ON k.TABLE_NAME = c.TABLE_NAME AND k.COLUMN_NAME = c.COLUMN_NAME "
      .. "AND k.CONSTRAINT_NAME = 'PRIMARY' AND k.TABLE_SCHEMA = c.TABLE_SCHEMA "
      .. "WHERE c.TABLE_NAME = '%s'",
      table_name:gsub("'", "''"))
    if db and db ~= "" then
      meta_query = meta_query .. string.format(" AND c.TABLE_SCHEMA = '%s'", db:gsub("'", "''"))
    end
  elseif dialect == "postgres" then
    local schema = "public"
    meta_query = string.format(
      "SELECT c.column_name, c.column_default, "
      .. "CASE WHEN pk.attname IS NOT NULL THEN 1 ELSE 0 END AS IS_PK "
      .. "FROM information_schema.columns c "
      .. "LEFT JOIN ("
      .. "SELECT a.attname FROM pg_index i "
      .. "JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey) "
      .. "JOIN pg_class cl ON cl.oid = i.indrelid "
      .. "WHERE i.indisprimary AND cl.relname = '%s'"
      .. ") pk ON pk.attname = c.column_name "
      .. "WHERE c.table_name = '%s' AND c.table_schema = '%s'",
      table_name:gsub("'", "''"), table_name:gsub("'", "''"), schema:gsub("'", "''"))
  elseif dialect == "sqlite" then
    meta_query = string.format(
      "SELECT name AS column_name, dflt_value AS column_default, pk AS IS_PK "
      .. "FROM pragma_table_info('%s')",
      table_name:gsub("'", "''"))
  end

  if not meta_query then
    vim.notify("[PK debug] no query for dialect: " .. dialect, vim.log.levels.INFO)
    pk_cache[cache_key] = true
    return
  end

  vim.notify("[PK debug] meta_query: " .. meta_query:sub(1, 120), vim.log.levels.INFO)

  -- Execute via poste run --stdin (connection passed via @connection directive)
  local binary = get_state().find_poste_binary()
  if not binary then
    vim.notify("[PK debug] no poste binary found", vim.log.levels.INFO)
    return
  end

  -- poste run needs a FILE for connections.json discovery; use the source SQL file
  local src_file = tab.src_file or ""
  if src_file == "" then
    local ok, buf_name = pcall(vim.api.nvim_buf_get_name, 0)
    if ok and buf_name and buf_name ~= "" and not buf_name:match("^poste://") then
      src_file = buf_name
    else
      src_file = vim.fn.tempname() .. ".sql"
    end
  end

  local args = { binary, "run", "--stdin", "--line", "2", src_file, "--json" }
  if database and database ~= "" then
    table.insert(args, "--database")
    table.insert(args, database)
  end

  local sql_content = "-- @connection " .. connection .. "\n" .. meta_query
  vim.notify("[PK debug] src_file=" .. src_file .. " args=" .. vim.inspect(args), vim.log.levels.INFO)
  local output = vim.fn.system(args, sql_content)
  vim.notify("[PK debug] shell_error=" .. vim.v.shell_error .. " output_len=" .. #output, vim.log.levels.INFO)
  if vim.v.shell_error ~= 0 then
    vim.notify("[PK debug] exec failed: " .. output:sub(1, 200), vim.log.levels.INFO)
    return
  end

  local ok, parsed = pcall(vim.json.decode, output)
  if not ok or not parsed then
    vim.notify("[PK debug] json decode failed: " .. tostring(parsed), vim.log.levels.INFO)
    return
  end

  -- Parse the result to get column metadata (defaults + PK)
  local body_ok, body = pcall(vim.json.decode, parsed.body or "{}")
  vim.notify("[PK debug] body_ok=" .. tostring(body_ok) .. " results=" .. tostring(body and body.results and #body.results), vim.log.levels.INFO)
  if body_ok and body and body.results then
    local defaults = {}
    local pk_names = {}
    local is_pk_col_idx = (dialect == "mysql" and 4) or 3  -- postgres/sqlite=3, mysql=4

    for _, res in ipairs(body.results) do
      if res.rows then
        for _, row in ipairs(res.rows) do
          local col_name = tostring(row[1] or "")
          local col_default = row[2]
          local is_pk = row[is_pk_col_idx]
          if col_name ~= "" then
            defaults[col_name] = (col_default ~= vim.NIL and col_default ~= nil) and col_default or nil
            if is_pk and (is_pk == 1 or is_pk == "1") then
              pk_names[col_name] = true
            end
          end
        end
      end
    end

    -- Set metadata on matching columns
    for _, col in ipairs(layout.columns) do
      if defaults[col.name] ~= nil then
        col.default = defaults[col.name]
      end
      if pk_names[col.name] then
        col.primary_key = true
      end
    end
  end

  pk_cache[cache_key] = true
end

--- Clear PK cache (for testing).
function M.clear_pk_cache()
  pk_cache = {}
end

---------------------------------------------------------------------------
-- Editable row check
---------------------------------------------------------------------------

--- Check if a row index is a data row (not header/border).
--- @param tab table Tab state
--- @param row_idx number 1-based buffer line index
--- @return boolean
function M.is_data_row(tab, row_idx)
  if not tab or not tab.meta then return false end
  local meta = tab.meta
  if meta.type ~= "resultset" then return false end
  if not meta.row_count then return false end
  return row_idx >= 1 and row_idx <= meta.row_count
end

---------------------------------------------------------------------------
-- Interactive edit functions (vim.ui dependent)
---------------------------------------------------------------------------

local function ensure_edit_state(tab)
  if not tab.edit_state then
    tab.edit_state = M.create_edit_state()
  end
  return tab.edit_state
end

local function apply_cell_edit(row_idx, col_idx, new_val)
  local tab = get_dataset().T()
  if not tab or not tab.layout then return end

  local es = ensure_edit_state(tab)
  local row_key = tostring(row_idx) .. ":" .. tostring(col_idx)

  -- Check if this row is an added row — update data directly, no modified_cell entry
  local is_added = false
  for _, added in ipairs(es.added_rows) do
    if added.row_idx == row_idx then
      is_added = true
      break
    end
  end

  if is_added then
    tab.layout.rows[row_idx][col_idx] = new_val
    es.dirty = #es.added_rows > 0
  else
    local existing = es.modified_cells[row_key]
    local old_val = existing and existing.old_val or tab.layout.rows[row_idx][col_idx]
    M.track_cell_edit(es, row_key, col_idx, old_val, new_val)
    tab.layout.rows[row_idx][col_idx] = new_val
  end

  -- Also update rows_source so refresh_page shows the edit
  if tab.rows_source and tab.rows_source[row_idx] then
    tab.rows_source[row_idx][col_idx] = new_val
  end

  -- Clear any previous error for this cell
  M.clear_cell_error(es, row_key)

  -- Re-render the buffer line
  local buf = get_dataset().dataset_buffer
  if buf and vim.api.nvim_buf_is_valid(buf) and tab.padded and tab.meta then
    local meta = tab.meta
    if meta.data_start_line then
      local line_idx = meta.data_start_line + row_idx - 1
      local fmt = require("poste.sql.format")
      local row = tab.rows_source and tab.rows_source[row_idx] or tab.layout.rows[row_idx]
      if row then
        local new_line = fmt.render_row(row, tab.layout, #tostring(row_idx))
        if new_line then
          -- Update padded table
          if tab.padded[line_idx] then
            tab.padded[line_idx] = "  " .. new_line
          end
          vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
          vim.api.nvim_buf_set_lines(buf, line_idx - 1, line_idx, false, { "  " .. new_line })
          vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
          local sql_highlights = require("poste.sql.highlights")
          sql_highlights.invalidate_sep_cache()
          sql_highlights.apply_edit_highlights(buf, tab)
        end
      end
    end
  end

  -- Update winbar
  if tab.edit_state.dirty then
    local pending = M.pending_changes_text(tab.edit_state)
    local meta = tab.meta
    local winbar_base = require("poste.sql.buffer_nav").build_status_winbar(meta)
    if pending and winbar_base then
      winbar_base = winbar_base .. " " .. pending
    end
    if get_dataset().dataset_window and vim.api.nvim_win_is_valid(get_dataset().dataset_window) then
      pcall(vim.api.nvim_set_option_value, "winbar", winbar_base or "", { win = get_dataset().dataset_window })
    end
  end
end

--- Edit the current cell via floating input.
function M.edit_cell()
  local tab = get_dataset().T()
  if not tab or not tab.layout then return end

  -- Guard: raw mode
  if get_state().sql._raw_mode then
    vim.notify("Editing is not supported in raw mode", vim.log.levels.WARN)
    return
  end

  -- Guard: large result set
  if tab.layout.rows and #tab.layout.rows > 5000 then
    vim.notify("Editing is not supported for result sets > 5000 rows", vim.log.levels.WARN)
    return
  end

  -- Guard: single-table only (no JOINs)
  if tab.original_sql and M.has_join(tab.original_sql) then
    vim.notify("Editing is not supported for multi-table (JOIN) queries", vim.log.levels.WARN)
    return
  end

  -- Ensure primary key info is available
  M.ensure_primary_key(tab)

  local state = get_state()
  local row_idx = state.sql.cell.row
  local col_idx = state.sql.cell.col
  local col_meta = tab.layout.columns[col_idx]

  -- Guard: data row check
  if not M.is_data_row(tab, row_idx) then return end

  -- Guard: editable field
  if not M.is_editable_field(col_meta) then
    vim.notify("Cannot edit " .. (col_meta.ctype or "unknown") .. " field", vim.log.levels.WARN)
    return
  end

  local old_val = tab.layout.rows[row_idx][col_idx]

  -- Boolean selector
  if M.is_boolean_column(col_meta) then
    local choices = { "(NULL)", "true", "false" }
    vim.ui.select(choices, {
      prompt = col_meta.name or "value",
      format_item = function(item) return item end,
    }, function(choice)
      if not choice then return end
      local new_val
      if choice == "(NULL)" then
        new_val = vim.NIL
      elseif choice == "true" then
        new_val = true
      else
        new_val = false
      end
      apply_cell_edit(row_idx, col_idx, new_val)
    end)
    return
  end

  -- Date/time picker
  if M.is_datetime_column(col_meta) then
    local now = os.date("*t")
    local choices = { "(NULL)", "Now" }
    if col_meta.ctype == "date" then
      choices = { "(NULL)", os.date("%Y-%m-%d") }
    elseif col_meta.ctype == "time" then
      choices = { "(NULL)", os.date("%H:%M:%S") }
    else
      choices = { "(NULL)", os.date("%Y-%m-%d %H:%M:%S"), "CURRENT_TIMESTAMP" }
    end
    table.insert(choices, "Custom…")
    vim.ui.select(choices, {
      prompt = (col_meta.name or "value") .. " (" .. (col_meta.ctype or "") .. ")",
      format_item = function(item) return item end,
    }, function(choice)
      if not choice or choice == "(NULL)" then
        if choice == "(NULL)" then
          apply_cell_edit(row_idx, col_idx, vim.NIL)
        end
        return
      end
      if choice == "Custom…" then
        vim.ui.input({
          prompt = (col_meta.name or "value") .. ": ",
          default = os.date(col_meta.ctype == "date" and "%Y-%m-%d" or "%Y-%m-%d %H:%M:%S"),
        }, function(input)
          if not input then return end
          apply_cell_edit(row_idx, col_idx, input)
        end)
        return
      end
      apply_cell_edit(row_idx, col_idx, choice)
    end)
    return
  end

  -- Enum selector
  if M.is_enum_column(col_meta) then
    local choices = {}
    for _, v in ipairs(col_meta.enum_values) do
      table.insert(choices, v)
    end
    table.insert(choices, "(NULL)")
    vim.ui.select(choices, {
      prompt = col_meta.name or "value",
      format_item = function(item) return item end,
    }, function(choice)
      if not choice then return end
      local new_val = choice == "(NULL)" and vim.NIL or choice
      apply_cell_edit(row_idx, col_idx, new_val)
    end)
    return
  end

  -- Standard text input
  local initial_text
  if M.is_json_column(col_meta) and type(old_val) == "table" then
    initial_text = M.format_json_input(old_val)
  else
    initial_text = (old_val == nil or old_val == vim.NIL) and "" or tostring(old_val)
  end

  vim.ui.input({
    prompt = (col_meta.name or "value") .. ": ",
    default = initial_text,
  }, function(input)
    if input == nil then return end  -- cancelled

    local new_val = M.parse_value(input, old_val)
    if new_val == nil then return end  -- no change

    -- Type validation
    local ok, err = M.validate_value(new_val, col_meta)
    if not ok then
      local es = ensure_edit_state(tab)
      local row_key = tostring(row_idx) .. ":" .. tostring(col_idx)
      M.set_cell_error(es, row_key, err)
      vim.notify("Validation error: " .. err, vim.log.levels.ERROR)
      return
    end

    -- Clear any previous error
    local es = ensure_edit_state(tab)
    local row_key = tostring(row_idx) .. ":" .. tostring(col_idx)
    M.clear_cell_error(es, row_key)

    apply_cell_edit(row_idx, col_idx, new_val)
  end)
end

--- Delete the current row.
function M.delete_row()
  local tab = get_dataset().T()
  if not tab or not tab.layout then return end

  if get_state().sql._raw_mode then
    vim.notify("Editing is not supported in raw mode", vim.log.levels.WARN)
    return
  end

  if tab.layout.rows and #tab.layout.rows > 5000 then
    vim.notify("Editing is not supported for result sets > 5000 rows", vim.log.levels.WARN)
    return
  end

  -- Guard: single-table only
  if tab.original_sql and M.has_join(tab.original_sql) then
    vim.notify("Editing is not supported for multi-table (JOIN) queries", vim.log.levels.WARN)
    return
  end

  M.ensure_primary_key(tab)

  local state = get_state()
  local row_idx = state.sql.cell.row

  if not M.is_data_row(tab, row_idx) then return end

  local es = ensure_edit_state(tab)
  M.track_row_delete(es, row_idx)

  -- Visual feedback: strikethrough the line
  local buf = get_dataset().dataset_buffer
  if buf and vim.api.nvim_buf_is_valid(buf) and tab.padded then
    local sql_highlights = require("poste.sql.highlights")
    sql_highlights.apply_edit_highlights(buf, tab)
  end

  -- Update winbar
  local pending = M.pending_changes_text(es)
  local meta = tab.meta
  local winbar_base = require("poste.sql.buffer_nav").build_status_winbar(meta)
  if pending and winbar_base then
    winbar_base = winbar_base .. " " .. pending
  end
  if get_dataset().dataset_window and vim.api.nvim_win_is_valid(get_dataset().dataset_window) then
    pcall(vim.api.nvim_set_option_value, "winbar", winbar_base or "", { win = get_dataset().dataset_window })
  end
end

--- Insert a new row at the end of the table.
function M.insert_row()
  local tab = get_dataset().T()
  if not tab or not tab.layout then return end

  if get_state().sql._raw_mode then
    vim.notify("Editing is not supported in raw mode", vim.log.levels.WARN)
    return
  end

  if tab.layout.rows and #tab.layout.rows > 5000 then
    vim.notify("Editing is not supported for result sets > 5000 rows", vim.log.levels.WARN)
    return
  end

  if tab.original_sql and M.has_join(tab.original_sql) then
    vim.notify("Editing is not supported for multi-table (JOIN) queries", vim.log.levels.WARN)
    return
  end

  M.ensure_primary_key(tab)
  local es = ensure_edit_state(tab)
  local num_cols = #tab.layout.columns
  local row_data = {}
  for i = 1, num_cols do
    local col_meta = tab.layout.columns[i]
    if col_meta.primary_key and col_meta.ctype and M.is_integer_type(col_meta.ctype) then
      row_data[i] = "[Auto]"
    else
      row_data[i] = nil
    end
  end

  -- Append to layout rows and track in edit_state
  local new_row_idx = #tab.layout.rows + 1
  tab.layout.rows[new_row_idx] = vim.deepcopy(row_data)
  M.track_row_add(es, row_data, new_row_idx)

  -- Re-render current page to show the new row
  local sql_format = require("poste.sql.format")
  local sql_buffer = require("poste.sql.buffer")
  local buf = get_dataset().dataset_buffer
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local lines, meta = sql_format.render_page(tab.layout, tab.page or 1, tab.page_size or 50)
    meta.table_name = tab.meta and tab.meta.table_name
    sql_buffer.apply_rendered_page(tab, lines, meta)
    -- Re-apply edit highlights (green for added row)
    local sql_highlights = require("poste.sql.highlights")
    sql_highlights.apply_edit_highlights(buf, tab)
    -- Move cursor to new row if visible
    if new_row_idx <= meta.row_count then
      get_state().sql.cell.row = new_row_idx
      local line_idx = meta.data_start_line + new_row_idx - 1
      pcall(vim.api.nvim_win_set_cursor, get_dataset().dataset_window, { line_idx, 0 })
      sql_highlights.highlight_cell(buf, new_row_idx, get_state().sql.cell.col or 1, meta)
    end
  end

  -- Update winbar
  local pending = M.pending_changes_text(es)
  local meta = tab.meta
  local winbar_base = require("poste.sql.buffer_nav").build_status_winbar(meta)
  if pending and winbar_base then
    winbar_base = winbar_base .. " " .. pending
  end
  if get_dataset().dataset_window and vim.api.nvim_win_is_valid(get_dataset().dataset_window) then
    pcall(vim.api.nvim_set_option_value, "winbar", winbar_base or "", { win = get_dataset().dataset_window })
  end

  vim.notify("Row queued for insertion (commit with <leader>w)", vim.log.levels.INFO)
end

--- Rollback all edits and re-run query.
function M.rollback_edits()
  local tab = get_dataset().T()
  if not tab then return end
  if not tab.edit_state or not tab.edit_state.dirty then
    vim.notify("No pending changes", vim.log.levels.INFO)
    return
  end

  M.reset_edit_state(tab.edit_state)
  tab.edit_state = nil

  vim.schedule(function()
    require("poste.sql.init").run_sql_request()
  end)
end

return M
