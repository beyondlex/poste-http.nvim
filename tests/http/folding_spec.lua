local folding = require("poste-http.http.folding")
local ts_query = require("poste-http.http.ts_query")

describe("folding.foldexpr", function()
  local buf_a
  local buf_b

  before_each(function()
    package.loaded["poste-http.http.folding"] = nil
    folding = require("poste-http.http.folding")

    buf_a = vim.api.nvim_create_buf(false, true)
    vim.bo[buf_a].filetype = "poste_http"
    vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, {
      "### One",
      "GET /a",
      "",
      "### Two",
      "GET /b",
    })

    buf_b = vim.api.nvim_create_buf(false, true)
    vim.bo[buf_b].filetype = "poste_http"
    vim.api.nvim_buf_set_lines(buf_b, 0, -1, false, {
      "### Single",
      "GET /c",
      "",
      "",
      "",
    })
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf_a, { force = true })
    pcall(vim.api.nvim_buf_delete, buf_b, { force = true })
    package.loaded["poste-http.http.folding"] = nil
  end)

  --- Both buffers were created fresh and given one set_lines call, so they
  --- carry the SAME changedtick. A module-level cache keyed by tick alone
  --- cannot tell them apart.
  it("keys the cache per-buffer so equal ticks on different buffers do not collide", function()
    if not ts_query.is_available(buf_a) then
      return -- parser not installed, skip
    end

    -- Prime the cache with buffer A: separator at 0-based row 0, next at row 3,
    -- so its first block folds with size 2 → ">2".
    vim.api.nvim_set_current_buf(buf_a)
    vim.v.lnum = 1
    assert.equals(">2", folding.foldexpr())

    -- Buffer B has a single separator at row 0 with 5 lines → ">4".
    -- Same changedtick as A, so the old tick-only cache would serve A's
    -- separators and wrongly report ">2".
    vim.api.nvim_set_current_buf(buf_b)
    vim.v.lnum = 1
    assert.equals(">4", folding.foldexpr())
  end)

  it("recomputes when the same buffer is edited", function()
    if not ts_query.is_available(buf_a) then
      return
    end

    vim.api.nvim_set_current_buf(buf_a)
    vim.v.lnum = 1
    assert.equals(">2", folding.foldexpr())

    vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, {
      "### One",
      "GET /a",
      "",
      "GET /middle",
      "### Two",
      "GET /b",
    })
    vim.v.lnum = 1
    assert.equals(">3", folding.foldexpr())
  end)

  it("evicts the cache entry when the buffer is wiped out", function()
    if not ts_query.is_available(buf_a) then
      return
    end

    local before = folding._cache_size()
    vim.api.nvim_set_current_buf(buf_a)
    vim.v.lnum = 1
    folding.foldexpr() -- primes cached_separators[buf_a]
    assert.is_true(folding._cache_size() >= before + 1,
      "priming must add a cache entry")

    vim.api.nvim_buf_delete(buf_a, { force = true }) -- fires BufWipeout
    assert.equals(before, folding._cache_size(),
      "BufWipeout must drop the buffer's cache entry")
  end)

  it("returns = for a single-line foldable body, never the invalid >0", function()
    if not ts_query.is_available(buf_a) then
      return
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "poste_http"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "### A",
      "POST https://x",
      '{"a":1}',
      "",
    })
    vim.api.nvim_set_current_buf(buf)
    -- Row 2 (lnum 3) is a one-line json_body: the old ">0" is not a legal
    -- fold start and nested the blank line below into a phantom fold.
    vim.v.lnum = 3
    assert.equals("=", folding.foldexpr())
    -- A multi-line body still folds normally.
    vim.api.nvim_buf_set_lines(buf, 3, 4, false, {
      "### B",
      "POST https://y",
      "{",
      '  "a": 1',
      "}",
      "",
    })
    vim.v.lnum = 6
    assert.equals(">2", folding.foldexpr())
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)