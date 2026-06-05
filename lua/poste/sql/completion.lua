--- SQL completion source for blink.cmp and nvim-cmp.
---
--- Smart context detection (based on last keyword before cursor):
---   FROM / JOIN / UPDATE / INTO / TABLE  → table names
---   WHERE / SET / ON / HAVING / AND / OR / NOT / BY / SELECT  → column names
---     (columns inferred from current statement's FROM/JOIN tables)
---   table.  → columns for that table
---   @connection  → connection names
---   otherwise  → keywords + data types
---
--- Cache is populated lazily on first trigger per connection+database key.

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
  "CREATE TABLE", "ALTER TABLE", "DROP TABLE", "ADD COLUMN", "DROP COLUMN",
  "RENAME COLUMN", "MODIFY COLUMN",
  "AND", "OR", "NOT", "IN", "NOT IN", "EXISTS", "IS NULL", "IS NOT NULL",
  "LIKE", "ILIKE", "BETWEEN",
  "COUNT", "SUM", "AVG", "MAX", "MIN", "COALESCE", "NULLIF",
  "CAST", "NOW", "CURRENT_TIMESTAMP", "CURRENT_DATE",
  "TRIM", "UPPER", "LOWER", "LENGTH", "SUBSTRING", "CONCAT",
  "PRIMARY KEY", "FOREIGN KEY", "UNIQUE", "NOT NULL", "DEFAULT", "REFERENCES",
  "BEGIN", "COMMIT", "ROLLBACK",
}

local DATA_TYPES = {
  "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "DECIMAL", "NUMERIC",
  "FLOAT", "DOUBLE", "REAL", "SERIAL", "BIGSERIAL",
  "VARCHAR(255)", "TEXT", "CHAR(1)",
  "DATE", "TIME", "DATETIME", "TIMESTAMP", "TIMESTAMPTZ",
  "BOOLEAN", "BOOL", "BLOB", "BYTEA", "JSON", "JSONB", "UUID",
}

-- After these words the next token is a table name
local TABLE_CTX = {
  from = true, join = true, update = true, into = true, table = true,
}

-- After these words the next token is a column/expression
local COLUMN_CTX = {
  where = true, set = true, on = true, having = true, select = true,
  ["and"] = true, ["or"] = true, ["not"] = true,
  by = true,  -- ORDER BY, GROUP BY
  ["="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true,
  ["!="] = true, ["<>"] = true,
}

---------------------------------------------------------------------------
-- Cache  { [key] = { tables=[], columns={[tbl]=[]} } }
---------------------------------------------------------------------------

local cache = {}

local function resolve_current_context()
  -- Resolve context live from the current buffer (mirrors what run_sql_request does)
  local ok, sql_context = pcall(require, "poste.sql.context")
  if not ok then return state.sql and state.sql.context end
  local ctx = sql_context.resolve_context(vim.api.nvim_get_current_buf())
  -- Fall back to global state for fields not found in buffer
  if not ctx.connection then
    ctx.connection = state.sql and state.sql.context and state.sql.context.connection
  end
  if not ctx.database then
    ctx.database = state.sql and state.sql.context and state.sql.context.database
  end
  return ctx
end

local function conn_key()
  local ctx = resolve_current_context()
  if ctx and ctx.connection then
    return ctx.connection .. "/" .. (ctx.database or "")
  end
  -- Debug: log when connection is missing
  if vim.g.poste_sql_debug then
    state.log("WARN", "SQL completion: no connection context found")
  end
  return nil
end

function M.cache_tables(items)
  local key = conn_key()
  if not key then return end
  cache[key] = cache[key] or { tables = {}, columns = {} }
  cache[key].tables = vim.tbl_map(function(i) return i.name end, items or {})
end

function M.cache_columns(tbl, items)
  local key = conn_key()
  if not key then return end
  cache[key] = cache[key] or { tables = {}, columns = {} }
  cache[key].columns[tbl] = vim.tbl_map(function(i) return i.name end, items or {})
end

---------------------------------------------------------------------------
-- Binary helper
---------------------------------------------------------------------------

local function find_binary()
  if state.config and state.config.poste_binary ~= "" then
    return state.config.poste_binary
  end
  for _, p in ipairs({ "./target/debug/poste", "./target/release/poste" }) do
    if vim.fn.filereadable(p) == 1 then return vim.fn.fnamemodify(p, ":p") end
  end
  return nil
end

local function search_dir()
  local name = vim.api.nvim_buf_get_name(0)
  return name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
end

---------------------------------------------------------------------------
-- Lazy fetch tables
---------------------------------------------------------------------------

local fetching_tables = {}
local tables_callbacks = {}  -- Queue callbacks while fetching

local function ensure_tables(callback)
  local key = conn_key()
  local ctx = resolve_current_context()
  if not key or not ctx or not ctx.connection then
    callback()
    return
  end

  -- Cache hit
  if cache[key] and #cache[key].tables > 0 then callback(); return end
  
  -- Already fetching: queue callback
  if fetching_tables[key] then
    tables_callbacks[key] = tables_callbacks[key] or {}
    table.insert(tables_callbacks[key], callback)
    return
  end
  
  fetching_tables[key] = true
  tables_callbacks[key] = { callback }

  local binary = find_binary()
  if not binary then 
    fetching_tables[key] = false
    for _, cb in ipairs(tables_callbacks[key] or {}) do cb() end
    tables_callbacks[key] = nil
    return
  end

  local args = { binary, "introspect", ctx.connection,
    "--type", "tables", "--path", search_dir(),
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

local function ensure_databases(callback)
  local ctx = resolve_current_context()
  if not ctx or not ctx.connection then callback({}); return end

  local conn_key_str = ctx.connection  -- databases are per-connection, not per-database
  if fetching_dbs[conn_key_str] then
    dbs_callbacks[conn_key_str] = dbs_callbacks[conn_key_str] or {}
    table.insert(dbs_callbacks[conn_key_str], callback)
    return
  end

  -- Use cache entry keyed by connection alone
  local cache_key = conn_key_str .. "/__databases__"
  if cache[cache_key] then callback(cache[cache_key]); return end

  fetching_dbs[conn_key_str] = true
  dbs_callbacks[conn_key_str] = { callback }

  local binary = find_binary()
  if not binary then fetching_dbs[conn_key_str] = false; callback({}); return end

  local args = { binary, "introspect", ctx.connection,
    "--type", "databases", "--path", search_dir(),
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
local cols_callbacks = {}  -- Queue callbacks while fetching

local function ensure_columns(tbl, callback)
  local key = conn_key()
  local ctx = resolve_current_context()
  
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

  -- Cache hit
  if cache[key] and cache[key].columns[tbl] then 
    if vim.g.poste_sql_debug then
      vim.notify(string.format("DEBUG: cache hit for %s, %d columns", 
        tbl, #cache[key].columns[tbl]), vim.log.levels.INFO)
    end
    callback()
    return
  end
  
  local fkey = key .. "/" .. tbl
  
  -- Already fetching: queue callback
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

  local binary = find_binary()
  if not binary then 
    vim.notify("DEBUG: binary not found!", vim.log.levels.ERROR)
    fetching_cols[fkey] = false
    for _, cb in ipairs(cols_callbacks[fkey] or {}) do cb() end
    cols_callbacks[fkey] = nil
    return
  end

  local args = { binary, "introspect", ctx.connection,
    "--type", "columns", "--table", tbl,
    "--path", search_dir(), "--env", state.current_env or "dev" }
  if ctx.database and ctx.database ~= "" then
    vim.list_extend(args, { "--database", ctx.database })
  end
  if ctx.schema and ctx.schema ~= "" then
    vim.list_extend(args, { "--schema", ctx.schema })
  end

  if vim.g.poste_sql_debug then
    vim.notify("DEBUG: jobstart: " .. table.concat(args, " "), vim.log.levels.INFO)
  end

  vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if vim.g.poste_sql_debug then
        state.log("INFO", string.format("ensure_columns on_stdout: data=%s", vim.inspect(data)))
      end
      
      if not data then return end
      while #data > 0 and data[#data] == "" do data[#data] = nil end
      if #data == 0 then return end
      local ok, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
      
      if vim.g.poste_sql_debug then
        state.log("INFO", string.format("ensure_columns parsed: ok=%s, items=%d", 
          tostring(ok), ok and parsed and parsed.items and #parsed.items or 0))
      end
      
      if ok and parsed and parsed.items then
        cache[key] = cache[key] or { tables = {}, columns = {} }
        cache[key].columns[tbl] = vim.tbl_map(function(i) return i.name end, parsed.items)
        
        if vim.g.poste_sql_debug then
          state.log("INFO", string.format("ensure_columns cached %d columns for %s", 
            #cache[key].columns[tbl], tbl))
        end
      end
      fetching_cols[fkey] = false
      vim.schedule(function()
        if vim.g.poste_sql_debug then
          state.log("INFO", string.format("ensure_columns calling %d callbacks", 
            #(cols_callbacks[fkey] or {})))
        end
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
-- Connection names
---------------------------------------------------------------------------

local conn_names_cache = nil

local function ensure_conn_names(callback)
  if conn_names_cache then callback(conn_names_cache); return end
  local binary = find_binary()
  if not binary then callback({}); return end

  vim.fn.jobstart({ binary, "connection", "list",
    "--path", search_dir(), "--env", state.current_env or "dev", "--json" }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      while #data > 0 and data[#data] == "" do data[#data] = nil end
      if #data == 0 then return end
      local ok, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
      if ok and type(parsed) == "table" then
        conn_names_cache = vim.tbl_map(function(c) return c.name end, parsed)
        callback(conn_names_cache)
      end
    end,
    on_exit = function(_, code) if code ~= 0 then callback({}) end end,
  })
end

---------------------------------------------------------------------------
-- Parse FROM/JOIN tables from current SQL block
---------------------------------------------------------------------------

local function extract_from_tables(bufnr, cursor_lnum)
  -- collect lines from start of current ### block to cursor
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, cursor_lnum, false)
  local block_start = 1
  for i = #lines, 1, -1 do
    if lines[i]:match("^###") then block_start = i; break end
  end
  -- Strip -- comments per line BEFORE joining (joining loses \n so [^\n]* would eat everything)
  local stripped = {}
  for i = block_start, #lines do
    local l = (lines[i] or ""):gsub("%-%-.*", " ")
    stripped[#stripped + 1] = l
  end
  local text = table.concat(stripped, " ")

  -- alias_map: alias (or table name) → real table name
  local alias_map = {}
  local seen, tbls = {}, {}

  local function add(tbl, alias)
    -- real table name
    if not seen[tbl] then seen[tbl] = true; table.insert(tbls, tbl) end
    -- alias → real table (also map table name to itself for dot-notation without alias)
    alias_map[tbl] = tbl
    if alias and alias ~= tbl then alias_map[alias] = tbl end
  end

  for _, pat in ipairs({
    -- table_name optional_alias  (alias = bare word after table name, not a keyword)
    "[Ff][Rr][Oo][Mm]%s+([%w_]+)%s+([%w_]+)",
    "[Jj][Oo][Ii][Nn]%s+([%w_]+)%s+([%w_]+)",
    "[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_]+)%s+([%w_]+)",
  }) do
    for tbl, alias in text:gmatch(pat) do
      -- Skip if alias is a SQL keyword (ON, SET, WHERE, etc.)
      local kw = { on=true, set=true, where=true, left=true, right=true,
                   inner=true, outer=true, cross=true, full=true, join=true,
                   ["as"]=true, using=true }
      add(tbl, kw[alias:lower()] and nil or alias)
    end
  end
  -- Also match without alias
  for _, pat in ipairs({
    "[Ff][Rr][Oo][Mm]%s+([%w_]+)",
    "[Jj][Oo][Ii][Nn]%s+([%w_]+)",
    "[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_]+)",
  }) do
    for t in text:gmatch(pat) do
      if not seen[t] then seen[t] = true; table.insert(tbls, t) end
      alias_map[t] = alias_map[t] or t
    end
  end

  return tbls, alias_map
end

---------------------------------------------------------------------------
-- Context detection
---------------------------------------------------------------------------

--- Returns: ctx_type ("table"|"column"|"dot_column"|"connection"|"database"|"keyword"), extra
local function detect_context(line_before)
  -- @connection directive (anywhere on the line up to cursor)
  if line_before:match("@connection%s+%S*$") then
    return "connection", nil
  end

  -- USE statement: USE <db>
  if line_before:match("^%s*[Uu][Ss][Ee]%s+%S*$") then
    return "database", nil
  end

  -- table.col  (e.g. "users." or "users.na")
  local dot_tbl = line_before:match("([%w_]+)%.[%w_]*$")
  if dot_tbl then
    return "dot_column", dot_tbl
  end

  -- Extract all words, but check the SECOND-TO-LAST word for context
  -- The last word is the user's typing prefix (for filtering)
  local words = {}
  for word in line_before:gmatch("[%w_]+") do
    table.insert(words, word)
  end
  
  -- Check if line ends with a partial word (for context, we want the word BEFORE it)
  local check_word_idx = #words
  if line_before:match("[%w_]+$") then
    -- Ends with alphanumeric: last word is user's prefix, check second-to-last
    check_word_idx = #words - 1
  end
  
  if check_word_idx >= 1 then
    local keyword = words[check_word_idx]:lower()
    if TABLE_CTX[keyword] then return "table", nil end
    if COLUMN_CTX[keyword] then return "column", nil end
  end

  return "keyword", nil
end

---------------------------------------------------------------------------
-- Item helpers
---------------------------------------------------------------------------

local function make_items(names, kind, doc_prefix)
  local items = {}
  for _, n in ipairs(names or {}) do
    table.insert(items, { label = n, kind = kind, insertText = n,
      documentation = doc_prefix and (doc_prefix .. n) or n })
  end
  return items
end

local function filter(items, prefix)
  if prefix == "" then return items end
  local low = prefix:lower()
  return vim.tbl_filter(function(i)
    return i.label:lower():sub(1, #low) == low
  end, items)
end

local function kw_items(prefix)
  local low = prefix:lower()
  local items = {}
  for _, kw in ipairs(KEYWORDS) do
    if kw:lower():sub(1, #low) == low then
      table.insert(items, { label = kw, kind = 14, insertText = kw, documentation = "keyword" })
    end
  end
  for _, t in ipairs(DATA_TYPES) do
    if t:lower():sub(1, #low) == low then
      table.insert(items, { label = t, kind = 25, insertText = t, documentation = "type" })
    end
  end
  return items
end

---------------------------------------------------------------------------
-- Main entry
---------------------------------------------------------------------------

local function get_items(bufnr, line_before, cursor_line, callback)
  local prefix = line_before:match("[%w_]*$") or ""
  local ctx_type, ctx_data = detect_context(line_before)

  if vim.g.poste_sql_debug then
    vim.notify(string.format("DEBUG get_items: ctx=%s, prefix='%s', line='%s'", 
      ctx_type, prefix, line_before), vim.log.levels.WARN)
  end

  if ctx_type == "connection" then
    local cp = line_before:match("@connection%s+(%S*)$") or ""
    ensure_conn_names(function(names)
      callback(filter(make_items(names, 6, "connection: "), cp))
    end)
    return
  end

  if ctx_type == "database" then
    local db_prefix = line_before:match("[Uu][Ss][Ee]%s+(%S*)$") or ""
    ensure_databases(function(names)
      callback(filter(make_items(names, 1, "database: "), db_prefix))
    end)
    return
  end

  if ctx_type == "dot_column" then
    local col_prefix = line_before:match("[%w_]+%.([%w_]*)$") or ""
    -- Resolve alias to real table name using current block's alias map
    local _, alias_map = extract_from_tables(bufnr, cursor_line or vim.fn.line("."))
    local real_tbl = alias_map[ctx_data] or ctx_data
    ensure_columns(real_tbl, function()
      local key = conn_key()
      local cols = cache[key] and cache[key].columns[real_tbl] or {}
      callback(filter(make_items(cols, 5, "col: "), col_prefix))
    end)
    return
  end

  if ctx_type == "table" then
    ensure_tables(function()
      local key = conn_key()
      local tbls = cache[key] and cache[key].tables or {}
      local items = make_items(tbls, 7, "table: ")
      -- If no tables available (no connection or empty DB), still show keywords
      if #items == 0 then
        items = kw_items(prefix)
      end
      callback(filter(items, prefix))
    end)
    return
  end

  if ctx_type == "column" then
    local from_tbls, alias_map = extract_from_tables(bufnr, cursor_line or vim.fn.line("."))
    -- Resolve aliases to real table names (deduplicated)
    local real_tbls, seen_real = {}, {}
    for _, t in ipairs(from_tbls) do
      local real = alias_map[t] or t
      if not seen_real[real] then seen_real[real] = true; table.insert(real_tbls, real) end
    end
    
    if vim.g.poste_sql_debug then
      vim.notify(string.format("DEBUG: column context, %d tables: %s",
        #real_tbls, vim.inspect(real_tbls)), vim.log.levels.INFO)
    end

    if #real_tbls == 0 then
      callback(kw_items(prefix))
      return
    end
    local pending = #real_tbls
    local all = {}
    for _, tbl in ipairs(real_tbls) do
      if vim.g.poste_sql_debug then
        vim.notify(string.format("DEBUG: calling ensure_columns for %s", tbl), vim.log.levels.INFO)
      end
      
      ensure_columns(tbl, function()
        local key = conn_key()
        local cols = cache[key] and cache[key].columns[tbl] or {}
        
        if vim.g.poste_sql_debug then
          vim.notify(string.format("DEBUG: callback fired! tbl=%s, cols=%d, pending=%d->%d", 
            tbl, #cols, pending, pending - 1), vim.log.levels.WARN)
        end
        
        for _, col in ipairs(cols) do
          table.insert(all, { 
            label = col, 
            kind = 5, 
            insertText = col,
            filterText = col,  -- Explicit for blink.cmp
            sortText = col,
            documentation = "col: " .. tbl .. "." .. col 
          })
        end
        pending = pending - 1
        
        if pending == 0 then 
          if vim.g.poste_sql_debug then
            vim.notify(string.format("DEBUG: calling final callback with %d items", #all), vim.log.levels.WARN)
          end
          callback(filter(all, prefix))
        end
      end)
    end
    return
  end

  -- keyword: also mix in table names so they show up in general typing
  ensure_tables(function()
    local key = conn_key()
    local tbls = cache[key] and cache[key].tables or {}
    local items = kw_items(prefix)
    for _, item in ipairs(filter(make_items(tbls, 7, "table: "), prefix)) do
      table.insert(items, item)
    end
    callback(items)
  end)
end

---------------------------------------------------------------------------
-- blink.cmp interface
-- blink calls require("poste.sql.completion").new() then instance methods
---------------------------------------------------------------------------

function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

--- blink uses :enabled(), not :is_available()
function M:enabled()
  local ft = vim.bo.filetype
  return ft == "poste_sql" or ft == "poste_sqlite"
end

function M:get_trigger_characters()
  return { ".", " ", "@" }
end

--- Tell blink.cmp the minimum keyword length (0 = show immediately after trigger)
function M:get_keyword_length()
  return 0
end

--- blink.cmp calls this with (ctx, callback)
--- ctx.line  = full line text
--- ctx.cursor = {row, col}  (col is byte-index into line, 1-based in some versions)
function M:get_completions(ctx, callback)
  -- Use real-time cursor state (blink ctx snapshot may lag by one character
  -- when triggered by a trigger character like space)
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.fn.line(".")
  local cursor_col  = vim.fn.col(".")   -- 1-based byte offset of cursor
  local line = vim.api.nvim_get_current_line()
  local line_before = line:sub(1, cursor_col - 1)

  -- Debug logging
  if vim.g.poste_sql_debug then
    state.log("INFO", string.format("SQL completion triggered: line_before='%s'", line_before))
  end

  get_items(bufnr, line_before, cursor_line, function(items)
    if vim.g.poste_sql_debug then
      state.log("INFO", string.format("SQL completion: returning %d items", #items))
    end
    callback({ is_incomplete_forward = true, is_incomplete_backward = false, items = items })
  end)
end

function M:resolve(item, callback) callback(item) end
function M:execute(ctx, item, callback, default_impl)
  if default_impl then default_impl() end
  callback()
end

---------------------------------------------------------------------------
-- nvim-cmp interface
---------------------------------------------------------------------------

M.source = {}
function M.source.new() return setmetatable({}, { __index = M.source }) end
function M.source:is_available()
  local ft = vim.bo.filetype
  return ft == "poste_sql" or ft == "poste_sqlite"
end
function M.source:get_trigger_characters() return { ".", " ", "@" } end
function M.source:complete(params, callback)
  local line_before = params.context.cursor_before_line or ""
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.fn.line(".")
  get_items(bufnr, line_before, cursor_line, function(items)
    callback({ items = items, isIncomplete = false })
  end)
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

--- Called from ftplugin for nvim-cmp registration.
function M.register()
  local ok, cmp = pcall(require, "cmp")
  if not ok then return end
  cmp.register_source("poste_sql", M.source.new())
  cmp.setup.filetype({ "poste_sql", "poste_sqlite" }, {
    sources = cmp.config.sources({ { name = "poste_sql" } }, { { name = "buffer" } }),
  })
end

---------------------------------------------------------------------------
-- Test interface
---------------------------------------------------------------------------
M._test = {
  detect_context = detect_context,
  resolve_current_context = resolve_current_context,
  conn_key = conn_key,
  get_items = get_items,
  extract_from_tables = extract_from_tables,
}

return M
