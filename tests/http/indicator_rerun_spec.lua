-- Regression: a re-run ("running") must clear the previous run's payload
-- extmark (latency / verdict) on the separator line. Uses the real Neovim
-- API — no gui/mock harness.

local indicators = require("poste-http.indicators")

describe("indicators.set_indicator", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "### Demo",
      "GET https://example.com",
    })
  end)

  after_each(function()
    if buf then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      buf = nil
    end
  end)

  -- Count only the payload namespace: signs are extmarks internally too.
  local function count_extmarks()
    local ns = vim.api.nvim_get_namespaces()["poste_indicator"]
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    local count = 0
    for _ in ipairs(marks) do count = count + 1 end
    return count
  end

  it("success leaves a payload extmark", function()
    indicators.set_indicator(buf, 1, "success", 250, nil)
    assert.equals(1, count_extmarks())
  end)

  it("running clears the previous run's payload extmark", function()
    indicators.set_indicator(buf, 1, "success", 250, nil)
    indicators.set_indicator(buf, 1, "running")
    assert.equals(0, count_extmarks(),
      "re-running must remove the previous run's latency/verdict")
  end)
end)
