-- Text objects over the poste_http tree: the pure block_rows layer plus the
-- visual-mode keymaps buffer_setup registers (aR / iH / iB / iS and their
-- <Plug> aliases). Range assertions are parser-gated like the folding specs;
-- the keymap assertions are not.

local ts_query = require("poste-http.http.ts_query")
local textobj = require("poste-http.http.textobj")

describe("textobj.block_rows", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "poste_http"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "### One",
      "GET https://api.example.com/a",
      "X-Api: v",
      "Authorization: Bearer t",
      "",
      "### Two",
      "POST https://api.example.com/b",
      "Content-Type: application/json",
      "",
      "{",
      '  "a": 1',
      "}",
      "",
    })
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("spans the block from its separator to the last non-blank line", function()
    if not ts_query.is_available(buf) then return end
    local sr, er = textobj.block_rows(buf, 2)
    assert.equals(0, sr, "block One starts at its ### row")
    assert.equals(3, er, "trailing blank line before the next ### is trimmed")
  end)

  it("resolves the last block to the last non-blank line of the buffer", function()
    if not ts_query.is_available(buf) then return end
    local sr, er = textobj.block_rows(buf, 10)
    assert.equals(5, sr, "block Two starts at its ### row")
    assert.equals(11, er, "the } row; the final blank line is trimmed")
  end)

  it("selects the block whose separator the cursor sits on", function()
    if not ts_query.is_available(buf) then return end
    local sr, er = textobj.block_rows(buf, 0)
    assert.equals(0, sr)
    assert.equals(3, er)
  end)

  it("returns nil above every separator", function()
    if not ts_query.is_available(buf) then return end
    -- file-level @var lines live above the first ### in real files
    local empty = vim.api.nvim_create_buf(false, true)
    vim.bo[empty].filetype = "poste_http"
    vim.api.nvim_buf_set_lines(empty, 0, -1, false, { "@base = https://x", "GET {{base}}" })
    assert.is_nil(textobj.block_rows(empty, 1))
    vim.api.nvim_buf_delete(empty, { force = true })
  end)
end)

describe("textobj keymaps", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "poste_http"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "### One",
      "GET https://api.example.com/a",
      "X-Api: v",
      "",
    })
    vim.api.nvim_set_current_buf(buf)
    require("poste-http.buffer_setup").setup_buffer_keymaps(buf)
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    buf = nil
  end)

  local function has_map(mode, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      -- maparg dicts carry <Plug> LHS in display form, plain keys in raw
      -- form; accept either spelling
      if m.lhs == lhs or m.lhs == vim.api.nvim_replace_termcodes(lhs, true, true, true) then
        return true
      end
    end
    return false
  end

  it("registers the visual-mode defaults", function()
    for _, key in ipairs({ "aR", "iH", "iB", "iS" }) do
      assert.is_truthy(has_map("x", key), "x-mode default missing: " .. key)
    end
  end)

  it("registers the <Plug> aliases buffer-locally", function()
    assert.is_truthy(has_map("x", "<Plug>(PosteHttpSelectBlock)"))
    assert.is_truthy(has_map("x", "<Plug>(PosteHttpSelectBody)"))
  end)

  it("selects the block under the cursor through the mapping", function()
    if not ts_query.is_available(buf) then return end
    -- Enter visual mode first, then let the mapped handler feed its
    -- range motions, then flush — the nested feedkeys of a mapping are
    -- consumed on the next loop tick, not inside the same batch (a
    -- headless feedkeys('vaR', 'x') single batch leaves them queued).
    vim.fn.cursor(3, 1)
    vim.fn.feedkeys("V", "x")
    vim.fn.feedkeys("aR", "x")
    vim.fn.feedkeys("", "x")
    -- The '< / '> marks are only reliable AFTER visual mode ends (the
    -- o-swapped selection does not keep them fresh mid-selection), so exit
    -- and read them.
    vim.fn.feedkeys("<Esc>", "x")
    assert.equals("n", vim.fn.mode(), "back to normal mode after <Esc>")
    assert.equals(1, vim.api.nvim_buf_get_mark(0, "<")[1], "selection starts at the ### row")
    assert.equals(3, vim.api.nvim_buf_get_mark(0, ">")[1], "selection ends on the last header")
  end)
end)
