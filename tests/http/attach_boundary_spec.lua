--- Real-API tests for the boundary autocmd pair extracted from
--- plugin/poste.lua (REVIEW-2026-09-06 smell: the CursorMoved/BufDelete
--- group setup existed twice).
---
--- Own spec file on purpose: tests/http/buffer_setup_spec.lua stubs
--- vim.api via helpers.mock_nvim and that poisoning outlives its
--- teardown within the same runner process, so real-API autocmd tests
--- cannot share a file with it.

local buffer_setup = require("poste-http.buffer_setup")

describe("buffer_setup.attach_boundary", function()
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
