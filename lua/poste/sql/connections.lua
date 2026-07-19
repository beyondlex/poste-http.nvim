--- SQL connection management UI.
--- Provides :PosteConnection command to list, select, and test connections.
local cli = require("poste.cli")
local state = require("poste.state")
local util = require("poste.util")
local select_mod = require("poste.select")

local M = {}

-----------------------------------------------------------------------
-- Get search directory for connections.json
-----------------------------------------------------------------------
local function get_search_dir()
  local buf_name = vim.api.nvim_buf_get_name(0)
  if buf_name ~= "" then
    return vim.fn.fnamemodify(buf_name, ":h")
  end
  return vim.fn.getcwd()
end

-----------------------------------------------------------------------
-- Config file discovery
-----------------------------------------------------------------------

local _config_search_cache = {}

--- Walk up from `search_dir` to find connections.json (matches Rust logic).
--- Caches results to avoid directory traversal on every cursor move.
--- @param search_dir string Directory to start from
--- @return string|nil Path to connections.json
function M.find_connections_json(search_dir)
  if _config_search_cache[search_dir] ~= nil then
    return _config_search_cache[search_dir] ~= false and _config_search_cache[search_dir] or nil
  end
  local result = util.find_file_upwards("connections.json", search_dir)
  _config_search_cache[search_dir] = result or false
  return result
end

local _config_cache = nil
local _config_cache_path = nil

--- Get the config for a named connection by reading connections.json directly.
--- Returns raw values (before {{var}} substitution — use env-aware call for that).
--- Caches parsed config to avoid file I/O on every cursor move.
--- @param name string Connection name
--- @return table|nil Connection config or nil
function M.get_connection_config(name)
  local search_dir = get_search_dir()
  local config_path = M.find_connections_json(search_dir)
  if not config_path then
    _config_cache = nil
    _config_cache_path = nil
    return nil
  end
  if _config_cache_path ~= config_path then
    local ok, data = pcall(vim.fn.readfile, config_path)
    if not ok or not data then return nil end
    local ok2, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
    if not ok2 or type(parsed) ~= "table" then return nil end
    _config_cache = parsed
    _config_cache_path = config_path
  end
  return _config_cache[name]
end

---------------------------------------------------------------------------
-- Binary discovery
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- List connections
---------------------------------------------------------------------------

--- Fetch connections from CLI and parse JSON.
--- @param callback function(connections: table[]) Called with parsed connection list
function M.list_connections(callback)
  local search_dir = get_search_dir()
  local cmd = { "connection", "list", "--path", search_dir, "--json" }

  cli.run_async(cmd, {
    on_stdout = function(data)
      if not data then return end
      while #data > 0 and data[#data] == "" do data[#data] = nil end
      if #data == 0 then
        callback({})
        return
      end

      local output = table.concat(data, "\n")
      local ok, connections = pcall(vim.json.decode, output)
      if not ok or type(connections) ~= "table" then
        callback({})
        return
      end

      vim.schedule(function()
        callback(connections)
      end)
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          callback({})
        end)
      end
    end,
  })
end

---------------------------------------------------------------------------
-- Format connection for display
---------------------------------------------------------------------------

local dialect_icons = {
  postgres = "🐘",
  mysql = "🐬",
  sqlite = "📦",
}

local function format_connection(conn)
  local icon = dialect_icons[conn.dialect] or "❓"
  local name = conn.name or "?"

  if conn.dialect == "sqlite" then
    return string.format("%s %s — %s", icon, name, conn.path or "?")
  else
    local host = conn.host or "localhost"
    local port = conn.port or (conn.dialect == "postgres" and 5432 or 3306)
    local db = conn.database or ""
    return string.format("%s %s — %s:%d/%s", icon, name, host, port, db)
  end
end

---------------------------------------------------------------------------
-- Select connection
---------------------------------------------------------------------------

--- Open connection picker.
function M.select_connection()
  M.list_connections(function(connections)
    if #connections == 0 then
      vim.notify("No connections found. Create a connections.json file.", vim.log.levels.WARN)
      return
    end

    local items = {}
    for _, conn in ipairs(connections) do
      table.insert(items, format_connection(conn))
    end

    select_mod.select(items, "Select Connection", function(selected)
      if not selected then return end

      -- Find the matching connection
      for i, item in ipairs(items) do
        if item == selected then
          local conn = connections[i]
          M.apply_connection(conn)
          break
        end
      end
    end)
  end)
end

--- Apply a selected connection to the current buffer.
--- Updates @connection directive and state.sql.context.connection.
function M.apply_connection(conn)
  local conn_name = conn.name
  state.sql.context.connection = conn_name

  -- Update or insert @connection directive in the current buffer
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local found = false

  for i, line in ipairs(lines) do
    if line:match("^%s*--%s*@connection%s") then
      -- Update existing directive
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { "-- @connection " .. conn_name })
      found = true
      break
    end
    -- Stop searching after first ### marker
    if line:match("^%s*###") then break end
  end

  if not found then
    -- Insert at the top of the file (before first ### or at line 1)
    local insert_line = 1
    for i, line in ipairs(lines) do
      if line:match("^%s*###") then
        insert_line = i
        break
      end
      insert_line = i + 1
    end
    vim.api.nvim_buf_set_lines(buf, insert_line - 1, insert_line - 1, false, {
      "-- @connection " .. conn_name,
      "",
    })
  end

  vim.notify(string.format("Connection set to: %s", conn_name), vim.log.levels.INFO)
end

---------------------------------------------------------------------------
-- Test connection
---------------------------------------------------------------------------

--- Test a connection by name.
function M.test_connection()
  M.list_connections(function(connections)
    if #connections == 0 then
      vim.notify("No connections found.", vim.log.levels.WARN)
      return
    end

    local items = {}
    for _, conn in ipairs(connections) do
      table.insert(items, format_connection(conn))
    end

    select_mod.select(items, "Test Connection", function(selected)
      if not selected then return end

      for i, item in ipairs(items) do
        if item == selected then
          local conn = connections[i]
          M.run_test(conn)
          break
        end
      end
    end)
  end)
end

--- Run the test for a specific connection.
function M.run_test(conn)
  local search_dir = get_search_dir()
  local cmd = { "connection", "test", conn.name, "--path", search_dir }

  vim.notify(string.format("Testing '%s'...", conn.name), vim.log.levels.INFO)

  cli.run_async(cmd, {
    on_exit = function(code)
      vim.schedule(function()
        if code == 0 then
          vim.notify(string.format("✓ Connection '%s' OK", conn.name), vim.log.levels.INFO)
        else
          vim.notify(string.format("✗ Connection '%s' FAILED", conn.name), vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

---------------------------------------------------------------------------
-- Main entry point
---------------------------------------------------------------------------

--- Show the connection management menu.
function M.show_menu()
  local items = {
    "Select connection",
    "Test connection",
  }

  select_mod.select(items, "Connection Manager", function(selected)
    if selected == "Select connection" then
      M.select_connection()
    elseif selected == "Test connection" then
      M.test_connection()
    end
  end)
end

return M
