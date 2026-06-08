--- SQL completion — Lua context detection (fallback path).
--- Provides table extraction, alias resolution, and heuristic context
--- detection for when the Rust binary is unavailable or returns Keyword
--- on a partial identifier.
local data = require("poste.sql.completion_data")

local M = {}

---------------------------------------------------------------------------
-- Parse FROM/JOIN tables from current SQL block
---------------------------------------------------------------------------

local function add_to_table(seen, tbls, alias_map, tbl, alias)
  if not seen[tbl] then seen[tbl] = true; table.insert(tbls, tbl) end
  alias_map[tbl] = tbl
  if alias and alias ~= tbl then alias_map[alias] = tbl end
end

function M.extract_from_tables(bufnr, cursor_lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, cursor_lnum + 1, false)
  local block_start = 1
  for i = #lines, 1, -1 do
    if lines[i]:match("^###") then block_start = i; break end
  end
  local stripped = {}
  for i = block_start, #lines do
    local l = (lines[i] or ""):gsub("%-%-.*", " ")
    stripped[#stripped + 1] = l
  end
  local text = table.concat(stripped, " ")

  local alias_map = {}
  local seen, tbls = {}, {}

  for _, pat in ipairs({
    "[Ff][Rr][Oo][Mm]%s+([%w_]+)%s+([%w_]+)",
    "[Jj][Oo][Ii][Nn]%s+([%w_]+)%s+([%w_]+)",
    "[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_]+)%s+([%w_]+)",
    "[Ii][Nn][Tt][Oo]%s+([%w_]+)%s+([%w_]+)",
  }) do
    for tbl, alias in text:gmatch(pat) do
      local kw = { on=true, set=true, where=true, left=true, right=true,
                   inner=true, outer=true, cross=true, full=true, join=true,
                   ["as"]=true, using=true }
      add_to_table(seen, tbls, alias_map, tbl, kw[alias:lower()] and nil or alias)
    end
  end
  for _, pat in ipairs({
    "[Ff][Rr][Oo][Mm]%s+([%w_]+)",
    "[Jj][Oo][Ii][Nn]%s+([%w_]+)",
    "[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_]+)",
    "[Ii][Nn][Tt][Oo]%s+([%w_]+)",
  }) do
    for t in text:gmatch(pat) do
      if not seen[t] then seen[t] = true; table.insert(tbls, t) end
      alias_map[t] = alias_map[t] or t
    end
  end

  return tbls, alias_map
end

--- Get extracted tables and alias map, preferring Rust context when available.
--- Returns: (from_tbls, alias_map, schema_map)
---   from_tbls: list of table names
---   alias_map: { alias_or_name → table_name }
---   schema_map: { table_name → schema }
function M.get_tables_and_alias(bufnr, cursor_line, rust_ctx)
  if rust_ctx and rust_ctx.tables and #rust_ctx.tables > 0 then
    local from_tbls, alias_map, schema_map = {}, {}, {}
    for _, t in ipairs(rust_ctx.tables) do
      if t.name and t.name ~= "" then
        table.insert(from_tbls, t.name)
        alias_map[t.name] = t.name
        if t.alias then alias_map[t.alias] = t.name end
        if t.schema then schema_map[t.name] = t.schema end
      end
    end
    return from_tbls, alias_map, schema_map
  end
  local tbls, alias_map = M.extract_from_tables(bufnr, cursor_line)
  return tbls, alias_map, {}
end

---------------------------------------------------------------------------
-- Context detection (Lua heuristic)
---------------------------------------------------------------------------

--- Returns: ctx_type, ctx_data
function M.detect_context(line_before)
  if line_before:match("@connection%s") or line_before:match("^%s*%-%-%s*@connection$") then
    return "connection", nil
  end

  if line_before:match("@database%s") or line_before:match("^%s*%-%-%s*@database$") then
    return "database", "directive"
  end

  if line_before:match("^%s*[Uu][Ss][Ee]%s+%S*$") then
    return "database", nil
  end

  local insert_tbl = line_before:match(
    "^%s*[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+([%w_]+)%s*%([%w_,%s]*$")
  if insert_tbl then
    return "insert_column", insert_tbl
  end

  local dot_tbl = line_before:match("([%w_]+)%.[%w_]*$")
  if dot_tbl then
    return "dot_column", dot_tbl
  end

  local words = {}
  for word in line_before:gmatch("[%w_]+") do
    table.insert(words, word)
  end

  if line_before:match(",%s*$") or line_before:match(",%s*[%w_]*$") then
    for i = #words, 1, -1 do
      local w = words[i]:lower()
      if data.COLUMN_CTX[w] then return "column", nil end
      if data.TABLE_CTX[w] then return "table", nil end
    end
    return "column", nil
  end

  local check_word_idx = #words
  if line_before:match("[%w_]+$") then
    check_word_idx = #words - 1
  end

  if check_word_idx >= 1 then
    local keyword = words[check_word_idx]:lower()
    if data.TABLE_CTX[keyword] then return "table", nil end
    if data.COLUMN_CTX[keyword] then return "column", nil end
  end

  return "keyword", nil
end

---------------------------------------------------------------------------
-- Item helpers
---------------------------------------------------------------------------

function M.make_items(names, kind, doc_prefix)
  local items = {}
  for _, n in ipairs(names or {}) do
    table.insert(items, { label = n, kind = kind, insertText = n,
      documentation = doc_prefix and (doc_prefix .. n) or n })
  end
  return items
end

function M.filter(items, prefix)
  if prefix == "" then return items end
  local low = prefix:lower()
  return vim.tbl_filter(function(i)
    return i.label:lower():sub(1, #low) == low
  end, items)
end

function M.func_items(prefix, funcs)
  local low = prefix:lower()
  local items = {}
  local list = funcs or data.SQL_FUNCTIONS
  for _, fn in ipairs(list) do
    if fn:lower():sub(1, #low) == low then
      table.insert(items, {
        label = fn,
        kind = 10,
        insertText = fn,
        sortText = "2" .. fn,
        documentation = "function"
      })
    end
  end
  return items
end

function M.kw_items(prefix)
  local low = prefix:lower()
  local items = {}
  for _, kw in ipairs(data.KEYWORDS) do
    if kw:lower():sub(1, #low) == low then
      table.insert(items, { label = kw, kind = 14, insertText = kw, sortText = "0" .. kw, documentation = "keyword" })
    end
  end
  for _, t in ipairs(data.DATA_TYPES) do
    if t:lower():sub(1, #low) == low then
      table.insert(items, { label = t, kind = 25, insertText = t, sortText = "0" .. t, documentation = "type" })
    end
  end
  return items
end

return M
