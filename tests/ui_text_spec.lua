-- Tests for the display-width aware text truncation helpers (poste-http.ui.text).
--
-- Consolidates the five truncation implementations that used to live in
-- columns.lua / outline.lua / symbols.lua / variable_inspector.lua. The unified
-- semantics are display-width based (vim.fn.strdisplaywidth), so CJK text is
-- never split mid-glyph and alignment stays correct.

local text = require("poste-http.ui.text")

local function width(s)
  return vim.fn.strdisplaywidth(s)
end

describe("poste-http.ui.text", function()
  describe("truncate", function()
    it("returns short strings unchanged", function()
      assert.equals("GET /api", text.truncate("GET /api", 20))
      assert.equals("GET /api", text.truncate("GET /api", 8))
    end)

    it("truncates ASCII with a single-char ellipsis, filling the budget", function()
      local out = text.truncate("ThisNameIsWayTooLong", 10)
      assert.equals("ThisNameI…", out)
      assert.equals(10, width(out))
    end)

    it("never splits a wide (CJK) character", function()
      local out = text.truncate("中文内容很长需要截断", 8)
      assert.is_true(width(out) <= 8, "display width must stay within max")
      assert.equals("中文内…", out)
    end)

    it("keeps CJK text within width when truncating to odd budgets", function()
      local out = text.truncate("请求请求请求", 5)
      assert.is_true(width(out) <= 5)
      assert.equals("请求…", out)
    end)

    it("handles nil and degenerate widths", function()
      assert.equals("", text.truncate(nil, 10))
      assert.equals("", text.truncate("abc", 0))
      assert.equals("", text.truncate("abc", -1))
      assert.equals("…", text.truncate("abc", 1))
    end)
  end)

  describe("middle", function()
    it("returns short strings unchanged", function()
      assert.equals("/api/users", text.middle("/api/users", 20))
      assert.equals("/api/users", text.middle("/api/users", 10))
    end)

    it("cuts from both ends with a middle ellipsis", function()
      local out = text.middle("https://api.example.com/v1/very/long/path", 20)
      assert.is_true(width(out) <= 20)
      assert.equals("…", vim.fn.strcharpart(out, 9, 1), "ellipsis char sits in the middle")
      assert.equals("h", out:sub(1, 1))
      assert.equals("h", out:sub(-1))
    end)

    it("never splits a wide (CJK) character", function()
      local out = text.middle("值前缀部分很长值后缀部分也很长", 10)
      assert.is_true(width(out) <= 10)
    end)

    it("handles nil and degenerate widths", function()
      assert.equals("", text.middle(nil, 10))
      assert.equals("", text.middle("abc", 0))
      assert.equals("…", text.middle("abcdef", 1))
    end)
  end)

  describe("NUL bytes (binary-derived text)", function()
    -- A literal \u0000 arriving from JSON variables or response previews
    -- makes vim.fn.strdisplaywidth raise Vim E976 ("Using a Blob as a
    -- String"); truncation must survive it instead of killing the render.
    it("truncate drops NUL bytes instead of raising E976", function()
      assert.equals("ab", text.truncate("a\0b", 10))
      assert.equals(2, width(text.truncate("a\0b", 10)))
    end)

    it("truncate still respects the budget with NULs present", function()
      assert.equals("a…", text.truncate("a\0bcdef", 2))
    end)

    it("middle drops NUL bytes instead of raising E976", function()
      assert.equals("ab", text.middle("a\0b", 10))
    end)

    it("strings without NULs are untouched", function()
      assert.equals("plain", text.truncate("plain", 10))
    end)
  end)
end)
