--- SQL introspection utilities — float window display, column info, and DDL.
---
--- Extracted from sql/init.lua to reduce module size.
--- Provides show_table_ddl() and supporting functions.
-- luacheck: ignore 411

local cli = require("poste.cli")
local state = require("poste.state")
local util = require("poste.util")

local M = {}

---------------------------------------------------------------------------
-- Float window
---------------------------------------------------------------------------

--- Show or open a float window with text content.
--- @param lines string[]
--- @param title string
--- @param ft string|nil  filetype (default "sql")
function M.show_float(lines, title, ft)
  if not lines or #lines == 0 then
    vim.notify("No content to display", vim.log.levels.WARN, { title = "Poste SQL" })
    return
  end

  local max_width = math.min(math.floor(vim.o.columns * 0.7), 100)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 4, max_width)

  local max_height = math.floor(vim.o.lines * 0.5)
  local height = math.max(3, math.min(#lines + 2, max_height))

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].filetype = ft or "sql"
  vim.bo[float_buf].modifiable = false

  local win_opts = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height, style = "minimal",
    border = "rounded", title = title, title_pos = "left",
  }
  local ok, win = pcall(vim.api.nvim_open_win, float_buf, true, win_opts)
  if not ok then
    win_opts.title = nil; win_opts.title_pos = nil
    win = vim.api.nvim_open_win(float_buf, true, win_opts)
  end

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].scrolloff = 1
  vim.wo[win].cursorline = true

  local sopts = { buffer = float_buf, noremap = true, silent = true }
  vim.keymap.set("n", "j", "j", sopts)
  vim.keymap.set("n", "k", "k", sopts)
  vim.keymap.set("n", "d", "<C-d>", sopts)
  vim.keymap.set("n", "u", "<C-u>", sopts)
  vim.keymap.set("n", "g", "gg", sopts)
  vim.keymap.set("n", "G", "G", sopts)
  local close_fn = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  local ck = state.get_keymap("sql_introspect", "close", "q")
  if ck then vim.keymap.set("n", ck, close_fn, sopts) end
  ck = state.get_keymap("sql_introspect", "close_alt", "<Esc>")
  if ck then vim.keymap.set("n", ck, close_fn, sopts) end
end

---------------------------------------------------------------------------
-- Column info
---------------------------------------------------------------------------

--- Show column info in a float window.
--- @param binary string
--- @param conn string
--- @param db string|nil
--- @param file string
--- @param table_name string Parent table
--- @param col_name string Column name under cursor
local function show_column_info(binary, conn, db, file, table_name, col_name)
  -- Strip backtick/quote quoting from names (from RENAME/CHANGE COLUMN SQL)
  table_name = table_name:gsub("^`", ""):gsub("`$", ""):gsub('^"', ''):gsub('"$', '')
  col_name = col_name:gsub("^`", ""):gsub("`$", ""):gsub('^"', ''):gsub('"$', '')
  local cmd = string.format("%s introspect %s --type columns --table %s --env %s",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(conn),
    vim.fn.shellescape(table_name),
    vim.fn.shellescape(state.current_env)
  )
  if file and file ~= "" then
    cmd = cmd .. " --path " .. vim.fn.shellescape(vim.fn.fnamemodify(file, ":h"))
  end
  if db and db ~= vim.NIL and db ~= "" then
    cmd = cmd .. " --database " .. vim.fn.shellescape(db)
  end

  state.log("INFO", "Column info cmd: " .. cmd)

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      data = util.ensure_job_data(data)
      if #data == 0 then return end

      local output = table.concat(data, "\n")
      vim.schedule(function()
        local ok, parsed = pcall(vim.json.decode, output)
        if not ok or type(parsed) ~= "table" then
          vim.notify("Failed to parse introspection response", vim.log.levels.ERROR, { title = "Poste SQL" })
          return
        end

        local items = parsed.items
        if not items or #items == 0 then
          vim.notify("No columns found for table '" .. table_name .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
          return
        end

        local col = nil
        for _, c in ipairs(items) do
          if c.name == col_name then col = c; break end
        end
        if not col then
          vim.notify("Column '" .. col_name .. "' not found in table '" .. table_name .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
          return
        end

        local lines = {
          "  Table:    " .. table_name,
          "  Type:     " .. tostring(col.type or ""),
          "  Nullable: " .. tostring(col.nullable == true and "YES" or (col.nullable == false and "NO" or "?")),
          "  Default:  " .. (col.default ~= vim.NIL and col.default or "(null)"),
        }
        if col.extra and col.extra ~= "" and col.extra ~= vim.NIL then
          table.insert(lines, "  Extra:    " .. tostring(col.extra))
        end
        if col.max_length then
          table.insert(lines, "  Max Len:  " .. tostring(col.max_length))
        end
        if col.comment and col.comment ~= vim.NIL then
          table.insert(lines, "  Comment:  '" .. tostring(col.comment) .. "'")
        end

        M.show_float(lines, "Column: " .. col_name, "sql")
      end)
    end,
    on_stderr = function(_, data)
      data = util.ensure_job_data(data)
      if #data == 0 then return end
      for _, l in ipairs(data) do
        state.log("ERROR", "Column info stderr: " .. l)
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("Column introspection exited with code " .. code, vim.log.levels.ERROR, { title = "Poste SQL" })
        end)
      end
    end,
  })
end

---------------------------------------------------------------------------
-- Table DDL
---------------------------------------------------------------------------

--- List all tables in a database and show them in a float window.
--- @param binary string
--- @param conn string
--- @param db_name string
--- @param file string
local function list_tables_in_db(binary, conn, db_name, file)
  local search_dir = vim.fn.fnamemodify(file, ":h")
  local cmd = string.format("%s introspect %s --type tables --database %s --env %s --path %s",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(conn),
    vim.fn.shellescape(db_name),
    vim.fn.shellescape(state.current_env),
    vim.fn.shellescape(search_dir))
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      data = util.ensure_job_data(data)
      if #data == 0 then return end
      local output = table.concat(data, "\n")
      vim.schedule(function()
        local ok, parsed = pcall(vim.json.decode, output)
        if not ok or type(parsed) ~= "table" then
          vim.notify("Failed to list tables", vim.log.levels.ERROR, { title = "Poste SQL" })
          return
        end
        local items = parsed.items
        if not items or #items == 0 then
          vim.notify("No tables found in database '" .. db_name .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
          return
        end
        local lines = {}
        for _, t in ipairs(items) do
          table.insert(lines, "  " .. t.name .. "  (" .. t.type .. ")")
        end
        M.show_float(lines, "Tables: " .. db_name)
      end)
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then state.log("ERROR", "introspect stderr: " .. l) end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("Table listing failed with exit code " .. code, vim.log.levels.ERROR, { title = "Poste SQL" })
        end)
      end
    end,
  })
end

--- Show DDL for the table under the cursor in a floating window.
function M.show_table_ddl()
  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found.", vim.log.levels.ERROR, { title = "Poste SQL" })
    return
  end

  -- Check if cursor is on a -- @database <name> line → list tables
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""
  local db_match = line_text:match("^%s*--%s*@database%s+(.+)")
  if db_match then
    local db_name = vim.trim(db_match)
    local ctx = require("poste.sql.context").resolve_full_context(buf, line_num)
    local conn = ctx.connection
    if not conn then
      vim.notify("No connection context for database '" .. db_name .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
      return
    end
    local file = vim.api.nvim_buf_get_name(buf)
    if file == "" then file = vim.fn.getcwd() .. "/query.sql" end
    local search_dir = vim.fn.fnamemodify(file, ":h")
    local cmd = { "introspect", conn, "--type", "tables", "--database", db_name, "--env", state.current_env, "--path", search_dir }
    cli.run_async(cmd, {
      on_stdout = function(data)
        data = util.ensure_job_data(data)
        if #data == 0 then return end
        local output = table.concat(data, "\n")
        vim.schedule(function()
          local ok, parsed = pcall(vim.json.decode, output)
          if not ok or type(parsed) ~= "table" then
            vim.notify("Failed to list tables", vim.log.levels.ERROR, { title = "Poste SQL" })
            return
          end
          local items = parsed.items
          if not items or #items == 0 then
            vim.notify("No tables found in database '" .. db_name .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
            return
          end
          local lines = {}
          for _, t in ipairs(items) do
            table.insert(lines, "  " .. t.name .. "  (" .. t.type .. ")")
          end
          M.show_float(lines, "Tables: " .. db_name)
        end)
      end,
      on_stderr = function(data)
        if not data then return end
        for _, l in ipairs(data) do
          if l ~= "" then state.log("ERROR", "introspect stderr: " .. l) end
        end
      end,
      on_exit = function(code)
        if code ~= 0 then
          vim.schedule(function()
            vim.notify("Table listing failed with exit code " .. code, vim.log.levels.ERROR, { title = "Poste SQL" })
          end)
        end
      end,
    })
    return
  end

  -- Check if cursor is on a -- @connection <name> line → show config
  local conn_match = line_text:match("^%s*--%s*@connection%s+(.+)")
  if conn_match then
    local conn_name = vim.trim(conn_match)
    local config = require("poste.sql.connections").get_connection_config(conn_name)
    if not config then
      vim.notify("Connection '" .. conn_name .. "' not found in connections.json", vim.log.levels.WARN, { title = "Poste SQL" })
      return
    end
    local lines = {}
    local label_width = 10
    local fields = {
      { "Dialect", config.dialect },
      { "Host", config.host },
      { "Port", config.port },
      { "Database", config.database },
      { "User", config.user },
      { "Socket", config.path },
    }
    for _, f in ipairs(fields) do
      if f[2] and f[2] ~= "" then
        table.insert(lines, string.format("  %s%s  %s", string.rep(" ", label_width - #f[1]), f[1], f[2]))
      end
    end
    M.show_float(lines, "Connection: " .. conn_name)
    return
  end

  local cword = vim.fn.expand("<cword>")
  if not cword or cword == "" then
    vim.notify("No word under cursor", vim.log.levels.WARN, { title = "Poste SQL" })
    return
  end
  local keywords = {}
  local kw_list = { "select","from","where","join","on",
                     "and","or","set","insert","into",
                     "values","update","delete","create","modify",
                     "table","index","drop","alter","add",
                     "column","primary","key","foreign",
                     "references","not","null","default",
                     "unique","check","constraint","as",
                     "left","right","inner","outer","cross",
                     "full","order","by","group","having",
                     "limit","offset","union","all","distinct",
                     "exists","in","like","between","case",
                     "when","then","else","end","count",
                     "sum","avg","min","max","true","false" }
  for _, kw in ipairs(kw_list) do keywords[kw] = true end
  if keywords[cword:lower()] then
    vim.notify("'" .. cword .. "' is a SQL keyword", vim.log.levels.INFO, { title = "Poste SQL" })
    return
  end

  local sql_context = require("poste.sql.context")
  local buf = vim.api.nvim_get_current_buf()
  local ctx = sql_context.resolve_full_context(buf)
  local conn = ctx.connection
  if not conn or conn == "" then
    vim.notify("No SQL connection context. Add -- @connection <name> to the file header.", vim.log.levels.ERROR, { title = "Poste SQL" })
    return
  end

  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then
    file = vim.fn.getcwd() .. "/query.sql"
  end
  local db = ctx.database

  -- Try to detect if cursor is on a column name via Rust context detection
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col = cursor[2]
  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local line_text = all_lines[line_num] or ""
  local line_len = #line_text

  local end_col = col
  while end_col < line_len do
    local ch = line_text:sub(end_col + 1, end_col + 1)
    if ch:match("[%w_]") then end_col = end_col + 1 else break end
  end

  -- Check for .column suffix (alias.column → column part)
  local after_dot_col = nil
  local nxt = line_text:sub(end_col + 1, end_col + 1)
  if nxt == "." then
    local cm = line_text:match("^([%w_]+)", end_col + 2)
    if cm then after_dot_col = cm end
  end

  if after_dot_col then
    -- alias.column pattern: resolve alias via context detection
    local block_start = 1
    if line_num > 1 then
      for i = line_num - 1, 1, -1 do
        if all_lines[i] and all_lines[i]:match("^###") then block_start = i + 1; break end
      end
    end
    local block_end = #all_lines
    for i = line_num + 1, #all_lines do
      if all_lines[i] and all_lines[i]:match("^###") then block_end = i - 1; break end
    end
    if block_start <= line_num and line_num <= block_end then
      local before_parts = {}
      for i = block_start, line_num - 1 do
        table.insert(before_parts, all_lines[i] or "")
      end
      -- Include alias.column for context: extend end_col past .column
      local xtra = end_col + 1 + #after_dot_col
      table.insert(before_parts, line_text:sub(1, xtra))
      local offset = #table.concat(before_parts, "\n")
      if offset > 0 then
        offset = offset - 1
      end
      local block_parts = {}
      for i = block_start, block_end do table.insert(block_parts, all_lines[i] or "") end
      local sql_text = table.concat(block_parts, "\n")
      local dial = ""
      local cc = require("poste.sql.connections").get_connection_config(conn)
      if cc and cc.dialect then dial = " --dialect " .. cc.dialect end
      local cmd = string.format("%s context detect %d%s", vim.fn.shellescape(binary), offset, dial)
      local out = vim.fn.system(cmd, sql_text)
      if vim.v.shell_error == 0 and out and out ~= "" then
        local ok, parsed = pcall(vim.json.decode, out)
        if ok and parsed then
          util.clean_nil(parsed)
          local pt = nil
          local prefix = parsed.ctx_data or cword
          if parsed.tables then
            for _, t in ipairs(parsed.tables) do
              if t.alias and t.alias:lower() == prefix:lower() then pt = t.name; break end
            end
          end
          if pt then
            show_column_info(binary, conn, db, file, pt, after_dot_col)
            return
          end
        end
      end
    end
  end

  -- Check if cword is a column name (not a table) via context detection
  local block_start = 1
  if line_num > 1 then
    for i = line_num - 1, 1, -1 do
      if all_lines[i] and all_lines[i]:match("^###") then block_start = i + 1; break end
    end
  end
  local block_end = #all_lines
  for i = line_num + 1, #all_lines do
    if all_lines[i] and all_lines[i]:match("^###") then block_end = i - 1; break end
  end

  if block_start <= line_num and line_num <= block_end then
    local before_parts = {}
    for i = block_start, line_num - 1 do
      table.insert(before_parts, all_lines[i] or "")
    end
    table.insert(before_parts, line_text:sub(1, end_col))
    local offset = #table.concat(before_parts, "\n")
    -- Adjust offset to point to the last character of the word, not the
    -- character after it (e.g., for "authors;" the offset should be on
    -- "s" not on ";"). This ensures the Rust binary detects the correct
    -- context type (e.g., schema_table for schema-qualified table refs).
    if offset > 0 then
      offset = offset - 1
    end

    local block_parts = {}
    for i = block_start, block_end do table.insert(block_parts, all_lines[i] or "") end
    local sql_text = table.concat(block_parts, "\n")

    local dial = ""
    local cc = require("poste.sql.connections").get_connection_config(conn)
    if cc and cc.dialect then dial = " --dialect " .. cc.dialect end

    local cmd = string.format("%s context detect %d%s",
      vim.fn.shellescape(binary), offset, dial)
    local out = vim.fn.system(cmd, sql_text)
    if vim.v.shell_error == 0 and out and out ~= "" then
      local ok, parsed = pcall(vim.json.decode, out)
      if ok and parsed then
        util.clean_nil(parsed)

        local ct = parsed.ctx_type
        local tables = parsed.tables
        local function strip_q(s)
          if not s then return "" end
          return s:gsub("^`", ""):gsub("`$", ""):gsub('^"', ''):gsub('"$', '')
        end

        -- Resolve column: check if cword is a known column (not table name)
        local is_column = false
        local parent_table = nil
        if ct == "dot_column" and parsed.ctx_data then
          -- alias.column: resolve alias
          local prefix = parsed.ctx_data
          if tables then
            for _, t in ipairs(tables) do
              if t.alias and t.alias:lower() == prefix:lower() then
                parent_table = strip_q(t.name); break
              end
            end
          end
          is_column = parent_table ~= nil
        elseif ct == "schema_table" and parsed.ctx_data then
          -- Schema-qualified table reference: schema.table (e.g., blog.authors)
          -- ctx_data is the schema name (e.g., "blog").
          -- The cursor is on the table name (e.g., "authors").
          local schema = parsed.ctx_data or ""
          if schema ~= "" then
            db = schema
          end
          -- cword is already the table name; fall through to DDL below
        elseif ct == "table" and tables and #tables > 0 then
          -- Cursor is on a table reference: could be a table name, alias,
          -- or schema/database qualifier (e.g., "blog" in "blog.authors").
          local schema_match = nil
          local alias_match = nil
          for _, t in ipairs(tables) do
            local tn = strip_q(t.name):lower()
            local ta = strip_q(t.alias):lower()
            local ts = t.schema and t.schema:lower() or ""
            if tn == cword:lower() then
              alias_match = t
              if ts ~= "" then
                db = ts
              end
              break
            end
            if ta == cword:lower() then alias_match = t; break end
            if ts == cword:lower() then schema_match = t end
          end
          if schema_match then
            -- cword is a schema/database qualifier: list all tables in this database
            db = cword
            list_tables_in_db(binary, conn, db, file)
            return
          elseif alias_match then
            cword = alias_match.name
          end
          -- fall through to DDL below
        elseif (ct == "column" or ct == "keyword") and tables and #tables > 0 then
          -- Check if cword is NOT a table name → it's a column
          local is_table = false
          local schema_match = nil
          for _, t in ipairs(tables) do
            local tn = strip_q(t.name):lower()
            local ta = strip_q(t.alias):lower()
            local ts = t.schema and t.schema:lower() or ""
            if tn == cword:lower() or ta == cword:lower() then is_table = true; break end
            if ts == cword:lower() then schema_match = t end
          end
          if schema_match then
            -- cword is a schema/database qualifier (e.g., "blog" in "blog.authors")
            db = cword
            cword = schema_match.name
          elseif not is_table then
            -- Not a table name: use first table as parent, cword is column
            parent_table = strip_q(tables[1].name or tables[1].alias)
            is_column = parent_table ~= nil
          end
        end

        if is_column and parent_table and parent_table:lower() ~= cword:lower() then
          show_column_info(binary, conn, db, file, parent_table, cword)
          return
        end
      end
    end
  end

  -- Fallback: show DDL (table mode)
  local cmd = string.format("%s introspect %s --type ddl --table %s --env %s",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(conn),
    vim.fn.shellescape(cword),
    vim.fn.shellescape(state.current_env)
  )
  if file and file ~= "" then
    cmd = cmd .. " --path " .. vim.fn.shellescape(vim.fn.fnamemodify(file, ":h"))
  end
  if db and db ~= vim.NIL and db ~= "" then
    cmd = cmd .. " --database " .. vim.fn.shellescape(db)
  end

  state.log("INFO", "DDL cmd: " .. cmd)

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      data = util.ensure_job_data(data)
      if #data == 0 then return end

      local output = table.concat(data, "\n")
      vim.schedule(function()
        local ok, parsed = pcall(vim.json.decode, output)
        if not ok or type(parsed) ~= "table" then
          vim.notify("Failed to parse DDL response", vim.log.levels.ERROR, { title = "Poste SQL" })
          return
        end

        local items = parsed.items
        if not items or #items == 0 then
          vim.notify("No DDL found for table '" .. cword .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
          return
        end

        local ddl_text = items[1].ddl
        if not ddl_text or ddl_text == "" then
          vim.notify("No DDL found for table '" .. cword .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
          return
        end

        local lines = vim.split(ddl_text, "\n", { plain = true })
        M.show_float(lines, "DDL: " .. cword, "sql")
      end)
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then state.log("ERROR", "DDL stderr: " .. l) end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("DDL introspection exited with code " .. code, vim.log.levels.ERROR, { title = "Poste SQL" })
        end)
      end
    end,
  })
end

return M