-- Tests for json_body.lua: request-body JSON normalization.
--
-- A JSON body may carry comments (`//`, `/* */`, `#`, `--`) and blank lines in
-- the .http file. Those must never reach the server — but the body is only
-- rewritten when the cleaned text actually parses, so a `{`-shaped payload that
-- is not JSON is sent byte-for-byte as written.

local json_body = require("poste-http.http.json_body")

describe("json_body.looks_like_json", function()
  it("accepts objects and arrays, ignoring leading whitespace", function()
    assert.is_true(json_body.looks_like_json('{"a": 1}'))
    assert.is_true(json_body.looks_like_json('  \n  { "a": 1 }'))
    assert.is_true(json_body.looks_like_json("[\n  1\n]"))
  end)

  it("rejects every other body shape", function()
    assert.is_false(json_body.looks_like_json("------boundary\ncontent\n------boundary--"))
    assert.is_false(json_body.looks_like_json("a=1&b=2"))
    assert.is_false(json_body.looks_like_json("query { me }"))
    assert.is_false(json_body.looks_like_json(""))
    assert.is_false(json_body.looks_like_json("   \n  "))
    assert.is_false(json_body.looks_like_json(nil))
  end)
end)

describe("json_body.strip_comments", function()
  it("drops a whole-line // comment", function()
    local out = json_body.strip_comments('{\n  "a": "b",\n  // note\n  "c": "d"\n}')
    assert.equals('{\n  "a": "b",\n  "c": "d"\n}', out)
  end)

  it("drops a trailing // comment and its leading whitespace", function()
    local out = json_body.strip_comments('{\n  "a": 1,   // why\n  "b": 2\n}')
    assert.equals('{\n  "a": 1,\n  "b": 2\n}', out)
  end)

  it("keeps // inside a string (URLs)", function()
    local src = '{\n  "link": "https://x.test/a//b"\n}'
    assert.equals(src, json_body.strip_comments(src))
  end)

  it("drops a /* */ comment spanning lines", function()
    local out = json_body.strip_comments('{\n  /*\n   * header\n   */\n  "a": 1\n}')
    assert.equals('{\n  "a": 1\n}', out)
  end)

  it("drops an inline /* */ comment", function()
    local out = json_body.strip_comments('{ "a": /* x */ 1 }')
    assert.equals('{ "a":  1 }', out)
  end)

  it("keeps /* and */ inside a string", function()
    local src = '{\n  "pattern": "/* not a comment */"\n}'
    assert.equals(src, json_body.strip_comments(src))
  end)

  it("drops whole-line # and -- comments", function()
    local out = json_body.strip_comments('{\n  # hash\n  -- sql style\n  "a": 1\n}')
    assert.equals('{\n  "a": 1\n}', out)
  end)

  it("keeps # inside a string and a mid-line -- value", function()
    local src = '{\n  "tag": "#release",\n  "range": "1--2"\n}'
    assert.equals(src, json_body.strip_comments(src))
  end)

  it("leaves a body without comments untouched", function()
    local src = '{\n  "a": "b"\n}'
    assert.equals(src, json_body.strip_comments(src))
  end)

  it("handles CJK after the marker (bytes, not characters)", function()
    local out = json_body.strip_comments('{\n  "a": "b"\n  -- 有空行要 trim\n}')
    assert.equals('{\n  "a": "b"\n}', out)
  end)
end)

describe("json_body.drop_blank_lines", function()
  it("removes interior blank lines and trims the ends", function()
    assert.equals('{\n  "a": 1\n}', json_body.drop_blank_lines('\n{\n  "a": 1\n\n}\n\n'))
  end)

  it("treats whitespace-only lines as blank", function()
    assert.equals('{\n  "a": 1\n}', json_body.drop_blank_lines('{\n  "a": 1\n \n}'))
  end)
end)

describe("json_body.repair_trailing_commas", function()
  it("removes a comma before a closing brace or bracket", function()
    assert.equals('{"a": 1}', json_body.repair_trailing_commas('{"a": 1,}'))
    assert.equals('{\n  "a": 1\n}', json_body.repair_trailing_commas('{\n  "a": 1,\n}'))
    assert.equals("[1, 2]", json_body.repair_trailing_commas("[1, 2,]"))
  end)

  it("keeps a comma inside a string", function()
    assert.equals('{"a": "1,}"}', json_body.repair_trailing_commas('{"a": "1,}"}'))
  end)

  it("keeps the inner comma of a nested object", function()
    assert.equals('{"a": {"b": 1}, "c": 2}',
      json_body.repair_trailing_commas('{"a": {"b": 1}, "c": 2,}'))
  end)

  it("removes a run of commas left by several commented-out fields", function()
    assert.equals("[1]", json_body.repair_trailing_commas("[1,,]"))
    assert.equals("[1, 2]", json_body.repair_trailing_commas("[1,, 2,]"))
    assert.equals('{"a": 1 }', json_body.repair_trailing_commas('{"a": 1, ,}'))
  end)
end)

describe("json_body.normalize", function()
  it("strips comments and blank lines from a JSONC body", function()
    local out, info = json_body.normalize('{\n    "a": "b"\n    // trim me\n\n}')
    assert.equals('{\n    "a": "b"\n}', out)
    assert.is_true(info.json)
    assert.is_true(info.valid)
    assert.is_true(info.changed)
  end)

  it("repairs a trailing comma left by a commented-out field", function()
    local out, info = json_body.normalize('{\n  "a": 1,\n  // "b": 2\n}')
    assert.equals('{\n  "a": 1\n}', out)
    assert.is_true(info.valid)
  end)

  it("rescues a body whose commented-out field leaves two commas", function()
    -- The whitespace a removed comma leaves behind becomes a blank line, which
    -- normalize() drops as well.
    local out, info = json_body.normalize('{\n  "a": 1,\n  // gone\n  ,\n}')
    assert.equals('{\n  "a": 1\n}', out)
    assert.is_true(info.valid)
  end)

  it("leaves an already valid body semantically intact", function()
    local out, info = json_body.normalize('{\n  "a": 1,\n  "b": [1, 2]\n}')
    assert.equals('{\n  "a": 1,\n  "b": [1, 2]\n}', out)
    assert.is_true(info.json)
    assert.is_true(info.valid)
  end)

  it("sends an unparseable JSON-shaped body verbatim", function()
    local src = '{\n  "a": ,,\n}'
    local out, info = json_body.normalize(src)
    assert.equals(src, out)
    assert.is_true(info.json)
    assert.is_false(info.valid)
    assert.is_false(info.changed)
  end)

  it("passes non-JSON bodies through untouched", function()
    local src = "------X\nContent-Disposition: form-data; name=\"a\"\n\n1\n------X--"
    local out, info = json_body.normalize(src)
    assert.equals(src, out)
    assert.is_false(info.json)
    assert.is_false(info.changed)
  end)

  it("is idempotent", function()
    local src = '{\n  // one\n  "a": 1,\n\n  "b": "https://x.test",\n}'
    local once = json_body.normalize(src)
    local twice = json_body.normalize(once)
    assert.equals(once, twice)
  end)

  it("handles empty and nil input", function()
    assert.equals("", json_body.normalize(""))
    assert.equals("   \n ", json_body.normalize("   \n "))
    assert.equals(nil, json_body.normalize(nil))
  end)
end)
