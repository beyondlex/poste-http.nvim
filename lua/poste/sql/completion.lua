--- SQL completion — orchestrator.
---
--- Provides completion for blink.cmp and nvim-cmp by:
--- 1. Calling the Rust CLI for context detection (full ### block)
--- 2. Falling back to Lua heuristic when Rust returns empty/incomplete
--- 3. Dispatching to the correct completion source (columns/tables/keywords)
local state = require("poste.state")
local data = require("poste.sql.completion_data")
local ctx = require("poste.sql.completion_ctx")

local M = {}

---------------------------------------------------------------------------
-- Rust context detection
---------------------------------------------------------------------------

--- Try to detect completion context using the Rust binary.
--- Sends the full ### block (before + after cursor) so extract_tables
--- can see FROM/JOIN clauses after the cursor position.
--- Returns a context dict or nil (fall back to Lua).
local function try_rust_context(bufnr, line_before, cursor_line)
  local ok_ft, ft = pcall(vim.api.nvim_buf_get_option, bufnr, "filetype")
  if not ok_ft or (ft ~= "poste_sql" and ft ~= "poste_sqlite") then return nil end

  local binary = data.find_binary()
  if not binary then return nil end

  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, total_lines, false)

  -- Find block boundaries
  local block_start = 1
  if cursor_line > 1 then
    for i = cursor_line - 1, 1, -1 do
      if all_lines[i] and all_lines[i]:match("^###") then
        block_start = i + 1
        break
      end
    end
  end

  local block_end = total_lines
  for i = cursor_line + 1, total_lines do
    if all_lines[i] and all_lines[i]:match("^###") then
      block_end = i - 1
      break
    end
  end

  if block_start > cursor_line or cursor_line > block_end then
    return nil
  end

  local sql_parts = {}
  for i = block_start, block_end do
    table.insert(sql_parts, all_lines[i])
  end
  local sql_text = table.concat(sql_parts, "\n")

  local before_parts = {}
  for i = block_start, cursor_line - 1 do
    table.insert(before_parts, all_lines[i])
  end
  table.insert(before_parts, line_before)
  local offset = #table.concat(before_parts, "\n")

  local cmd = string.format("%s context detect %d", vim.fn.shellescape(binary), offset)
  local output = vim.fn.system(cmd, sql_text)
  if vim.v.shell_error ~= 0 then return nil end

  local ok, parsed = pcall(vim.json.decode, output)
  if not ok or not parsed or type(parsed) ~= "table" then return nil end

  if vim.g.poste_sql_debug then
    state.log("INFO", string.format("Rust context: type=%s, prefix='%s', tables=%d, in_string=%s, in_comment=%s",
      tostring(parsed.ctx_type), tostring(parsed.prefix or ""),
      parsed.tables and #parsed.tables or 0,
      tostring(parsed.in_string), tostring(parsed.in_comment)))
  end

  return parsed
end

---------------------------------------------------------------------------
-- Main entry
---------------------------------------------------------------------------

local function get_items(bufnr, line_before, cursor_line, callback)
  local prefix = line_before:match("[%w_]*$") or ""

  -- Directive lines: handle immediately, bypass Rust path entirely
  if line_before:match("^%s*%-%-%s*@connection") then
    local cp = line_before:match("@connection$")
      or line_before:match("@connection%s+(%S*)$")
      or ""
    data.ensure_conn_names(function(names)
      callback(ctx.filter(ctx.make_items(names, 6, "connection: "), cp))
    end)
    return
  end

  if line_before:match("^%s*%-%-%s*@database") then
    local db_prefix = line_before:match("@database$")
      or line_before:match("@database%s+(%S*)$")
      or ""
    data.ensure_databases(function(names)
      if #names == 0 then
        data.ensure_conn_names(function(conn_names)
          local items = {}
          for _, name in ipairs(conn_names) do
            table.insert(items, {
              label = name,
              kind = 6,
              insertText = "",
              data = { directive_fallback = true, conn_name = name },
              documentation = "connection: " .. name,
            })
          end
          callback(ctx.filter(items, db_prefix))
        end)
      else
        callback(ctx.filter(ctx.make_items(names, 1, "database: "), db_prefix))
      end
    end)
    return
  end

  -- Partial directive: show @connection, @database while user types
  if line_before:match("^%s*%-%-%s*@%w*$") then
    local partial = line_before:match("@(%w*)$") or ""
    local low = partial:lower()
    local directives = { "@connection", "@database" }
    local items = {}
    for _, d in ipairs(directives) do
      local name = d:sub(2)
      if name:lower():sub(1, #low) == low then
        table.insert(items, { label = d, kind = 14, insertText = d, documentation = "directive" })
      end
    end
    callback(items)
    return
  end

  local ctx_type, ctx_data = ctx.detect_context(line_before)

  -- vim.g.poste_sql_legacy_completion controls completion mode:
  --   nil     → Rust + Lua fallback (default)
  --   true    → Pure Lua (Rust disabled)
  --   "rust"  → Pure Rust (no Lua fallback — for regression testing)
  local rust_ctx = nil
  local use_rust = not vim.g.poste_sql_legacy_completion or vim.g.poste_sql_legacy_completion == "rust"
  if use_rust then
    local rust_ok, rust_ctx_raw = pcall(try_rust_context, bufnr, line_before, cursor_line)
    if rust_ok and rust_ctx_raw then
      rust_ctx = rust_ctx_raw
      ctx_type, ctx_data = rust_ctx.ctx_type, rust_ctx.ctx_data
      if vim.g.poste_sql_legacy_completion ~= "rust" then
        if ctx_type == "keyword" and prefix ~= "" then
          local lua_type = ctx.detect_context(line_before)
          if lua_type ~= "keyword" then
            ctx_type, ctx_data = lua_type, nil
          end
        end
      end
    end
  end

  local rust_functions = (rust_ctx and rust_ctx.functions) or nil

  if vim.g.poste_sql_debug then
    state.log("INFO", string.format("DEBUG get_items: ctx=%s, prefix='%s', line='%s'",
      ctx_type, prefix, line_before))
  end

  if ctx_type == "connection" then
    local cp = line_before:match("@connection$")
      or line_before:match("@connection%s+(%S*)$")
      or ""
    data.ensure_conn_names(function(names)
      callback(ctx.filter(ctx.make_items(names, 6, "connection: "), cp))
    end)
    return
  end

  if ctx_type == "database" then
    local db_prefix
    if ctx_data == "directive" then
      db_prefix = line_before:match("@database$")
        or line_before:match("@database%s+(%S*)$")
        or ""
    else
      db_prefix = line_before:match("[Uu][Ss][Ee]%s+(%S*)$") or ""
    end
    data.ensure_databases(function(names)
      if ctx_data == "directive" and #names == 0 then
        data.ensure_conn_names(function(conn_names)
          local items = {}
          for _, name in ipairs(conn_names) do
            table.insert(items, {
              label = name,
              kind = 6,
              insertText = "",
              data = { directive_fallback = true, conn_name = name },
              documentation = "connection: " .. name,
            })
          end
          callback(ctx.filter(items, db_prefix))
        end)
      else
        callback(ctx.filter(ctx.make_items(names, 1, "database: "), db_prefix))
      end
    end)
    return
  end

  if ctx_type == "dot_column" then
    local col_prefix = line_before:match("[%w_]+%.([%w_]*)$") or ""
    local _, alias_map = ctx.get_tables_and_alias(bufnr, cursor_line or vim.fn.line("."), rust_ctx)
    local real_tbl = alias_map[ctx_data] or ctx_data
    data.ensure_columns(real_tbl, function()
      local key = data.conn_key()
      local cache = data.get_cache()
      local cols = cache[key] and cache[key].columns[real_tbl] or {}
      callback(ctx.filter(ctx.make_items(cols, 5, "col: "), col_prefix))
    end)
    return
  end

  if ctx_type == "table" then
    data.ensure_tables(function()
      local key = data.conn_key()
      local cache = data.get_cache()
      local tbls = cache[key] and cache[key].tables or {}
      local items = ctx.make_items(tbls, 7, "table: ")
      if #items == 0 then
        items = ctx.kw_items(prefix)
      end
      callback(ctx.filter(items, prefix))
    end)
    return
  end

  if ctx_type == "column" then
    local from_tbls, alias_map = ctx.get_tables_and_alias(bufnr, cursor_line or vim.fn.line("."), rust_ctx)
    local real_tbls, seen_real = {}, {}
    for _, t in ipairs(from_tbls) do
      local real = alias_map[t] or t
      if not seen_real[real] then seen_real[real] = true; table.insert(real_tbls, real) end
    end

    if vim.g.poste_sql_debug then
      state.log("INFO", string.format("DEBUG: column context, %d tables: %s",
        #real_tbls, vim.inspect(real_tbls)))
    end

    if #real_tbls == 0 then
      local items = ctx.kw_items(prefix)
      vim.list_extend(items, ctx.func_items(prefix, rust_functions))
      callback(items)
      return
    end
    local pending = #real_tbls
    local all = {}
    local seen_keys = {}
    local done = false
    local function flush()
      if done then return end
      done = true
      local items = ctx.filter(all, prefix)
      -- Show functions only when user typed a prefix to avoid clobbering
      if prefix ~= "" then
        local funcs = ctx.func_items(prefix, rust_functions)
        if vim.g.poste_sql_debug then
          state.log("INFO", string.format("DEBUG flush: prefix='%s', %d cols, %d funcs (rust_functions=%s)",
            prefix, #items, #funcs, tostring(rust_functions ~= nil)))
        end
        vim.list_extend(items, funcs)
      end
      callback(items)
    end
    for _, tbl in ipairs(real_tbls) do
      data.ensure_columns(tbl, function()
        local key = data.conn_key()
        local cache = data.get_cache()
        local cols = cache[key] and cache[key].columns[tbl] or {}

        for _, col in ipairs(cols) do
          local uniq = tbl .. "." .. col
          if not seen_keys[uniq] then
            seen_keys[uniq] = true
            table.insert(all, {
              label = col,
              kind = 5,
              insertText = col,
              filterText = col,
              sortText = "1" .. col,
              documentation = "col: " .. uniq
            })
          end
        end
        pending = pending - 1
        if pending <= 0 then flush() end
      end)
    end
    return
  end

  if ctx_type == "insert_column" then
    local tbl = ctx_data
    local prefix = line_before:match("([%w_]*)$") or ""
    local inside = line_before:match("%(([%w_,%s]*)$") or ""
    local seen = {}
    for col in inside:gmatch("([%w_]+)") do
      seen[col:lower()] = true
    end
    data.ensure_columns(tbl, function()
      local key = data.conn_key()
      local cache = data.get_cache()
      local all = cache[key] and cache[key].columns[tbl] or {}
      local result = {}
      if #all > 0 then
        local all_csv = table.concat(all, ", ")
        result[#result + 1] = {
          label = all_csv, kind = 8,
          insertText = all_csv,
          documentation = "Insert all columns",
        }
        local no_id = {}
        for _, c in ipairs(all) do
          if c:lower() ~= "id" then no_id[#no_id + 1] = c end
        end
        if #no_id > 0 and #no_id < #all then
          local no_id_csv = table.concat(no_id, ", ")
          result[#result + 1] = {
            label = no_id_csv, kind = 8,
            insertText = no_id_csv,
            documentation = "All columns except id",
          }
        end
      end
      for _, c in ipairs(all) do
        if not seen[c:lower()] and (prefix == "" or c:lower():sub(1, #prefix) == prefix) then
          result[#result + 1] = { label = c, kind = 5, insertText = c, documentation = "col: " .. tbl .. "." .. c }
        end
      end
      callback(result)
    end)
    return
  end

  if ctx_type == "datatype" then
    callback(ctx.filter(ctx.make_items(data.DATA_TYPES, 25, "type: "), prefix))
    return
  end

  -- Don't show keywords on directive lines (prevents @ trigger pollution)
  if line_before:match("^%s*%-%-%s*@") then
    callback({})
    return
  end

  if vim.g.poste_sql_legacy_completion == true then
    data.ensure_tables(function()
      local key = data.conn_key()
      local cache = data.get_cache()
      local tbls = cache[key] and cache[key].tables or {}
      local items = ctx.kw_items(prefix)
      vim.list_extend(items, ctx.func_items(prefix))
      for _, item in ipairs(ctx.filter(ctx.make_items(tbls, 7, "table: "), prefix)) do
        table.insert(items, item)
      end
      callback(items)
    end)
  else
    local items = ctx.kw_items(prefix)
    vim.list_extend(items, ctx.func_items(prefix, rust_functions))
    callback(items)
  end
end

---------------------------------------------------------------------------
-- blink.cmp interface
---------------------------------------------------------------------------

function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

function M:enabled()
  local ft = vim.bo.filetype
  return ft == "poste_sql" or ft == "poste_sqlite"
end

function M:get_trigger_characters()
  return { ".", " ", "@", "(", "," }
end

function M:get_keyword_length()
  return 0
end

local completion_gen = 0

function M:get_completions(ctx, callback)
  completion_gen = completion_gen + 1
  local my_gen = completion_gen

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line, cursor_col, line
  if ctx and ctx.cursor then
    cursor_line = ctx.cursor[1]
    cursor_col = ctx.cursor[2]
    line = ctx.line or ""
  else
    cursor_line = vim.fn.line(".")
    cursor_col = vim.fn.col(".")
    line = vim.api.nvim_get_current_line()
  end
  local line_before = line:sub(1, cursor_col)

  if vim.g.poste_sql_debug then
    state.log("INFO", string.format("SQL completion triggered: line_before='%s'", line_before))
  end

  get_items(bufnr, line_before, cursor_line, function(items)
    if my_gen ~= completion_gen then return end
    local seen = {}
    local deduped = {}
    for _, item in ipairs(items) do
      if not seen[item.label] then
        seen[item.label] = true
        table.insert(deduped, item)
      end
    end
    if vim.g.poste_sql_debug then
      state.log("INFO", string.format("SQL completion: %d items (deduped from %d)", #deduped, #items))
    end
    callback({ is_incomplete_forward = true, is_incomplete_backward = false, items = deduped })
  end)
end

function M:resolve(item, callback) callback(item) end
function M:execute(ctx, item, callback, default_impl)
  if item.data and item.data.directive_fallback then
    vim.schedule(function()
      local buf = vim.api.nvim_get_current_buf()
      local lnum = vim.fn.line(".")
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local indent = (lines[lnum] or ""):match("^(%s*)") or ""
      table.insert(lines, lnum, indent .. "-- @connection " .. item.data.conn_name)
      lines[lnum + 1] = indent .. "-- @database "
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_win_set_cursor(0, { lnum + 1, #(indent .. "-- @database ") })
      vim.cmd("startinsert!")
      vim.fn.feedkeys(vim.api.nvim_replace_termcodes(" ", true, false, true), "n")
    end)
    callback()
    return
  end
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
function M.source:get_trigger_characters() return { ".", " ", "@", "(", "," } end
function M.source:execute(entry, callback)
  local item = entry:get_completion_item()
  if item.data and item.data.directive_fallback then
    vim.schedule(function()
      local buf = vim.api.nvim_get_current_buf()
      local lnum = vim.fn.line(".")
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local indent = (lines[lnum] or ""):match("^(%s*)") or ""
      table.insert(lines, lnum, indent .. "-- @connection " .. item.data.conn_name)
      lines[lnum + 1] = indent .. "-- @database "
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_win_set_cursor(0, { lnum + 1, #(indent .. "-- @database ") })
      vim.cmd("startinsert!")
      vim.fn.feedkeys(vim.api.nvim_replace_termcodes(" ", true, false, true), "n")
    end)
    callback()
    return
  end
  callback()
end
function M.source:complete(params, callback)
  local line_before = params.context.cursor_before_line or ""
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.fn.line(".")
  get_items(bufnr, line_before, cursor_line, function(items)
    local seen = {}
    local deduped = {}
    for _, item in ipairs(items) do
      if not seen[item.label] then
        seen[item.label] = true
        table.insert(deduped, item)
      end
    end
    callback({ items = deduped, isIncomplete = false })
  end)
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

local did_register_cmp = false

function M.register()
  if did_register_cmp then return end
  did_register_cmp = true
  local ok, cmp = pcall(require, "cmp")
  if not ok then
    did_register_cmp = false
    vim.api.nvim_create_autocmd("User", {
      pattern = "CmpReady",
      once = true,
      callback = function()
        M.register()
      end,
    })
    return
  end
  cmp.register_source("poste_sql", M.source.new())
  cmp.setup.filetype({ "poste_sql", "poste_sqlite" }, {
    sources = cmp.config.sources({ { name = "poste_sql" } }),
  })
end

---------------------------------------------------------------------------
-- Re-exports for test access and external callers
---------------------------------------------------------------------------

--- Cache helpers are on the data module; re-export for tests that
--- access them via `require("poste.sql.completion").cache_tables()`.
M.cache_tables = data.cache_tables
M.cache_columns = data.cache_columns
M.resolve_current_context = data.resolve_current_context

---------------------------------------------------------------------------
-- Toggle: legacy-only mode for regression comparison
---------------------------------------------------------------------------

function M.toggle_legacy()
  local current = vim.g.poste_sql_legacy_completion
  if current == nil then
    vim.g.poste_sql_legacy_completion = true
    vim.notify("Poste SQL completion: Legacy Lua-only mode (Rust disabled)", vim.log.levels.WARN)
  elseif current == true then
    vim.g.poste_sql_legacy_completion = "rust"
    vim.notify("Poste SQL completion: Rust strict mode (no Lua fallback)", vim.log.levels.WARN)
  else
    vim.g.poste_sql_legacy_completion = nil
    vim.notify("Poste SQL completion: Rust + Lua fallback (default)", vim.log.levels.INFO)
  end
end

---------------------------------------------------------------------------
-- Test interface
---------------------------------------------------------------------------

M._test = {
  detect_context = ctx.detect_context,
  resolve_current_context = data.resolve_current_context,
  conn_key = data.conn_key,
  get_items = get_items,
  extract_from_tables = ctx.extract_from_tables,
  try_rust_context = try_rust_context,
  get_tables_and_alias = ctx.get_tables_and_alias,
}

return M
