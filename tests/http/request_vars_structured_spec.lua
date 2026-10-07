--- Tests for structured prompt options (name|key|description tuples)
--- and dynamic jq-style mapping.
---
--- The parsing helpers live in the jq_mapping module; tests call its public API.

local jq_mapping = require("poste-http.http.jq_mapping")

local parse_structured_options = jq_mapping.parse_structured_options
local parse_dynamic_mapping   = jq_mapping.parse_dynamic_mapping
local apply_jq_mapping        = jq_mapping.apply_jq_mapping

describe("parse_structured_options", function()
  -----------------------------------------------------------------------
  -- Simple strings (backward compatible)
  -----------------------------------------------------------------------
  it("parses simple string options", function()
    local result = parse_structured_options("GET, POST, PUT")
    assert.equals(3, #result)
    assert.equals("GET", result[1].name)
    assert.equals("GET", result[1].key)
    assert.equals("", result[1].description)
    assert.equals("POST", result[2].name)
    assert.equals("PUT", result[3].name)
  end)

  it("handles single option without comma", function()
    local result = parse_structured_options("GET")
    assert.equals(1, #result)
    assert.equals("GET", result[1].name)
    assert.equals("GET", result[1].key)
  end)

  -----------------------------------------------------------------------
  -- 2-field tuples (name|key)
  -----------------------------------------------------------------------
  it("parses 2-field tuples with pipe", function()
    local result = parse_structured_options("GET|get, POST|post")
    assert.equals(2, #result)
    assert.equals("GET", result[1].name)
    assert.equals("get", result[1].key)
    assert.equals("", result[1].description)
    assert.equals("POST", result[2].name)
    assert.equals("post", result[2].key)
  end)

  it("trims whitespace around name/key in tuples", function()
    local result = parse_structured_options("GET | get, POST|post")
    assert.equals("GET", result[1].name)
    assert.equals("get", result[1].key)
  end)

  -----------------------------------------------------------------------
  -- 3-field tuples (name|key|description)
  -----------------------------------------------------------------------
  it("parses 3-field tuples with pipe", function()
    local result = parse_structured_options("GET|get|This is GET, POST|post|This is POST")
    assert.equals(2, #result)
    assert.equals("GET", result[1].name)
    assert.equals("get", result[1].key)
    assert.equals("This is GET", result[1].description)
    assert.equals("POST", result[2].name)
    assert.equals("post", result[2].key)
    assert.equals("This is POST", result[2].description)
  end)

  it("handles pipe in description", function()
    local result = parse_structured_options("A|a|desc with | pipe")
    assert.equals(1, #result)
    assert.equals("A", result[1].name)
    assert.equals("a", result[1].key)
    assert.equals("desc with | pipe", result[1].description)
  end)

  it("handles empty description", function()
    local result = parse_structured_options("GET|get|")
    assert.equals(1, #result)
    assert.equals("GET", result[1].name)
    assert.equals("get", result[1].key)
    assert.equals("", result[1].description)
  end)

  -----------------------------------------------------------------------
  -- Edge cases
  -----------------------------------------------------------------------
  it("handles trailing comma gracefully", function()
    local result = parse_structured_options("GET, ")
    assert.equals(1, #result)
    assert.equals("GET", result[1].name)
  end)

  it("handles empty string", function()
    local result = parse_structured_options("")
    assert.equals(0, #result)
  end)
end)

describe("parse_dynamic_mapping", function()
  it("parses simple response ref without mapping", function()
    local ref, mapping = parse_dynamic_mapping("{{RequestName.response.body}}")
    assert.equals("RequestName.response.body", ref)
    assert.is_nil(mapping)
  end)

  it("parses response ref with pipe and structured mapping", function()
    local ref, mapping = parse_dynamic_mapping("{{Req.response.body | {name: .[].login, key: .[].id} }}")
    assert.equals("Req.response.body", ref)
    assert.equals(".[].login", mapping.name)
    assert.equals(".[].id", mapping.key)
    assert.is_nil(mapping.description)
  end)

  it("parses mapping with nested paths", function()
    local ref, mapping = parse_dynamic_mapping("{{Req.resp.body | {name: .[].author.name, key: .[].author.email, desc: .[].author.bio} }}")
    assert.equals("Req.resp.body", ref)
    assert.equals(".[].author.name", mapping.name)
    assert.equals(".[].author.email", mapping.key)
    assert.equals(".[].author.bio", mapping.description)
  end)

  it("parses mapping with full 'description' field name", function()
    local ref, mapping = parse_dynamic_mapping("{{Req.body | {name: .x, key: .y, description: .z} }}")
    assert.equals("Req.body", ref)
    assert.equals(".x", mapping.name)
    assert.equals(".y", mapping.key)
    assert.equals(".z", mapping.description)
  end)

  it("handles no space around pipe", function()
    local ref, mapping = parse_dynamic_mapping("{{Req.body|{name: .x, key: .y} }}")
    assert.equals("Req.body", ref)
    assert.equals(".x", mapping.name)
    assert.equals(".y", mapping.key)
  end)

  it("accepts 'desc' as alias for 'description'", function()
    local ref, mapping = parse_dynamic_mapping("{{Req.body | {name: .x, key: .y, desc: .z} }}")
    assert.equals("Req.body", ref)
    assert.equals(".x", mapping.name)
    assert.equals(".y", mapping.key)
    -- desc gets normalized to description
    assert.equals(".z", mapping.description)
  end)

  it("returns nil for non-matching string", function()
    local ref, mapping = parse_dynamic_mapping("GET|get")
    assert.is_nil(ref)
    assert.is_nil(mapping)
  end)
end)

describe("apply_jq_mapping", function()
  it("applies mapping to array of objects", function()
    local data = { { login = "alice", id = 1 }, { login = "bob", id = 2 } }
    local mapping = { name = ".[].login", key = ".[].id" }
    local result = apply_jq_mapping(data, mapping)
    assert.equals(2, #result)
    assert.equals("alice", result[1].name)
    assert.equals("1", result[1].key)
    assert.equals("bob", result[2].name)
    assert.equals("2", result[2].key)
  end)

  it("applies mapping with nested paths", function()
    local data = {
      { author = { name = "Alice", email = "a@x.com" } },
      { author = { name = "Bob", email = "b@x.com" } },
    }
    local mapping = { name = ".[].author.name", key = ".[].author.email" }
    local result = apply_jq_mapping(data, mapping)
    assert.equals(2, #result)
    assert.equals("Alice", result[1].name)
    assert.equals("a@x.com", result[1].key)
    assert.equals("Bob", result[2].name)
    assert.equals("b@x.com", result[2].key)
  end)

  it("returns empty array for empty input", function()
    local result = apply_jq_mapping({}, { name = ".[].x", key = ".[].y" })
    assert.equals(0, #result)
  end)

  it("handles single object (wraps in array)", function()
    local data = { login = "admin", id = 0 }
    local mapping = { name = ".login", key = ".id" }
    local result = apply_jq_mapping(data, mapping)
    assert.equals(1, #result)
    assert.equals("admin", result[1].name)
    assert.equals("0", result[1].key)
  end)

  it("includes description when mapped", function()
    local data = { { n = "A", k = "a", d = "desc A" } }
    local mapping = { name = ".[].n", key = ".[].k", description = ".[].d" }
    local result = apply_jq_mapping(data, mapping)
    assert.equals("A", result[1].name)
    assert.equals("a", result[1].key)
    assert.equals("desc A", result[1].description)
  end)

  it("handles null/missing fields gracefully", function()
    local data = { { name = "A" } }
    local mapping = { name = ".[].name", key = ".[].nonexistent" }
    local result = apply_jq_mapping(data, mapping)
    assert.equals("A", result[1].name)
    assert.equals("", result[1].key)
  end)

  it("JSON-encodes a path that lands on an object, never a table address", function()
    -- A shorthand path hitting a nested object/array used to be tostring()ed
    -- into a "table: 0x…" option label.
    local data = { { name = "A", extra = { deep = true, n = 1 } } }
    local mapping = { name = ".[].name", description = ".[].extra" }
    local result = apply_jq_mapping(data, mapping)
    assert.equals("A", result[1].name)
    assert.truthy(result[1].description:find('"deep":true', 1, true),
      "object fields JSON-encode: " .. tostring(result[1].description))
  end)

  it("tolerates non-string inputs (options string, mapping paths)", function()
    -- 2026-10-08 probe: the sibling parsers guard non-string input; these two
    -- indexed nil/numbers directly. Unreachable from today's call sites (the
    -- option text always comes from a buffer-line match), fixed for the
    -- module's own convention.
    assert.equals(0, #parse_structured_options(nil))
    assert.equals(0, #parse_structured_options(42))
    assert.equals(0, #apply_jq_mapping({ a = 1 }, { name = nil, key = 5 }))
  end)
end)
