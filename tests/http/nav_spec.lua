--- Tests for navigation: gd on client.run("#target", ...) inside SCRIPT blocks.
local nav_util = require("poste-http.http.nav.util")

local function setup_buffers()
  local req_file = os.tmpname() .. ".http"
  local f = io.open(req_file, "w")
  f:write("### Login\nPOST /api/login\nContent-Type: application/json\n\n{\"username\": \"{{username}}\"}\n")
  f:close()

  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, os.tmpname() .. ".http")
  vim.bo[buf].filetype = "poste_http"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "import " .. req_file .. " as api",
    "",
    "### Orchestration",
    "SCRIPT",
    "> {%",
    '  local login = client.run("#api.Login", { username = "u" })',
    "%}",
  })
  return req_file, buf
end

describe("nav_util.goto_client_run_definition", function()
  local req_file
  local buf

  before_each(function()
    req_file, buf = setup_buffers()
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    os.remove(req_file)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
  end)

  it("jumps to the imported request when the cursor is on the target", function()
    local line_text = vim.api.nvim_buf_get_lines(buf, 5, 6, false)[1]
    local col = line_text:find("Login", 1, true) - 1

    local handled = nav_util.goto_client_run_definition(buf, 6, col)
    assert.is_true(handled)
    assert.are_equal(vim.fn.resolve(req_file), vim.api.nvim_buf_get_name(0))
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.are_equal(1, cursor[1])
    local target_text = vim.api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], false)[1] or ""
    assert.matches("### Login", target_text)
  end)

  it("does nothing when the cursor is outside the target", function()
    local handled = nav_util.goto_client_run_definition(buf, 6, 0)
    assert.is_false(handled)
    assert.are_equal(vim.api.nvim_buf_get_name(buf), vim.api.nvim_buf_get_name(0))
  end)

  it("returns false on lines without a client.run call", function()
    local handled = nav_util.goto_client_run_definition(buf, 2, 0)
    assert.is_false(handled)
  end)

  it("handles an unresolvable target without jumping", function()
    local buf2 = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf2, os.tmpname() .. ".http")
    vim.api.nvim_buf_set_lines(buf2, 0, -1, false, {
      "import ./missing.http as api",
      "",
      "### Orchestration",
      "SCRIPT",
      "> {%",
      '  local r = client.run("#api.Nope", {})',
      "%}",
    })
    vim.api.nvim_set_current_buf(buf2)
    local line_text = vim.api.nvim_buf_get_lines(buf2, 5, 6, false)[1]
    local handled = nav_util.goto_client_run_definition(buf2, 6, line_text:find("Nope", 1, true) - 1)
    assert.is_true(handled)
    assert.are_equal(vim.api.nvim_buf_get_name(buf2), vim.api.nvim_buf_get_name(0))
    pcall(vim.api.nvim_buf_delete, buf2, { force = true })
  end)
end)

describe("nav.text.goto_definition on client.run", function()
  it("jumps through the default text nav path", function()
    local req_file, buf = setup_buffers()
    vim.api.nvim_set_current_buf(buf)
    local line_text = vim.api.nvim_buf_get_lines(buf, 5, 6, false)[1]
    vim.api.nvim_win_set_cursor(0, { 6, line_text:find("Login", 1, true) - 1 })

    require("poste-http.http.nav.text").goto_definition()

    assert.are_equal(vim.fn.resolve(req_file), vim.api.nvim_buf_get_name(0))
    assert.are_equal(1, vim.api.nvim_win_get_cursor(0)[1])
    os.remove(req_file)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
  end)
end)

describe("nav.text.goto_definition on Lua import @var = alias.keypath", function()
  local function setup_lua_import()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local lua_file = dir .. "/vars.lua"
    local f = io.open(lua_file, "w")
    f:write("return {\n  a_string = \"hello from lua\",\n}\n")
    f:close()

    local buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, dir .. "/test.http")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "import ./vars.lua as m",
      "",
      "@my_name = m.a_string",
      "",
      "### 01",
      "GET /test",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "poste_http"
    return dir, lua_file, buf
  end

  it("jumps to import line when cursor is on the alias", function()
    local dir, _, buf = setup_lua_import()

    -- Cursor on 'm' in 'm.a_string' (col 11, 0-indexed where 'm' starts)
    vim.api.nvim_win_set_cursor(0, { 3, 11 })

    require("poste-http.http.nav.text").goto_definition()

    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.equals(1, cursor[1])
    local line = vim.api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], false)[1] or ""
    assert.truthy(line:match("import.*as m"))

    pcall(vim.fn.delete, dir, "rf")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
  end)

  it("opens the Lua file when cursor is on the keypath", function()
    local dir, lua_file, buf = setup_lua_import()

    -- Cursor on 'a_string' in 'm.a_string' (col 13, 0-indexed where 'a' of 'a_string' starts)
    -- '@my_name = m.a_string' → 'a' at 1-indexed 14, 0-indexed 13
    vim.api.nvim_win_set_cursor(0, { 3, 13 })

    require("poste-http.http.nav.text").goto_definition()

    assert.are_equal(vim.fn.resolve(lua_file), vim.api.nvim_buf_get_name(0))
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], false)[1] or ""
    assert.truthy(line:match("a_string"))

    pcall(vim.fn.delete, dir, "rf")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
  end)
end)

describe("nav.ts.goto_definition on Lua import_var_ref", function()
  local function setup_lua_import()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local lua_file = dir .. "/vars.lua"
    local f = io.open(lua_file, "w")
    f:write("return {\n  a_string = \"hello from lua\",\n  users = {\n    { id = 1, name = \"alice\" },\n  },\n}\n")
    f:close()

    local buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, dir .. "/test.http")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "import ./vars.lua as m",
      "",
      "@my_name = m.a_string",
      "@first_user = m.users[1].name",
      "",
      "### 01",
      "GET /test",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "poste_http"
    vim.treesitter.start(buf, "poste_http")
    return dir, lua_file, buf
  end

  it("jumps to import line when cursor is on the alias", function()
    local dir, _, buf = setup_lua_import()

    vim.api.nvim_win_set_cursor(0, { 3, 11 })

    require("poste-http.http.nav.ts").goto_definition()

    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.equals(1, cursor[1])
    local line = vim.api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], false)[1] or ""
    assert.truthy(line:match("import.*as m"))

    pcall(vim.fn.delete, dir, "rf")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
  end)

  it("opens the Lua file when cursor is on the keypath", function()
    local dir, lua_file, buf = setup_lua_import()

    vim.api.nvim_win_set_cursor(0, { 3, 13 })

    require("poste-http.http.nav.ts").goto_definition()

    assert.are_equal(vim.fn.resolve(lua_file), vim.api.nvim_buf_get_name(0))
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], false)[1] or ""
    assert.truthy(line:match("a_string"))

    pcall(vim.fn.delete, dir, "rf")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
  end)

  it("opens the Lua file at the correct table for array-indexed keypath", function()
    local dir, lua_file, buf = setup_lua_import()

    vim.api.nvim_win_set_cursor(0, { 4, 16 })

    require("poste-http.http.nav.ts").goto_definition()

    assert.are_equal(vim.fn.resolve(lua_file), vim.api.nvim_buf_get_name(0))
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], false)[1] or ""
    assert.truthy(line:match("users"),
      "expected to land on 'users' line, got: " .. line)

    pcall(vim.fn.delete, dir, "rf")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
  end)
end)

describe("nav.ts.goto_definition on {{m.keypath}} in URL/header", function()
  local function setup_lua_import_ref()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local lua_file = dir .. "/vars.lua"
    local f = io.open(lua_file, "w")
    f:write([[local M = {}
M.a_string = "hello"
M.an_int = 100
return M
]])
    f:close()

    local buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, dir .. "/test.http")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "import " .. lua_file .. " as m",
      "",
      "### 01",
      "GET /anything/{{m.an_int}}",
      "X-Direct: {{m.a_string}}",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "poste_http"
    vim.treesitter.start(buf, "poste_http")
    return dir, lua_file, buf
  end

  it("opens the Lua file from {{m.keypath}} in URL", function()
    local dir, lua_file, buf = setup_lua_import_ref()
    vim.api.nvim_win_set_cursor(0, { 4, 16 })
    require("poste-http.http.nav.ts").goto_definition()
    assert.are_equal(vim.fn.resolve(lua_file), vim.api.nvim_buf_get_name(0))
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], false)[1] or ""
    assert.truthy(line:match("an_int"),
      "expected to land on 'an_int' line, got: " .. line)
    pcall(vim.fn.delete, dir, "rf")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
  end)

  it("opens the Lua file from {{m.keypath}} in header value", function()
    local dir, lua_file, buf = setup_lua_import_ref()
    vim.api.nvim_win_set_cursor(0, { 5, 12 })
    require("poste-http.http.nav.ts").goto_definition()
    assert.are_equal(vim.fn.resolve(lua_file), vim.api.nvim_buf_get_name(0))
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(0, cursor[1] - 1, cursor[1], false)[1] or ""
    assert.truthy(line:match("a_string"),
      "expected to land on 'a_string' line, got: " .. line)
    pcall(vim.fn.delete, dir, "rf")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
  end)
end)

describe("nav.jump_next / jump_prev", function()
  local nav = require("poste-http.http.nav")

  local function write_request_file()
    local req_file = os.tmpname() .. ".http"
    local f = io.open(req_file, "w")
    f:write("   ### Indented First\nGET /first\n\n   ### Indented Second\nGET /second\n")
    f:close()
    return req_file
  end

  local function open_request_file(req_file)
    local buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, req_file)
    vim.bo[buf].filetype = "poste_http"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "   ### Indented First",
      "GET /first",
      "",
      "   ### Indented Second",
      "GET /second",
    })
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  it("jump_next lands on an indented ### separator", function()
    local req_file = write_request_file()
    local buf = open_request_file(req_file)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    assert.has_no.errors(function() nav.jump_next() end)
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.equal(4, cursor[1])
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
    os.remove(req_file)
  end)

  it("jump_prev lands on an indented ### separator", function()
    local req_file = write_request_file()
    local buf = open_request_file(req_file)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })

    assert.has_no.errors(function() nav.jump_prev() end)
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.equal(4, cursor[1])
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
    os.remove(req_file)
  end)
end)
