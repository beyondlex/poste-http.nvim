--- SQL execution context management.
--- Handles connection → database context resolution and status display.
local state = require("poste.state")
local select_mod = require("poste.select")

local M = {}

---------------------------------------------------------------------------
-- Context resolution
---------------------------------------------------------------------------

--- Resolve the SQL execution context from the current buffer.
--- Scans file header for @connection/@database directives, then scans
--- ALL lines from file start up to the cursor for USE statements.
--- The last USE statement before the cursor wins (JetBrains behavior).
--- @param buf number Buffer handle (default: current buffer)
--- @return table context { connection = string|nil, database = string|nil }
function M.resolve_context(buf, limit_line)
  buf = buf or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cursor_line = limit_line or vim.fn.line(".")

  -- Phase 1: Scan file header (before first ###) for global defaults
  local connection = nil
  local database = nil

  for i, line in ipairs(lines) do
    if line:match("^%s*###") then break end
    local conn_match = line:match("^%s*--%s*@connection%s+(.+)")
    if conn_match then connection = vim.trim(conn_match) end
    local db_match = line:match("^%s*--%s*@database%s+(.+)")
    if db_match then database = vim.trim(db_match) end
  end

  -- Phase 2: Scan ALL lines from top to cursor for USE statements and
  -- block-level @connection/@database overrides. Last one wins.
  for i = 1, cursor_line do
    local line = lines[i]
    if not line then break end

    -- Block-level directive override
    local conn_match = line:match("^%s*--%s*@connection%s+(.+)")
    if conn_match then connection = vim.trim(conn_match) end
    local db_match = line:match("^%s*--%s*@database%s+(.+)")
    if db_match then database = vim.trim(db_match) end

    -- USE statement: last one before cursor wins
    local use_match = line:match("^%s*[Uu][Ss][Ee]%s+(%S+)")
    if use_match then
      database = use_match:gsub(";$", ""):gsub("^['\"`]", ""):gsub("['\"`]$", "")
    end
  end

  return { connection = connection, database = database }
end

--- Resolve the full context chain: buffer scan → connections.json default.
--- Priority: block-level > USE > file-level > runtime connection > connections.json default
--- Does NOT fall back to state.sql.context.database — context is position-determined.
--- @param buf number Buffer handle (default: current buffer)
--- @return table context { connection = string|nil, database = string|nil }
function M.resolve_full_context(buf, limit_line)
  buf = buf or vim.api.nvim_get_current_buf()

  local ctx = M.resolve_context(buf, limit_line)

  -- Fallback to runtime state for connection (from :PosteSQLContext or manual set)
  local conn = ctx.connection or state.sql.context.connection

  -- Database: buffer scan → connections.json default
  local db = ctx.database
  if not db and conn then
    local connections = require("poste.sql.connections")
    local config = connections.get_connection_config(conn)
    if config and config.database and config.database ~= "" then
      db = config.database
    end
  end

  return { connection = conn, database = db, raw = ctx }
end

--- Update context from a SQL response (e.g., USE statement).
--- @param response table Parsed response object
function M.handle_use_statement(response)
  if not response or not response.body then return end

  local ok, body = pcall(vim.json.decode, response.body)
  if not ok or type(body) ~= "table" then return end

  if body.type == "use" and body.database_name then
    state.sql.context.database = body.database_name
    state.log("INFO", "SQL context database updated: " .. body.database_name)
  end
end

--- Get status text for the statusline.
--- @return string Status text like "[db: conn/database]"
function M.get_status_text()
  local ctx = state.sql.context
  local conn = ctx.connection
  local db = ctx.database

  if not conn and not db then
    return ""
  end

  if conn and db then
    return string.format("[db: %s/%s]", conn, db)
  elseif conn then
    return string.format("[db: %s]", conn)
  else
    return string.format("[db: ?/%s]", db)
  end
end

--- Get status text for cursor position in a SQL buffer.
--- Resolves context at cursor line: @connection → @database/USE → connections.json default.
--- @param buf number|nil Buffer handle (default: current buffer)
--- @return string Status text like "[my-blog/inventory]" or ""
function M.get_cursor_status_text(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ctx = M.resolve_full_context(buf)
  if not ctx.connection then return "" end
  if ctx.database then
    return string.format("[%s/%s]", ctx.connection, ctx.database)
  end
  return string.format("[%s]", ctx.connection)
end

---------------------------------------------------------------------------
-- Context switching command
---------------------------------------------------------------------------

--- Switch SQL context interactively.
--- Usage:
---   :PosteSQLContext              — interactive: pick connection, then database
---   :PosteSQLContext <conn>       — set connection only
---   :PosteSQLContext <conn> <db>  — set connection and database
function M.switch_context(args)
  if args and #args >= 1 then
    -- Direct argument mode
    state.sql.context.connection = args[1]
    if #args >= 2 then
      state.sql.context.database = args[2]
    end
    vim.notify(string.format("Context: %s", M.get_status_text()), vim.log.levels.INFO)
    return
  end

  -- Interactive mode: list connections, then let user pick
  local connections = require("poste.sql.connections")
  connections.list_connections(function(conn_list)
    if #conn_list == 0 then
      vim.notify("No connections found. Create a connections.json file.", vim.log.levels.WARN)
      return
    end

    local items = {}
    for _, conn in ipairs(conn_list) do
      local icon = ({ postgres = "🐘", mysql = "🐬", sqlite = "📦" })[conn.dialect] or "❓"
      table.insert(items, string.format("%s %s", icon, conn.name))
    end

    select_mod.select(items, "Select Connection", function(selected)
      if not selected then return end

      -- Extract connection name
      local conn_name = selected:match("^[^%s]+%s+(.+)")
      if not conn_name then return end

      state.sql.context.connection = conn_name
      vim.notify(string.format("Context connection: %s", conn_name), vim.log.levels.INFO)
    end)
  end)
end

return M
