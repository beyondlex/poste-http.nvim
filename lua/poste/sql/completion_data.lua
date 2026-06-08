--- SQL completion — data + cache layer.
--- Provides keyword tables, connection context resolution, lazy-fetch
--- (tables/columns/databases via the Rust CLI), and binary helpers.
local state = require("poste.state")

local M = {}

---------------------------------------------------------------------------
-- Keywords & types
---------------------------------------------------------------------------

local KEYWORDS = {
  "SELECT", "FROM", "WHERE", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN",
  "FULL JOIN", "CROSS JOIN", "ON", "GROUP BY", "ORDER BY", "HAVING",
  "LIMIT", "OFFSET", "DISTINCT", "ALL", "UNION", "UNION ALL", "AS", "WITH",
  "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM",
  "CREATE TABLE", "ALTER TABLE", "DROP TABLE", "TRUNCATE TABLE", "ADD COLUMN", "DROP COLUMN",
  "RENAME COLUMN", "MODIFY COLUMN",
  "AND", "OR", "NOT", "IN", "NOT IN", "EXISTS", "IS NULL", "IS NOT NULL",
  "LIKE", "ILIKE", "BETWEEN",
  "COUNT", "SUM", "AVG", "MAX", "MIN", "COALESCE", "NULLIF",
  "CAST", "NOW", "CURRENT_TIMESTAMP", "CURRENT_DATE",
  "TRIM", "UPPER", "LOWER", "LENGTH", "SUBSTRING", "CONCAT",
  "PRIMARY KEY", "FOREIGN KEY", "UNIQUE", "NOT NULL", "DEFAULT", "REFERENCES",
  "COMMENT", "AFTER",
  "BEGIN", "COMMIT", "ROLLBACK",
  "DESC", "SHOW", "USE",
}

local DATA_TYPES = {
  "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "DECIMAL", "NUMERIC",
  "FLOAT", "DOUBLE", "REAL", "SERIAL", "BIGSERIAL",
  "VARCHAR(255)", "TEXT", "CHAR(1)",
  "DATE", "TIME", "DATETIME", "TIMESTAMP", "TIMESTAMPTZ",
  "BOOLEAN", "BOOL", "BLOB", "BYTEA", "JSON", "JSONB", "UUID",
}

local TABLE_CTX = {
  from = true, join = true, update = true, into = true, table = true,
}

local COLUMN_CTX = {
  where = true, set = true, on = true, having = true, select = true,
  ["and"] = true, ["or"] = true, ["not"] = true,
  by = true,  -- ORDER BY, GROUP BY
  ["after"] = true,  -- ALTER TABLE ... ADD/MODIFY COLUMN col AFTER col_name
  ["="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true,
  ["!="] = true, ["<>"] = true,
}

local SQL_FUNCTIONS = {
  -- String
  "CONCAT", "CONCAT_WS", "FORMAT", "INSTR", "LOCATE", "POSITION",
  "LEFT", "RIGHT", "SUBSTRING", "SUBSTR", "MID", "SUBSTRING_INDEX",
  "LENGTH", "CHAR_LENGTH", "CHARACTER_LENGTH", "OCTET_LENGTH", "BIT_LENGTH",
  "LOWER", "LCASE", "UPPER", "UCASE", "TRIM", "LTRIM", "RTRIM",
  "REPLACE", "REGEXP_REPLACE", "REGEXP_LIKE", "REGEXP_SUBSTR", "REGEXP_INSTR",
  "REPEAT", "REVERSE", "LPAD", "RPAD", "SPACE",
  "FIELD", "FIND_IN_SET", "ELT", "SOUNDEX",
  "ASCII", "ORD", "CHAR", "UNICODE", "UNHEX", "HEX",
  "QUOTE", "STRCMP",

  -- Numeric / Math
  "ABS", "CEIL", "CEILING", "FLOOR", "ROUND", "TRUNCATE", "TRUNC",
  "RAND", "RANDOM", "POWER", "POW", "SQRT", "EXP", "LN", "LOG", "LOG2", "LOG10",
  "MOD", "SIGN", "PI", "DIV", "CRC32",
  "SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "ATAN2",
  "RADIANS", "DEGREES",
  "GREATEST", "LEAST",

  -- Aggregate / Window
  "COUNT", "SUM", "AVG", "MIN", "MAX", "GROUP_CONCAT", "STRING_AGG", "ARRAY_AGG",
  "STD", "STDDEV", "STDDEV_POP", "STDDEV_SAMP",
  "VAR_POP", "VAR_SAMP", "VARIANCE",
  "BIT_AND", "BIT_OR", "BIT_XOR",
  "ROW_NUMBER", "RANK", "DENSE_RANK", "NTILE", "LAG", "LEAD",
  "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE",
  "CUME_DIST", "PERCENT_RANK", "PERCENTILE_CONT", "PERCENTILE_DISC",

  -- Date / Time
  "NOW", "SYSDATE", "LOCALTIME", "LOCALTIMESTAMP",
  "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP",
  "CURDATE", "CURTIME",
  "YEAR", "MONTH", "DAY", "DAYOFMONTH", "DAYOFWEEK", "DAYOFYEAR",
  "WEEK", "WEEKDAY", "WEEKOFYEAR",
  "HOUR", "MINUTE", "SECOND", "MICROSECOND",
  "QUARTER", "LAST_DAY",
  "DATE_FORMAT", "TIME_FORMAT",
  "FROM_UNIXTIME", "UNIX_TIMESTAMP",
  "STR_TO_DATE", "TO_DAYS", "FROM_DAYS",
  "DATE_ADD", "DATE_SUB", "ADDDATE", "SUBDATE",
  "ADDTIME", "SUBTIME", "TIMEDIFF", "TIMESTAMPDIFF", "TIMESTAMPADD",
  "DATEDIFF",
  "EXTRACT", "DATE_PART",
  "MAKEDATE", "MAKETIME", "MAKE_DATE", "MAKE_TIME", "MAKE_TIMESTAMP",
  "CONVERT_TZ",
  "DATE_TRUNC", "TIME_TRUNC",
  "AGE", "ISFINITE", "JUSTIFY_DAYS", "JUSTIFY_HOURS", "JUSTIFY_INTERVAL",
  "CLOCK_TIMESTAMP", "STATEMENT_TIMESTAMP", "TRANSACTION_TIMESTAMP",

  -- JSON
  "JSON_EXTRACT", "JSON_UNQUOTE", "JSON_KEYS", "JSON_CONTAINS",
  "JSON_CONTAINS_PATH", "JSON_SET", "JSON_INSERT", "JSON_REPLACE",
  "JSON_REMOVE", "JSON_ARRAY", "JSON_OBJECT", "JSON_ARRAY_APPEND",
  "JSON_MERGE", "JSON_MERGE_PATCH",
  "JSON_TYPE", "JSON_VALID", "JSON_DEPTH", "JSON_LENGTH",
  "JSON_QUOTE", "JSON_TABLE", "JSON_VALUE",
  "JSON_AGG", "JSON_OBJECT_AGG",
  "JSONB_BUILD_OBJECT", "JSONB_AGG", "JSONB_PRETTY", "JSONB_EXTRACT_PATH",
  "TO_JSON", "ROW_TO_JSON",

  -- Conditional
  "COALESCE", "NULLIF", "IFNULL", "IF",

  -- Type conversion
  "CAST", "CONVERT", "TRY_CAST", "TRY_CONVERT",
  "TO_CHAR", "TO_NUMBER", "TO_TIMESTAMP",

  -- Security / Hash
  "MD5", "SHA1", "SHA2", "AES_ENCRYPT", "AES_DECRYPT",
  "RANDOM_BYTES", "UUID", "UUID_SHORT",

  -- System / Info
  "VERSION", "DATABASE", "SCHEMA", "USER",
  "SESSION_USER", "SYSTEM_USER", "CONNECTION_ID",
  "ROW_COUNT", "FOUND_ROWS", "LAST_INSERT_ID",
  "CHARSET", "COLLATION", "CURRENT_SCHEMA",
  "CURRENT_SETTING", "SET_CONFIG",

  -- Full-Text Search
  "MATCH", "AGAINST",

  -- Postgres extras
  "UNNEST", "GENERATE_SERIES", "ARRAY", "ROW", "SETSEED",

  -- MySQL extras
  "ANY_VALUE", "BENCHMARK",
  "GET_LOCK", "RELEASE_LOCK", "RELEASE_ALL_LOCKS",
  "IS_FREE_LOCK", "IS_USED_LOCK",
  "SLEEP", "VALUES",

  -- SQLite extras
  "TOTAL", "TYPEOF", "LIKELY", "UNLIKELY", "LIKELIHOOD",
  "CHANGES", "TOTAL_CHANGES",
  "SQLITE_VERSION", "SQLITE_SOURCE_ID", "ZEROBLOB",
}

M.KEYWORDS = KEYWORDS
M.DATA_TYPES = DATA_TYPES
M.SQL_FUNCTIONS = SQL_FUNCTIONS
M.TABLE_CTX = TABLE_CTX
M.COLUMN_CTX = COLUMN_CTX

---------------------------------------------------------------------------
-- Cache  { [key] = { tables=[], columns={[tbl]=[]} } }
---------------------------------------------------------------------------

local cache = {}

function M.get_cache() return cache end

function M.resolve_current_context()
  local ok, sql_context = pcall(require, "poste.sql.context")
  if not ok then return state.sql and state.sql.context end
  local ctx = sql_context.resolve_context(vim.api.nvim_get_current_buf())
  if not ctx.connection then
    ctx.connection = state.sql and state.sql.context and state.sql.context.connection
  end
  if not ctx.database then
    ctx.database = state.sql and state.sql.context and state.sql.context.database
  end
  return ctx
end

function M.conn_key()
  local ctx = M.resolve_current_context()
  if ctx and ctx.connection then
    return ctx.connection .. "/" .. (ctx.database or "")
  end
  if vim.g.poste_sql_debug then
    state.log("WARN", "SQL completion: no connection context found")
  end
  return nil
end

function M.cache_tables(items)
  local key = M.conn_key()
  if not key then return end
  cache[key] = cache[key] or { tables = {}, columns = {} }
  cache[key].tables = vim.tbl_map(function(i) return i.name end, items or {})
end

function M.cache_columns(tbl, items, schema)
  local key = M.conn_key()
  if not key then return end
  local cache_key = schema and (schema .. "." .. tbl) or tbl
  cache[key] = cache[key] or { tables = {}, columns = {} }
  cache[key].columns[cache_key] = vim.tbl_map(function(i) return i.name end, items or {})
end

---------------------------------------------------------------------------
-- Binary helper
---------------------------------------------------------------------------

function M.find_binary()
  if state.config and state.config.poste_binary ~= "" then
    return state.config.poste_binary
  end
  for _, p in ipairs({ "./target/debug/poste", "./target/release/poste" }) do
    if vim.fn.filereadable(p) == 1 then return vim.fn.fnamemodify(p, ":p") end
  end
  return nil
end

function M.search_dir()
  local name = vim.api.nvim_buf_get_name(0)
  return name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
end

---------------------------------------------------------------------------
-- Lazy fetch tables
---------------------------------------------------------------------------

local fetching_tables = {}
local tables_callbacks = {}

function M.ensure_tables(callback)
  local key = M.conn_key()
  local ctx = M.resolve_current_context()
  if not key or not ctx or not ctx.connection then
    callback()
    return
  end

  if cache[key] and #cache[key].tables > 0 then callback(); return end

  if fetching_tables[key] then
    tables_callbacks[key] = tables_callbacks[key] or {}
    table.insert(tables_callbacks[key], callback)
    return
  end

  fetching_tables[key] = true
  tables_callbacks[key] = { callback }

  local binary = M.find_binary()
  if not binary then
    fetching_tables[key] = false
    for _, cb in ipairs(tables_callbacks[key] or {}) do cb() end
    tables_callbacks[key] = nil
    return
  end

  local args = { binary, "introspect", ctx.connection,
    "--type", "tables", "--path", M.search_dir(),
    "--env", state.current_env or "dev" }
  if ctx.database and ctx.database ~= "" then
    vim.list_extend(args, { "--database", ctx.database })
  end

  vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      while #data > 0 and data[#data] == "" do data[#data] = nil end
      if #data == 0 then return end
      local ok, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
      if ok and parsed and parsed.items then
        cache[key] = cache[key] or { tables = {}, columns = {} }
        cache[key].tables = vim.tbl_map(function(i) return i.name end, parsed.items)
      end
      fetching_tables[key] = false
      vim.schedule(function()
        for _, cb in ipairs(tables_callbacks[key] or {}) do cb() end
        tables_callbacks[key] = nil
      end)
    end,
    on_exit = function(_, code)
      fetching_tables[key] = false
      if code ~= 0 then
        vim.schedule(function()
          for _, cb in ipairs(tables_callbacks[key] or {}) do cb() end
          tables_callbacks[key] = nil
        end)
      end
    end,
  })
end

---------------------------------------------------------------------------
-- Lazy fetch databases for current connection
---------------------------------------------------------------------------

local fetching_dbs = {}
local dbs_callbacks = {}

function M.ensure_databases(callback)
  local ctx = M.resolve_current_context()
  if not ctx or not ctx.connection then callback({}); return end

  local conn_key_str = ctx.connection
  if fetching_dbs[conn_key_str] then
    dbs_callbacks[conn_key_str] = dbs_callbacks[conn_key_str] or {}
    table.insert(dbs_callbacks[conn_key_str], callback)
    return
  end

  local cache_key = conn_key_str .. "/__databases__"
  if cache[cache_key] then callback(cache[cache_key]); return end

  fetching_dbs[conn_key_str] = true
  dbs_callbacks[conn_key_str] = { callback }

  local binary = M.find_binary()
  if not binary then fetching_dbs[conn_key_str] = false; callback({}); return end

  local args = { binary, "introspect", ctx.connection,
    "--type", "databases", "--path", M.search_dir(),
    "--env", state.current_env or "dev" }

  vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      while #data > 0 and data[#data] == "" do data[#data] = nil end
      if #data == 0 then return end
      local ok, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
      local names = {}
      if ok and parsed and parsed.items then
        names = vim.tbl_map(function(i) return i.name end, parsed.items)
        cache[cache_key] = names
      end
      fetching_dbs[conn_key_str] = false
      vim.schedule(function()
        for _, cb in ipairs(dbs_callbacks[conn_key_str] or {}) do cb(names) end
        dbs_callbacks[conn_key_str] = nil
      end)
    end,
    on_exit = function(_, code)
      fetching_dbs[conn_key_str] = false
      if code ~= 0 then
        vim.schedule(function()
          for _, cb in ipairs(dbs_callbacks[conn_key_str] or {}) do cb({}) end
          dbs_callbacks[conn_key_str] = nil
        end)
      end
    end,
  })
end

---------------------------------------------------------------------------
-- Lazy fetch columns for a single table
---------------------------------------------------------------------------

local fetching_cols = {}
local cols_callbacks = {}

--- Ensure columns for `tbl` are cached, optionally with schema qualification.
--- schema can be a string or nil. When set, columns are cached and fetched
--- as `schema.table` to distinguish same-named tables in different schemas.
function M.ensure_columns(tbl, schema, callback)
  if type(schema) == "function" then
    callback = schema
    schema = nil
  end
  local key = M.conn_key()
  local ctx = M.resolve_current_context()
  local cache_tbl_key = schema and (schema .. "." .. tbl) or tbl

  if vim.g.poste_sql_debug then
    vim.notify(string.format("DEBUG: ensure_columns(%s, %s) key=%s, conn=%s",
      tbl, tostring(schema), tostring(key), tostring(ctx and ctx.connection)), vim.log.levels.INFO)
  end

  if not key or not ctx or not ctx.connection then
    if vim.g.poste_sql_debug then
      vim.notify("DEBUG: ensure_columns - NO CONNECTION, returning", vim.log.levels.ERROR)
    end
    callback()
    return
  end

  if cache[key] and cache[key].columns[cache_tbl_key] then
    if vim.g.poste_sql_debug then
      vim.notify(string.format("DEBUG: cache hit for %s, %d columns",
        cache_tbl_key, #cache[key].columns[cache_tbl_key]), vim.log.levels.INFO)
    end
    callback()
    return
  end

  local fkey = key .. "/" .. cache_tbl_key

  if fetching_cols[fkey] then
    if vim.g.poste_sql_debug then
      vim.notify(string.format("DEBUG: already fetching %s, queuing callback", cache_tbl_key), vim.log.levels.WARN)
    end
    cols_callbacks[fkey] = cols_callbacks[fkey] or {}
    table.insert(cols_callbacks[fkey], callback)
    return
  end

  if vim.g.poste_sql_debug then
    vim.notify(string.format("DEBUG: starting fetch for %s", cache_tbl_key), vim.log.levels.WARN)
  end

  fetching_cols[fkey] = true
  cols_callbacks[fkey] = { callback }

  local binary = M.find_binary()
  if not binary then
    vim.notify("DEBUG: binary not found!", vim.log.levels.ERROR)
    fetching_cols[fkey] = false
    for _, cb in ipairs(cols_callbacks[fkey] or {}) do cb() end
    cols_callbacks[fkey] = nil
    return
  end

  local args = { binary, "introspect", ctx.connection,
    "--type", "columns", "--table", tbl,
    "--path", M.search_dir(), "--env", state.current_env or "dev" }
  if schema then
    vim.list_extend(args, { "--schema", schema })
  end
  if ctx.database and ctx.database ~= "" then
    vim.list_extend(args, { "--database", ctx.database })
  end

  vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      while #data > 0 and data[#data] == "" do data[#data] = nil end
      if #data == 0 then return end
      local ok, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
      if ok and parsed and parsed.items then
        cache[key] = cache[key] or { tables = {}, columns = {} }
        local cols = {}
        for _, item in ipairs(parsed.items) do
          table.insert(cols, item.name)
        end
        cache[key].columns[cache_tbl_key] = cols
      end
      fetching_cols[fkey] = false
      vim.schedule(function()
        for _, cb in ipairs(cols_callbacks[fkey] or {}) do cb() end
        cols_callbacks[fkey] = nil
      end)
    end,
    on_exit = function(_, code)
      fetching_cols[fkey] = false
      if code ~= 0 then
        vim.schedule(function()
          for _, cb in ipairs(cols_callbacks[fkey] or {}) do cb() end
          cols_callbacks[fkey] = nil
        end)
      end
    end,
  })
end

---------------------------------------------------------------------------
-- Lazy fetch connection names
---------------------------------------------------------------------------

local conn_names_cache = nil

function M.ensure_conn_names(callback)
  if conn_names_cache then callback(conn_names_cache); return end
  local binary = M.find_binary()
  if not binary then callback({}); return end
  local args = { binary, "connection", "list", "--json", "--path", M.search_dir(), "--env", state.current_env or "dev" }
  vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      while #data > 0 and data[#data] == "" do data[#data] = nil end
      if #data == 0 then return end
      local ok, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
      local names = {}
      if ok and parsed then
        for _, item in ipairs(parsed) do
          table.insert(names, item.name)
        end
        conn_names_cache = names
      end
      callback(names)
    end,
    on_exit = function(_, code)
      if code ~= 0 then callback({}) end
    end,
  })
end

return M
