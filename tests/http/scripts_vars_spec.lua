-- Tests for scripts.collect_script_variables:
-- file-level + block-level @var collection via the canonical vars.lua parser
-- (supports >>>/<<< multiline values and {{var}} reference resolution).

local scripts = require("poste-http.http.scripts")
local state = require("poste-http.state")

local function with_buf(name)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

describe("collect_script_variables", function()
  local buf
  local orig_env

  before_each(function()
    orig_env = state.current_env
    state.current_env = nil
  end)

  after_each(function()
    state.current_env = orig_env
    if buf then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      buf = nil
    end
  end)

  it("collects file-level vars and resolves {{ref}} chains", function()
    buf = with_buf("/tmp/collect_vars.http")
    local content = table.concat({
      "@base = https://api.example.com",
      "@url = {{base}}/users",
      "",
      "### Get",
      "GET {{url}}",
    }, "\n")

    local result = scripts.collect_script_variables(content, 4, 5)
    assert.equals("https://api.example.com", result.variables.base)
    assert.equals("https://api.example.com/users", result.variables.url)
  end)

  it("resolves {{_underscore}} var names in collected variables", function()
    buf = with_buf("/tmp/underscore_vars.http")
    local content = table.concat({
      "@_base = https://api.example.com",
      "@_url = {{_base}}/users",
      "",
      "### Get",
      "GET {{_url}}",
    }, "\n")

    local result = scripts.collect_script_variables(content, 4, 5)
    -- The canonical {{var}} grammar accepts names that start with `_`
    -- (vars.lua matches {{([^}]+)}}); the script sandbox must agree.
    assert.equals("https://api.example.com/users", result.variables._url)
  end)

  it("collects block-level vars overriding file-level", function()
    buf = with_buf("/tmp/collect_vars2.http")
    local content = table.concat({
      "@mode = file",
      "",
      "### One",
      "@mode = block",
      "GET /x",
    }, "\n")

    local result = scripts.collect_script_variables(content, 4, 5)
    assert.equals("block", result.variables.mode)
  end)

  it("supports >>>/<<< multiline block values", function()
    buf = with_buf("/tmp/collect_vars3.http")
    local content = table.concat({
      "### Payload",
      "@payload = >>>",
      "{\"a\": 1}",
      "<<<",
      "POST /x",
    }, "\n")

    local result = scripts.collect_script_variables(content, 2, 5)
    assert.equals('{"a": 1}', result.variables.payload)
  end)

  it("reads env vars from the target file dir, not the current buffer", function()
    local env_dir = vim.fn.tempname()
    vim.fn.mkdir(env_dir, "p")
    local env_path = vim.fs.joinpath(env_dir, "env.json")
    local f = io.open(env_path, "w")
    f:write(vim.json.encode({ dev = { token = "dev-token" } }))
    f:close()

    buf = with_buf("/tmp/other_dir/unrelated.http")
    state.current_env = "dev"

    local result = scripts.collect_script_variables("@token = {{token}}", 1, 1, env_dir)
    assert.equals("dev-token", result.env.token)

    os.remove(env_path)
    vim.fn.delete(env_dir, "d")
  end)
end)

describe("pre-script variable logging", function()
  it("never writes the stored value to the log file", function()
    -- Regression: client.global.set / request.variables.set /
    -- client.global.header.set logged the stored VALUE verbatim. Script
    -- variables are where tokens land, and the log file is a sync /
    -- screenshot leak surface — only the name and the value's length go out.
    local secret = "super-secret-bearer-token"
    local log_file = vim.fn.tempname() .. "-poste.log"
    state.config.log_file = log_file
    vim.fn.delete(log_file)

    local result = scripts.run_pre_script([[
      request.variables.set('v', ']] .. secret .. [[')
      client.global.set('g', ']] .. secret .. [[')
      client.global.header.set('Authorization', 'Bearer ]] .. secret .. [[')
    ]], { variables = {}, env = {} })
    assert.is_nil(result.error)

    local f = io.open(log_file, "r")
    assert.truthy(f, "log file was written")
    local logged = f:read("*a")
    f:close()
    assert.falsy(logged:find(secret, 1, true), "the secret must not appear in the log")
    assert.truthy(logged:find("request%.variables%.set%('v', %[REDACTED len=25%]%)"))
    assert.truthy(logged:find("client%.global%.header%.set%('Authorization', %[REDACTED len=32%]%)"))

    os.remove(log_file)
    state.config.log_file = nil
  end)
end)
