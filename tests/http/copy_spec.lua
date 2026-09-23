-- Tests for copy.lua: copy_as_curl exports request blocks as curl commands.

local copy = require("poste-http.http.copy")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("copy_as_curl", function()
  it("quotes IPv6 URLs so the [] survive shell parsing", function()
    local buf = make_buf({
      "### Ping",
      "GET http://[::1]:8080/health",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.fn.setpos(".", { 0, 2, 1, 0 })

    local cmd = copy.copy_as_curl()
    assert.is_not_nil(cmd)
    assert.matches("'http://%[::1%]:8080/health'", cmd)
  end)

  it("leaves simple URLs unquoted", function()
    local buf = make_buf({
      "GET https://api.example.com/users",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.fn.setpos(".", { 0, 1, 1, 0 })

    local cmd = copy.copy_as_curl()
    assert.is_not_nil(cmd)
    assert.matches("https://api%.example%.com/users", cmd)
  end)

  it("quotes values with the shared util.shell_escape dialect", function()
    -- Regression: copy.lua kept a private blacklist-based escape that drifted
    -- from util.shell_escape (whitelist). Both dialects agree on the common
    -- shapes (plain URLs unquoted, spaces quoted); this pins a `+`-bearing
    -- header value, which the old local variant left bare, to the shared one.
    local buf = make_buf({
      "### Ping",
      "POST https://api.example.com/echo",
      "X-Trace: a+b+c",
      "",
      "-leading-dash body",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.fn.setpos(".", { 0, 2, 1, 0 })

    local cmd = copy.copy_as_curl()
    assert.is_not_nil(cmd)
    assert.matches("'X%-Trace: a%+b%+c'", cmd)
    assert.matches("%-%-data%-binary '%-leading%-dash body'", cmd)
  end)

  it("includes headers and method", function()
    local buf = make_buf({
      "### Create",
      "POST https://api.example.com/users",
      "Content-Type: application/json",
      "",
      '{"name": "test"}',
    })
    vim.api.nvim_set_current_buf(buf)
    vim.fn.setpos(".", { 0, 2, 1, 0 })

    local cmd = copy.copy_as_curl()
    assert.is_not_nil(cmd)
    assert.matches("-X POST", cmd)
    assert.matches("Content%-Type: application/json", cmd)
    assert.matches("data%-binary", cmd)
  end)

  it("normalizes a JSON body so the copied command sends what runs", function()
    local buf = make_buf({
      "### Annotated JSON",
      "POST https://api.example.com/users",
      "Content-Type: application/json",
      "",
      "{",
      '  "a": "b",',
      "  // blank lines and comments are stripped",
      "",
      '  "c": 1',
      "}",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.fn.setpos(".", { 0, 2, 1, 0 })

    local cmd = copy.copy_as_curl()
    assert.is_not_nil(cmd)
    local payload = cmd:match("%-%-data%-binary '(.*)'$")
    assert.equals('{\n  "a": "b",\n  "c": 1\n}', payload)
  end)

  it("returns error when no request block at cursor (blank separator line)", function()
    local buf = make_buf({
      "### Block one",
      "GET https://example.com/a",
      "",
      "### Block two",
      "GET https://example.com/b",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.fn.setpos(".", { 0, 3, 1, 0 })

    local cmd, err = copy.copy_as_curl()
    assert.is_nil(cmd)
    assert.matches("No request block", err)
  end)

  it("resolves the block from a trailing comment line", function()
    local buf = make_buf({
      "### Block one",
      "GET https://example.com/a",
      "",
      "-- trailing comment",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.fn.setpos(".", { 0, 4, 1, 0 })

    local cmd = copy.copy_as_curl()
    assert.is_not_nil(cmd)
  end)
end)

describe("collect_vars (multipart variable layer)", function()
  local tmpdir, buf

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local f = io.open(vim.fs.joinpath(tmpdir, "env.json"), "w")
    f:write('{"dev": {"base": "https://env.example.com"}}')
    f:close()
  end)

  after_each(function()
    if buf then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      buf = nil
    end
    pcall(vim.fn.delete, tmpdir, "rf")
  end)

  local function make_file_buf(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fs.joinpath(tmpdir, "req.http"))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  it("lets file-level @vars reference env.json vars", function()
    make_file_buf({
      "@url = {{base}}/api",
      "",
      "### Upload",
      "POST https://example.com",
    })
    local vars = copy._collect_vars(buf, 3)
    assert.equals("https://env.example.com/api", vars.url)
  end)

  it("includes the file-level line directly above the separator", function()
    make_file_buf({
      "@tok = abc",
      "### Upload",
      "POST https://example.com",
    })
    local vars = copy._collect_vars(buf, 2)
    assert.equals("abc", vars.tok)
  end)
end)

describe("copy_as_curl multipart", function()
  local tmpdir, buf

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
  end)

  after_each(function()
    if buf then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      buf = nil
    end
    pcall(vim.fn.delete, tmpdir, "rf")
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
  end)

  local function make_file_buf(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fs.joinpath(tmpdir, "req.http"))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  local function multipart_buf(part_value)
    return make_file_buf({
      "### Upload",
      "@tok = abc",
      "POST https://example.com/upload",
      "Content-Type: multipart/form-data; boundary=BOUND",
      "",
      "--BOUND",
      'Content-Disposition: form-data; name="token"',
      "",
      part_value,
      "--BOUND--",
    })
  end

  it("resolves block-level @vars in multipart part values", function()
    -- Regression: the -F path rebuilt its variable map from FILE-level
    -- vars + env only, so a part value referencing a block-level @var
    -- copied as the literal {{tok}}.
    multipart_buf("{{tok}}")
    vim.fn.setpos(".", { 0, 3, 1, 0 })

    local cmd = copy.copy_as_curl()
    assert.is_not_nil(cmd)
    assert.truthy(cmd:find("token=abc", 1, true),
      "part value must resolve from the block-level @var, got: " .. cmd)
  end)

  it("arms random seeding for multipart magic vars", function()
    -- Regression: the -F path generated {{$uuid}}/{{$randomInt}} with raw
    -- math.random, bypassing the resolver's seed_random — the first copied
    -- value repeated across sessions (LuaJIT's fixed per-process seed).
    local util = require("poste-http.util")
    local saved = util._random_seeded
    util._random_seeded = false
    multipart_buf("{{$randomInt}}")
    vim.fn.setpos(".", { 0, 3, 1, 0 })

    local cmd = copy.copy_as_curl()
    util._random_seeded = saved
    assert.is_not_nil(cmd)
    assert.is_true(util._random_seeded,
      "copy_as_curl must seed the PRNG before generating magic vars")
  end)
end)
