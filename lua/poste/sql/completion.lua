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

local function conn_key()
  local ctx = state.sql and state.sql.context
  if ctx and ctx.connection then
    return ctx.connection .. "/" .. (ctx.database or "")
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

local function ensure_tables(callback)
  local key = conn_key()
  local ctx = state.sql and state.sql.context
  if not key or not ctx or not ctx.connection then callback(); return end

  if cache[key] and #cache[key].tables > 0 then callback(); return end
  if fetching_tables[key] then callback(); return end
  fetching_tables[key] = true

  local binary = find_binary()
  if not binary then callback(); return end

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
      vim.schedule(callback)
    end,
    on_exit = function(_, code)
      fetching_tables[key] = false
      if code ~= 0 then vim.schedule(callback) end
    end,
  })
end

---------------------------------------------------------------------------
-- Lazy fetch columns for a single table
---------------------------------------------------------------------------

local fetching_cols = {}

local function ensure_columns(tbl, callback)
  local key = conn_key()
  local ctx = state.sql and state.sql.context
  if not key or not ctx or not ctx.connection then callback(); return end

  if cache[key] and cache[key].columns[tbl] then callback(); return end
  local fkey = key .. "/" .. tbl
  if fetching_cols[fkey] then callback(); return end
  fetching_cols[fkey] = true

  local binary = find_binary()
  if not binary then callback(); return end

  local args = { binary, "introspect", ctx.connection,
    "--type", "columns", "--table", tbl,
    "--path", search_dir(), "--env", state.current_env or "dev" }
  if ctx.database and ctx.database ~= "" then
    vim.list_extend(args, { "--database", ctx.database })
  end
  if ctx.schema and ctx.schema ~= "" then
    vim.list_extend(args, { "--schema", ctx.schema })
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
        cache[key].columns[tbl] = vim.tbl_map(function(i) return i.name end, parsed.items)
      end
      fetching_cols[fkey] = false
      vim.schedule(callback)
    end,
    on_exit = function(_, code)
      fetching_cols[fkey] = false
      if code ~= 0 then vim.schedule(callback) end
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
  local text = table.concat(lines, " ", block_start, #lines)
        :gsub("%-%-[^\n]*", " ")   -- strip -- comments

  local seen, tbls = {}, {}
  for _, pat in ipairs({
    "[Ff][Rr][Oo][Mm]%s+([%w_]+)",
    "[Jj][Oo][Ii][Nn]%s+([%w_]+)",
    "[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_]+)",
  }) do
    for t in text:gmatch(pat) do
      if not seen[t] then seen[t] = true; table.insert(tbls, t) end
    end
  end
  return tbls
end

---------------------------------------------------------------------------
-- Context detection
---------------------------------------------------------------------------

--- Returns: ctx_type ("table"|"column"|"dot_column"|"connection"|"keyword"), extra
local function detect_context(line_before)
  -- @connection directive (anywhere on the line up to cursor)
  if line_before:match("@connection%s+%S*$") then
    return "connection", nil
  end

  -- table.col  (e.g. "users." or "users.na")
  local dot_tbl = line_before:match("([%w_]+)%.[%w_]*$")
  if dot_tbl then
    return "dot_column", dot_tbl
  end

  -- Strip the partial word the user is currently typing (may be empty)
  -- then find the last complete token before it.
  -- Use gsub with a function to replace only the trailing partial word.
  local before = line_before:gsub("[%w_]+$", ""):gsub("%s+$", "")
  -- If line ends with space (no partial word), before == line with trailing spaces stripped
  -- If line ends with a word, before == everything up to (not including) that word

  -- last token: word or operator
  local last = before:match("(%S+)%s*$") or ""
  local lower = last:lower()

  if TABLE_CTX[lower] then return "table", nil end
  if COLUMN_CTX[lower] then return "column", nil end

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

local function get_items(bufnr, line_before, callback)
  local prefix = line_before:match("[%w_]*$") or ""
  local ctx_type, ctx_data = detect_context(line_before)

  if ctx_type == "connection" then
    local cp = line_before:match("@connection%s+(%S*)$") or ""
    ensure_conn_names(function(names)
      callback(filter(make_items(names, 6, "connection: "), cp))
    end)
    return
  end

  if ctx_type == "dot_column" then
    local col_prefix = line_before:match("[%w_]+%.([%w_]*)$") or ""
    ensure_columns(ctx_data, function()
      local key = conn_key()
      local cols = cache[key] and cache[key].columns[ctx_data] or {}
      callback(filter(make_items(cols, 5, "col: "), col_prefix))
    end)
    return
  end

  if ctx_type == "table" then
    ensure_tables(function()
      local key = conn_key()
      local tbls = cache[key] and cache[key].tables or {}
      callback(filter(make_items(tbls, 7, "table: "), prefix))
    end)
    return
  end

  if ctx_type == "column" then
    local from_tbls = extract_from_tables(bufnr, vim.fn.line("."))
    if #from_tbls == 0 then
      callback(kw_items(prefix))
      return
    end
    local pending = #from_tbls
    local all = {}
    for _, tbl in ipairs(from_tbls) do
      ensure_columns(tbl, function()
        local key = conn_key()
        for _, col in ipairs(cache[key] and cache[key].columns[tbl] or {}) do
          table.insert(all, { label = col, kind = 5, insertText = col,
            documentation = "col: " .. tbl .. "." .. col })
        end
        pending = pending - 1
        if pending == 0 then callback(filter(all, prefix)) end
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

--- blink.cmp calls this with (ctx, callback)
--- ctx.line  = full line text
--- ctx.cursor = {row, col}  (col is byte-index into line, 1-based in some versions)
function M:get_completions(ctx, callback)
  -- blink ctx.cursor[2] is 0-based col in newer versions; ctx.line is the full line
  local line = ctx.line or ""
  local col = ctx.cursor and ctx.cursor[2] or #line
  local line_before = line:sub(1, col)
  local bufnr = vim.api.nvim_get_current_buf()

  get_items(bufnr, line_before, function(items)
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
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
  get_items(bufnr, line_before, function(items)
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

return M
