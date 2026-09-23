--- A script that extracts a field the response doesn't carry — the normal
--- shape of a failed request — must not overwrite a good value with the string
--- "nil". `{{token}}` would then expand to a literal `nil` on the wire
--- (`Authorization: Bearer nil`), which is harder to spot than an empty value.
--- The guard lives in the shared set() coercion, so it applies to every runner:
--- pre-script, post-script and orchestration (dependency and imported blocks
--- reuse those two, so they are covered by construction).
local scripts = require("poste-http.http.scripts")
local assertions = require("poste-http.http.assertions")
local orchestration = require("poste-http.http.orchestration")
local state = require("poste-http.state")

local function failed_response()
  return { status = 500, status_text = "Server Error", headers = {}, body = '{"error":"boom"}', ok = false }
end

local function run_orchestration(code)
  local result
  orchestration.run_script(code, { response = failed_response() }, function(r) result = r end)
  assert.is_not_nil(result, "run_script must call on_complete")
  return result
end

describe("script set() with a nil value", function()
  local saved_globals, saved_vars, saved_headers

  before_each(function()
    saved_globals = state.global_vars
    saved_vars = state.script_variables
    saved_headers = state.global_headers
    state.global_vars = { token = "good-token" }
    state.script_variables = { trace = "good-trace" }
    state.global_headers = { ["X-Trace"] = "good-trace" }
  end)

  after_each(function()
    state.global_vars = saved_globals
    state.script_variables = saved_vars
    state.global_headers = saved_headers
  end)

  describe("post-script (client.global / request.variables)", function()
    it("keeps the previous global when the failed response has no such field", function()
      local results = assertions.run_assertions(failed_response(),
        "client.global.set('token', response.body.token)", { variables = {}, env = {} })
      assert.is_nil(results.error)
      assert.equals("good-token", state.global_vars.token,
        'a missing field must not overwrite the global (got: ' .. tostring(state.global_vars.token) .. ")")
    end)

    it("keeps the previous request variable when the value is nil", function()
      assertions.run_assertions(failed_response(),
        "request.variables.set('trace', response.body.trace_id)", { variables = {}, env = {} })
      assert.equals("good-trace", state.script_variables.trace)
    end)

    it("keeps the previous global header when the value is nil", function()
      assertions.run_assertions(failed_response(),
        "client.global.header.set('X-Trace', response.body.trace_id)", { variables = {}, env = {} })
      assert.equals("good-trace", state.global_headers["X-Trace"])
    end)

    it("still stores a value the response does carry", function()
      assertions.run_assertions(failed_response(),
        "client.global.set('status', response.status)", { variables = {}, env = {} })
      assert.equals("500", state.global_vars.status)
    end)
  end)

  describe("pre-script", function()
    it("keeps the previous global when the extracted value is nil", function()
      local result = scripts.run_pre_script("client.global.set('token', variables.missing)",
        { variables = {}, env = {} })
      assert.is_nil(result.error)
      assert.equals("good-token", state.global_vars.token)
    end)

    it("does not record an injected variable for a nil value", function()
      local result = scripts.run_pre_script("request.variables.set('a', variables.missing)",
        { variables = {}, env = {} })
      assert.is_nil(result.error)
      assert.is_nil(result.variables.a, 'injected value must be absent, got: ' .. tostring(result.variables.a))
    end)
  end)

  describe("orchestration script", function()
    it("keeps the previous global and header when the value is nil", function()
      local result = run_orchestration([[
client.global.set('token', response.body.token)
client.global.header.set('X-Trace', response.body.trace_id)
]])
      assert.is_nil(result.error)
      assert.equals("good-token", state.global_vars.token)
      assert.equals("good-trace", state.global_headers["X-Trace"])
    end)
  end)

  -- The guard tests for nil specifically: `false` and `0` are values, not
  -- absent values, and a `if not value` shortcut would silently drop them.
  describe("falsy-but-real values", function()
    it("stores false and 0 from a post-script", function()
      assertions.run_assertions({ status = 200, headers = {}, body = '{"retry":false,"count":0}' },
        [[
client.global.set('retry', response.body.retry)
client.global.set('count', response.body.count)
]], { variables = {}, env = {} })
      assert.equals("false", state.global_vars.retry)
      assert.equals("0", state.global_vars.count)
    end)

    it("stores false and 0 from an orchestration script", function()
      run_orchestration("client.global.set('retry', false)\nclient.global.set('count', 0)")
      assert.equals("false", state.global_vars.retry)
      assert.equals("0", state.global_vars.count)
    end)
  end)
end)
