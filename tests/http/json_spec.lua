-- Tests for http/json.lua — jq-style filtering of the response body.
--
-- Focus: the pure logic (key-path generation and the built-in JSON path
-- evaluator used when the jq binary is absent). The two must stay
-- symmetric: every path get_key_paths() offers must be evaluable by
-- _jsonpath_query.

local state = require("poste-http.state")
local json = require("poste-http.http.json")

describe("json.get_key_paths", function()
  after_each(function()
    state.last_response = nil
  end)

  it("returns empty for a missing or non-JSON body", function()
    state.last_response = nil
    assert.same({}, json.get_key_paths())
    state.last_response = { body = "not json" }
    assert.same({}, json.get_key_paths())
  end)

  it("walks nested objects with dot paths", function()
    state.last_response = { body = '{"user": {"name": "ada", "id": 1}}' }
    -- Intermediate object paths stay selectable (filtering .user returns
    -- the whole object), so all three are offered.
    assert.same({ ".user", ".user.id", ".user.name" }, json.get_key_paths())
  end)

  it("offers wildcard and indexed paths for arrays", function()
    state.last_response = { body = '{"items": [{"name": "a"}]}' }
    local paths = json.get_key_paths()
    assert.is_truthy(vim.tbl_contains(paths, ".items[]"))
    assert.is_truthy(vim.tbl_contains(paths, ".items[0]"))
    assert.is_truthy(vim.tbl_contains(paths, ".items[].name"))
  end)
end)

describe("json._jsonpath_query", function()
  it("resolves a top-level key", function()
    local out = json._jsonpath_query('{"name": "ada"}', ".name")
    assert.is_truthy(out:find("ada"))
  end)

  it("resolves a nested path", function()
    local out = json._jsonpath_query('{"user": {"name": "ada"}}', ".user.name")
    assert.is_truthy(out:find("ada"))
  end)

  it("resolves a root array index", function()
    local out = json._jsonpath_query('[{"n": 1}, {"n": 2}]', ".[1]")
    assert.is_truthy(out:find("2"))
  end)

  it("resolves an array index after a key — paths from get_key_paths replay", function()
    local out = json._jsonpath_query('{"items": [{"name": "a"}, {"name": "b"}]}', ".items[1]")
    assert.is_truthy(out:find("b"), "get_key_paths offers .items[1]; the evaluator must accept it")
  end)

  it("expands [] over array elements", function()
    local out = json._jsonpath_query('{"items": [1, 2]}', ".items[]")
    assert.is_truthy(out:find("1"))
    assert.is_truthy(out:find("2"))
  end)

  it("maps a key across array elements after [] (jq semantics)", function()
    -- get_key_paths offers `.items[].name`; the no-jq fallback used to fail
    -- it with "Key 'name' not found" because it looked up the key on the
    -- array itself instead of mapping across elements.
    local out = json._jsonpath_query('{"items": [{"name": "a"}, {"name": "b"}]}', ".items[].name")
    assert.is_truthy(out:find("a"))
    assert.is_truthy(out:find("b"))
  end)

  it("returns nil and notifies for a missing key", function()
    local notified
    local orig = vim.notify
    vim.notify = function(msg) notified = msg end
    local out = json._jsonpath_query('{"a": 1}', ".missing")
    vim.notify = orig
    assert.is_nil(out)
    assert.is_truthy(tostring(notified):find("missing"))
  end)

  it("returns nil for an invalid JSON body", function()
    local orig = vim.notify
    vim.notify = function() end
    local out = json._jsonpath_query("not json", ".a")
    vim.notify = orig
    assert.is_nil(out)
  end)
end)

describe("json.restore_original", function()
  it("is a no-op without a saved filter state", function()
    state._json.original_lines = nil
    -- Must not error even though no response buffer exists.
    json.restore_original()
    assert.is_nil(state._json.original_lines)
  end)
end)
