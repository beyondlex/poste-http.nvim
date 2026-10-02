-- Tests for format_file: .http buffer formatting (JSON body pretty-print).
local format_file = require("poste-http.http.format_file")

describe("format_file JSON key escaping", function()
  it("re-emits keys containing quotes/backslashes as valid JSON", function()
    -- key holds a decoded `a"b\c` (escaped in source); the formatted output
    -- must escape it again instead of emitting broken JSON
    local formatted = format_file.format(
      '### t\nPOST https://x\nContent-Type: application/json\n\n{"a\\"b\\\\c": 1}'
    )
    local body = formatted:match("%b{}")
    assert.truthy(body, "formatted block should still carry the JSON body")
    local ok, decoded = pcall(vim.json.decode, body)
    assert.is_true(ok, "formatted body must be valid JSON, got: " .. body)
    assert.equals(1, decoded['a"b\\c'])
  end)

  it("leaves plain bodies unchanged in structure", function()
    local formatted = format_file.format(
      '### t\nPOST https://x\n\n{"b": 2, "a": [1, 2]}'
    )
    local body = formatted:match("%b{}")
    local ok, decoded = pcall(vim.json.decode, body)
    assert.is_true(ok)
    assert.equals(2, decoded.b)
    assert.same({ 1, 2 }, decoded.a)
  end)
end)

describe("format_file: non-finite numbers", function()
  it("encodes huge/tiny decoded numbers as null instead of bare inf", function()
    -- vim.json.decode accepts 1e999 and hands back math.huge; tostring
    -- emitted a bare "inf", invalid JSON that broke every later parse of
    -- the formatted body (jq, treesitter, filters).
    local out = require("poste-http.http.format_file").format('{\n"a":1e999\n}')
    assert.truthy(out:match('"a": null'), out)
    assert.falsy(out:match("inf"), out)
  end)
end)
