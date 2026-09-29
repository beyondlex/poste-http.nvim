--- Tests for the shared sandbox environment builder.
--- Both scripts.run_pre_script and assertions.run_assertions build the same
--- whitelisted stdlib env; only the injected API objects differ.
local script_sandbox = require("poste-http.http.script_sandbox")

describe("script_sandbox.build_sandbox_env", function()
  it("exposes the whitelisted standard library functions", function()
    local env = script_sandbox.build_sandbox_env({ request = {}, client = {} })
    assert.is_function(env.error)
    assert.is_function(env.pcall)
    assert.is_function(env.tostring)
    assert.is_function(env.tonumber)
    assert.is_function(env.next)
    assert.is_function(env.type)
    assert.is_function(env.ipairs)
    assert.is_function(env.pairs)
    assert.is_function(env.md5)
    assert.is_table(env.string)
    assert.is_table(env.table)
    assert.is_table(env.math)
    assert.is_table(env.os)
  end)

  it("exposes only the curated os members (no shell/filesystem/exit)", function()
    local env = script_sandbox.build_sandbox_env({ request = {}, client = {} })
    assert.is_function(env.os.date)
    assert.is_function(env.os.time)
    assert.is_function(env.os.clock)
    assert.is_function(env.os.getenv)
    assert.is_nil(env.os.execute)
    assert.is_nil(env.os.exit)
    assert.is_nil(env.os.remove)
    assert.is_nil(env.os.rename)
    assert.is_nil(env.os.tmpname)
  end)

  it("does not expose io at all", function()
    local env = script_sandbox.build_sandbox_env({ request = {}, client = {} })
    assert.is_nil(env.io)
    local chunk = load("return io ~= nil", "t", "t", env)
    assert.is_false(chunk())
  end)

  it("exposes non-whitelisted globals as never-defined (restricted env)", function()
    local env = script_sandbox.build_sandbox_env({ request = {}, client = {} })
    local chunk = load("return print", "t", "t", env)
    local res = chunk()
    assert.is_nil(res)
  end)

  it("threads request, client, variables, and env through", function()
    local variables = { foo = "bar" }
    local env_vars = { BASE = "https://x" }
    local env = script_sandbox.build_sandbox_env({
      request = { marker = "req" },
      client = { marker = "client" },
      variables = variables,
      env = env_vars,
    })
    assert.equals("req", env.request.marker)
    assert.equals("client", env.client.marker)
    assert.equals("bar", env.variables.foo)
    assert.equals("https://x", env.env.BASE)
  end)

  it("sets response only when provided", function()
    local plain = script_sandbox.build_sandbox_env({ request = {}, client = {} })
    assert.is_nil(plain.response)

    local with_resp = script_sandbox.build_sandbox_env({
      request = {},
      client = {},
      response = { status = 200 },
    })
    assert.equals(200, with_resp.response.status)
  end)

  it("sets assert only when provided", function()
    local plain = script_sandbox.build_sandbox_env({ request = {}, client = {} })
    assert.is_nil(plain.assert)

    local fn = function() end
    local with_assert = script_sandbox.build_sandbox_env({ request = {}, client = {}, assert = fn })
    assert.equals(fn, with_assert.assert)
  end)

  it("produces an env whose sandboxed code runs through load", function()
    local env = script_sandbox.build_sandbox_env({
      request = { variables = { set = function() end } },
      client = {},
      variables = { n = 41 },
      env = {},
    })
    local chunk = load("return math.floor(tonumber(variables.n) + 1) .. string.upper('ok')", "t", "t", env)
    assert.equals("42OK", chunk())
  end)

  it("std-lib writes raise instead of poisoning the process-wide libraries", function()
    -- Regression: string/table/math/os were handed out as THE process-wide
    -- tables — `string.format = junk` inside one shared .http script
    -- corrupted the whole nvim session (and every later script) until
    -- restart. Writes now raise (the runner's pcall shows it as a script
    -- failure) and the real libraries stay untouched.
    local env = script_sandbox.build_sandbox_env({ request = {}, client = {} })
    local ok, err = pcall(load([[
      string.format = function() return "poisoned" end
    ]], "t", "t", env))
    assert.is_false(ok)
    assert.match("read%-only", tostring(err))
    -- the process-wide library is untouched
    assert.equals("not-poisoned", string.format("not-%s", "poisoned"))
    -- curated os writes are blocked too
    local ok_os, err_os = pcall(load([[
      os.time = function() return 0 end
    ]], "t", "t", env))
    assert.is_false(ok_os)
    assert.match("read%-only", tostring(err_os))
    assert.is_true(os.time() > 0, "real os.time untouched")
  end)

  it("std-lib reads keep working through the read-only view", function()
    local env = script_sandbox.build_sandbox_env({ request = {}, client = {} })
    local chunk = load([[
      local hex = string.format("%02x", 255)
      local joined = table.concat({ "a", "b" }, "-")
      local biggest = math.max(1, 2)
      local now = os.time()
      return hex == "ff" and joined == "a-b" and biggest == 2 and type(now) == "number"
    ]], "t", "t", env)
    assert.is_true(chunk())
  end)
end)

describe("run_pre_script / run_assertions still execute via the shared env", function()
  it("run_pre_script executes sandboxed code with script variables", function()
    local scripts = require("poste-http.http.scripts")
    local result = scripts.run_pre_script("request.variables.set('a', tonumber(variables.x) + 1)", {
      variables = { x = "2" },
      env = {},
    })
    assert.is_nil(result.error)
    assert.equals("3", result.variables.a)
  end)

  it("run_assertions executes sandboxed code with response and assert", function()
    local assertions = require("poste-http.http.assertions")
    local results = assertions.run_assertions(
      { status = 200, headers = {}, body = vim.json.encode({ ok = true }) },
      "client.test('t', function() assert(response.status == 200) end)",
      { variables = {}, env = {} }
    )
    assert.is_nil(results.error)
    assert.equals(1, results.passed)
  end)
end)