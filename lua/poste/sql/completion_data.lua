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

M.KEYWORDS = KEYWORDS
M.DATA_TYPES = DATA_TYPES
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

function M.cache_columns(tbl, items)
  local key = M.conn_key()
  if not key then return end
  cache[key] = cache[key] or { tables = {}, columns = {} }
  cache[key].columns[tbl] = vim.tbl_map(function(i) return i.name end, items or {})
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

function M.ensure_columns(tbl, callback)
  local key = M.conn_key()
  local ctx = M.resolve_current_context()

  if vim.g.poste_sql_debug then
    vim.notify(string.format("DEBUG: ensure_columns(%s) key=%s, conn=%s",
      tbl, tostring(key), tostring(ctx and ctx.connection)), vim.log.levels.INFO)
  end

  if not key or not ctx or not ctx.connection then
    if vim.g.poste_sql_debug then
      vim.notify("DEBUG: ensure_columns - NO CONNECTION, returning", vim.log.levels.ERROR)
    end
    callback()
    return
  end

  if cache[key] and cache[key].columns[tbl] then
    if vim.g.poste_sql_debug then
      vim.notify(string.format("DEBUG: cache hit for %s, %d columns",
        tbl, #cache[key].columns[tbl]), vim.log.levels.INFO)
    end
    callback()
    return
  end

  local fkey = key .. "/" .. tbl

  if fetching_cols[fkey] then
    if vim.g.poste_sql_debug then
      vim.notify(string.format("DEBUG: already fetching %s, queuing callback", tbl), vim.log.levels.WARN)
    end
    cols_callbacks[fkey] = cols_callbacks[fkey] or {}
    table.insert(cols_callbacks[fkey], callback)
    return
  end

  if vim.g.poste_sql_debug then
    vim.notify(string.format("DEBUG: starting fetch for %s", tbl), vim.log.levels.WARN)
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
        cache[key].columns[tbl] = cols
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
