--- Tests for the orchestration module: typed response wrapping and the
--- coroutine-driven client.run() sandbox used by SCRIPT blocks.
local orchestration = require("poste-http.http.orchestration")
local import = require("poste-http.http.import")

local function run(code, opts)
  local result
  orchestration.run_script(code, opts or {}, function(r)
    result = r
  end)
  assert.is_not_nil(result, "run_script must call on_complete")
  return result
end

describe("orchestration.build_response", function()
  it("exposes status and metadata fields from the raw response", function()
    local resp = orchestration.build_response({
      status = 201,
      status_text = "Created",
      url = "https://api.example.com/users",
      latency_ms = 12,
      content_type = "application/json",
      cookies = { "a=1" },
      metadata = { env = "dev" },
    })
    assert.are_equal(201, resp.status)
    assert.are_equal("Created", resp.status_text)
    assert.are_equal("https://api.example.com/users", resp.url)
    assert.are_equal(12, resp.latency_ms)
    assert.are_equal("application/json", resp.content_type)
    assert.same({ "a=1" }, resp.cookies)
    assert.are_equal("dev", resp.metadata.env)
  end)

  it("provides case-insensitive header access", function()
    local resp = orchestration.build_response({
      headers = { { "Content-Type", "application/json" }, { "X-Token", "abc" } },
    })
    assert.are_equal("application/json", resp.headers["content-type"])
    assert.are_equal("application/json", resp.headers["Content-Type"])
    assert.are_equal("abc", resp.headers["x-token"])
  end)

  it("lazily decodes a JSON body into a table", function()
    local resp = orchestration.build_response({
      status = 200,
      body = '{"token": "t1", "user": {"id": 7}}',
    })
    assert.are_equal("t1", resp.body.token)
    assert.are_equal(7, resp.body.user.id)
  end)

  it("keeps a non-JSON body as a string", function()
    local resp = orchestration.build_response({ status = 200, body = "plain text" })
    assert.are_equal("plain text", resp.body)
  end)
end)

describe("orchestration.run_script", function()
  local orig_execute

  before_each(function()
    package.loaded["poste-http.http.import"] = nil
    package.loaded["poste-http.http.orchestration"] = nil
    import = require("poste-http.http.import")
    orchestration = require("poste-http.http.orchestration")
    orig_execute = import.execute_request_reference
  end)

  after_each(function()
    import.execute_request_reference = orig_execute
    package.loaded["poste-http.http.orchestration"] = nil
    package.loaded["poste-http.http.import"] = nil
  end)

  it("runs a script without client.run", function()
    local result = run("local x = 1 + 1", {})
    assert.is_nil(result.error)
    assert.same({}, result.calls)
  end)

  it("collects client.log and print output", function()
    local result = run([[
client.log("hello")
print("world", 42)
]])
    assert.is_nil(result.error)
    assert.are_equal("hello", result.logs[1])
    assert.are_equal("world\t42", result.logs[2])
  end)

  it("shares the tightened sandbox stdlib: md5 available, io/os.execute not", function()
    local result = run([[
client.log(md5("abc"))
assert(io == nil, "io leaked into the orchestration sandbox")
assert(os.execute == nil, "os.execute leaked into the orchestration sandbox")
assert(os.date ~= nil and os.time ~= nil and os.clock ~= nil and os.getenv ~= nil,
  "curated os members missing")
]])
    assert.is_nil(result.error)
    assert.are_equal("900150983cd24fb0d6963f7d28e17f72", result.logs[1])
  end)

  it("executes a single client.run call and returns a typed response", function()
    local captured_target, captured_args
    import.execute_request_reference = function(target, args, _, callback)
      captured_target, captured_args = target, args
      callback(true, {
        status = 200,
        body = '{"token": "abc"}',
        headers = {},
      }, "login")
    end

    local result = run([[
local r = client.run("#alias.login", { username = "u" })
assert(r.status == 200, "login status")
client.log(r.body.token)
]])

    assert.is_nil(result.error)
    assert.are_equal("#alias.login", captured_target)
    assert.are_equal("u", captured_args.username)
    assert.are_equal(1, #result.calls)
    assert.are_equal("login", result.calls[1].name)
    assert.are_equal(200, result.calls[1].response.status)
    assert.are_equal("abc", result.logs[1])
  end)

  it("passes values from one response into the next call", function()
    local second_args
    local call = 0
    import.execute_request_reference = function(target, args, _, callback)
      call = call + 1
      if call == 1 then
        callback(true, { status = 200, body = '{"token": "t1"}', headers = {} }, "login")
      else
        second_args = args
        callback(true, { status = 200, body = '{"name": "lex"}', headers = {} }, "get_profile")
      end
    end

    local result = run([[
local login = client.run("#alias.login", {})
local profile = client.run("#alias.get_profile", { Authorization = login.body.token })
assert(profile.body.name == "lex")
]])

    assert.is_nil(result.error)
    assert.are_equal("t1", second_args.Authorization)
    assert.are_equal(2, #result.calls)
  end)

  it("aborts on a failed assert with the message", function()
    local result = run('assert(false, "boom")')
    assert.matches("boom", result.error)
  end)

  it("supports client.assert and client.test like assertion blocks", function()
    local result = run([[
client.test("flow", function()
  client.assert(true, "ok")
end)
]])
    assert.is_nil(result.error)
  end)

  it("reports a failed client.test as a script error", function()
    local result = run([[
client.test("flow", function()
  client.assert(false, "step failed")
end)
]])
    assert.matches("step failed", result.error)
    assert.matches("flow", result.error)
  end)

  it("reports a client.run failure as a script error", function()
    import.execute_request_reference = function(target, _, _, callback)
      callback(false, nil, nil, "Request 'nope' not found in imports")
    end

    local result = run('client.run("#alias.nope", {})')
    assert.matches("#alias.nope", result.error)
  end)

  it("reports syntax errors", function()
    local result = run("this is not lua {{{", {})
    assert.matches("Syntax error", result.error)
  end)

  it("exposes opts.response to keep assertion-style scripts working", function()
    local result = run('assert(response.status == 200, "synthetic ok")', {
      response = { status = 200 },
    })
    assert.is_nil(result.error)
  end)

  it("client.global.set/get stores and retrieves global variables", function()
    local result = run([[
client.global.set("token", "abc123")
local v = client.global.get("token")
assert(v == "abc123", "global var should be retrievable")
]])
    assert.is_nil(result.error)
  end)

  it("client.global.header.set/get/remove/clear works", function()
    local result = run([[
client.global.header.set("X-Custom", "val1")
local v = client.global.header.get("X-Custom")
assert(v == "val1", "global header should be retrievable")
client.global.header.remove("X-Custom")
local v2 = client.global.header.get("X-Custom")
assert(v2 == nil, "removed header should be nil")
]])
    assert.is_nil(result.error)
  end)
end)
