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

describe("format_assertions shape drift", function()
  -- The assertions tab also renders HISTORY entries, whose shape comes from
  -- persisted JSON (hand-editable, written by older versions). A drifted
  -- results object used to raise "number expected, got nil" out of
  -- string.format mid-render instead of degrading.
  it("renders a malformed results object as a readable tab, never raises", function()
    local lines = assertions.format_assertions({ passed = "x", failed = nil, tests = "y", logs = 5 })
    assert.equals(3, #lines, table.concat(lines, "\n"))
    assert.truthy(lines[1]:match("0 passed, 0 failed"), lines[1])
    assert.truthy(lines[1]:match("✘"))
    assert.truthy(lines[3]:match("No test assertions executed"))

    lines = assertions.format_assertions({ tests = { "not-a-table", { name = "t" } } })
    assert.equals(4, #lines, table.concat(lines, "\n"))
    assert.truthy(lines[3]:match("✘ %?"), "a drifted test renders as unnamed-failed")
    assert.truthy(lines[4]:match("✓ t"))
  end)

  it("keeps the well-formed rendering byte-identical", function()
    local lines = assertions.format_assertions({
      passed = 1, failed = 1, error = "boom",
      tests = { { name = "ok one", failed = 0, errors = {} },
                { name = "bad one", failed = 1, errors = { "first", "second" } } },
      logs = { "line1", "line2" },
    })
    assert.equals("▸ Test Results: 1 passed, 1 failed  ✘", lines[1])
    assert.equals("  ✘ boom", lines[4])
    assert.truthy(lines[6]:match("✓ ok one"))
    assert.truthy(lines[7]:match("✘ bad one"))
    assert.truthy(lines[8]:match("first"))
    assert.truthy(lines[#lines - 1]:match("line1"))
    assert.truthy(lines[#lines]:match("line2"))
  end)
end)
