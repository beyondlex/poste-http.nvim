-- Regression coverage for the assertion sandbox (client.test / client.assert).
local assertions = require("poste-http.http.assertions")

describe("run_assertions client.test/client.assert", function()
  local response = { status = 500, body = "{}" }

  it("counts one failing client.assert inside a test exactly once", function()
    local result = assertions.run_assertions(response, [[
client.test("status is 200", function()
  client.assert(response.status == 200, "expected 200")
end)
]])
    assert.equals(1, result.total)
    local test = result.tests[1]
    assert.equals(1, test.failed, "one failing assert must increment failed once")
    assert.equals(1, #test.errors, "one failing assert must record one error, got: "
      .. table.concat(test.errors, " | "))
    assert.equals(1, result.failed)
  end)

  it("still records non-assert runtime errors inside a test", function()
    local result = assertions.run_assertions(response, [[
client.test("boom", function()
  error("kaboom")
end)
]])
    assert.equals(1, result.tests[1].failed)
    assert.equals(1, #result.tests[1].errors)
  end)

  it("reports per-test totals, not hardcoded zeros, on runtime errors", function()
    -- One passing test, then a top-level error: the summary must not claim
    -- the passing test failed.
    local result = assertions.run_assertions(response, [[
client.test("always passes", function()
  client.assert(true, "ok")
end)
error("top-level boom")
]])
    assert.is_not_nil(result.error)
    assert.equals(1, result.total)
    assert.equals(1, result.passed, "the passing test must be counted as passed")
    assert.equals(0, result.failed)
  end)

  it("counts every test on runtime errors (failing ones stay failing)", function()
    local result = assertions.run_assertions(response, [[
client.test("fails", function()
  client.assert(false, "nope")
end)
error("top-level boom")
]])
    assert.is_not_nil(result.error)
    assert.equals(1, result.total)
    assert.equals(0, result.passed)
    assert.equals(1, result.failed)
  end)
end)

describe("response.headers lookups", function()
  local response = {
    status = 200,
    body = "{}",
    headers = { { "Content-Type", "application/json" } },
  }

  it("resolves case-insensitively", function()
    local result = assertions.run_assertions(response, [[
client.test("header lookup", function()
  client.assert(response.headers["content-type"] == "application/json", "lowercase miss")
  client.assert(response.headers["CONTENT-TYPE"] == "application/json", "uppercase miss")
end)
]])
    assert.equals(0, result.failed, table.concat(result.tests[1].errors, " | "))
  end)

  it("returns nil (not an error) for nil and non-string keys", function()
    -- A raw table yields nil for these; the case-insensitive __index used
    -- to call k:lower() and crash on them instead.
    local result = assertions.run_assertions(response, [[
client.test("odd keys", function()
  client.assert(response.headers[nil] == nil, "nil key must be nil")
  client.assert(response.headers[42] == nil, "number key must be nil")
end)
]])
    assert.equals(0, result.failed, table.concat(result.tests[1].errors, " | "))
  end)
end)
