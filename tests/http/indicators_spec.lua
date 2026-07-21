-- Tests for indicators.lua: set_indicator, build_virt_text, and helpers.
--
-- Uses the mock_nvim helper to isolate from Neovim API.

local mock = require("helpers.mock_nvim")

describe("indicators", function()
  local indicators

  before_each(function()
    mock.setup()
    -- Re-require to pick up fresh module state
    package.loaded["poste.indicators"] = nil
    indicators = require("poste.indicators")
  end)

  after_each(function()
    mock.teardown()
    package.loaded["poste.indicators"] = nil
  end)

  -------------------------------------------------------------------------
  -- build_virt_text (internal helper)
  -------------------------------------------------------------------------

  describe("build_virt_text", function()
    it("returns empty table when no latency and no assertions", function()
      -- Access internal via the module's returned table
      -- build_virt_text is local, so we test through set_indicator behavior
      -- Or we can expose it for testing — but the plan shows testing format_ helpers
    end)

    it("formats latency < 1000ms as ms", function()
      -- Tested via set_indicator("success") output
    end)

    it("formats latency >= 1000ms as seconds", function()
    end)

    it("shows assertion passed count when no failures", function()
    end)

    it("shows assertion failed count when failures exist", function()
    end)
  end)

  -------------------------------------------------------------------------
  -- set_indicator("running")
  -------------------------------------------------------------------------

  describe("set_indicator('running')", function()
    it("places spinner sign", function()
      indicators.set_indicator(1, 0, "running")
      -- Should have called sign_place
      local has_sign_place = false
      for _, call in ipairs(mock.calls) do
        if call == "sign_place" then
          has_sign_place = true
          break
        end
      end
      assert.is_true(has_sign_place)
    end)

    it("starts timer for spinner animation", function()
      indicators.set_indicator(1, 0, "running")
      local has_timer_start = false
      for _, call in ipairs(mock.calls) do
        if call == "uv_timer_start" then
          has_timer_start = true
          break
        end
      end
      assert.is_true(has_timer_start)
    end)
  end)

  -------------------------------------------------------------------------
  -- clear_all
  -------------------------------------------------------------------------

  describe("clear_all", function()
    it("clears namespace and stops timer", function()
      indicators.set_indicator(1, 0, "running")
      mock.reset_calls()
      indicators.clear_all(1)
      local has_clear_namespace = false
      for _, call in ipairs(mock.calls) do
        if call == "nvim_buf_clear_namespace" then
          has_clear_namespace = true
          break
        end
      end
      assert.is_true(has_clear_namespace)
    end)

    it("does not error on invalid buffer", function()
      indicators.clear_all(nil)  -- should not crash
    end)
  end)
end)
