--- Operations dispatched from the DB Browser context menu.
--- Each function: op(node, context) → performs the action.
local state = require("poste.state")
local tree = require("poste.sql.db_browser.tree")
local async = require("poste.sql.db_browser.async")
local icons = require("poste.sql.db_browser.icons")
local forms = require("poste.sql.db_browser.forms")

local HEADER_LINES = icons.HEADER_LINES
local M = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function safe_str(v)
  if v == nil or v == vim.NULL or type(v) == "userdata" then return nil end
  return tostring(v)
end

local function get_dialect(node, context)
  if node.meta and node.meta.dialect then return node.meta.dialect end
  local conn_name = node.meta and node.meta.connection or state.sql.db_browser.connection
  for _, root in ipairs(context.root_nodes) do
    if root.name == conn_name then
      return root.meta and root.meta.dialect or "postgres"
    end
  end
  return "postgres"
end

local function get_connection_name(node, context)
  if node.node_type == "connection" then return node.name end
  return node.meta and node.meta.connection or state.sql.db_browser.connection
end

local function get_search_dir(context)
  if context.source_buf and vim.api.nvim_buf_is_valid(context.source_buf) then
    local buf_name = vim.api.nvim_buf_get_name(context.source_buf)
    if buf_name ~= "" then return vim.fn.fnamemodify(buf_name, ":p:h") end
  end
  return vim.fn.getcwd()
end

local function find_table_node(context, start_idx)
  for i = start_idx, 1, -1 do
    local n = context.line_to_node[i]
    if n and n.node_type == "table" then return n end
    if n and (n.node_type == "database" or n.node_type == "schema" or n.node_type == "connection") then break end
  end
  return nil
end

local function insert_into_source(context, lines, cursor_offset, cursor_col)
  if not context.source_buf or not vim.api.nvim_buf_is_valid(context.source_buf) then
    vim.notify("No source SQL buffer found", vim.log.levels.WARN)
    return false
  end
  local line_count = vim.api.nvim_buf_line_count(context.source_buf)
  vim.api.nvim_buf_set_lines(context.source_buf, line_count, line_count, false, lines)
  local target_win = vim.fn.bufwinid(context.source_buf)
  if target_win and target_win ~= -1 then
    vim.api.nvim_set_current_win(target_win)
    if cursor_offset then
      vim.api.nvim_win_set_cursor(target_win, { line_count + cursor_offset, cursor_col or 0 })
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Operations
---------------------------------------------------------------------------

--- SELECT * LIMIT 100 for table/view; insert at end of source buffer.
function M.select_star(node, context)
  local table_node = node
  if node.node_type == "column" then
    table_node = find_table_node(context, context.line_to_node[node] and 0 or 0)
  end

  -- Fallback: walk up from current line to find table
  if not table_node or table_node.node_type ~= "table" then
    local buf_line = vim.fn.line(".")
    local idx = buf_line - HEADER_LINES
    table_node = find_table_node(context, idx)
  end

  if not table_node or (table_node.node_type ~= "table" and table_node.node_type ~= "view") then
    vim.notify("Move cursor to a table or view node", vim.log.levels.INFO)
    return
  end

  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)
  local schema_prefix = ""
  if table_node.meta and table_node.meta.schema and dialect == "postgres" then
    schema_prefix = table_node.meta.schema .. "."
  end

  local query_lines = { "" }
  local cursor_offset = 2  -- line 1: empty, line 2: SELECT
  if conn then
    table.insert(query_lines, "-- @connection " .. conn)
    cursor_offset = cursor_offset + 1
  end
  if table_node.meta and table_node.meta.database then
    table.insert(query_lines, "-- @database " .. table_node.meta.database)
    cursor_offset = cursor_offset + 1
  end
  table.insert(query_lines, "SELECT * FROM " .. schema_prefix .. table_node.name .. " LIMIT 100;")
  table.insert(query_lines, "")

  if insert_into_source(context, query_lines, cursor_offset) then
    vim.notify("Generated SELECT for: " .. table_node.name, vim.log.levels.INFO)
  end
end

--- Show DDL for table/view in a float window.
function M.show_ddl(node, context)
  local table_node = node
  if node.node_type ~= "table" and node.node_type ~= "view" then
    -- For index/key nodes, walk up to table
    table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  end

  if not table_node or (table_node.node_type ~= "table" and table_node.node_type ~= "view") then
    vim.notify("DDL is only available for tables and views", vim.log.levels.INFO)
    return
  end

  local conn = get_connection_name(table_node, context)
  local search_dir = get_search_dir(context)
  local schema = table_node.meta and table_node.meta.schema
  local database = table_node.meta and table_node.meta.database

  local cmd = { "introspect", conn, "--type", "ddl", "--table", table_node.name, "--path", search_dir, "--env", state.current_env }
  if schema then
    table.insert(cmd, "--schema"); table.insert(cmd, schema)
  end
  if database then
    table.insert(cmd, "--database"); table.insert(cmd, database)
  end

  state.log("INFO", "DB Browser DDL: " .. table.concat(cmd, " "))

  cli.run_async(cmd, {
    on_stdout = function(data)
      if not data then return end
      while #data > 0 and data[#data] == "" do data[#data] = nil end
      if #data == 0 then return end
      local output = table.concat(data, "\n")
      local ok, parsed = pcall(vim.json.decode, output)
      if not ok or type(parsed) ~= "table" then
        vim.schedule(function()
          vim.notify("DDL: failed to parse output", vim.log.levels.WARN)
        end)
        return
      end

      local items = parsed.items
      if not items or #items == 0 then
        vim.schedule(function()
          vim.notify("DDL: no items in response", vim.log.levels.WARN)
        end)
        return
      end

      vim.schedule(function()
        local ddl = items[1].ddl or ""
        if ddl == "" then
          vim.notify("DDL: empty result", vim.log.levels.WARN)
          return
        end
        local lines = vim.split(ddl, "\n")
        local title = "DDL: " .. table_node.name
        require("poste.sql.introspect").show_float(lines, title, "sql")
      end)
    end,
    on_stderr = function(data)
      if not data then return end
    end,
    on_exit = function(code)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("DDL fetch failed (exit " .. tostring(code) .. ")", vim.log.levels.ERROR)
        end)
      end
    end,
  })
end

--- Copy node name to system clipboard.
function M.copy_name(node)
  local name = node.name or ""
  vim.fn.setreg("+", name)
  vim.notify("Copied: " .. name, vim.log.levels.INFO)
end

--- Rename table or column via vim.ui.input → generate ALTER SQL.
function M.rename(node, context)
  if node.node_type ~= "table" and node.node_type ~= "column" then
    vim.notify("Rename is only available for tables and columns", vim.log.levels.INFO)
    return
  end

  local dialect = get_dialect(node, context)
  local label = node.node_type == "table" and "table" or "column"

  -- Temporarily disable dressing.nvim to avoid cmp completions
  local ok_dr, dr = pcall(require, "dressing")
  local dr_saved = ok_dr and dr.config and dr.config.input and dr.config.input.enabled
  if ok_dr and dr.config and dr.config.input then dr.config.input.enabled = false end

  vim.ui.input({
    prompt = "Rename " .. label .. " (" .. node.name .. "): ",
    default = node.name,
  }, function(input)
    if ok_dr and dr.config and dr.config.input then dr.config.input.enabled = dr_saved end
    if not input or input == "" or input == node.name then return end

    local conn = get_connection_name(node, context)
    local lines = { "" }
    local cursor_offset = 2  -- after empty line → ALTER line

    if node.node_type == "table" then
      if conn then
        table.insert(lines, "-- @connection " .. conn)
        cursor_offset = cursor_offset + 1
      end
      if node.meta and node.meta.database then
        table.insert(lines, "-- @database " .. node.meta.database)
        cursor_offset = cursor_offset + 1
      end

      if dialect == "mysql" then
        table.insert(lines, "RENAME TABLE `" .. node.name .. "` TO `" .. input .. "`;")
      elseif dialect == "sqlite" then
        table.insert(lines, "ALTER TABLE " .. node.name .. " RENAME TO " .. input .. ";")
      else
        table.insert(lines, "ALTER TABLE " .. node.name .. " RENAME TO " .. input .. ";")
      end
    elseif node.node_type == "column" then
      local table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
      if not table_node then
        vim.notify("Could not find parent table", vim.log.levels.WARN)
        return
      end
      if conn then
        table.insert(lines, "-- @connection " .. conn)
        cursor_offset = cursor_offset + 1
      end
      if table_node.meta and table_node.meta.database then
        table.insert(lines, "-- @database " .. table_node.meta.database)
        cursor_offset = cursor_offset + 1
      end
      if dialect == "mysql" then
        local col_type = node.meta and node.meta.col_type or "TEXT"
        table.insert(lines, "ALTER TABLE `" .. table_node.name
          .. "` CHANGE COLUMN `" .. node.name .. "` `" .. input .. "` " .. col_type .. ";")
      else
        table.insert(lines, "ALTER TABLE " .. table_node.name
          .. " RENAME COLUMN " .. node.name .. " TO " .. input .. ";")
      end
    end

    table.insert(lines, "")
    insert_into_source(context, lines, cursor_offset)
    vim.notify("Generated RENAME " .. label .. " SQL", vim.log.levels.INFO)
  end)
end

--- Refresh (re-fetch children) for expandable nodes.
function M.refresh(node, context)
  if node.node_type == "column" or node.node_type == "index"
      or node.node_type == "key_item" or node.node_type == "fk_item"
      or node.node_type == "index_item" then
    vim.notify("Cannot refresh leaf nodes", vim.log.levels.INFO)
    return
  end

  node.children = nil
  node.expanded = false
  node.loading = true
  local new_map = tree.render_tree(context.browser_buf, context.line_to_node, context.root_nodes, context.conn_label)
  for i, n in ipairs(new_map) do context.line_to_node[i] = n end

  local search_dir = get_search_dir(context)
  async.fetch_children(node, function()
    node.expanded = true
    vim.schedule(function()
      local nm = tree.render_tree(context.browser_buf, context.line_to_node, context.root_nodes, context.conn_label)
      for i, n in ipairs(nm) do context.line_to_node[i] = n end
    end)
  end, search_dir)
end

--- Insert a new query block with connection context.
function M.new_query(node, context)
  local conn = get_connection_name(node, context)
  local lines = { "" }
  local cursor_offset = 2  -- empty + first blank line
  if conn then
    table.insert(lines, "-- @connection " .. conn)
    cursor_offset = cursor_offset + 1
  end
  if node.node_type == "database" then
    table.insert(lines, "USE " .. node.name .. ";")
    cursor_offset = cursor_offset + 1
  end
  table.insert(lines, "")
  table.insert(lines, "")

  insert_into_source(context, lines, cursor_offset)
  vim.notify("New query block created", vim.log.levels.INFO)
end

--- Set default database/schema: insert USE or SET search_path.
function M.set_default(node, context)
  local dialect = get_dialect(node, context)
  local conn = get_connection_name(node, context)
  local lines = { "" }
  local cursor_offset = 2  -- empty + USE/SET line
  if conn then
    table.insert(lines, "-- @connection " .. conn)
    cursor_offset = cursor_offset + 1
  end

  if node.node_type == "database" then
    table.insert(lines, "USE " .. node.name .. ";")
  elseif node.node_type == "schema" then
    if dialect == "postgres" then
      table.insert(lines, "SET search_path TO " .. node.name .. ";")
    elseif dialect == "mysql" then
      table.insert(lines, "USE " .. node.name .. ";")
    else
      table.insert(lines, "-- schema: " .. node.name)
    end
  end
  table.insert(lines, "")

  insert_into_source(context, lines, cursor_offset)
  vim.notify("Set default: " .. node.name, vim.log.levels.INFO)
end

--- Open connections.json at this connection's entry.
function M.edit_conn(node, context)
  local conn_name = node.node_type == "connection" and node.name
    or (node.meta and node.meta.connection)
  if not conn_name then
    vim.notify("No connection name found", vim.log.levels.WARN)
    return
  end

  local connections = require("poste.sql.connections")
  local config_path = connections.find_connections_json(get_search_dir(context))
  if not config_path then
    vim.notify("connections.json not found", vim.log.levels.WARN)
    return
  end

  local target_win = vim.fn.bufwinid(context.source_buf)
  if target_win and target_win ~= -1 then
    vim.api.nvim_set_current_win(target_win)
  end
  vim.cmd("edit " .. vim.fn.fnameescape(config_path))

  -- Jump to the connection entry
  local search_target = '"' .. conn_name .. '"'
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local found_line = nil
  for i, line in ipairs(lines) do
    if line:find(search_target, 1, true) then
      found_line = i
      break
    end
  end
  if found_line then
    vim.api.nvim_win_set_cursor(0, { found_line, 0 })
  else
    vim.notify("Connection '" .. conn_name .. "' not found in file", vim.log.levels.WARN)
  end
end

--- Modify Column: open form with type/nullable/default, generate ALTER SQL.
function M.modify_col(node, context)
  if node.node_type ~= "column" then
    vim.notify("Modify is only available for columns", vim.log.levels.INFO)
    return
  end

  local table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  if not table_node then
    vim.notify("Could not find parent table", vim.log.levels.WARN)
    return
  end

  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)

  local fields = {
    { label = "Type",     key = "col_type", value = node.meta and node.meta.col_type or "", kind = "text" },
    { label = "Nullable", key = "nullable", value = not not (node.meta and node.meta.nullable), kind = "bool" },
    { label = "Default",  key = "default",  value = safe_str(node.meta and node.meta.default), kind = "text" },
    { label = "Comment",  key = "comment",  value = safe_str(node.meta and node.meta.comment), kind = "text" },
  }

  vim.g.poste_sql_dialect = dialect

  forms.open("Modify Column: " .. table_node.name .. "." .. node.name, fields, function(updated)
    local col_type = updated[1].value
    local nullable = updated[2].value
    local default_val = updated[3].value
    local comment_val = updated[4].value

    local sql_parts
    if dialect == "mysql" then
      sql_parts = { "ALTER TABLE `" .. table_node.name .. "` MODIFY COLUMN `" .. node.name .. "` " .. col_type }
    elseif dialect == "postgres" then
      sql_parts = { "ALTER TABLE " .. table_node.name .. " ALTER COLUMN " .. node.name .. " TYPE " .. col_type }
    else
      sql_parts = { "ALTER TABLE " .. table_node.name .. " ALTER COLUMN " .. node.name .. " TYPE " .. col_type }
    end

    if not nullable then
      table.insert(sql_parts, " NOT NULL")
    end
    if default_val ~= nil and default_val ~= "" then
      table.insert(sql_parts, " DEFAULT " .. default_val)
    elseif default_val == "" then
      table.insert(sql_parts, " DEFAULT ''")
    end
    table.insert(sql_parts, ";")

    local sql_line = table.concat(sql_parts, "")

    -- For PG: separate ALTER statements needed for null/default
    local lines = { "" }
    local cursor_offset = 2
    if conn then
      table.insert(lines, "-- @connection " .. conn)
      cursor_offset = cursor_offset + 1
    end
    if table_node.meta and table_node.meta.database then
      table.insert(lines, "-- @database " .. table_node.meta.database)
      cursor_offset = cursor_offset + 1
    end

    if dialect == "postgres" then
      table.insert(lines, "ALTER TABLE " .. table_node.name .. " ALTER COLUMN " .. node.name .. " TYPE " .. col_type .. ";")
      if not nullable then
        table.insert(lines, "ALTER TABLE " .. table_node.name .. " ALTER COLUMN " .. node.name .. " SET NOT NULL;")
      end
      if default_val ~= nil and default_val ~= "" then
        table.insert(lines, "ALTER TABLE " .. table_node.name .. " ALTER COLUMN " .. node.name .. " SET DEFAULT " .. default_val .. ";")
      elseif default_val == "" then
        table.insert(lines, "ALTER TABLE " .. table_node.name .. " ALTER COLUMN " .. node.name .. " SET DEFAULT '';")
      end
      if comment_val ~= nil and comment_val ~= "" then
        table.insert(lines, "COMMENT ON COLUMN " .. table_node.name .. "." .. node.name .. " IS '" .. comment_val:gsub("'", "''") .. "';")
      end
    elseif dialect == "mysql" then
      local parts = { "ALTER TABLE `" .. table_node.name .. "` MODIFY COLUMN `" .. node.name .. "` " .. col_type }
      if not nullable then table.insert(parts, " NOT NULL") end
      if default_val ~= nil and default_val ~= "" then table.insert(parts, " DEFAULT " .. default_val)
      elseif default_val == "" then table.insert(parts, " DEFAULT ''") end
      if comment_val ~= nil and comment_val ~= "" then
        table.insert(parts, " COMMENT '" .. comment_val:gsub("'", "''") .. "'")
      end
      table.insert(parts, ";")
      table.insert(lines, table.concat(parts, ""))
    else
      table.insert(lines, sql_line)
    end

    table.insert(lines, "")
    insert_into_source(context, lines, cursor_offset)
    vim.notify("Generated ALTER SQL for column: " .. node.name, vim.log.levels.INFO)
  end)
end

--- New Table: open form with table name, generate CREATE TABLE template.
function M.new_table(node, context)
  local dialect = get_dialect(node, context)
  local conn = get_connection_name(node, context)
  local schema = node.node_type == "schema" and node.name or nil
  local database = node.node_type == "database" and node.name or (node.meta and node.meta.database)

  local fields = {
    { label = "Name", key = "table_name", value = "", kind = "text" },
  }

  local title = "New Table"
  if node.node_type == "database" then title = "New Table: " .. node.name end
  if node.node_type == "schema" then title = "New Table: " .. (schema or "") end

  forms.open(title, fields, function(updated)
    local table_name = updated[1].value
    if table_name == "" then
      vim.notify("Table name cannot be empty", vim.log.levels.WARN)
      return
    end

    local lines = { "" }
    local cursor_offset = 2
    if conn then
      table.insert(lines, "-- @connection " .. conn)
      cursor_offset = cursor_offset + 1
    end
    if database then
      table.insert(lines, "-- @database " .. database)
      cursor_offset = cursor_offset + 1
    end

    local qualified = table_name
    if schema and dialect == "postgres" then
      qualified = schema .. "." .. table_name
    end

    table.insert(lines, "CREATE TABLE " .. qualified .. " (")
    table.insert(lines, "  id SERIAL PRIMARY KEY,")
    table.insert(lines, "  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP")
    table.insert(lines, ");")
    table.insert(lines, "")

    insert_into_source(context, lines, cursor_offset)
    vim.notify("Generated CREATE TABLE: " .. table_name, vim.log.levels.INFO)
  end)
end

--- New Column: open form with name/type/nullable/default, generate ALTER TABLE ADD COLUMN.
function M.new_column(node, context)
  local table_node = node
  if node.node_type ~= "table" then
    table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  end
  if not table_node or table_node.node_type ~= "table" then
    vim.notify("Move cursor to a table node", vim.log.levels.INFO)
    return
  end

  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)

  local fields = {
    { label = "Name",     key = "col_name",  value = "",   kind = "text" },
    { label = "Type",     key = "col_type",  value = "TEXT", kind = "text" },
    { label = "Nullable", key = "nullable",  value = true, kind = "bool" },
    { label = "Default",  key = "default",   value = "",   kind = "text" },
  }

  vim.g.poste_sql_dialect = dialect

  forms.open("New Column: " .. table_node.name, fields, function(updated)
    local col_name = updated[1].value
    local col_type = updated[2].value
    local nullable = updated[3].value
    local default_val = updated[4].value

    if col_name == "" then
      vim.notify("Column name cannot be empty", vim.log.levels.WARN)
      return
    end

    local lines = { "" }
    local cursor_offset = 2
    if conn then
      table.insert(lines, "-- @connection " .. conn)
      cursor_offset = cursor_offset + 1
    end
    if table_node.meta and table_node.meta.database then
      table.insert(lines, "-- @database " .. table_node.meta.database)
      cursor_offset = cursor_offset + 1
    end

    local add_col = "ALTER TABLE " .. table_node.name .. " ADD COLUMN " .. col_name .. " " .. col_type
    if not nullable then add_col = add_col .. " NOT NULL" end
    if default_val ~= "" then add_col = add_col .. " DEFAULT " .. default_val end
    add_col = add_col .. ";"

    if dialect == "mysql" then
      add_col = "ALTER TABLE `" .. table_node.name .. "` ADD COLUMN `" .. col_name .. "` " .. col_type
      if not nullable then add_col = add_col .. " NOT NULL" end
      if default_val ~= "" then add_col = add_col .. " DEFAULT " .. default_val end
      add_col = add_col .. ";"
    end

    table.insert(lines, add_col)
    table.insert(lines, "")

    insert_into_source(context, lines, cursor_offset)
    vim.notify("Generated ADD COLUMN: " .. col_name, vim.log.levels.INFO)
  end)
end

--- Get column names/types from a table node (must be expanded).
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
      })
    end
  end
  if #cols == 0 then return nil end
  return cols
end

--- INSERT template: generate INSERT INTO ... VALUES based on table columns.
function M.insert_template(node, context)
  local table_node = node
  if node.node_type ~= "table" then
    table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  end
  if not table_node or table_node.node_type ~= "table" then
    vim.notify("Move cursor to a table node", vim.log.levels.INFO)
    return
  end

  local cols = get_columns_from_node(table_node)
  if not cols then
    vim.notify("Expand the table first to see columns", vim.log.levels.WARN)
    return
  end

  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)
  local schema_prefix = ""
  if table_node.meta and table_node.meta.schema and dialect == "postgres" then
    schema_prefix = table_node.meta.schema .. "."
  end

  local col_names = {}
  for _, c in ipairs(cols) do
    if not c.is_pk then  -- skip auto-increment PK
      local q = dialect == "mysql" and "`" or ""
      table.insert(col_names, q .. c.name .. q)
    end
  end

  local lines = { "" }
  local cursor_offset = 2
  if conn then
    table.insert(lines, "-- @connection " .. conn)
    cursor_offset = cursor_offset + 1
  end
  if table_node.meta and table_node.meta.database then
    table.insert(lines, "-- @database " .. table_node.meta.database)
    cursor_offset = cursor_offset + 1
  end

  table.insert(lines, "INSERT INTO " .. schema_prefix .. table_node.name .. " (" .. table.concat(col_names, ", ") .. ")")
  table.insert(lines, "VALUES ()")
  table.insert(lines, "")
  cursor_offset = cursor_offset + 1  -- land on VALUES line

  insert_into_source(context, lines, cursor_offset, 8)  -- col 8 = inside VALUES ()
  vim.notify("Generated INSERT template for: " .. table_node.name, vim.log.levels.INFO)
end

--- UPDATE template: generate UPDATE ... SET ... WHERE based on table columns.
function M.update_template(node, context)
  local table_node = node
  if node.node_type ~= "table" then
    table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  end
  if not table_node or table_node.node_type ~= "table" then
    vim.notify("Move cursor to a table node", vim.log.levels.INFO)
    return
  end

  local cols = get_columns_from_node(table_node)
  if not cols then
    vim.notify("Expand the table first to see columns", vim.log.levels.WARN)
    return
  end

  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)
  local schema_prefix = ""
  if table_node.meta and table_node.meta.schema and dialect == "postgres" then
    schema_prefix = table_node.meta.schema .. "."
  end

  local pk_cols = {}
  local set_cols = {}
  for _, c in ipairs(cols) do
    local q = dialect == "mysql" and "`" or ""
    if c.is_pk then
      table.insert(pk_cols, q .. c.name .. q)
    else
      table.insert(set_cols, "  " .. q .. c.name .. q .. " = 'val'")
    end
  end

  local lines = { "" }
  local cursor_offset = 2
  if conn then
    table.insert(lines, "-- @connection " .. conn)
    cursor_offset = cursor_offset + 1
  end
  if table_node.meta and table_node.meta.database then
    table.insert(lines, "-- @database " .. table_node.meta.database)
    cursor_offset = cursor_offset + 1
  end

  table.insert(lines, "UPDATE " .. schema_prefix .. table_node.name)
  table.insert(lines, "SET")
  for _, sc in ipairs(set_cols) do table.insert(lines, sc .. ",") end
  -- Remove trailing comma from last SET column
  local last = lines[#lines]
  lines[#lines] = last:sub(1, -2)
  if #pk_cols > 0 then
    table.insert(lines, "WHERE " .. table.concat(pk_cols, " = ? AND ") .. " = ?;")
  else
    table.insert(lines, "WHERE ?;")
  end
  table.insert(lines, "")

  insert_into_source(context, lines, cursor_offset)
  vim.notify("Generated UPDATE template for: " .. table_node.name, vim.log.levels.INFO)
end

--- Import data from CSV/TSV/JSON into this table.
function M.import_data(node, context)
  if node.meta and node.meta.table_type == "VIEW" then
    vim.notify("Cannot import data into a view", vim.log.levels.WARN)
    return
  end
  if node.node_type ~= "table" then
    vim.notify("Import is only available for tables", vim.log.levels.INFO)
    return
  end
  require("poste.sql.import").run(node, context)
end

--- DELETE template: generate DELETE FROM ... WHERE based on table columns.
function M.delete_template(node, context)
  local table_node = node
  if node.node_type ~= "table" then
    table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  end
  if not table_node or table_node.node_type ~= "table" then
    vim.notify("Move cursor to a table node", vim.log.levels.INFO)
    return
  end

  local cols = get_columns_from_node(table_node)
  if not cols then
    vim.notify("Expand the table first to see columns", vim.log.levels.WARN)
    return
  end

  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)
  local schema_prefix = ""
  if table_node.meta and table_node.meta.schema and dialect == "postgres" then
    schema_prefix = table_node.meta.schema .. "."
  end

  local pk_cols = {}
  for _, c in ipairs(cols) do
    if c.is_pk then
      local q = dialect == "mysql" and "`" or ""
      table.insert(pk_cols, q .. c.name .. q)
    end
  end

  local lines = { "" }
  local cursor_offset = 2
  if conn then
    table.insert(lines, "-- @connection " .. conn)
    cursor_offset = cursor_offset + 1
  end
  if table_node.meta and table_node.meta.database then
    table.insert(lines, "-- @database " .. table_node.meta.database)
    cursor_offset = cursor_offset + 1
  end

  table.insert(lines, "DELETE FROM " .. schema_prefix .. table_node.name)
  if #pk_cols > 0 then
    table.insert(lines, "WHERE " .. table.concat(pk_cols, " = ? AND ") .. " = ?;")
  else
    table.insert(lines, "WHERE ?;")
  end
  table.insert(lines, "")

  insert_into_source(context, lines, cursor_offset)
  vim.notify("Generated DELETE template for: " .. table_node.name, vim.log.levels.INFO)
end

return M
