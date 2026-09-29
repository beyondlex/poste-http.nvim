--- Real-API tests for the `boundary_style` setup option, which picks how
--- :PosteHttpBoundary marks the request block: "background" (default,
--- full-width rectangle) or "gutter" (only the number column, poste-db.nvim
--- parity).
---
--- Own spec file on purpose: tests/http/boundary_indicator_spec.lua stubs
--- vim.api via helpers.mock_nvim and that poisoning outlives its teardown
--- within the same runner process, so real-API extmark tests cannot share
--- a file with it (same reason as attach_boundary_spec.lua's header note).

local state = require("poste-http.state")
local boundary = require("poste-http.http.boundary_indicator")
-- plugin/poste.lua loads the plugin lazily, so the highlight definitions
-- are not in this process unless the spec requires them itself.
require("poste-http.http.highlights")

local ns = vim.api.nvim_create_namespace("poste_boundary")

local function make_request_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "### a",
    "GET https://x.dev/api",
    "Authorization: Bearer token",
  })
  vim.bo[buf].filetype = "poste_http"
  return buf
end

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

describe("boundary_indicator boundary_style", function()
  local buf

  before_each(function()
    state.config.boundary_style = "background"
    buf = make_request_buf()
  end)

  after_each(function()
    state.config.boundary_style = "background"
    boundary.clear(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("background (default) paints a full-width rectangle", function()
    boundary.refresh(buf, 1)
    local all = marks(buf)
    assert.is_true(#all > 0, "refresh must paint boundary extmarks")
    for _, m in ipairs(all) do
      assert.are.equal("PosteHttpBoundary", m[4].hl_group)
      assert.is_truthy(m[4].hl_eol, "background must reach past EOL")
      assert.is_nil(m[4].number_hl_group)
    end
  end)

  it("gutter tints only the number column, not the lines", function()
    state.config.boundary_style = "gutter"
    boundary.refresh(buf, 1)
    local all = marks(buf)
    assert.is_true(#all > 0, "refresh must paint boundary extmarks")
    for _, m in ipairs(all) do
      assert.are.equal("PosteHttpBoundaryGutter", m[4].number_hl_group)
      assert.is_nil(m[4].hl_group, "gutter style must not tint the lines")
      assert.is_nil(m[4].hl_eol, "gutter style must not reach past EOL")
    end
  end)

  it("switching the style replaces the old marks on the next refresh", function()
    boundary.refresh(buf, 1)
    assert.is_true(#marks(buf) > 0)
    state.config.boundary_style = "gutter"
    boundary.refresh(buf, 1)
    local all = marks(buf)
    assert.is_true(#all > 0)
    for _, m in ipairs(all) do
      assert.is_nil(m[4].hl_group, "stale background rectangle survived the switch")
      assert.are.equal("PosteHttpBoundaryGutter", m[4].number_hl_group)
    end
  end)

  it("PosteHttpBoundaryGutter links to PosteHttpBoundary", function()
    local hl = vim.api.nvim_get_hl(0, { name = "PosteHttpBoundaryGutter" })
    assert.are.equal("PosteHttpBoundary", hl.link,
      "gutter must follow the rectangle colour unless overridden")
  end)
end)
