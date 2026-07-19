local cli = require("poste.cli")
local state = require("poste.state")
local tree = require("poste.sql.db_browser.tree")

local M = {}

function M.run_introspect(conn_name, introspect_type, schema, table_name, database, callback, search_dir)
  local cmd = { "introspect", conn_name, "--type", introspect_type, "--path", search_dir, "--env", state.current_env }

  if schema then
    table.insert(cmd, "--schema"); table.insert(cmd, schema)
  end
  if table_name then
    table.insert(cmd, "--table"); table.insert(cmd, table_name)
  end
  if database then
    table.insert(cmd, "--database"); table.insert(cmd, database)
  end

  state.log("INFO", "DB Browser introspect: " .. table.concat(cmd, " "))

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

  cli.run_async(cmd, {
    on_stdout = function(data)
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
    on_stderr = function(data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(stderr_buf, l) end
      end
    end,
    on_exit = function(code)
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

function M.fetch_children(node, callback, search_dir)
  node.loading = true

  local conn = node.node_type == "connection" and node.name
    or (node.meta and node.meta.connection) or state.sql.db_browser.connection

  local dialect = "postgres"
  if node.meta and node.meta.dialect then
    dialect = node.meta.dialect
  end

  if node.node_type == "connection" then
    if dialect == "sqlite" then
      M.run_introspect(conn, "tables", nil, nil, nil, function(result)
        node.loading = false
        node.children = {}
        if result and result.items then
          for _, item in ipairs(result.items) do
            table.insert(node.children, tree.make_table_node(item, nil, nil, conn))
          end
        end
        callback()
      end, search_dir)
    else
      M.run_introspect(conn, "databases", nil, nil, nil, function(result)
        node.loading = false
        node.children = {}
        if result and result.items then
          for _, item in ipairs(result.items) do
            -- Skip system databases
            local skip = {
              information_schema = true, mysql = true,
              performance_schema = true, sys = true,
              template0 = true, template1 = true,
            }
            if not skip[item.name] then
              table.insert(node.children, tree.make_database_node(item, conn, dialect))
            end
          end
        end
        callback()
      end, search_dir)
    end

  elseif node.node_type == "database" then
    if dialect == "postgres" then
      M.run_introspect(conn, "schemas", nil, nil, node.name, function(result)
        node.loading = false
        node.children = {}
        if result and result.items then
          for _, item in ipairs(result.items) do
            -- Skip system schemas
            if item.name ~= "pg_catalog"
              and item.name ~= "information_schema"
              and item.name:sub(1, 8) ~= "pg_toast" then
              table.insert(node.children, tree.make_schema_node(item, conn, node.name))
            end
          end
        end
        callback()
      end, search_dir)
    else
      M.run_introspect(conn, "tables", nil, nil, node.name, function(result)
        node.loading = false
        node.children = {}
        if result and result.items then
          for _, item in ipairs(result.items) do
            table.insert(node.children, tree.make_table_node(item, nil, node.name, conn))
          end
        end
        callback()
      end, search_dir)
    end

  elseif node.node_type == "schema" then
    local db_name = node.meta and node.meta.database
    M.run_introspect(conn, "tables", node.name, nil, db_name, function(result)
      node.loading = false
      node.children = {}
      if result and result.items then
        for _, item in ipairs(result.items) do
          table.insert(node.children, tree.make_table_node(item, node.name, db_name, conn))
        end
      end
      callback()
    end, search_dir)

  elseif node.node_type == "table" then
    local schema_name = node.meta and node.meta.schema
    local db_name = node.meta and node.meta.database
    local table_name = node.name
    local columns_done, indexes_done = false, false
    local columns_result, indexes_result = nil, nil

    local function check_done()
      if columns_done and indexes_done then
        node.loading = false
        local cols = columns_result and columns_result.items or {}
        local idxs = indexes_result and indexes_result.items or {}
        local pk_cols, fk_cols, regular_cols = {}, {}, {}
        for _, item in ipairs(cols) do
          local pk = item.pk or item.key == "PRI"
          local fk = item.is_fk or item.key == "MUL"
          if pk then table.insert(pk_cols, item)
          elseif fk then table.insert(fk_cols, item)
          else table.insert(regular_cols, item) end
        end
        node.children = {}
        for _, item in ipairs(pk_cols) do
          table.insert(node.children, tree.make_column_node(item))
        end
        for _, item in ipairs(regular_cols) do
          table.insert(node.children, tree.make_column_node(item))
        end
        for _, item in ipairs(fk_cols) do
          table.insert(node.children, tree.make_column_node(item))
        end

        local key_items = {}
        for _, item in ipairs(pk_cols) do
          table.insert(key_items, { type = "pk", name = item.name })
        end
        for _, item in ipairs(idxs) do
          if item.unique and item.name ~= "PRIMARY" then
            local cols_str = item.columns and #item.columns > 0 and (" (" .. table.concat(item.columns, ", ") .. ")") or ""
            table.insert(key_items, { type = "unique", name = item.name .. cols_str })
          end
        end
        if #key_items > 0 then
          local keys_node = {
            node_type = "key_group",
            name = "keys",
            children = {},
            expanded = false, loading = false,
          }
          for _, ki in ipairs(key_items) do
            table.insert(keys_node.children, {
              node_type = "key_item",
              name = ki.name,
              full_name = ki.name,
              children = {},
              expanded = false, loading = false,
              meta = { is_pk = ki.type == "pk" },
            })
          end
          table.insert(node.children, keys_node)
        end

        local fk_items = {}
        local function s(v) -- normalize null/nil to empty string
          if v == nil or v == vim.NIL then return "" end
          return tostring(v)
        end
        for _, item in ipairs(cols) do
          local ref_table = s(item.fk_table)
          local ref_column = s(item.fk_column)
          if ref_table ~= "" then
            table.insert(fk_items, {
              name = item.name,
              ref_table = ref_table,
              ref_column = ref_column,
            })
          elseif item.is_fk or item.key == "MUL" then
            table.insert(fk_items, {
              name = item.name,
              ref_table = "",
              ref_column = "",
            })
          end
        end
        if #fk_items > 0 then
          local fk_node = {
            node_type = "fk_group",
            name = "foreign keys",
            children = {},
            expanded = false, loading = false,
          }
          for _, fi in ipairs(fk_items) do
            local label = fi.name
            if fi.ref_table and fi.ref_table ~= "" then
              label = label .. " -> " .. fi.ref_table .. "(" .. fi.ref_column .. ")"
            end
            table.insert(fk_node.children, {
              node_type = "fk_item",
              name = label,
              full_name = label,
              children = {},
              expanded = false, loading = false,
            })
          end
          table.insert(node.children, fk_node)
        end

        local idx_items = {}
        for _, item in ipairs(idxs) do
          local cols_str = item.columns and #item.columns > 0 and (" (" .. table.concat(item.columns, ", ") .. ")") or ""
          local unique_str = item.unique and " UNIQUE" or ""
          local label = item.name .. cols_str .. unique_str
          table.insert(idx_items, { name = label, is_pk = item.name == "PRIMARY" })
        end
        if #idx_items > 0 then
          local idx_node = {
            node_type = "index_group",
            name = "indexes",
            children = {},
            expanded = false, loading = false,
          }
          for _, ii in ipairs(idx_items) do
            table.insert(idx_node.children, {
              node_type = "index_item",
              name = ii.name,
              full_name = ii.name,
              children = {},
              expanded = false, loading = false,
              meta = { is_pk = ii.is_pk },
            })
          end
          table.insert(node.children, idx_node)
        end
        callback()
      end
    end

    M.run_introspect(conn, "columns", schema_name, table_name, db_name, function(result)
      columns_result = result
      columns_done = true
      check_done()
    end, search_dir)

    M.run_introspect(conn, "indexes", schema_name, table_name, db_name, function(result)
      indexes_result = result
      indexes_done = true
      check_done()
    end, search_dir)
  else
    node.loading = false
    callback()
  end
end

function M.load_connections(callback, search_dir)
  local cmd = { "connection", "list", "--path", search_dir, "--json" }

  state.log("INFO", "DB Browser load_connections: search_dir=" .. search_dir)

  local stdout_done = false
  local exit_done = false
  local conn_list = {}

  local function try_finish()
    if not stdout_done or not exit_done then return end
    vim.schedule(function()
      local nodes = {}
      for _, conn in ipairs(conn_list) do
        table.insert(nodes, tree.make_connection_node(conn))
      end
      state.log("INFO", "DB Browser: loaded " .. #nodes .. " connections")
      callback(nodes)
    end)
  end

  cli.run_async(cmd, {
    on_stdout = function(data)
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
    on_stderr = function(data)
      if data then
        for _, l in ipairs(data) do
          if l ~= "" then state.log("WARN", "DB Browser stderr: " .. l) end
        end
      end
    end,
    on_exit = function(code)
      exit_done = true
      if code ~= 0 then
        state.log("ERROR", "DB Browser: connection list exited with code " .. code)
      end
      try_finish()
    end,
  })
end

return M