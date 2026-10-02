-- Regression coverage for format/util.lua JSON re-encoding and form decoding.

local fmt_util = require("poste-http.http.format.util")

describe("json_pretty string/key escaping", function()
  it("escapes double quotes inside object keys", function()
    -- The key a"b is legal JSON; re-encoding it unescaped produced
    -- invalid JSON ("a"b": 1) that broke the json treesitter parse.
    local out = fmt_util.json_pretty({ ['a"b'] = 1 })
    assert.equals('{\n  "a\\"b": 1\n}', out)
  end)

  it("escapes backslashes and control chars in keys and values", function()
    local out = fmt_util.json_pretty({ ["k\\x"] = "line1\nline2\x01" })
    assert.is_truthy(out:find('k\\\\x', 1, true), "key backslash must be escaped")
    assert.is_truthy(out:find('line1\\nline2', 1, true), "value newline must be escaped")
    assert.is_truthy(out:find('\\u0001', 1, true), "control char must become \\u0001")
  end)

  it("round-trips through vim.json.decode", function()
    local original = { ['we"ird'] = { nested = "a\1b" } }
    local out = fmt_util.json_pretty(original)
    local decoded = vim.json.decode(out)
    assert.equals("a\1b", decoded['we"ird'].nested)
  end)
end)

describe("format_urlencoded_body key decoding", function()
  it("decodes percent-escapes and plus signs in keys, not just values", function()
    local lines = fmt_util.format_urlencoded_body("user%20name=john+doe&keep%2Bid=1")
    assert.same({ "  user name: john doe", "  keep+id: 1" }, lines)
  end)
end)

describe("url_decode contract", function()
  it("returns exactly one value (no gsub substitution count)", function()
    -- A bare `return s:gsub(...)` shipped two values; harmless to the
    -- current single-assignment callers but corrupts any future caller
    -- that consumes varargs or table-constructor positions.
    assert.equals(1, select("#", fmt_util.url_decode("a%2Bb")))
  end)

  it("decodes an encoded literal plus before treating + as space", function()
    assert.equals("a+b c", fmt_util.url_decode("a%2Bb+c"))
  end)

  it("leaves malformed escapes as literal text", function()
    assert.equals("100%", fmt_util.url_decode("100%"))
    assert.equals("%ZZ", fmt_util.url_decode("%ZZ"))
  end)
end)

describe("json_pretty mixed-type keys", function()
  it("sorts mixed number/string keys without raising", function()
    -- Lua-built tables (sparse arrays, e.g. from filters) can carry number
    -- and string keys at once; a bare table.sort raised
    -- "attempt to compare number with string".
    local out = fmt_util.json_pretty({ ["b"] = 1, [1] = "x" })
    local decoded = vim.json.decode(out)
    assert.equals("x", decoded["1"])
    assert.equals(1, decoded["b"])
  end)

  it("renders a sparse array as an object without raising", function()
    local t = {}
    t[1] = "a"
    t[3] = "c"
    local out = fmt_util.json_pretty(t)
    assert.equals("a", vim.json.decode(out)["1"])
  end)
end)

describe("json_pretty non-finite numbers", function()
  it("encodes inf/nan as null instead of bare inf/nan", function()
    -- vim.json.decode hands back math.huge for 1e999; a bare "inf"/"nan"
    -- token is invalid JSON and broke every later parse of the output.
    local out = fmt_util.json_pretty({ a = math.huge, b = 0 / 0, c = -math.huge, d = 1 })
    assert.truthy(out:match('"a": null'), out)
    assert.truthy(out:match('"b": null'), out)
    assert.truthy(out:match('"c": null'), out)
    assert.truthy(out:match('"d": 1'), out)
    -- the output must survive a decode round-trip
    local ok, decoded = pcall(vim.json.decode, out)
    assert.truthy(ok, out)
    -- null decodes back to the vim.NIL sentinel, not Lua nil
    assert.equals(vim.NIL, decoded.a)
  end)
end)
