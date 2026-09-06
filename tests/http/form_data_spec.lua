local form_data = require("poste-http.http.form_data")

describe("substitute_magic_vars", function()
  it("replaces magic var placeholders with the generated values", function()
    local line = "ts={{$timestamp}} id={{$uuid}} d={{$date}} n={{$randomInt}}"
    local r = form_data.substitute_magic_vars(line, {
      timestamp = "1710000123456789",
      uuid = "550e8400-e29b-41d4-a716-446655440000",
      date = "2026-09-06",
      randomInt = "42",
    })
    assert.equals(
      "ts=1710000123456789 id=550e8400-e29b-41d4-a716-446655440000 d=2026-09-06 n=42",
      r
    )
  end)

  it("replaces every occurrence of a placeholder", function()
    local line = "{{$timestamp}}-{{$timestamp}}"
    local r = form_data.substitute_magic_vars(line, { timestamp = "7" })
    assert.equals("7-7", r)
  end)

  it("keeps a % in the generated value literal (no capture-reference interpretation)", function()
    local line = "token={{$timestamp}}&sig={{$uuid}}"
    local r = form_data.substitute_magic_vars(line, { timestamp = "100%1", uuid = "a%b" })
    assert.equals("token=100%1&sig=a%b", r)
  end)

  it("leaves lines without placeholders untouched", function()
    local r = form_data.substitute_magic_vars("Content-Type: application/x-www-form-urlencoded", {
      timestamp = "7",
    })
    assert.equals("Content-Type: application/x-www-form-urlencoded", r)
  end)
end)
