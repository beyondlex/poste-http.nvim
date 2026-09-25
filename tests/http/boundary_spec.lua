--- Boundary-indicator toggle lifecycle. The repaint path is covered by the
--- UI specs indirectly; this spec pins the OFF path: the extmarks live in
--- the buffer the cursor LAST moved in, and the toggle must clear that one
--- even when another buffer is focused.
local boundary = require("poste-http.http.boundary_indicator")

local ns = vim.api.nvim_create_namespace("poste_boundary")

-- buftype=nofile buffers abandon cleanly at qa (a modified unnamed
-- scratch left current used to flake the runner's exit code with E37).
local function make_request_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
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
  after_each(function()
    vim.cmd("silent! enew!") -- leave the window on a clean buffer
  end)

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

  it("when ON, every poste_http buffer follows the cursor — not just the armed one", function()
    -- The old autocmd was buffer=0-local: toggling on in one buffer
    -- silently dropped tracking everywhere else. The command is global
    -- (one toggle, one notification), so a second .http buffer must paint
    -- from the shared autocmd without re-arming.
    -- State invariant: test 2 left the module ON with the augroup armed.
    local buf_b = make_request_buf()
    vim.api.nvim_set_current_buf(buf_b)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf_b })

    assert.truthy(#vim.api.nvim_buf_get_extmarks(buf_b, ns, 0, -1, {}) > 0,
      "a second .http buffer must paint from the global toggle")

    -- a non-.http buffer (markdown carries ### too) must never paint
    local md = vim.api.nvim_create_buf(false, true)
    vim.bo[md].buftype = "nofile"
    vim.api.nvim_buf_set_lines(md, 0, -1, false, { "### heading", "text" })
    vim.bo[md].filetype = "markdown"
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = md })
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(md, ns, 0, -1, {}))

    -- restore the state the suite started with: ON, augroup armed
    boundary.toggle()
    boundary.toggle()
  end)
end)
