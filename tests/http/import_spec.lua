--- Tests for the import/run cross-file reference resolution module.
local import_mod = require("poste.http.import")
local _test = import_mod._test

describe("parse_import_line", function()
  it("parses bare import", function()
    local r = _test.parse_import_line("import ./auth.http")
    assert.are_equal("bare", r.type)
    assert.are_equal("./auth.http", r.path)
  end)

  it("parses aliased import", function()
    local r = _test.parse_import_line("import ./orders.http as orders")
    assert.are_equal("aliased", r.type)
    assert.are_equal("./orders.http", r.path)
    assert.are_equal("orders", r.alias)
  end)

  it("rejects non-import lines", function()
    assert.is_nil(_test.parse_import_line("### Request"))
    assert.is_nil(_test.parse_import_line("@var = value"))
    assert.is_nil(_test.parse_import_line(""))
    assert.is_nil(_test.parse_import_line("run #Login"))
  end)

  it("handles leading whitespace", function()
    local r = _test.parse_import_line("  import ./auth.http")
    assert.are_equal("bare", r.type)
  end)
end)

describe("parse_run_line", function()
  it("parses run #Name", function()
    local r = _test.parse_run_line("run #Login")
    assert.are_equal("by_name", r.type)
    assert.are_equal("Login", r.name)
    assert.is_true(next(r.vars) == nil)
  end)

  it("parses run #alias.Name", function()
    local r = _test.parse_run_line("run #orders.ListOrders")
    assert.are_equal("by_alias", r.type)
    assert.are_equal("orders", r.alias)
    assert.are_equal("ListOrders", r.name)
  end)

  it("parses run ./path", function()
    local r = _test.parse_run_line("run ./batch.http")
    assert.are_equal("by_path", r.type)
    assert.are_equal("./batch.http", r.path)
  end)

  it("parses run with variable overrides", function()
    local r = _test.parse_run_line("run #Login (@token=xyz)")
    assert.are_equal("by_name", r.type)
    assert.are_equal("Login", r.name)
    assert.are_equal("xyz", r.vars.token)
  end)

  it("parses run with multiple variable overrides", function()
    local r = _test.parse_run_line("run #Login (@token=xyz, @env=staging)")
    assert.are_equal("by_name", r.type)
    assert.are_equal("xyz", r.vars.token)
    assert.are_equal("staging", r.vars.env)
  end)

  it("rejects non-run lines", function()
    assert.is_nil(_test.parse_run_line("### Request"))
    assert.is_nil(_test.parse_run_line(""))
    assert.is_nil(_test.parse_run_line("import ./auth.http"))
  end)
end)

describe("resolve_path", function()
  it("keeps absolute paths", function()
    local r = _test.resolve_path("/absolute/path.http", "/dir")
    assert.are_equal("/absolute/path.http", r)
  end)

  it("resolves relative paths", function()
    local r = _test.resolve_path("./sub/file.http", "/base/dir")
    assert.are_equal("/base/dir/sub/file.http", r)
  end)
end)

describe("extract_request_names", function()
  it("extracts named blocks", function()
    local content = "### Login\nGET /api/login\n\n### Logout\nGET /api/logout\n"
    local names = _test.extract_request_names(content)
    assert.are_equal(2, #names)
    assert.are_equal("Login", names[1].name)
    assert.are_equal(1, names[1].line)
    assert.are_equal("Logout", names[2].name)
    assert.are_equal(4, names[2].line)
  end)

  it("returns empty for no blocks", function()
    local content = "@var = value\n"
    local names = _test.extract_request_names(content)
    assert.are_equal(0, #names)
  end)

  it("ignores nameless ###", function()
    local content = "###\nGET /api\n"
    local names = _test.extract_request_names(content)
    assert.are_equal(0, #names)
  end)
end)

describe("resolve_reference", function()
  local index = {
    bare = {
      {
        path = "/dir/auth.http",
        requests = { { name = "Login", line = 1 }, { name = "Logout", line = 4 } },
      },
    },
    aliased = {
      orders = {
        path = "/dir/orders.http",
        requests = { { name = "ListOrders", line = 1 }, { name = "GetOrder", line = 5 } },
      },
    },
    errors = {},
    warnings = {},
  }

  it("resolves bare reference", function()
    local r = _test.resolve_reference("Login", index)
    assert.are_equal("/dir/auth.http", r.path)
    assert.are_equal(1, r.line)
  end)

  it("resolves aliased reference", function()
    local r = _test.resolve_reference("orders.ListOrders", index)
    assert.are_equal("/dir/orders.http", r.path)
    assert.are_equal(1, r.line)
  end)

  it("returns nil for unknown reference", function()
    assert.is_nil(_test.resolve_reference("Unknown", index))
  end)

  it("returns nil for unknown alias", function()
    assert.is_nil(_test.resolve_reference("bad.Name", index))
  end)
end)
