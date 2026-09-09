-- Tests for the <<prompt variable resolution in prompt_vars.
-- Select/input UI is stubbed at the poste-select boundary; vim.fn.input
-- paths are intentionally not exercised here (headless input hangs).
local prompt_vars = require("poste-http.http.prompt_vars")
local poste_select = require("poste-http.select")

describe("prompt_vars.handle_prompt_variables", function()
  local orig_select
  local buf

  before_each(function()
    orig_select = poste_select.select
  end)

  after_each(function()
    poste_select.select = orig_select
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    buf = nil
  end)

  local function setup_buffer(lines)
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  it("passes content through unchanged when the block has no prompt lines", function()
    local lines = { "### Plain", "GET /plain" }
    setup_buffer(lines)
    local done, out = false, nil
    prompt_vars.handle_prompt_variables(buf, 1, table.concat(lines, "\n"), nil, nil,
      function(resolved) done = true; out = resolved end)
    assert.is_true(done)
    assert.are_equal("### Plain\nGET /plain", out)
  end)

  it("injects the selected option as a @var definition", function()
    local lines = { "### Login", "<<token [alpha, beta]", "GET /login" }
    setup_buffer(lines)
    poste_select.select = function(_items, _prompt, cb) cb("beta") end
    local done, out = false, nil
    prompt_vars.handle_prompt_variables(buf, 1, table.concat(lines, "\n"), nil, nil,
      function(resolved) done = true; out = resolved end)
    assert.is_true(done)
    assert.are_equal("### Login\n@token = beta\nGET /login", out)
  end)

  it("aborts remaining prompts after a cancellation", function()
    local lines = { "### Login", "<<a [x, y]", "<<b [p, q]", "GET /login" }
    setup_buffer(lines)
    local select_calls = 0
    poste_select.select = function(_items, _prompt, cb)
      select_calls = select_calls + 1
      cb(nil)
    end
    local done, out = false, "SENTINEL"
    prompt_vars.handle_prompt_variables(buf, 1, table.concat(lines, "\n"), nil, nil,
      function(resolved) done = true; out = resolved end)
    assert.is_true(done)
    assert.is_nil(out)
    assert.are_equal(1, select_calls,
      "second <<var must not prompt after the first was cancelled")
  end)
end)
