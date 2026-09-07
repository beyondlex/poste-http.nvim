local _ = require("poste-http.state")

describe("errors.find_unresolved_vars", function()
  local errors

  before_each(function()
    package.loaded["poste-http.http.errors"] = nil
    errors = require("poste-http.http.errors")
  end)

  after_each(function()
    package.loaded["poste-http.http.errors"] = nil
  end)

  it("detects unresolved var in a single string", function()
    local r = errors.find_unresolved_vars("GET /users/{{id}}")
    assert.same({ "id" }, r)
  end)

  it("returns empty for fully resolved string", function()
    local r = errors.find_unresolved_vars("GET /users/42")
    assert.same({}, r)
  end)

  it("detects across url, body and header values", function()
    local r = errors.find_unresolved_vars({
      "GET /users/{{id}}",
      '{"token": "{{token}}"}',
      "X-Foo: {{header_var}}",
    })
    assert.same({ "id", "token", "header_var" }, r)
  end)

  it("dedupes repeated references", function()
    local r = errors.find_unresolved_vars({ "{{a}}/{{a}}/{{b}}" })
    assert.same({ "a", "b" }, r)
  end)

  it("handles nil and empty parts", function()
    assert.same({}, errors.find_unresolved_vars(nil))
    assert.same({}, errors.find_unresolved_vars({}))
    assert.same({}, errors.find_unresolved_vars(""))
  end)

  it("scans header values not names", function()
    local r = errors.find_unresolved_vars({ "Authorization: Bearer {{token}}" })
    assert.same({ "token" }, r)
  end)

  it("finds multiple distinct unresolved vars", function()
    local r = errors.find_unresolved_vars({ "{{scheme}}://{{host}}/api" })
    assert.same({ "scheme", "host" }, r)
  end)
end)

describe("errors.format_errors", function()
  local errors

  before_each(function()
    package.loaded["poste-http.http.errors"] = nil
    errors = require("poste-http.http.errors")
  end)

  after_each(function()
    package.loaded["poste-http.http.errors"] = nil
  end)

  it("renders hint when no errors", function()
    local lines = errors.format_errors(nil)
    assert.matches("No errors", lines[1])
    lines = errors.format_errors({})
    assert.matches("No errors", lines[1])
  end)

  it("renders summary bar with total and pre/post counts", function()
    local e = {
      { type = "pre_request", stage = "variable_resolution", message = "Cannot resolve {{id}}" },
      { type = "post_request", stage = "post_script", message = "attempt to index nil" },
    }
    local lines = errors.format_errors(e)
    assert.matches("Errors: 2 %(1 pre%-request, 1 post%-request%)", lines[1])
  end)

  it("renders each error with stage, message, and source location", function()
    local e = {
      { type = "pre_request", stage = "variable_resolution", message = "Cannot resolve {{id}}", source = { var = "id", line = 3, file = "/tmp/f.http" } },
    }
    local lines = errors.format_errors(e)
    local joined = table.concat(lines, "\n")
    assert.matches("variable_resolution:", joined)
    assert.matches("Cannot resolve {{id}}", joined)
    assert.matches("variable: id", joined)
    assert.matches("f%.http:3", joined)
    assert.is_nil(joined:find("⨯"))
    assert.is_nil(joined:find("✘"))
    assert.is_nil(joined:find("▸"))
    assert.is_nil(joined:find("──"))
  end)
end)

describe("errors.find_var_line", function()
  local errors

  before_each(function()
    package.loaded["poste-http.http.errors"] = nil
    errors = require("poste-http.http.errors")
  end)

  after_each(function()
    package.loaded["poste-http.http.errors"] = nil
  end)

  it("finds the line where {{name}} appears", function()
    local lines = {
      "GET /api/users/{{id}}",
      "Authorization: Bearer {{token}}",
    }
    assert.equal(1, errors.find_var_line(lines, "id"))
    assert.equal(2, errors.find_var_line(lines, "token"))
  end)

  it("returns nil when name is not found", function()
    local lines = { "GET /api/users/42" }
    assert.is_nil(errors.find_var_line(lines, "missing"))
  end)

  it("returns nil for nil or empty inputs", function()
    assert.is_nil(errors.find_var_line(nil, "x"))
    assert.is_nil(errors.find_var_line({}, "x"))
    assert.is_nil(errors.find_var_line({ "hello" }, nil))
  end)

  it("finds the first occurrence only", function()
    local lines = { "{{a}}", "{{a}}" }
    assert.equal(1, errors.find_var_line(lines, "a"))
  end)

  it("scopes search to a line range (start_line..end_line)", function()
    local lines = {
      "# {{a}} (comment in earlier block)",
      "GET /x",
      "# {{a}} (comment in target block)",
      '  "id": {{a}}',
    }
    assert.equal(3, errors.find_var_line(lines, "a", 3, 4))
  end)

  it("returns nil when name is outside the given line range", function()
    local lines = {
      "{",
      '  "id": {{a}},',
      "}",
    }
    assert.is_nil(errors.find_var_line(lines, "a", 3, 3))
  end)

  it("returns the line within the block even when the first file occurrence is earlier", function()
    local lines = {
      "# {{my_number}} → 100",
      "### 07",
      "POST /x",
      "{",
      '  "id": {{my_number}},',
      "}",
    }
    assert.equal(5, errors.find_var_line(lines, "my_number", 2, 6))
  end)

  it("clamps a start_line greater than end_line to nil result", function()
    local lines = { "{{a}}" }
    assert.is_nil(errors.find_var_line(lines, "a", 5, 2))
  end)
end)

describe("errors.apply_highlights jump targets", function()
  local errors

  before_each(function()
    package.loaded["poste-http.http.errors"] = nil
    errors = require("poste-http.http.errors")
  end)

  after_each(function()
    package.loaded["poste-http.http.errors"] = nil
  end)

  it("stores jump targets on variable: lines", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local list = {
      {
        type = "pre_request", stage = "variable_resolution", message = "msg",
        source = { var = "timeout2", line = 11, file = "/tmp/a.http" },
      },
    }
    local lines = errors.format_errors(list)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    errors.apply_highlights(buf, lines, list)
    local jumps = errors.get_jump_targets(buf)
    assert.is_not_nil(jumps, "jumps should not be nil")
    local found = nil
    for _, t in pairs(jumps) do
      if t.file == "/tmp/a.http" then
        found = t
      end
    end
    assert.is_not_nil(found, "should find jump target for /tmp/a.http")
    assert.equal(11, found.line)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("does not store jumps when source has no file", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local list = {
      { type = "post_request", stage = "post_script", message = "msg", source = { var = "x", line = 3 } },
    }
    local lines = errors.format_errors(list)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    errors.apply_highlights(buf, lines, list)
    local jumps = errors.get_jump_targets(buf)
    assert.is_not_nil(jumps)
    assert.is_true(next(jumps) == nil)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)

describe("errors.builders", function()
  local errors

  before_each(function()
    package.loaded["poste-http.http.errors"] = nil
    errors = require("poste-http.http.errors")
  end)

  after_each(function()
    package.loaded["poste-http.http.errors"] = nil
  end)

  it("pre_request builds correct structure", function()
    local e = errors.pre_request("variable_resolution", "msg", { var = "x" })
    assert.equal("pre_request", e.type)
    assert.equal("variable_resolution", e.stage)
    assert.equal("msg", e.message)
    assert.equal("x", e.source.var)
  end)

  it("post_request builds correct structure", function()
    local e = errors.post_request("post_script", "msg", nil)
    assert.equal("post_request", e.type)
    assert.equal("post_script", e.stage)
    assert.equal("msg", e.message)
  end)
end)