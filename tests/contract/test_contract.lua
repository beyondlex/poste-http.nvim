--- Contract tests for Rust→Lua JSON shapes.
---
--- These tests ensure that every JSON shape consumed by Lua code
--- matches the expected field structure. If a Rust-side struct adds,
--- removes, or renames a field, the corresponding fixture must be updated.
---
--- See docs/dev/refactoring-plan.md (Phase 0: F4) for context.
local path_sep = package.config:sub(1, 1)
local fixture_dir = vim.fn.fnamemodify("tests/contract/fixtures", ":p")

local function load_fixture(name)
  local path = fixture_dir .. name
  local fd = io.open(path, "r")
  if not fd then
    error("Fixture not found: " .. path)
  end
  local content = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok then
    error("Failed to decode fixture " .. name .. ": " .. tostring(data))
  end
  return data
end

describe("contract: http-run-response", function()
  local r = load_fixture("http-run-response.json")

  it("has top-level protocol field", function()
    assert.equal("http", r.protocol)
  end)

  it("has numeric status code", function()
    assert.is_true(type(r.status) == "number")
    assert.equal(200, r.status)
  end)

  it("has status_text string", function()
    assert.is_true(type(r.status_text) == "string")
    assert.equal("200 OK", r.status_text)
  end)

  it("has latency_ms as number", function()
    assert.is_true(type(r.latency_ms) == "number")
    assert.is_true(r.latency_ms >= 0)
  end)

  it("has url string", function()
    assert.is_true(type(r.url) == "string")
    assert.is_true(#r.url > 0)
  end)

  it("has content_type string", function()
    assert.is_true(type(r.content_type) == "string")
    assert.equal("application/json; charset=utf-8", r.content_type)
  end)

  it("has headers as array of [key, value] pairs", function()
    assert.is_true(type(r.headers) == "table")
    assert.is_true(#r.headers >= 1)
    for _, pair in ipairs(r.headers) do
      assert.is_true(type(pair) == "table")
      assert.is_true(type(pair[1]) == "string") -- key
      assert.is_true(type(pair[2]) == "string") -- value
    end
  end)

  it("has body string", function()
    assert.is_true(type(r.body) == "string")
  end)

  it("has cookies array", function()
    assert.is_true(type(r.cookies) == "table")
    for _, cookie in ipairs(r.cookies) do
      assert.is_true(type(cookie.name) == "string")
      assert.is_true(type(cookie.value) == "string")
      assert.is_true(type(cookie.domain) == "string")
      assert.is_true(type(cookie.path) == "string")
      assert.is_true(type(cookie.http_only) == "boolean")
      assert.is_true(type(cookie.secure) == "boolean")
      if cookie.expires then
        assert.is_true(type(cookie.expires) == "string")
      end
    end
  end)

  it("has metadata table", function()
    assert.is_true(type(r.metadata) == "table")
    -- metadata is a map (string -> string)
    for k, v in pairs(r.metadata) do
      assert.is_true(type(k) == "string")
      assert.is_true(type(v) == "string")
    end
  end)

  it("body can be decoded as JSON", function()
    local ok, json = pcall(vim.json.decode, r.body)
    assert.is_true(ok, "response body should be valid JSON: " .. tostring(json))
    assert.is_true(type(json) == "table")
    assert.equal(1, json.id)
    assert.equal(1, json.userId)
  end)
end)

describe("contract: context-detect", function()
  local d = load_fixture("context-detect.json")

  it("has version field", function()
    assert.equal(1, d.version)
  end)

  it("has ctx_type string", function()
    assert.is_true(type(d.ctx_type) == "string")
    assert.equal("table", d.ctx_type)
  end)

  it("has ctx_data (nullable string)", function()
    assert.is_true(d.ctx_data == nil or d.ctx_data == vim.NIL or type(d.ctx_data) == "string")
    assert.equal("users", d.ctx_data)
  end)

  it("has ctx_schema (nullable string)", function()
    -- JSON null decodes to vim.NIL in Lua
    assert.is_true(d.ctx_schema == nil or d.ctx_schema == vim.NIL or type(d.ctx_schema) == "string")
  end)

  it("has prefix string", function()
    assert.is_true(type(d.prefix) == "string")
    assert.equal("SELECT * FROM ", d.prefix)
  end)

  it("has tables array", function()
    assert.is_true(type(d.tables) == "table")
    for _, t in ipairs(d.tables) do
      assert.is_true(type(t.name) == "string")
      -- JSON null decodes to vim.NIL in Lua
      assert.is_true(t.alias == nil or t.alias == vim.NIL or type(t.alias) == "string")
      assert.is_true(t.schema == nil or t.schema == vim.NIL or type(t.schema) == "string")
    end
  end)

  it("has functions array of strings", function()
    assert.is_true(type(d.functions) == "table")
    if #d.functions > 0 then
      assert.is_true(type(d.functions[1]) == "string")
    end
  end)

  it("has in_string / in_comment booleans", function()
    assert.is_true(type(d.in_string) == "boolean")
    assert.is_true(type(d.in_comment) == "boolean")
  end)
end)

describe("contract: context-stmt", function()
  local s = load_fixture("context-stmt.json")

  it("has start_line and end_line as numbers", function()
    assert.is_true(type(s.start_line) == "number")
    assert.is_true(type(s.end_line) == "number")
    assert.equal(5, s.start_line)
    assert.equal(12, s.end_line)
  end)
end)

describe("contract: context-stmt-ranges", function()
  local ranges = load_fixture("context-stmt-ranges.json")

  it("is an array of range objects", function()
    assert.is_true(type(ranges) == "table")
    assert.is_true(#ranges >= 1)
    for _, r in ipairs(ranges) do
      assert.is_true(type(r.start_line) == "number")
      assert.is_true(type(r.end_line) == "number")
      assert.is_true(r.start_line <= r.end_line)
    end
  end)

  it("has expected number of ranges", function()
    assert.equal(3, #ranges)
  end)
end)