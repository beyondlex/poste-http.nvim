--- Shared sandbox environment builder for script execution.
---
--- Pre-scripts (`scripts.run_pre_script`), assertion scripts
--- (`assertions.run_assertions`), and orchestration scripts each execute user
--- Lua in a restricted environment that exposes only a whitelisted set of
--- standard libraries plus injected API objects. The whitelist + globals
--- assembly used to be duplicated in every runner; this is the single builder.
local M = {}

local md5 = require("poste-http.http.md5").md5

--- Curated `os` for sandboxed scripts. `.http` files are shared (checked
--- into repos, imported from Postman) and their scripts run on execution,
--- so nothing here may shell out, terminate nvim, or touch the filesystem.
--- Time/clock/env reads stay available; file input is covered by `< path`
--- includes and Lua imports.
local sandbox_os = {
  date = os.date,
  time = os.time,
  clock = os.clock,
  getenv = os.getenv,
}

--- Build a sandbox environment for executing script code.
--- Exposes the whitelisted stdlibs unconditionally. `response` and `assert`
--- are only set when provided, so runners that don't support them keep them
--- hidden from the sandbox.
--- @param api table  Injected API objects:
---   request  table   exposed as `request`
---   client   table   exposed as `client`
---   variables table|nil  exposed as `variables`
---   env      table|nil  exposed as `env`
---   response table|nil  (assertions) exposed as `response` when non-nil
---   assert   function|nil  (assertions) exposed as `assert` when non-nil
--- @return table sandbox_env
function M.build_sandbox_env(api)
  local env = {
    request = api.request,
    client = api.client,
    variables = api.variables,
    env = api.env,
    error = error,
    pcall = pcall,
    tostring = tostring,
    tonumber = tonumber,
    next = next,
    type = type,
    string = string,
    table = table,
    math = math,
    os = sandbox_os,
    ipairs = ipairs,
    pairs = pairs,
    md5 = md5,
  }

  if api.response ~= nil then
    env.response = api.response
  end
  if api.assert ~= nil then
    env.assert = api.assert
  end

  return env
end

return M