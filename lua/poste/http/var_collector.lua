--- Variable collection for HTTP completion.
--- Merges file-level, request-level, environment, and magic variables.

local M = {}

local cache = require("poste.http.cache")

--- Collect all variables available at a given position.
--- Merges file-level, request-level, environment, and magic variables.
--- @param buf number  Buffer number
--- @param cursor_line number  Cursor line number (1-indexed)
--- @return table  All available variable names as keys with value `true`
function M.collect_all_vars(buf, cursor_line)
  local vars = {}

  -- File-level variables (from @var = syntax before first ###)
  for k, _ in pairs(cache.collect_file_vars(buf)) do
    vars[k] = true
  end

  -- Request-level variables (current request block only)
  for k, _ in pairs(cache.collect_request_vars(buf, cursor_line)) do
    vars[k] = true
  end

  -- Environment variables (from env.json)
  for k, _ in pairs(cache.collect_env_vars()) do
    vars[k] = true
  end

  return vars
end

--- Get magic variable definitions.
--- @return table  Magic variable definitions with name, description, and value
function M.collect_magic_vars()
  local data = require("poste.http.data")
  return data.magic_var_defs or {}
end

return M
