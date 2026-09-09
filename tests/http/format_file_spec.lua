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
