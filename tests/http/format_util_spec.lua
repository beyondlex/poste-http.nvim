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
