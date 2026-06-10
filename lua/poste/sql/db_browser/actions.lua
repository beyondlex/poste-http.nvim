local icons = require("poste.sql.db_browser.icons")
local tree = require("poste.sql.db_browser.tree")
local async = require("poste.sql.db_browser.async")
local state = require("poste.state")

local ICONS = icons.ICONS
local HEADER_LINES = icons.HEADER_LINES

local M = {}

function M.find_table_node(line_to_node, start_idx)
  for i = start_idx, 1, -1 do
    if line_to_node[i] and line_to_node[i].node_type == "table" then
      return line_to_node[i]
    end
  end
  return nil
end

local function get_connection(node, root_nodes)
  if node.node_type == "connection" then
    return node.name
  end
  return node.meta and node.meta.connection or state.sql.db_browser.connection
end

local function get_dialect(node, root_nodes)
  if node.meta and node.meta.dialect then
    return node.meta.dialect
  end
  local conn = get_connection(node, root_nodes)
  for _, root in ipairs(root_nodes) do
    if root.name == conn then
      return root.meta and root.meta.dialect
    end
  end
  return "postgres"
end

local function get_search_dir(source_buf)
  if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
    local buf_name = vim.api.nvim_buf_get_name(source_buf)
    if buf_name ~= "" then
      return vim.fn.fnamemodify(buf_name, ":p:h")
    end
  end
  return vim.fn.getcwd()
end

function M.toggle_node(buf_line, context)
  local node = tree.get_node_at_line(context.line_to_node, buf_line)
  if not node then return end

  if node.node_type == "column" or node.node_type == "index"
      or node.node_type == "key_item" or node.node_type == "fk_item"
      or node.node_type == "index_item" then
    return
  end

  if node.expanded then
    node.expanded = false
    local new_map = tree.render_tree(context.browser_buf, context.line_to_node, context.root_nodes, context.conn_label)
    for i, n in ipairs(new_map) do context.line_to_node[i] = n end
  else
    if node.children then
      node.expanded = true
      local new_map = tree.render_tree(context.browser_buf, context.line_to_node, context.root_nodes, context.conn_label)
      for i, n in ipairs(new_map) do context.line_to_node[i] = n end
    else
      node.loading = true
      local new_map = tree.render_tree(context.browser_buf, context.line_to_node, context.root_nodes, context.conn_label)
      for i, n in ipairs(new_map) do context.line_to_node[i] = n end
      local search_dir = get_search_dir(context.source_buf)
      async.fetch_children(node, function()
        node.expanded = true
        vim.schedule(function()
          local nm = tree.render_tree(context.browser_buf, context.line_to_node, context.root_nodes, context.conn_label)
          for i, n in ipairs(nm) do context.line_to_node[i] = n end
        end)
      end, search_dir)
    end
  end
end

function M.refresh_node(buf_line, context)
  local node = tree.get_node_at_line(context.line_to_node, buf_line)
  if not node then return end
  if node.node_type == "column" or node.node_type == "index"
      or node.node_type == "key_item" or node.node_type == "fk_item"
      or node.node_type == "index_item" then
    return
  end

  node.children = nil
  node.expanded = false
  node.loading = true
  local new_map = tree.render_tree(context.browser_buf, context.line_to_node, context.root_nodes, context.conn_label)
  for i, n in ipairs(new_map) do context.line_to_node[i] = n end

  local search_dir = get_search_dir(context.source_buf)
  async.fetch_children(node, function()
    node.expanded = true
    vim.schedule(function()
      local nm = tree.render_tree(context.browser_buf, context.line_to_node, context.root_nodes, context.conn_label)
      for i, n in ipairs(nm) do context.line_to_node[i] = n end
    end)
  end, search_dir)
end

function M.search_filter(buf_line, context)
  vim.ui.input({ prompt = "Filter: " }, function(input)
    if not input or input == "" then
      local new_map = tree.render_tree(context.browser_buf, context.line_to_node, context.root_nodes, context.conn_label)
      for i, n in ipairs(new_map) do context.line_to_node[i] = n end
      return
    end

    local lower = input:lower()
    local filtered = {}

    local function walk(nodes, path)
      for _, node in ipairs(nodes) do
        local current_path = path .. node.name
        if node.name:lower():find(lower, 1, true) then
          table.insert(filtered, { node = node, path = current_path })
        end
        if node.children and #node.children > 0 then
          walk(node.children, current_path .. "/")
        end
      end
    end

    walk(context.root_nodes, "")

    if #filtered == 0 then
      vim.notify("No matches for: " .. input, vim.log.levels.INFO)
      return
    end

    local display_lines = {}
    local filtered_map = {}
    for _, entry in ipairs(filtered) do
      local icon = ICONS[entry.node.node_type] or "  "
      if entry.node.node_type == "column" and entry.node.meta and entry.node.meta.icon then
        icon = entry.node.meta.icon
      end
      local line = "  " .. icon .. " " .. entry.path
      table.insert(display_lines, line)
      table.insert(filtered_map, entry.node)
    end

    local header = {
      " Filter: " .. input,
      string.rep("─", 40),
      "",
    }
    for _, line in ipairs(display_lines) do
      table.insert(header, line)
    end

    vim.api.nvim_set_option_value("modifiable", true, { buf = context.browser_buf })
    vim.api.nvim_buf_set_lines(context.browser_buf, 0, -1, false, header)
    vim.api.nvim_set_option_value("modifiable", false, { buf = context.browser_buf })

    for i, n in ipairs(filtered_map) do context.line_to_node[i] = n end
  end)
end

function M.generate_select_query(buf_line, context)
  local idx = buf_line - HEADER_LINES
  local table_node = M.find_table_node(context.line_to_node, idx)
  if not table_node then
    vim.notify("Move cursor to a table node", vim.log.levels.INFO)
    return
  end

  if not context.source_buf or not vim.api.nvim_buf_is_valid(context.source_buf) then
    vim.notify("No source SQL buffer found", vim.log.levels.WARN)
    return
  end

  local schema_prefix = ""
  local dialect = get_dialect(table_node, context.root_nodes)
  if table_node.meta and table_node.meta.schema then
    if dialect == "postgres" then
      schema_prefix = table_node.meta.schema .. "."
    end
  end

  local context_lines = {}
  local conn = get_connection(table_node, context.root_nodes)
  if conn then
    table.insert(context_lines, "-- @connection " .. conn)
  end

  local db_name = table_node.meta and table_node.meta.database
  if db_name then
    table.insert(context_lines, "-- @database " .. db_name)
  end

  local query_lines = {
    "",
    "### Query: " .. table_node.name,
  }
  for _, line in ipairs(context_lines) do
    table.insert(query_lines, line)
  end
  table.insert(query_lines, "SELECT * FROM " .. schema_prefix .. table_node.name .. " LIMIT 100;")
  table.insert(query_lines, "")

  local line_count = vim.api.nvim_buf_line_count(context.source_buf)
  vim.api.nvim_buf_set_lines(context.source_buf, line_count, line_count, false, query_lines)

  local header_line = line_count + 2
  local target_win = vim.fn.bufwinid(context.source_buf)
  if target_win and target_win ~= -1 then
    vim.api.nvim_set_current_win(target_win)
    vim.api.nvim_win_set_cursor(target_win, { header_line, 0 })
  end

  vim.notify("Generated SELECT for: " .. table_node.name, vim.log.levels.INFO)
end

function M.generate_describe_query(buf_line, context)
  local idx = buf_line - HEADER_LINES
  local table_node = M.find_table_node(context.line_to_node, idx)
  if not table_node then
    vim.notify("Move cursor to a table node", vim.log.levels.INFO)
    return
  end

  if not context.source_buf or not vim.api.nvim_buf_is_valid(context.source_buf) then
    vim.notify("No source SQL buffer found", vim.log.levels.WARN)
    return
  end

  local dialect = get_dialect(table_node, context.root_nodes)
  local describe_sql

  if dialect == "postgres" then
    local schema = table_node.meta and table_node.meta.schema or "public"
    describe_sql = string.format(
      "SELECT column_name, data_type, is_nullable, column_default\n"
      .. "FROM information_schema.columns\n"
      .. "WHERE table_schema = '%s' AND table_name = '%s'\n"
      .. "ORDER BY ordinal_position;",
      schema, table_node.name
    )
  elseif dialect == "mysql" then
    describe_sql = string.format("DESCRIBE `%s`;", table_node.name)
  else
    describe_sql = string.format("PRAGMA table_info(%s);", table_node.name)
  end

  local context_lines = {}
  local conn = get_connection(table_node, context.root_nodes)
  if conn then
    table.insert(context_lines, "-- @connection " .. conn)
  end

  local db_name = table_node.meta and table_node.meta.database
  if db_name then
    table.insert(context_lines, "-- @database " .. db_name)
  end

  local query_lines = {
    "",
    "### Describe: " .. table_node.name,
  }
  for _, line in ipairs(context_lines) do
    table.insert(query_lines, line)
  end
  table.insert(query_lines, describe_sql)
  table.insert(query_lines, "")

  local line_count = vim.api.nvim_buf_line_count(context.source_buf)
  vim.api.nvim_buf_set_lines(context.source_buf, line_count, line_count, false, query_lines)

  local header_line = line_count + 2
  local target_win = vim.fn.bufwinid(context.source_buf)
  if target_win and target_win ~= -1 then
    vim.api.nvim_set_current_win(target_win)
    vim.api.nvim_win_set_cursor(target_win, { header_line, 0 })
  end

  vim.notify("Generated DESCRIBE for: " .. table_node.name, vim.log.levels.INFO)
end

return M