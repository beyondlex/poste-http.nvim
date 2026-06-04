--- SQL execution context management.
--- Handles connection → database context resolution and status display.
local state = require("poste.state")
local select_mod = require("poste.select")

local M = {}

---------------------------------------------------------------------------
-- Context resolution
---------------------------------------------------------------------------

--- Resolve the SQL execution context from the current buffer.
--- Scans file header for @connection/@database directives and
--- cursor-preceding USE statements.
--- @param buf number Buffer handle (default: current buffer)
--- @return table context { connection = string|nil, database = string|nil }
function M.resolve_context(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cursor_line = vim.fn.line(".")

  local connection = nil
  local database = nil

  for i, line in ipairs(lines) do
    -- Stop scanning after cursor position for USE statements
    -- But continue scanning @directives in file header (before first ###)

    -- @connection directive
    local conn_match = line:match("^%s*--%s*@connection%s+(.+)")
    if conn_match then
      connection = vim.trim(conn_match)
    end

    -- @database directive
    local db_match = line:match("^%s*--%s*@database%s+(.+)")
    if db_match then
      database = vim.trim(db_match)
    end

    -- USE statement before cursor
    if i <= cursor_line then
      local use_match = line:match("^%s*[Uu][Ss][Ee]%s+(%S+)")
      if use_match then
        -- Strip trailing semicolon and quotes
        database = use_match:gsub(";$", ""):gsub("^['\"`]", ""):gsub("['\"`]$", "")
      end
    end

    -- Stop scanning @directives after first ### (but continue USE up to cursor)
    if line:match("^%s*###") and i > cursor_line then
      break
    end
  end

  return {
    connection = connection,
    database = database,
  }
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
