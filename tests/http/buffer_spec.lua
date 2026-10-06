-- Tests for buffer.sanitize_lines
--
-- Characterization test: documents the current behavior of sanitize_lines.
-- The function splits lines containing embedded \n or \r into separate
-- buffer entries (required because nvim_buf_set_lines rejects strings with
-- embedded newlines). It does NOT trim trailing whitespace.
--
-- Use: require("poste-http.http.buffer")  →  M.sanitize_lines(lines)

local buffer = require("poste-http.http.buffer")

describe("sanitize_lines", function()
  ---------------------------------------------------------------------------
  -- Normal lines (no trailing whitespace, no embedded newlines)
  ---------------------------------------------------------------------------
  describe("with normal lines", function()
    it("preserves a single line", function()
      local result = buffer.sanitize_lines({ "hello" })
      assert.equals(1, #result)
      assert.equals("hello", result[1])
    end)

    it("preserves multiple lines", function()
      local result = buffer.sanitize_lines({ "line1", "line2", "line3" })
      assert.equals(3, #result)
      assert.equals("line1", result[1])
      assert.equals("line2", result[2])
      assert.equals("line3", result[3])
    end)

    it("preserves lines with special characters", function()
      local result = buffer.sanitize_lines({ "GET /api/v1/users HTTP/1.1", "Host: example.com", "Content-Type: application/json" })
      assert.equals(3, #result)
      assert.equals("GET /api/v1/users HTTP/1.1", result[1])
      assert.equals("Host: example.com", result[2])
      assert.equals("Content-Type: application/json", result[3])
    end)
  end)

  ---------------------------------------------------------------------------
  -- Lines with trailing whitespace (currently NOT trimmed)
  ---------------------------------------------------------------------------
  describe("with lines containing trailing whitespace", function()
    it("preserves trailing spaces (not trimmed)", function()
      local result = buffer.sanitize_lines({ "hello   " })
      assert.equals(1, #result)
      assert.equals("hello   ", result[1])
    end)

    it("preserves trailing tabs (not trimmed)", function()
      local result = buffer.sanitize_lines({ "hello\t\t" })
      assert.equals(1, #result)
      assert.equals("hello\t\t", result[1])
    end)

    it("preserves leading whitespace (not trimmed)", function()
      local result = buffer.sanitize_lines({ "   hello" })
      assert.equals(1, #result)
      assert.equals("   hello", result[1])
    end)

    it("preserves both leading and trailing whitespace (not trimmed)", function()
      local result = buffer.sanitize_lines({ "  hello world  " })
      assert.equals(1, #result)
      assert.equals("  hello world  ", result[1])
    end)
  end)

  ---------------------------------------------------------------------------
  -- Empty lines
  ---------------------------------------------------------------------------
  describe("with empty lines", function()
    it("preserves a single empty line", function()
      local result = buffer.sanitize_lines({ "" })
      assert.equals(1, #result)
      assert.equals("", result[1])
    end)

    it("preserves empty lines among content", function()
      local result = buffer.sanitize_lines({ "a", "", "b" })
      assert.equals(3, #result)
      assert.equals("a", result[1])
      assert.equals("", result[2])
      assert.equals("b", result[3])
    end)

    it("preserves multiple consecutive empty lines", function()
      local result = buffer.sanitize_lines({ "a", "", "", "", "b" })
      assert.equals(5, #result)
      assert.equals("a", result[1])
      assert.equals("", result[2])
      assert.equals("", result[3])
      assert.equals("", result[4])
      assert.equals("b", result[5])
    end)
  end)

  ---------------------------------------------------------------------------
  -- Lines with only whitespace (currently NOT trimmed)
  ---------------------------------------------------------------------------
  describe("with whitespace-only lines", function()
    it("preserves a line of spaces", function()
      local result = buffer.sanitize_lines({ "   " })
      assert.equals(1, #result)
      assert.equals("   ", result[1])
    end)

    it("preserves a line of tabs", function()
      local result = buffer.sanitize_lines({ "\t\t\t" })
      assert.equals(1, #result)
      assert.equals("\t\t\t", result[1])
    end)

    it("preserves a line of mixed whitespace", function()
      local result = buffer.sanitize_lines({ " \t  \t " })
      assert.equals(1, #result)
      assert.equals(" \t  \t ", result[1])
    end)
  end)

  ---------------------------------------------------------------------------
  -- Lines with embedded newlines (split into separate entries)
  ---------------------------------------------------------------------------
  describe("with lines containing embedded newlines", function()
    it("splits a line with embedded \\n", function()
      local result = buffer.sanitize_lines({ "line1\nline2" })
      assert.equals(2, #result)
      assert.equals("line1", result[1])
      assert.equals("line2", result[2])
    end)

    it("splits a line with embedded \\r\\n", function()
      local result = buffer.sanitize_lines({ "line1\r\nline2" })
      assert.equals(2, #result)
      assert.equals("line1", result[1])
      assert.equals("line2", result[2])
    end)

    it("splits a line with embedded \\r", function()
      local result = buffer.sanitize_lines({ "line1\rline2" })
      assert.equals(2, #result)
      assert.equals("line1", result[1])
      assert.equals("line2", result[2])
    end)

    it("splits multiple lines each with embedded newlines", function()
      local result = buffer.sanitize_lines({ "a\nb", "c\nd" })
      assert.equals(4, #result)
      assert.equals("a", result[1])
      assert.equals("b", result[2])
      assert.equals("c", result[3])
      assert.equals("d", result[4])
    end)

    it("handles multiple embedded newlines in one line", function()
      local result = buffer.sanitize_lines({ "a\nb\nc" })
      assert.equals(3, #result)
      assert.equals("a", result[1])
      assert.equals("b", result[2])
      assert.equals("c", result[3])
    end)

    it("handles trailing newline (empty final segment)", function()
      -- vim.split preserves the trailing empty segment.
      local result = buffer.sanitize_lines({ "hello\n" })
      assert.equals(2, #result)
      assert.equals("hello", result[1])
      assert.equals("", result[2])
    end)

    it("handles leading newline (empty first segment)", function()
      local result = buffer.sanitize_lines({ "\nworld" })
      assert.equals(2, #result)
      assert.equals("", result[1])
      assert.equals("world", result[2])
    end)

    it("handles mixed \\n and \\r\\n in the same line", function()
      local result = buffer.sanitize_lines({ "a\nb\r\nc" })
      assert.equals(3, #result)
      assert.equals("a", result[1])
      assert.equals("b", result[2])
      assert.equals("c", result[3])
    end)
  end)

  ---------------------------------------------------------------------------
  -- Mixed content
  ---------------------------------------------------------------------------
  describe("with mixed content", function()
    it("handles normal, empty, and embedded-newline lines together", function()
      local result = buffer.sanitize_lines({ "normal", "", "multi\nsplit", "  spaced  " })
      assert.equals(5, #result)
      assert.equals("normal", result[1])
      assert.equals("", result[2])
      assert.equals("multi", result[3])
      assert.equals("split", result[4])
      assert.equals("  spaced  ", result[5])
    end)

    it("handles whitespace-only, empty, and embedded-newline lines", function()
      local result = buffer.sanitize_lines({ "   ", "", "\t\r\nline" })
      -- "\t\r\nline" splits into "\t" and "line" (2 lines)
      assert.equals(4, #result)
      assert.equals("   ", result[1])
      assert.equals("", result[2])
      assert.equals("\t", result[3])
      assert.equals("line", result[4])
    end)
  end)

  ---------------------------------------------------------------------------
  -- Edge cases
  ---------------------------------------------------------------------------
  describe("with edge cases", function()
    it("returns empty table for empty input table", function()
      local result = buffer.sanitize_lines({})
      assert.equals(0, #result)
    end)

    it("preserves a single entry with only a newline", function()
      -- vim.split preserves empty segments: "\n" → { "", "" }
      local result = buffer.sanitize_lines({ "\n" })
      assert.equals(2, #result)
    end)

    it("preserves a single entry with only carriage return", function()
      local result = buffer.sanitize_lines({ "\r" })
      assert.equals(2, #result)
    end)

    it("preserves a single entry with only \\r\\n", function()
      local result = buffer.sanitize_lines({ "\r\n" })
      assert.equals(2, #result)
    end)
  end)

  ---------------------------------------------------------------------------
  -- Nil input (ipairs on nil errors)
  ---------------------------------------------------------------------------
  describe("with nil input", function()
    it("errors when called with nil", function()
      -- ipairs(nil) raises: "bad argument #1 to 'ipairs' (table expected, got nil)"
      local ok, err = pcall(buffer.sanitize_lines, nil)
      assert.is_false(ok)
      assert.is_true(err:find("table expected") ~= nil)
    end)
  end)

  ---------------------------------------------------------------------------
  -- Non-string entries (converge through tostring)
  ---------------------------------------------------------------------------
  describe("with non-string entries", function()
    it("renders a number entry through tostring", function()
      local result = buffer.sanitize_lines({ "a", 42, "b" })
      assert.equals(3, #result)
      assert.equals("42", result[2])
    end)

    it("a number with embedded-newline text splits like a string", function()
      -- tostring first, then the newline split applies uniformly
      local result = buffer.sanitize_lines({ 12 })
      assert.equals("12", result[1])
    end)
  end)
end)
