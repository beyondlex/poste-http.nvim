--- Shared mutable state for the Poste plugin.
--- All modules require this to read/write cross-cutting state.
local M = {}

---------------------------------------------------------------------------
-- Configuration (defaults; replaced wholesale in setup via vim.tbl_deep_extend)
---------------------------------------------------------------------------
M.config = {
  poste_binary = vim.fn.exepath("poste"),
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
M.current_view = "body"          -- "body" | "headers" | "verbose" | "assertions"

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
