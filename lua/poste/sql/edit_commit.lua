--- Dataset edit commit — DML generation, commit, rollback, SQL logging.

local editor = require("poste.sql.editor")
local sql_format = require("poste.sql.format")
local sql_buffer = require("poste.sql.buffer")

local M = {}

---------------------------------------------------------------------------
-- Dialect quoting
---------------------------------------------------------------------------

local function quote_ident(name, dialect)
  if dialect == "mysql" then
    return "`" .. name .. "`"
  end
  -- postgres, sqlite, default: double quotes
  return '"' .. name .. '"'
end

local function quote_schema(schema, dialect)
  if not schema or schema == "" then return "" end
  return quote_ident(schema, dialect) .. "."
end

local function quote_val(val)
  if val == nil or val == vim.NIL then
    return "NULL"
  end
  -- Raw SQL expression (e.g. CURRENT_TIMESTAMP) — no quoting
  if type(val) == "string" then
    local expr = val:match("^__expr:(.*)$")
    if expr then return expr end
  end
  if type(val) == "boolean" then
    return val and "TRUE" or "FALSE"
  end
  if type(val) == "number" then
    if val == math.floor(val) then
      return string.format("%d", val)
    end
    return tostring(val)
  end
  if type(val) == "string" then
    -- Check if string is a numeric literal (no quotes in SQL)
    local num = tonumber(val)
    if num and val:match("^%-?%d+%.?%d*$") then
      if num == math.floor(num) then
        return string.format("%d", num)
      end
      return tostring(num)
    end
    return "'" .. val:gsub("'", "''") .. "'"
  end
  if type(val) == "table" then
    local ok, encoded = pcall(vim.json.encode, val)
    if ok then
      return "'" .. encoded:gsub("'", "''") .. "'"
    end
    return "NULL"
  end
  return "'" .. tostring(val) .. "'"
end

---------------------------------------------------------------------------
-- Primary key helpers
---------------------------------------------------------------------------

--- Find primary key columns.
--- @param columns table[] Column metadata array
--- @return table[] PK column indices (1-based), or empty
local function find_pk_columns(columns)
  local pks = {}
  for i, col in ipairs(columns) do
    if col.primary_key then
      table.insert(pks, i)
    end
  end
  return pks
end

--- Build WHERE clause for a row.
--- @param columns table[] Column metadata
--- @param pk_cols table[] Primary key column indices
--- @param row_values table[] Row cell values
--- @param dialect string Dialect identifier
--- @param schema string Schema/database name
--- @param table_name string Table name
--- @return string WHERE clause (without WHERE keyword)
local function build_where(columns, pk_cols, row_values, dialect, schema, table_name)
  if #pk_cols > 0 then
    local parts = {}
    for _, ci in ipairs(pk_cols) do
      local col = columns[ci]
      local val = row_values[ci]
      table.insert(parts, quote_ident(col.name, dialect) .. " = " .. quote_val(val))
    end
    return table.concat(parts, " AND ")
  end
  -- No PK: use all non-null columns
  local parts = {}
  for i, col in ipairs(columns) do
    local val = row_values[i]
    if val ~= nil and val ~= vim.NIL then
      table.insert(parts, quote_ident(col.name, dialect) .. " = " .. quote_val(val))
    end
  end
  return table.concat(parts, " AND ")
end

---------------------------------------------------------------------------
-- DML generation
---------------------------------------------------------------------------

--- Generate UPDATE statement for a modified cell.
--- @param schema string Schema/database name
--- @param table_name string Table name
--- @param columns table[] Column metadata
--- @param modifications table[] Array of {col, old_val, new_val}
--- @param row_values table[] Full row values (for WHERE)
--- @param dialect string Dialect
--- @return string SQL statement
function M.generate_update(schema, table_name, columns, modifications, row_values, dialect)
  local set_parts = {}
  for _, mod in ipairs(modifications) do
    local col = columns[mod.col]
    if col then
      table.insert(set_parts,
        quote_ident(col.name, dialect) .. " = " .. quote_val(mod.new_val))
    end
  end

  local where = ""
  if row_values then
    local pk_cols = find_pk_columns(columns)
    where = build_where(columns, pk_cols, row_values, dialect, schema, table_name)
  end

  local sql = "UPDATE " .. quote_schema(schema, dialect) .. quote_ident(table_name, dialect)
    .. " SET " .. table.concat(set_parts, ", ")
  if where ~= "" then
    sql = sql .. " WHERE " .. where
  end
  sql = sql .. ";"
  return sql
end

--- Generate INSERT statement for an added row.
--- @param schema string Schema/database name
--- @param table_name string Table name
--- @param columns table[] Column metadata
--- @param row_values table[] Row cell values (may contain "[Auto]" for auto-increment)
--- @param dialect string Dialect
--- @return string SQL statement
function M.generate_insert(schema, table_name, columns, row_values, dialect)
  local col_parts = {}
  local val_parts = {}

  for i, col in ipairs(columns) do
    local val = row_values[i]
    -- Skip [Auto] markers (auto-increment columns) and nil values
    -- (user never touched: let DB use DEFAULT)
    if val ~= "[Auto]" and val ~= nil then
      table.insert(col_parts, quote_ident(col.name, dialect))
      table.insert(val_parts, quote_val(val))
    end
  end

  local sql = "INSERT INTO " .. quote_schema(schema, dialect) .. quote_ident(table_name, dialect)
    .. " (" .. table.concat(col_parts, ", ") .. ")"
    .. " VALUES (" .. table.concat(val_parts, ", ") .. ");"
  return sql
end

--- Generate DELETE statement for a deleted row.
--- @param schema string Schema/database name
--- @param table_name string Table name
--- @param columns table[] Column metadata
--- @param row_values table[] Full row values
--- @param dialect string Dialect
--- @return string SQL statement
function M.generate_delete(schema, table_name, columns, row_values, dialect)
  local pk_cols = find_pk_columns(columns)
  local where = build_where(columns, pk_cols, row_values, dialect, schema, table_name)

  local sql = "DELETE FROM " .. quote_schema(schema, dialect) .. quote_ident(table_name, dialect)
    .. " WHERE " .. where .. ";"
  return sql
end

---------------------------------------------------------------------------
-- DML generation from edit_state
---------------------------------------------------------------------------

--- Generate all DML statements from edit state.
--- @param es table edit_state
--- @param tab table Tab state with layout, rows_source, view_indices
--- @param dialect string Dialect
--- @return table[] Array of { sql = "...", type = "update"|"insert"|"delete" }
function M.generate_dml(es, tab, dialect)
  local stmts = {}
  if not tab or not tab.layout then return stmts end

  local columns = tab.layout.columns
  local rows_source = tab.rows_source
  if not columns or not rows_source then return stmts end

  local schema = tab.layout.schema or ""
  local table_name = tab.layout.table_name or ""

  -- UPDATE statements
  -- Group modifications by row
  local row_mods = {}
  for row_key, mod in pairs(es.modified_cells) do
    local row_idx = tonumber(row_key:match("^(%d+):"))
    if row_idx then
      if not row_mods[row_idx] then row_mods[row_idx] = {} end
      table.insert(row_mods[row_idx], mod)
    end
  end

  for row_idx, mods in pairs(row_mods) do
    if row_idx <= #rows_source then
      -- Build original row values for WHERE clause:
      -- Start with current rows_source (which has been modified),
      -- then replace modified columns with their original values.
      local original_row = {}
      for i = 1, #columns do
        original_row[i] = rows_source[row_idx][i]
      end
      for _, mod in ipairs(mods) do
        original_row[mod.col] = mod.old_val
      end
      local sql = M.generate_update(schema, table_name, columns, mods, original_row, dialect)
      table.insert(stmts, { sql = sql, type = "update" })
    end
  end

  -- DELETE statements
  for row_idx, _ in pairs(es.deleted_rows) do
    if row_idx <= #rows_source then
      local row_values = rows_source[row_idx]
      local sql = M.generate_delete(schema, table_name, columns, row_values, dialect)
      table.insert(stmts, { sql = sql, type = "delete" })
    end
  end

  -- INSERT statements: use current layout values (reflects edits after insert)
  for _, added in ipairs(es.added_rows) do
    local row_values
    if added.row_idx and tab.layout.rows and tab.layout.rows[added.row_idx] then
      row_values = tab.layout.rows[added.row_idx]
    else
      row_values = added.data
    end
    local sql = M.generate_insert(schema, table_name, columns, row_values, dialect)
    table.insert(stmts, { sql = sql, type = "insert" })
  end

  return stmts
end

---------------------------------------------------------------------------
-- SQL Log
---------------------------------------------------------------------------

local SQL_LOG_PATH = nil

--- Get or create the SQL log file path.
local function get_log_path()
  if SQL_LOG_PATH then return SQL_LOG_PATH end
  SQL_LOG_PATH = vim.fn.stdpath("data") .. "/poste/sql_log.jsonl"
  -- Ensure directory exists
  local dir = vim.fn.fnamemodify(SQL_LOG_PATH, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return SQL_LOG_PATH
end

--- Format a log entry as JSON string.
--- @param entry table Log entry fields
--- @return string JSON line
function M.format_log_entry(entry)
  local data = {
    ts = os.date("!%Y-%m-%dT%H:%M:%S"),
  }
  if entry.source then data.source = entry.source end
  if entry.table_name then data["table"] = entry.table_name end
  if entry.connection then data.connection = entry.connection end
  if entry.dialect then data.dialect = entry.dialect end
  if entry.database then data.database = entry.database end
  if entry.sql then data.sql = entry.sql end
  if entry.status then data.status = entry.status end
  if entry.elapsed_ms then data.elapsed_ms = entry.elapsed_ms end
  if entry.error_msg then data.error = entry.error_msg end
  if entry.edit_summary then data.edit_summary = entry.edit_summary end
  if entry.affected_rows then data.affected_rows = entry.affected_rows end
  return vim.json.encode(data)
end

local MAX_LOG_ENTRIES = 1000
local _log_write_count = 0

--- Write a log entry to the JSONL file, trimming to MAX_LOG_ENTRIES.
--- @param entry table Log entry fields
function M.write_log(entry)
  local path = get_log_path()
  local line = M.format_log_entry(entry) .. "\n"
  local f = io.open(path, "a")
  if f then
    f:write(line)
    f:close()
  end
  -- Trim to MAX_LOG_ENTRIES (every 10th write to amortize)
  _log_write_count = _log_write_count + 1
  if _log_write_count < 10 then return end
  _log_write_count = 0
  local lines = {}
  for l in io.lines(path) do
    lines[#lines + 1] = l
  end
  if #lines > MAX_LOG_ENTRIES then
    local keep = {}
    for i = #lines - MAX_LOG_ENTRIES + 1, #lines do
      keep[#keep + 1] = lines[i]
    end
    f = io.open(path, "w")
    if f then
      f:write(table.concat(keep, "\n"), "\n")
      f:close()
    end
  end
end

---------------------------------------------------------------------------
-- Commit / Rollback
---------------------------------------------------------------------------

--- Generate combined DML and return as single SQL string.
--- @param es table edit_state
--- @param tab table Tab state
--- @param dialect string Dialect
--- @return string|nil combined SQL, table summary
function M.generate_combined_dml(es, tab, dialect)
  local stmts = M.generate_dml(es, tab, dialect)
  if #stmts == 0 then
    return nil, { updates = 0, inserts = 0, deletes = 0 }
  end

  local sql_parts = {}
  local summary = { updates = 0, inserts = 0, deletes = 0 }
  for _, s in ipairs(stmts) do
    table.insert(sql_parts, s.sql)
    if s.type == "update" then summary.updates = summary.updates + 1
    elseif s.type == "insert" then summary.inserts = summary.inserts + 1
    elseif s.type == "delete" then summary.deletes = summary.deletes + 1
    end
  end

  return table.concat(sql_parts, "\n"), summary
end

--- Set log path override (for testing).
function M.set_log_path(path)
  SQL_LOG_PATH = path
end

--- Re-execute original SELECT and refresh the dataset in-place.
--- Bypasses run_sql_request() to avoid cursor-position-dependent buffer parsing.
--- @param tab table Tab state with original_sql, src_file, src_buf
function M.refresh_dataset(tab)
  local state = require("poste.state")
  local statement = require("poste.sql.statement")

  local sql = tab.original_sql
  if not sql or sql == "" then
    vim.notify("No original SQL to re-execute", vim.log.levels.WARN)
    return
  end

  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found", vim.log.levels.ERROR)
    return
  end

  local conn = (tab.layout and tab.layout._conn_name) or state.sql.context.connection or ""
  local db = ""
  if tab.layout then
    local layout_db = tab.layout._database or tab.layout.database
    if layout_db and layout_db ~= "" then db = layout_db end
  end
  if db == "" then db = state.sql.context.database or "" end

  -- Strip directives and ### markers from SQL, since original_sql
  -- may contain the full buffer content (-- @connection, ###, etc.)
  local sql_lines = vim.split(sql, "\n", { plain = true })
  local clean_sql_lines = {}
  for _, line in ipairs(sql_lines) do
    local trimmed = line:match("^%s*(.*)$")
    if trimmed ~= "" and not trimmed:match("^%-%-") and not trimmed:match("^###") then
      table.insert(clean_sql_lines, line)
    end
  end

  local content_lines = {}
  if conn and conn ~= "" then
    table.insert(content_lines, "-- @connection " .. conn)
  end
  if db and db ~= "" then
    table.insert(content_lines, "-- @database " .. db)
  end
  table.insert(content_lines, "")
  table.insert(content_lines, "### refresh")
  local sql_start_line = #content_lines + 1
  for _, line in ipairs(clean_sql_lines) do
    table.insert(content_lines, line)
  end
  table.insert(content_lines, "")

  -- Write temp file alongside source for connections.json discovery
  local src_dir = tab.src_file and vim.fn.fnamemodify(tab.src_file, ":h") or ""
  local tmpfile
  if src_dir ~= "" and vim.fn.isdirectory(src_dir) == 1 then
    tmpfile = src_dir .. "/.poste_refresh_" .. vim.fn.strftime("%Y%m%d%H%M%S") .. ".sql"
  else
    tmpfile = vim.fn.tempname() .. ".sql"
  end
  vim.fn.writefile(content_lines, tmpfile)

  local cmd_parts = { binary, "run", tmpfile, "--line", tostring(sql_start_line), "--env", state.current_env, "--json" }
  if db and db ~= "" then
    local db_clean = vim.split(db, "/")
    table.insert(cmd_parts, "--database")
    table.insert(cmd_parts, db_clean[#db_clean])
  end

  -- Clear PK cache so the new layout gets primary_key info re-introspected
  editor.clear_pk_cache()

  local stderr_buf = {}

  local job_id = vim.fn.jobstart(cmd_parts, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data or #data == 0 then return end
      local output = table.concat(data, "\n")
      vim.schedule(function()
        local ok, parsed = pcall(vim.json.decode, output)
        if not ok or not parsed then
          local stderr_text = table.concat(stderr_buf, "\n")
          vim.notify("Refresh failed: JSON parse error\n" .. stderr_text:sub(1, 300), vim.log.levels.ERROR)
          return
        end

        local lines, meta, layout = sql_format.format_dataset(parsed)
        if layout then
          local table_name = statement.extract_table_name(sql)
          if table_name then meta.table_name = table_name end
        end

        sql_buffer.render_dataset(lines, meta, {
          exec_seq = 0,
          layout = layout,
          original_sql = tab.original_sql,
          src_file = tab.src_file,
          src_buf = tab.src_buf,
        })
      end)
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(stderr_buf, l) end
      end
    end,
    on_exit = function(_, code)
      pcall(vim.fn.delete, tmpfile)
      if code ~= 0 then
        vim.schedule(function()
          local stderr_text = table.concat(stderr_buf, "\n")
          vim.notify("Refresh failed (exit " .. code .. ")\n" .. stderr_text:sub(1, 300), vim.log.levels.ERROR)
        end)
      end
    end,
  })

  if job_id <= 0 then
    vim.notify("Failed to start refresh job", vim.log.levels.ERROR)
  end
end

---------------------------------------------------------------------------
-- Commit / Rollback execution
---------------------------------------------------------------------------

--- Commit all pending edits by generating and executing DML.
function M.commit_edits()
  local D = require("poste.sql.dataset")
  local state = require("poste.state")
  local tab = D.T()
  if not tab or not tab.edit_state or not tab.edit_state.dirty then
    vim.notify("No changes to commit", vim.log.levels.INFO)
    return
  end

  -- Guard: warn if no primary key for UPDATE/DELETE (but don't block — use all-column WHERE)
  local es = tab.edit_state
  local has_updates = not vim.tbl_isempty(es.modified_cells)
  local has_deletes = not vim.tbl_isempty(es.deleted_rows)
  if (has_updates or has_deletes) and tab.layout then
    local pk_cols = {}
    for _, col in ipairs(tab.layout.columns) do
      if col.primary_key then table.insert(pk_cols, col.name) end
    end
    if #pk_cols == 0 then
      vim.notify("No primary key info — WHERE will use all column values", vim.log.levels.WARN)
    end
  end

  local dialect = tab.layout and tab.layout.dialect or "postgres"
  local sql, summary = M.generate_combined_dml(es, tab, dialect)
  if not sql then
    vim.notify("No changes to commit", vim.log.levels.INFO)
    return
  end

  -- Execute via poste CLI
  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found", vim.log.levels.ERROR)
    return
  end

  local connection = tab.layout and tab.layout._conn_name or state.sql.context.connection or ""
  local table_name = tab.layout and tab.layout.table_name or ""

  -- Resolve database: layout._database → layout.database → context → connections.json default
  local database = ""
  if tab.layout then
    local layout_db = tab.layout._database or tab.layout.database
    if layout_db and layout_db ~= "" then database = layout_db end
  end
  if database == "" then
    database = state.sql.context.database or ""
  end
  if database == "" and connection ~= "" then
    local config = require("poste.sql.connections").get_connection_config(connection)
    if config and config.database and config.database ~= "" then
      database = config.database
    end
  end
  local src_file = tab.src_file or ""

  -- poste run needs a FILE for connections.json discovery
  if src_file == "" then
    src_file = vim.fn.tempname() .. ".sql"
  end

  -- Pass connection via @connection directive in SQL content (poste run has no --connection flag)
  local sql_content = ""
  if connection and connection ~= "" then
    sql_content = "-- @connection " .. connection .. "\n"
  end
  sql_content = sql_content .. sql

  local cmd = { binary, "run", "--stdin", "--line", "2", "--json", src_file }
  if database and database ~= "" then
    table.insert(cmd, "--database")
    table.insert(cmd, database)
  end

  local stderr_buf = {}
  local start_time = vim.uv.now()
  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data or #data == 0 then return end
      vim.schedule(function()
        local elapsed = vim.uv.now() - start_time
        local output = table.concat(data, "\n")

        local ok_r, resp = pcall(vim.json.decode, output)
        if not ok_r or not resp then
          local stderr_text = table.concat(stderr_buf, "\n")
          vim.notify("Commit: failed to parse poste response\n" .. stderr_text:sub(1, 300), vim.log.levels.ERROR)
          M.write_log({
            source = "dataset_commit",
            table_name = table_name,
            connection = connection,
            dialect = dialect,
            database = database,
            sql = sql,
            status = "error",
            elapsed_ms = elapsed,
            edit_summary = summary,
            error_msg = "JSON parse error: " .. (stderr_text:sub(1, 200)),
          })
          return
        end

        -- Decode inner body to get per-statement errors
        local ok_body, body = pcall(vim.json.decode, resp.body or "{}")
        if not ok_body or type(body) ~= "table" then
          body = {}
        end

        -- Collect per-statement errors
        local errors = {}
        if body.results then
          for i, result in ipairs(body.results) do
            if result.error and result.error ~= "" then
              table.insert(errors, "stmt " .. i .. ": " .. result.error)
            end
          end
        end

        if body.has_error or #errors > 0 then
          local err_msg = table.concat(errors, "\n")
          if err_msg == "" then
            err_msg = "Unknown SQL error (has_error=true)"
          end
          vim.notify("Commit failed:\n" .. err_msg:sub(1, 500), vim.log.levels.ERROR)
          M.write_log({
            source = "dataset_commit",
            table_name = table_name,
            connection = connection,
            dialect = dialect,
            database = database,
            sql = sql,
            status = "error",
            elapsed_ms = elapsed,
            edit_summary = summary,
            error_msg = err_msg:sub(1, 500),
          })
          return
        end

        -- Success
        local affected = 0
        if body.results then
          for _, result in ipairs(body.results) do
            local ar = result.affected_rows
            if type(ar) == "number" then affected = affected + ar end
          end
        end

        vim.notify(string.format("Committed: %d update(s), %d insert(s), %d delete(s) (%d row(s) affected)",
          summary.updates, summary.inserts, summary.deletes, affected), vim.log.levels.INFO)
        M.write_log({
          source = "dataset_commit",
          table_name = table_name,
          connection = connection,
          dialect = dialect,
          database = database,
          sql = sql,
          status = "success",
          elapsed_ms = elapsed,
          edit_summary = summary,
          affected_rows = affected,
        })
        -- Clear edit state and refresh dataset in-place
        require("poste.sql.editor").reset_edit_state(tab.edit_state)
        tab.edit_state = nil
        M.refresh_dataset(tab)
      end)
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(stderr_buf, l) end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          local stderr_text = table.concat(stderr_buf, "\n")
          -- Only notify if on_stdout didn't already handle it
          vim.notify("Commit process exited with code " .. code .. "\n" .. stderr_text:sub(1, 300), vim.log.levels.WARN)
        end)
      end
    end,
  })

  if job_id > 0 then
    vim.fn.chansend(job_id, sql_content)
    vim.fn.chanclose(job_id, "stdin")
  else
    vim.notify("Failed to start poste job", vim.log.levels.ERROR)
  end
end

return M
