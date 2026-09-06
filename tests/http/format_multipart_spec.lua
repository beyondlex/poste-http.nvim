-- Regression coverage for format/multipart.lua boundary handling.

local multipart = require("poste-http.http.format.multipart")

describe("condense_multipart_body with pattern-magic boundary chars", function()
  -- '(' is a legal quoted-boundary char (RFC 2046 bchars) and a Lua pattern
  -- control char: the old pattern-based find() crashed on it with
  -- "malformed pattern", breaking the whole verbose view.
  local ct = 'multipart/form-data; boundary="a(b"'

  local function make_body()
    return table.concat({
      "--a(b",
      'Content-Disposition: form-data; name="field"',
      "",
      "value",
      "--a(b--",
    }, "\r\n")
  end

  it("treats the boundary as a literal, not a Lua pattern", function()
    local out = multipart.condense_multipart_body(make_body(), ct)
    assert.matches("Content%-Disposition: form%-data; name=\"field\"", out)
    assert.is_truthy(out:find("\nvalue\n", 1, true), "part value must survive condensing")
  end)
end)

describe("strip_request_preamble with CRLF content", function()
  it("finds the blank separator when lines carry trailing \\r", function()
    local raw = "POST https://api.example.com\r\nContent-Type: application/json\r\n\r\n{\"a\":1}\r\n"
    -- Body ends at the last non-blank line; the CRLF remnant stays.
    assert.equals('{"a":1}\r', multipart.strip_request_preamble(raw))
  end)

  it("still handles LF-only content", function()
    local raw = "POST https://api.example.com\nContent-Type: application/json\n\n{\"a\":1}"
    assert.equals('{"a":1}', multipart.strip_request_preamble(raw))
  end)
end)
