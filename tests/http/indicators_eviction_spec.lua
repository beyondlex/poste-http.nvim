-- BufWipeout eviction for indicators.lua's per-buffer spinner timers.
--
-- A request wiped mid-run (":%bd", tab close) used to leave its uv spinner
-- timer ticking over a dead buffer forever — clear_all never runs for a
-- buffer nobody can focus again. Mirrors the folding.lua eviction precedent
-- (09-22): lazily-armed BufWipeout autocmd + an M._evict hook asserted here.
-- Real nvim buffers (no mock_nvim) — the eviction needs real autocmds.

describe("indicators BufWipeout eviction", function()
  local indicators

  before_each(function()
    indicators = require("poste-http.indicators")
  end)

  it("drops a buffer's spinner state when the buffer is wiped", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### sep", "GET https://x" })

    indicators.set_indicator(buf, 1, "running")
    assert.equals(1, indicators._spinner_count(),
      "the running spinner must be tracked before the wipe")

    vim.api.nvim_buf_delete(buf, { force = true }) -- fires BufWipeout
    assert.equals(0, indicators._spinner_count(),
      "BufWipeout must stop the spinner timer and drop the entry")
  end)

  it("eviction is a safe no-op for buffers without indicators", function()
    assert.has_no_errors(function()
      indicators._evict(999999)
    end)
    local buf = vim.api.nvim_create_buf(false, true)
    indicators.set_indicator(buf, 0, "success", 5)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.equals(0, indicators._spinner_count())
  end)
end)
