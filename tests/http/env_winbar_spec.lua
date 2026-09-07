--- Tests for the env winbar lifecycle (REVIEW-2026-09-06 smell):
--- BufEnter used to set vim.wo.winbar for .http buffers and never restored
--- it, so a window that later showed a non-http buffer kept the stale
--- "Env: ..." bar. env.sync_winbar sets it for http buffers and clears it
--- again — only when the current bar is one we set.

local env = require("poste-http.http.env")
local state = require("poste-http.state")
local winbar = require("poste-http.ui.winbar")

describe("env.sync_winbar", function()
  local http_buf, other_buf

  before_each(function()
    state.current_env = "winbar_test"
    http_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(http_buf, vim.fn.tempname() .. ".http")
    vim.bo[http_buf].filetype = "poste_http"
    other_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(other_buf, vim.fn.tempname() .. ".txt")
    vim.api.nvim_set_current_buf(other_buf)
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, http_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
  end)

  it("sets the env winbar for an http buffer", function()
    vim.api.nvim_set_current_buf(http_buf)
    env.sync_winbar()
    assert.equals(winbar.http_env("winbar_test"), vim.wo.winbar)
  end)

  it("accepts a .http-named buffer whose filetype is not set yet", function()
    -- First open: BufEnter fires before BufRead, so ft is still empty and
    -- the name pattern is the only signal.
    local fresh = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(fresh, vim.fn.tempname() .. ".rest")
    vim.api.nvim_set_current_buf(fresh)
    env.sync_winbar()
    assert.equals(winbar.http_env("winbar_test"), vim.wo.winbar)
    vim.api.nvim_buf_delete(fresh, { force = true })
  end)

  it("clears a bar we set when the window shows a non-http buffer", function()
    vim.api.nvim_set_current_buf(http_buf)
    env.sync_winbar()
    vim.api.nvim_set_current_buf(other_buf)
    env.sync_winbar()
    assert.is_false(vim.wo.winbar ~= "" and vim.wo.winbar ~= nil)
    assert.not_equals(winbar.http_env("winbar_test"), vim.wo.winbar)
  end)

  it("leaves a foreign winbar alone", function()
    vim.wo.winbar = "%#Todo#custom"
    vim.api.nvim_set_current_buf(other_buf)
    env.sync_winbar()
    assert.equals("%#Todo#custom", vim.wo.winbar)
  end)
end)
