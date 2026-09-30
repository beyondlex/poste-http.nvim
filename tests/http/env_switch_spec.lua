--- Tests for env switching validation. `:PosteHttpEnv <typo>` used to switch
--- silently; every subsequent {{var}} then resolved to nothing and the run
--- went out with literal placeholders. When a readable env.json defines the
--- universe of names, an unknown name must be rejected with the valid ones.
local env = require("poste-http.http.env")
local state = require("poste-http.state")
local util = require("poste-http.util")

describe("env.set_env validation", function()
  local dir, http_buf

  before_each(function()
    dir = os.tmpname() .. "-envdir"
    os.remove(dir)
    vim.fn.mkdir(dir, "p")
    local f = io.open(dir .. "/env.json", "w")
    f:write('{"dev": {"api_base": "http://localhost"}, "prod": {}}')
    f:close()
    http_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(http_buf, dir .. "/req.http")
    vim.api.nvim_set_current_buf(http_buf)
    state.current_env = "dev"
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, http_buf, { force = true })
    vim.fn.delete(dir, "rf")
  end)

  it("rejects an unknown env name and keeps the current one", function()
    local switched = env.set_env("prodX")
    assert.is_false(switched)
    assert.are_equal("dev", state.current_env)
  end)

  it("accepts a known env name", function()
    local switched = env.set_env("prod")
    assert.is_true(switched)
    assert.are_equal("prod", state.current_env)
  end)

  it("stays permissive when no env.json is discoverable", function()
    -- Walk-up finding nothing must not block the switch: without env.json
    -- the variable pool comes from other layers, so any name is legal.
    local orig = util.find_file_upwards
    util.find_file_upwards = function() return nil end
    local ok_switch, switched = pcall(env.set_env, "anything")
    util.find_file_upwards = orig
    assert.is_true(ok_switch)
    assert.is_true(switched)
    assert.are_equal("anything", state.current_env)
  end)

  it("stays permissive when env.json is unreadable garbage", function()
    local f = io.open(dir .. "/env.json", "w")
    f:write("{not json")
    f:close()
    local switched = env.set_env("anything")
    assert.is_true(switched)
    assert.are_equal("anything", state.current_env)
  end)
end)
