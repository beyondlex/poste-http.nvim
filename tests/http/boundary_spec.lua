--- Boundary-indicator toggle lifecycle. The repaint path is covered by the
--- UI specs indirectly; this spec pins the OFF path: the extmarks live in
--- the buffer the cursor LAST moved in, and the toggle must clear that one
--- even when another buffer is focused.
local boundary = require("poste-http.http.boundary_indicator")

local ns = vim.api.nvim_create_namespace("poste_boundary")

local function make_request_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "### a",
    "GET https://x.dev/api",
    "",
    "{",
    '  "k": 1',
    "}",
  })
  vim.bo[buf].filetype = "poste_http"
  return buf
end

describe("poste-http boundary_indicator", function()
  it("refresh paints the focused block", function()
    local buf_a = make_request_buf()
    boundary.refresh(buf_a, 1)
    assert.truthy(#vim.api.nvim_buf_get_extmarks(buf_a, ns, 0, -1, {}) > 0,
      "refresh must paint boundary extmarks")
  end)

  it("toggle OFF clears the painted buffer even when another buffer is focused", function()
    local buf_a = make_request_buf()
    boundary.refresh(buf_a, 1)
    assert.truthy(#vim.api.nvim_buf_get_extmarks(buf_a, ns, 0, -1, {}) > 0)

    local buf_b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf_b)
    boundary.toggle() -- OFF: clears buf_b AND the painted buf_a

    assert.equals(0, #vim.api.nvim_buf_get_extmarks(buf_a, ns, 0, -1, {}),
      "stale boundary rectangle left on the previously painted buffer")
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(buf_b, ns, 0, -1, {}))

    boundary.toggle() -- back ON, as at module load
  end)
end)
