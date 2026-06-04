--- Database structure browser — tree sidebar with lazy-loading.
--- Opens a 40-column left vertical split showing the database hierarchy:
---   Connection → Database → Schema (PG only) → Table → Columns + Indexes
local state = require("poste.state")

local M = {}

---------------------------------------------------------------------------
-- Icons and constants
---------------------------------------------------------------------------

-- Nerd font icons encoded as Lua byte escapes (LuaJIT doesn't support \u{})
-- U+F233 nf-fa-server    → EF 88 B3
-- U+F1C0 nf-fa-database  → EF 87 80
-- U+F07B nf-fa-folder    → EF 81 BB
-- U+F0CE nf-fa-table     → EF 83 8E
-- U+F084 nf-fa-key       → EF 82 84
-- U+F0C1 nf-fa-link      → EF 83 81
-- U+F105 nf-fa-angle_right → EF 84 85
-- U+F107 nf-fa-angle_down  → EF 84 87
-- U+E704 nf-dev-mysql    → EE 9C 84
-- U+E76E nf-dev-postgresql → EE 9D AE
-- U+E7C4 nf-dev-sqlite   → EE 9F 84
local ICONS = {
  connection = "\239\136\179",  --  nf-fa-server (fallback)
  mysql      = "\238\156\132",  --  nf-dev-mysql (dolphin)
  postgres   = "\238\157\174",  --  nf-dev-postgresql (elephant)
  sqlite     = "\238\159\132",  --  nf-dev-sqlite
  database   = "\239\135\128",  --  nf-fa-database
  schema     = "\239\129\187",  --  nf-fa-folder
  table      = "\239\131\142",  --  nf-fa-table
  column     = "\226\151\143",  -- ● U+25CF black circle
  column_pk  = "\239\130\132",  --  nf-fa-key
  column_fk  = "\239\131\129",  --  nf-fa-link
  index      = "#",
}

-- Map dialect names to their icons
local DIALECT_ICONS = {
  mysql    = ICONS.mysql,
  postgres = ICONS.postgres,
  sqlite   = ICONS.sqlite,
}

local MARKER_COLLAPSED = "\239\132\133"  --  nf-fa-angle_right
local MARKER_EXPANDED  = "\239\132\135"  --  nf-fa-angle_down
local MARKER_LOADING   = "\226\128\166"  -- … U+2026
local HEADER_LINES = 3  -- title, separator, blank line

---------------------------------------------------------------------------
-- Buffer and window handles
---------------------------------------------------------------------------

local browser_buf = nil
local browser_win = nil

-- Root nodes (one per connection)
local root_nodes = {}

-- Flat list mapping visible line numbers to tree nodes (rebuilt each render)
local line_to_node = {}

-- Source buffer handle (the SQL file active when browser opened)
local source_buf = nil

---------------------------------------------------------------------------
-- Binary discovery (same pattern as connections.lua)
---------------------------------------------------------------------------

local function find_poste_binary()
  if state.config.poste_binary ~= "" then
    return state.config.poste_binary
  end
  local local_paths = {
    "./target/debug/poste",
    "./target/release/poste",
  }
  for _, path in ipairs(local_paths) do
    if vim.fn.filereadable(path) == 1 then
      return vim.fn.fnamemodify(path, ":p")
    end
  end
  return nil
end

local function get_search_dir()
  if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
    local buf_name = vim.api.nvim_buf_get_name(source_buf)
    if buf_name ~= "" then
      return vim.fn.fnamemodify(buf_name, ":p:h")
    end
  end
  return vim.fn.getcwd()
end

---------------------------------------------------------------------------
-- Tree node factory functions
---------------------------------------------------------------------------

local function make_connection_node(conn_info)
  return {
    node_type = "connection",
    name = conn_info.name,
    full_name = conn_info.name,
    children = nil,
    expanded = false,
    loading = false,
    meta = {
      dialect = conn_info.dialect,
      host = conn_info.host,
      port = conn_info.port,
      database = conn_info.database,
      path = conn_info.path,
    },
  }
end

local function make_database_node(item, conn_name, dialect)
  return {
    node_type = "database",
    name = item.name,
    full_name = conn_name .. "/" .. item.name,
    children = nil,
    expanded = false,
    loading = false,
    meta = { dialect = dialect, connection = conn_name },
  }
end

local function make_schema_node(item, conn_name, database)
  return {
    node_type = "schema",
    name = item.name,
    full_name = conn_name .. "/" .. database .. "/" .. item.name,
    children = nil,
    expanded = false,
    loading = false,
    meta = { database = database, connection = conn_name },
  }
end

local function make_table_node(item, schema, database, conn_name)
  return {
    node_type = "table",
    name = item.name,
    full_name = (schema and schema .. "." or "") .. item.name,
    children = nil,
    expanded = false,
    loading = false,
    meta = {
      table_type = item.type or "BASE TABLE",
      schema = schema,
      database = database,
      connection = conn_name,
    },
  }
end

local function make_column_node(item)
  local icon = ICONS.column
  local is_pk = false
  if item.pk or item.key == "PRI" then
    icon = ICONS.column_pk
    is_pk = true
  elseif item.key == "MUL" or item.is_fk then
    icon = ICONS.column_fk
  end

  return {
    node_type = "column",
    name = item.name,
    full_name = item.name,
    children = {},  -- leaf
    expanded = false,
    loading = false,
    meta = {
      col_type = item.type or "?",
      nullable = item.nullable,
      default = item.default,
      is_pk = is_pk,
      icon = icon,
    },
  }
end

local function make_index_node(item)
  return {
    node_type = "index",
    name = item.name,
    full_name = item.name,
    children = {},  -- leaf
    expanded = false,
    loading = false,
    meta = {
      definition = item.definition or "",
    },
  }
end

---------------------------------------------------------------------------
-- Async introspection CLI call
---------------------------------------------------------------------------

--- Run an introspection query via the CLI.
--- @param conn_name string Connection name from connections.json
--- @param introspect_type string "databases"|"schemas"|"tables"|"columns"|"indexes"
--- @param schema string|nil Schema name
--- @param table_name string|nil Table name
--- @param database string|nil Database name (overrides connection default)
--- @param callback function(result: table|nil) Called with parsed JSON or nil
local function run_introspect(conn_name, introspect_type, schema, table_name, database, callback)
  local binary = find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found", vim.log.levels.ERROR)
    callback(nil)
    return
  end

  local search_dir = get_search_dir()
  local cmd = string.format(
    "%s introspect %s --type %s --path %s --env %s",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(conn_name),
    vim.fn.shellescape(introspect_type),
    vim.fn.shellescape(search_dir),
    vim.fn.shellescape(state.current_env)
  )

  if schema then
    cmd = cmd .. " --schema " .. vim.fn.shellescape(schema)
  end
  if table_name then
    cmd = cmd .. " --table " .. vim.fn.shellescape(table_name)
  end
  if database then
    cmd = cmd .. " --database " .. vim.fn.shellescape(database)
  end

  state.log("INFO", "DB Browser introspect: " .. cmd)

  local stderr_buf = {}
  local stdout_done = false
  local exit_done = false
  local parsed_result = nil

  local function try_finish()
    if not stdout_done or not exit_done then return end
    vim.schedule(function()
      callback(parsed_result)
    end)
  end

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout_done = true
      if not data then try_finish(); return end
      while #data > 0 and data[#data] == "" do data[#data] = nil end
      if #data == 0 then try_finish(); return end

      local output = table.concat(data, "\n")
      local ok, parsed = pcall(vim.json.decode, output)
      if ok and type(parsed) == "table" then
        parsed_result = parsed
      else
        state.log("WARN", "Introspect JSON parse failed: " .. output:sub(1, 200))
      end
      try_finish()
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(stderr_buf, l) end
      end
    end,
    on_exit = function(_, code)
      exit_done = true
      if code ~= 0 then
        vim.schedule(function()
          local err = table.concat(stderr_buf, "\n")
          vim.notify("Introspect failed: " .. (err ~= "" and err or "exit " .. code),
            vim.log.levels.ERROR)
        end)
        parsed_result = nil
      end
      try_finish()
    end,
  })
end

---------------------------------------------------------------------------
-- Fetch children for a tree node
---------------------------------------------------------------------------

--- Resolve which connection a node belongs to.
local function get_connection(node)
  if node.node_type == "connection" then
    return node.name
  end
  return node.meta and node.meta.connection or state.sql.db_browser.connection
end

local function get_dialect(node)
  -- Connection nodes carry dialect directly
  if node.meta and node.meta.dialect then
    return node.meta.dialect
  end
  -- Look up dialect from the root connection node this tree belongs to
  local conn = get_connection(node)
  for _, root in ipairs(root_nodes) do
    if root.name == conn then
      return root.meta and root.meta.dialect
    end
  end
  return "postgres"  -- default
end

local function fetch_children(node, callback)
  node.loading = true

  local conn = get_connection(node)
  local dialect = get_dialect(node)

  if node.node_type == "connection" then
    if dialect == "sqlite" then
      -- SQLite: connection → tables directly (no databases/schemas layer)
      run_introspect(conn, "tables", nil, nil, nil, function(result)
        node.loading = false
        if result and result.items then
          node.children = {}
          for _, item in ipairs(result.items) do
            table.insert(node.children, make_table_node(item, nil, nil, conn))
          end
        else
          node.children = {}
        end
        callback()
      end)
    else
      -- PG/MySQL: connection → databases
      run_introspect(conn, "databases", nil, nil, nil, function(result)
        node.loading = false
        if result and result.items then
          node.children = {}
          for _, item in ipairs(result.items) do
            table.insert(node.children, make_database_node(item, conn, dialect))
          end
        else
          node.children = {}
        end
        callback()
      end)
    end

  elseif node.node_type == "database" then
    if dialect == "postgres" then
      -- PG: database → schemas (connect to this database)
      run_introspect(conn, "schemas", nil, nil, node.name, function(result)
        node.loading = false
        if result and result.items then
          node.children = {}
          for _, item in ipairs(result.items) do
            table.insert(node.children, make_schema_node(item, conn, node.name))
          end
        else
          node.children = {}
        end
        callback()
      end)
    else
      -- MySQL: database → tables (no schema layer, connect to this database)
      run_introspect(conn, "tables", nil, nil, node.name, function(result)
        node.loading = false
        if result and result.items then
          node.children = {}
          for _, item in ipairs(result.items) do
            table.insert(node.children, make_table_node(item, nil, node.name, conn))
          end
        else
          node.children = {}
        end
        callback()
      end)
    end

  elseif node.node_type == "schema" then
    -- schema → tables (PG: connect to parent database)
    local db_name = node.meta and node.meta.database
    run_introspect(conn, "tables", node.name, nil, db_name, function(result)
      node.loading = false
      if result and result.items then
        node.children = {}
        for _, item in ipairs(result.items) do
          table.insert(node.children, make_table_node(item, node.name, db_name, conn))
        end
      else
        node.children = {}
      end
      callback()
    end)

  elseif node.node_type == "table" then
    -- table → columns + indexes (fetch both, merge on completion)
    local schema_name = node.meta and node.meta.schema
    local db_name = node.meta and node.meta.database
    local table_name = node.name
    local columns_done, indexes_done = false, false
    local columns_result, indexes_result = nil, nil

    local function check_done()
      if columns_done and indexes_done then
        node.loading = false
        node.children = {}
        if columns_result and columns_result.items then
          for _, item in ipairs(columns_result.items) do
            table.insert(node.children, make_column_node(item))
          end
        end
        if indexes_result and indexes_result.items then
          for _, item in ipairs(indexes_result.items) do
            table.insert(node.children, make_index_node(item))
          end
        end
        callback()
      end
    end

    run_introspect(conn, "columns", schema_name, table_name, db_name, function(result)
      columns_result = result
      columns_done = true
      check_done()
    end)

    run_introspect(conn, "indexes", schema_name, table_name, db_name, function(result)
      indexes_result = result
      indexes_done = true
      check_done()
    end)
  else
    -- Leaf node (column/index) — nothing to fetch
    node.loading = false
    callback()
  end
end

---------------------------------------------------------------------------
-- Tree rendering
---------------------------------------------------------------------------

--- Flatten the tree into visible lines and node map.
--- Returns: lines[], node_map[], count_ranges[] (for highlight)
local function flatten_tree(nodes, depth)
  depth = depth or 0
  local lines = {}
  local node_map = {}
  local count_ranges = {}  -- {line_idx, col_start, col_end} for muted count text

  for _, node in ipairs(nodes) do
    local indent = string.rep("  ", depth)
    local icon = ICONS[node.node_type] or "  "

    -- Use dialect-specific icons for connection nodes
    if node.node_type == "connection" and node.meta and node.meta.dialect then
      icon = DIALECT_ICONS[node.meta.dialect] or icon
    end

    -- Override icon for column nodes with PK/FK
    if node.node_type == "column" and node.meta and node.meta.icon then
      icon = node.meta.icon
    end

    local marker
    if node.node_type == "column" or node.node_type == "index" then
      marker = "  "  -- leaf: no expand marker
    elseif node.loading then
      marker = MARKER_LOADING .. " "
    elseif node.expanded then
      marker = MARKER_EXPANDED .. " "
    else
      marker = MARKER_COLLAPSED .. " "
    end

    -- Type annotation for columns
    local suffix = ""
    if node.node_type == "column" and node.meta then
      suffix = " " .. (node.meta.col_type or "?")
      if node.meta.is_pk then suffix = suffix .. " PK" end
    end

    -- View indicator for tables
    local type_suffix = ""
    if node.node_type == "table" and node.meta and node.meta.table_type == "VIEW" then
      type_suffix = " (view)"
    end

    local prefix = indent .. marker .. icon .. " " .. node.name .. type_suffix

    -- Child count for container nodes (database/schema/connection/table)
    local count_text = ""
    if node.children and #node.children > 0 then
      count_text = " (" .. #node.children .. ")"
    end

    local line = prefix .. suffix .. count_text
    table.insert(lines, line)
    table.insert(node_map, node)

    -- Track count position for highlighting
    -- nvim_buf_add_highlight uses 0-indexed, half-open ranges [start, end)
    -- col_start = #prefix + #suffix gives 0-indexed start of count_text
    if count_text ~= "" then
      local col_start = #prefix + #suffix
      table.insert(count_ranges, { #lines, col_start, col_start + #count_text })
    end

    -- Recurse into expanded children
    if node.expanded and node.children then
      local line_offset = #lines  -- save current line count before appending
      local child_lines, child_map, child_ranges = flatten_tree(node.children, depth + 1)
      for _, cl in ipairs(child_lines) do
        table.insert(lines, cl)
      end
      for _, cn in ipairs(child_map) do
        table.insert(node_map, cn)
      end
      -- Offset child line indices by parent's line count
      for _, cr in ipairs(child_ranges) do
        table.insert(count_ranges, { cr[1] + line_offset, cr[2], cr[3] })
      end
    end
  end

  return lines, node_map, count_ranges
end

local hl_ns = vim.api.nvim_create_namespace("poste_db_browser")

local function apply_highlights(buf, line_count, count_ranges)
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)

  -- Header lines
  vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteSqlBrowserHeader", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteSqlBrowserSeparator", 1, 0, -1)

  -- Highlight count ranges in muted color
  for _, cr in ipairs(count_ranges or {}) do
    local lnum, col_start, col_end = cr[1], cr[2], cr[3]
    -- lnum is 1-based index within lines[] (no header offset yet)
    vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteSqlBrowserCount",
      lnum + HEADER_LINES - 1, col_start, col_end)
  end

  -- Icon and type highlighting per node
  local icon_hl = {
    connection = "PosteSqlBrowserIconConn",
    database   = "PosteSqlBrowserIconDb",
    schema     = "PosteSqlBrowserIconSchema",
    table      = "PosteSqlBrowserIconTable",
    column     = "PosteSqlBrowserIconCol",
    index      = "PosteSqlBrowserIconIdx",
  }

  for i = HEADER_LINES + 1, line_count do
    local node_idx = i - HEADER_LINES
    local node = line_to_node[node_idx]
    if not node then goto continue end

    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""

    -- Calculate icon byte position: indent + marker
    local indent_bytes = 0
    for ci = 1, #text do
      if text:sub(ci, ci) == " " then
        indent_bytes = indent_bytes + 1
      else
        break
      end
    end

    -- Marker is either "" / "" (3 bytes) or "  " (2 bytes for leaf)
    local after_indent = text:sub(indent_bytes + 1)
    local marker_len = 2  -- default: leaf "  "
    if after_indent:sub(1, 3) == "" or after_indent:sub(1, 3) == "" then
      marker_len = 3
    end

    -- Icon starts at indent_bytes + marker_len + 1 (1-indexed)
    local icon_byte_start = indent_bytes + marker_len  -- 0-indexed
    local icon_hl_group = icon_hl[node.node_type]

    -- Override for PK/FK columns
    if node.node_type == "column" and node.meta then
      if node.meta.is_pk then
        icon_hl_group = "PosteSqlBrowserIconPk"
      elseif node.meta.icon == ICONS.column_fk then
        icon_hl_group = "PosteSqlBrowserIconFk"
      end
    end

    if icon_hl_group then
      -- Get icon byte length
      local icon_char = text:sub(icon_byte_start + 1)
      -- Nerd font chars are 3 bytes, "#" is 1 byte, "●" is 3 bytes
      local icon_len = 3
      local first_byte = icon_char:byte(1)
      if first_byte and first_byte < 128 then
        icon_len = 1
      end
      vim.api.nvim_buf_add_highlight(buf, hl_ns, icon_hl_group,
        i - 1, icon_byte_start, icon_byte_start + icon_len)
    end

    -- Column type suffix highlighting
    if node.node_type == "column" and node.meta then
      local name_pos = text:find(node.name, 1, true)
      if name_pos then
        local name_end = name_pos + #node.name - 1
        local after_name = text:sub(name_end + 1)
        local type_match = after_name:match("^ (%w+)")
        if type_match then
          vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteSqlBrowserType",
            i - 1, name_end, name_end + 1 + #type_match)
        end
      end
    end

    ::continue::
  end
end

--- Re-render the tree in the browser buffer.
local function render_tree()
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end

  local lines, node_map, count_ranges = flatten_tree(root_nodes)
  line_to_node = node_map

  -- Build full buffer content with header
  local conn_label = state.sql.db_browser.connection or "No connection"
  local header = {
    " DB Browser [" .. conn_label .. "]",
    string.rep("─", 40),
    "",
  }
  for _, line in ipairs(lines) do
    table.insert(header, line)
  end

  -- Add footer hint
  if #lines == 0 then
    local search_dir = vim.fn.getcwd()
    if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
      local buf_name = vim.api.nvim_buf_get_name(source_buf)
      if buf_name ~= "" then
        search_dir = vim.fn.fnamemodify(buf_name, ":p:h")
      end
    end
    table.insert(header, "  (no connections found)")
    table.insert(header, "  searched from: " .. vim.fn.fnamemodify(search_dir, ":~"))
    table.insert(header, "  need: connections.json")
  else
    table.insert(header, "")
    table.insert(header, " <CR> expand  r refresh  s SELECT")
    table.insert(header, " d describe   / filter   q close")
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = browser_buf })
  vim.api.nvim_buf_set_lines(browser_buf, 0, -1, false, header)
  vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })

  apply_highlights(browser_buf, #header, count_ranges)
end

---------------------------------------------------------------------------
-- Node interaction
---------------------------------------------------------------------------

--- Get the node at a buffer line (accounting for header offset).
local function get_node_at_line(buf_line)
  local idx = buf_line - HEADER_LINES
  if idx < 1 or idx > #line_to_node then return nil end
  return line_to_node[idx]
end

--- Toggle expand/collapse for the node at the given buffer line.
local function toggle_node(buf_line)
  local node = get_node_at_line(buf_line)
  if not node then return end

  -- Leaf nodes: no toggle
  if node.node_type == "column" or node.node_type == "index" then
    return
  end

  if node.expanded then
    node.expanded = false
    render_tree()
  else
    if node.children then
      -- Already loaded, just expand
      node.expanded = true
      render_tree()
    else
      -- Need to fetch children
      node.loading = true
      render_tree()
      fetch_children(node, function()
        node.expanded = true
        vim.schedule(render_tree)
      end)
    end
  end
end

--- Refresh a node's children (re-fetch from database).
local function refresh_node(buf_line)
  local node = get_node_at_line(buf_line)
  if not node then return end
  if node.node_type == "column" or node.node_type == "index" then
    return
  end

  node.children = nil
  node.expanded = false
  node.loading = true
  render_tree()

  fetch_children(node, function()
    node.expanded = true
    vim.schedule(render_tree)
  end)
end

---------------------------------------------------------------------------
-- Search filter
---------------------------------------------------------------------------

local function search_filter()
  vim.ui.input({ prompt = "Filter: " }, function(input)
    if not input or input == "" then
      render_tree()
      return
    end

    local lower = input:lower()
    local filtered = {}

    -- Walk all nodes and collect matches
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

    walk(root_nodes, "")

    if #filtered == 0 then
      vim.notify("No matches for: " .. input, vim.log.levels.INFO)
      return
    end

    -- Build filtered display
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

    vim.api.nvim_set_option_value("modifiable", true, { buf = browser_buf })
    vim.api.nvim_buf_set_lines(browser_buf, 0, -1, false, header)
    vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })

    line_to_node = filtered_map
  end)
end

---------------------------------------------------------------------------
-- Query generation (Step 23)
---------------------------------------------------------------------------

--- Find the nearest table node by walking backwards through line_to_node.
local function find_table_node(start_idx)
  local node = line_to_node[start_idx]
  if not node then return nil end
  if node.node_type == "table" then return node end

  -- Walk backwards to find parent table
  for i = start_idx - 1, 1, -1 do
    if line_to_node[i] and line_to_node[i].node_type == "table" then
      return line_to_node[i]
    end
  end
  return nil
end

--- Generate a SELECT query and insert into source buffer.
local function generate_select_query(buf_line)
  local idx = buf_line - HEADER_LINES
  local table_node = find_table_node(idx)
  if not table_node then
    vim.notify("Move cursor to a table node", vim.log.levels.INFO)
    return
  end

  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    vim.notify("No source SQL buffer found", vim.log.levels.WARN)
    return
  end

  -- Build schema-qualified name for PostgreSQL
  local schema_prefix = ""
  local dialect = get_dialect(table_node)
  if table_node.meta and table_node.meta.schema then
    if dialect == "postgres" then
      schema_prefix = table_node.meta.schema .. "."
    end
  end

  -- Build context directives
  local context_lines = {}
  local conn = get_connection(table_node)
  if conn then
    table.insert(context_lines, "-- @connection " .. conn)
  end

  local db_name = table_node.meta and table_node.meta.database
  if db_name and dialect == "mysql" then
    table.insert(context_lines, "USE " .. db_name .. ";")
  end

  local query_lines = {
    "",
  }

  -- Add context lines
  for _, line in ipairs(context_lines) do
    table.insert(query_lines, line)
  end

  table.insert(query_lines, "### Query: " .. table_node.name)
  table.insert(query_lines, "SELECT * FROM " .. schema_prefix .. table_node.name .. " LIMIT 100;")
  table.insert(query_lines, "")

  local line_count = vim.api.nvim_buf_line_count(source_buf)
  vim.api.nvim_buf_set_lines(source_buf, line_count, line_count, false, query_lines)

  -- Move cursor to the SELECT line (skip context lines)
  local select_line = line_count + 1 + #context_lines + 2
  local target_win = vim.fn.bufwinid(source_buf)
  if target_win and target_win ~= -1 then
    vim.api.nvim_set_current_win(target_win)
    vim.api.nvim_win_set_cursor(target_win, { select_line, 0 })
  end

  vim.notify("Generated SELECT for: " .. table_node.name, vim.log.levels.INFO)
end

--- Generate a DESCRIBE query and insert into source buffer.
local function generate_describe_query(buf_line)
  local idx = buf_line - HEADER_LINES
  local table_node = find_table_node(idx)
  if not table_node then
    vim.notify("Move cursor to a table node", vim.log.levels.INFO)
    return
  end

  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    vim.notify("No source SQL buffer found", vim.log.levels.WARN)
    return
  end

  local dialect = get_dialect(table_node)
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

  -- Build context directives
  local context_lines = {}
  local conn = get_connection(table_node)
  if conn then
    table.insert(context_lines, "-- @connection " .. conn)
  end

  local db_name = table_node.meta and table_node.meta.database
  if db_name and dialect == "mysql" then
    table.insert(context_lines, "USE " .. db_name .. ";")
  end

  local query_lines = {
    "",
  }

  -- Add context lines
  for _, line in ipairs(context_lines) do
    table.insert(query_lines, line)
  end

  table.insert(query_lines, "### Describe: " .. table_node.name)
  table.insert(query_lines, describe_sql)
  table.insert(query_lines, "")

  local line_count = vim.api.nvim_buf_line_count(source_buf)
  vim.api.nvim_buf_set_lines(source_buf, line_count, line_count, false, query_lines)

  -- Move cursor to the DESCRIBE line (skip context lines)
  local describe_line = line_count + 1 + #context_lines + 2
  local target_win = vim.fn.bufwinid(source_buf)
  if target_win and target_win ~= -1 then
    vim.api.nvim_set_current_win(target_win)
    vim.api.nvim_win_set_cursor(target_win, { describe_line, 0 })
  end

  vim.notify("Generated DESCRIBE for: " .. table_node.name, vim.log.levels.INFO)
end

---------------------------------------------------------------------------
-- Load connections (self-contained, uses source_buf for search dir)
---------------------------------------------------------------------------

local function load_connections(callback)
  local binary = find_poste_binary()
  if not binary then
    state.log("ERROR", "DB Browser: poste binary not found")
    vim.notify("Poste binary not found", vim.log.levels.ERROR)
    callback()
    return
  end

  -- Use source_buf's FULL path for search dir (more reliable than buf 0)
  local search_dir = vim.fn.getcwd()
  if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
    local buf_name = vim.api.nvim_buf_get_name(source_buf)
    if buf_name ~= "" then
      search_dir = vim.fn.fnamemodify(buf_name, ":p:h")
    end
  end

  local cmd = string.format("%s connection list --path %s --json",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(search_dir)
  )

  state.log("INFO", "DB Browser load_connections: search_dir=" .. search_dir .. " cmd=" .. cmd)

  local stdout_done = false
  local exit_done = false
  local conn_list = {}

  local function try_finish()
    if not stdout_done or not exit_done then return end
    vim.schedule(function()
      root_nodes = {}
      for _, conn in ipairs(conn_list) do
        table.insert(root_nodes, make_connection_node(conn))
      end
      if #root_nodes > 0 then
        state.sql.db_browser.connection = root_nodes[1].name
      end
      state.log("INFO", "DB Browser: loaded " .. #root_nodes .. " connections")
      callback()
    end)
  end

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout_done = true
      if data then
        while #data > 0 and data[#data] == "" do data[#data] = nil end
        if #data > 0 then
          local output = table.concat(data, "\n")
          local ok, parsed = pcall(vim.json.decode, output)
          if ok and type(parsed) == "table" then
            conn_list = parsed
          else
            state.log("WARN", "DB Browser: JSON parse failed: " .. output:sub(1, 200))
          end
        end
      end
      try_finish()
    end,
    on_stderr = function(_, data)
      if data then
        for _, l in ipairs(data) do
          if l ~= "" then state.log("WARN", "DB Browser stderr: " .. l) end
        end
      end
    end,
    on_exit = function(_, code)
      exit_done = true
      if code ~= 0 then
        state.log("ERROR", "DB Browser: connection list exited with code " .. code)
      end
      try_finish()
    end,
  })
end

---------------------------------------------------------------------------
-- Highlight group setup
---------------------------------------------------------------------------

local function setup_highlights()
  local function resolve_hl(name)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
    if ok and hl then return hl end
    return nil
  end

  -- Detect background luminance for theme-aware colors
  local normal = resolve_hl("Normal")
  local is_dark = true
  if normal and normal.bg then
    local bg = normal.bg
    local r = math.floor(bg / 65536) % 256
    local g = math.floor(bg / 256) % 256
    local b = bg % 256
    local luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255
    is_dark = luminance < 0.5
  end

  if is_dark then
    vim.api.nvim_set_hl(0, "PosteSqlBrowserHeader", { fg = "#7aa2f7", bold = true })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserSeparator", { fg = "#3b4261" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserMarker", { fg = "#565f89" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserTable", { fg = "#9ece6a" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserType", { fg = "#bb9af7" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserCount", { fg = "#565f89" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconConn", { fg = "#7aa2f7" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconDb", { fg = "#e0af68" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconSchema", { fg = "#e0af68" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconTable", { fg = "#9ece6a" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconCol", { fg = "#a9b1d6" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconPk", { fg = "#e0af68" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconFk", { fg = "#7dcfff" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconIdx", { fg = "#a9b1d6" })
  else
    vim.api.nvim_set_hl(0, "PosteSqlBrowserHeader", { fg = "#2e7de9", bold = true })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserSeparator", { fg = "#a8aecb" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserMarker", { fg = "#8990b3" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserTable", { fg = "#587539" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserType", { fg = "#9854f1" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserCount", { fg = "#8990b3" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconConn", { fg = "#2e7de9" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconDb", { fg = "#8c6c3e" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconSchema", { fg = "#8c6c3e" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconTable", { fg = "#587539" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconCol", { fg = "#6172b0" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconPk", { fg = "#8c6c3e" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconFk", { fg = "#1880a8" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconIdx", { fg = "#6172b0" })
  end
end

-- Setup highlights on load and on ColorScheme change
setup_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = setup_highlights,
})

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Open the DB browser sidebar.
function M.open()
  -- Remember the source buffer (the SQL file)
  source_buf = vim.api.nvim_get_current_buf()

  -- Create scratch buffer
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then
    browser_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = browser_buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = browser_buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = browser_buf })
    vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })
    vim.api.nvim_buf_set_name(browser_buf, "poste://db_browser")

    -- Keymaps
    local opts = { buffer = browser_buf, noremap = true, silent = true }

    vim.keymap.set("n", "<CR>", function()
      toggle_node(vim.fn.line("."))
    end, opts)

    vim.keymap.set("n", "r", function()
      refresh_node(vim.fn.line("."))
    end, opts)

    vim.keymap.set("n", "/", function()
      search_filter()
    end, opts)

    vim.keymap.set("n", "s", function()
      generate_select_query(vim.fn.line("."))
    end, opts)

    vim.keymap.set("n", "d", function()
      generate_describe_query(vim.fn.line("."))
    end, opts)

    vim.keymap.set("n", "q", function()
      M.close()
    end, opts)
  end

  -- Open left vertical split (40 cols)
  if not browser_win or not vim.api.nvim_win_is_valid(browser_win) then
    vim.cmd("topleft 40vsplit")
    browser_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(browser_win, browser_buf)

    -- Window options
    vim.api.nvim_set_option_value("number", false, { win = browser_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = browser_win })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = browser_win })
    vim.api.nvim_set_option_value("wrap", false, { win = browser_win })
    vim.api.nvim_set_option_value("cursorline", true, { win = browser_win })
    vim.api.nvim_set_option_value("conceallevel", 2, { win = browser_win })
    vim.api.nvim_set_option_value("spell", false, { win = browser_win })
  end

  -- Load connections and render
  load_connections(function()
    render_tree()
  end)
end

--- Close the browser sidebar.
function M.close()
  if browser_win and vim.api.nvim_win_is_valid(browser_win) then
    vim.api.nvim_win_close(browser_win, true)
    browser_win = nil
  end
end

--- Check if browser is open.
function M.is_open()
  return browser_win and vim.api.nvim_win_is_valid(browser_win)
end

--- Toggle the browser.
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

return M
