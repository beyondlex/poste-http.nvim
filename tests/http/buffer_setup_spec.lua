local mock = require("helpers.mock_nvim")
local state = require("poste-http.state")

describe("buffer_setup namespace leak", function()
  before_each(function()
    mock.setup()
    state.config.keymaps = {}
    package.loaded["poste-http.buffer_setup"] = nil
  end)

  after_each(function()
    mock.teardown()
  end)

  it("uses a single fileref namespace across buffers", function()
    local buf_setup = require("poste-http.buffer_setup")

    buf_setup.setup_buffer_keymaps(1001)
    buf_setup.setup_buffer_keymaps(1002)

    local ns_name = nil
    local ns_count = 0
    for i = 1, #mock.calls do
      if mock.calls[i] == "nvim_create_namespace" then
        local name = mock.calls[i + 1]
        if name and type(name) == "string" and name:match("poste_fileref") then
          ns_name = name
          ns_count = ns_count + 1
        end
      end
    end

    assert.is_not_nil(ns_name, "should create a fileref namespace")
    assert.equals("poste_fileref", ns_name,
      "should use static name, not per-buffer unique name")
    assert.equals(1, ns_count,
      "should create only one fileref namespace across multiple buffers")
  end)

  it("resolves buffer 0 to current buffer before binding TextChanged", function()
    local buf_setup = require("poste-http.buffer_setup")

    -- plugin/poste.lua passes 0 (current-buffer sentinel) on BufRead;
    -- the TextChanged closure must not forward 0 to sign_unplace (E158).
    buf_setup.setup_buffer_keymaps(0)

    local cb = nil
    for i = 1, #mock.calls do
      if mock.calls[i] == "nvim_create_autocmd" then
        local rec = mock.calls[i + 1]
        if rec and rec.events == "TextChanged" and rec.opts and rec.opts.callback then
          cb = rec.opts.callback
          break
        end
      end
    end
    assert.is_not_nil(cb, "should register a TextChanged autocmd")

    mock.reset_calls()
    cb()

    local unplaced_buf = nil
    for i = 1, #mock.calls do
      if mock.calls[i] == "sign_unplace" then
        local rec = mock.calls[i + 1]
        unplaced_buf = rec and rec.opts and rec.opts.buffer
      end
    end
    assert.is_not_nil(unplaced_buf, "TextChanged should clear signs via sign_unplace")
    assert.is_not_equal(0, unplaced_buf, "must not pass buffer 0 to sign_unplace (E158)")
  end)
end)
-- Real-API tests for the boundary autocmd pair extracted from
-- plugin/poste.lua (REVIEW-2026-09-06 smell: the CursorMoved/BufDelete
-- group setup existed twice).
describe("buffer_setup.attach_boundary", function()
  local buffer_setup

  before_each(function()
    buffer_setup = require("poste-http.buffer_setup")
  end)

  it("attaches CursorMoved + BufDelete into one per-buffer group", function()
    local buf = vim.api.nvim_create_buf(false, true)
    buffer_setup.attach_boundary(buf)

    local group_name = "PosteHttpBoundary_" .. buf
    local autocmds = vim.api.nvim_get_autocmds({ group = group_name })
    assert.equals(2, #autocmds)

    local events = {}
    for _, au in ipairs(autocmds) do
      events[au.event] = true
    end
    assert.is_truthy(events.CursorMoved, "must refresh the block indicator on CursorMoved")
    assert.is_truthy(events.BufDelete, "must clean the group up on BufDelete")

    -- Deleting the buffer fires BufDelete and removes the group again.
    vim.api.nvim_buf_delete(buf, { force = true })
    local ok, remaining = pcall(vim.api.nvim_get_autocmds, { group = group_name })
    if ok then
      assert.equals(0, #remaining, "augroup must be deleted with the buffer")
    else
      assert.matches("augroup", tostring(remaining), 1, true)
    end
  end)
end)
