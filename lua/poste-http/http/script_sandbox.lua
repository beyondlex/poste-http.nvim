--- Shared sandbox environment builder and script-API helpers.
---
--- Pre-scripts (`scripts.run_pre_script`), assertion scripts
--- (`assertions.run_assertions`), and orchestration scripts each execute user
--- Lua in a restricted environment that exposes only a whitelisted set of
--- standard libraries plus injected API objects. The whitelist + globals
--- assembly used to be duplicated in every runner; this is the single builder.
local M = {}

local state = require("poste-http.state")
local md5 = require("poste-http.http.md5").md5

--- Coerce a script `set()` value (client.global / request.variables /
--- client.global.header) into the string that gets stored.
---
--- Returns nil — after warning — when the script extracted nothing, and the
--- caller then leaves the previous value alone. Blindly `tostring`-ing nil
--- stored the literal "nil", so a request that failed with an unexpected body
--- (a 4xx/5xx error page, a renamed field) silently replaced a good session
--- variable, and the next request went out as e.g. `Authorization: Bearer nil`.
--- `false` and `0` are values, not absent values, and still get stored.
--- @param label string  the script-facing call, for the warning
--- @param name string
--- @param value any
--- @return string|nil
function M.coerce_set_value(label, name, value)
  if value == nil then
    state.log("WARN", string.format(
      "%s('%s') got nil — previous value kept. Guard the extraction"
      .. " (`if response.status < 400 then …`) to clear it on purpose.",
      label, tostring(name)))
    return nil
  end
  return tostring(value)
end

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

--- Read-only view over a standard-library table: reads fall through to the
--- real library, writes raise (the runner's pcall surfaces it as a script
--- failure). The sandbox hands out THE process-wide library tables — a
--- script evaluating `string.format = junk` or `os.time = function() return
--- 0 end` used to poison them for the whole nvim session and every later
--- script in it. Reads keep working (`string.format(...)`, `os.time`), so
--- no correct script changes behavior; `pairs(lib)` iterates nothing
--- (libraries are not enumerable through the view), which nothing in the
--- documented script API relies on.
local function readonly_lib(lib)
  return setmetatable({}, {
    __index = lib,
    __newindex = function()
      error("sandbox: standard libraries are read-only", 2)
    end,
  })
end

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
    string = readonly_lib(string),
    table = readonly_lib(table),
    math = readonly_lib(math),
    os = readonly_lib(sandbox_os),
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