--- Shared mutable state for the Poste plugin.
--- All modules require this to read/write cross-cutting state.
local M = {}

---------------------------------------------------------------------------
-- Configuration (defaults; replaced wholesale in setup via vim.tbl_deep_extend)
---------------------------------------------------------------------------
M.config = {
  poste_binary = vim.fn.stdpath("data") .. "/poste/bin/poste",
  default_env = "dev",
  split_direction = "vertical",
  split_size = 80,
  log_file = vim.fn.stdpath("cache") .. "/poste.log",
}

---------------------------------------------------------------------------
-- Cross-cutting mutable state
---------------------------------------------------------------------------
M.current_env = M.config.default_env
M.last_response = nil            -- parsed JSON table from --json output
M.last_assertion_results = nil   -- { tests, logs, total, passed, failed }
M.last_script_logs = nil         -- { "log line 1", "log line 2", ... } from pre/post scripts
M.current_view = "body"          -- "body" | "headers" | "verbose" | "assertions" | "script_logs"

-- Script variable stores
M.global_vars = {}               -- client.global.set/get persistence (session-scoped)
M.script_variables = {}          -- request.variables from post-scripts (available to next request)

---------------------------------------------------------------------------
-- SQL-specific state (isolated from HTTP/Redis)
---------------------------------------------------------------------------
M.sql = {
  context = {
    connection = nil,   -- current connection string or name
    database = nil,     -- current database (set by USE statement or @database)
  },
  last_dataset = nil,   -- last parsed dataset JSON for cell navigation
  pagination = {},      -- { page, page_size, total_rows, original_query }
  cell = {              -- current cell position in dataset buffer
    row = 1,
    col = 1,
  },
  highlight_cell = true, -- toggle: extmark on current cell
  _hide_header_float = false, -- toggle: suppress float header window
  _hide_row_numbers = false,  -- toggle: suppress row number column highlight
  _trace = false,        -- toggle: perf tracing for h/j/k/l navigation
  db_browser = {        -- Phase 3: database structure browser
    connection = nil,   -- current connection name being browsed
  },
}

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------
function M.log(level, msg)
  if not M.config.log_file or M.config.log_file == "" then return end
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local line = string.format("[%s] [%s] %s\n", ts, level, msg)
  local f = io.open(M.config.log_file, "a")
  if f then
    f:write(line)
    f:close()
  end
end

return M
