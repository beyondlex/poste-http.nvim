--- Tests for completion context (Phase 2).
--- Tests context_detector.lua using cache.lua's line_type and block index.

local context_detector = require("poste.http.context_detector")
local cache = require("poste.http.cache")

local function create_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("completion context", function()
  describe("detect_script_context", function()
    it("returns nil for non-script line", function()
      local buf = create_buf({
        "### Get",
        "GET /users",
      })
      local result = context_detector.detect_script_context(buf, 2, 1)
      assert.is_nil(result)
    end)

    it("returns 'pre_script' inside < {% %}", function()
      local buf = create_buf({
        "### Get",
        "< {%",
        "  local x = 1",
        "  x = x + 1",
        "%}",
        "GET /users",
      })
      local result = context_detector.detect_script_context(buf, 3, 5)
      assert.equals("pre_script", result)
    end)

    it("returns 'post_script' inside > {% %}", function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "",
        '{"page":1}',
        "> {%",
        "  client.test('status', function()",
        "    client.assert(response.status == 200)",
        "  end)",
        "%}",
      })
      local result = context_detector.detect_script_context(buf, 6, 10)
      assert.equals("post_script", result)
    end)
  end)

  describe("detect_context", function()
    it("returns 'pre_script' inside pre-script", function()
      local buf = create_buf({
        "### Get",
        "< {%",
        "  req",
        "%}",
        "GET /users",
      })
      local ctx, _ = context_detector.detect_context("  req", buf, 3, 5)
      assert.equals("pre_script", ctx)
    end)

    it("returns 'method' on empty line after ###", function()
      local buf = create_buf({
        "### Get",
        "",
      })
      local ctx, extra = context_detector.detect_context("", buf, 2, 0)
      assert.equals("method", ctx)
      assert.is_nil(extra)
    end)

    it("returns 'header_value' after colon", function()
      local ctx, extra = context_detector.detect_context("Content-Type: ", nil, nil, nil)
      assert.equals("header_value", ctx)
      assert.equals("Content-Type", extra)
    end)

    it("returns 'variable' inside {{", function()
      local ctx, extra = context_detector.detect_context("{{base_", nil, nil, nil)
      assert.equals("variable", ctx)
      assert.equals("base_", extra)
    end)

    it("returns 'method_or_header' for single word", function()
      local ctx, extra = context_detector.detect_context("GET", nil, nil, nil)
      assert.equals("method_or_header", ctx)
      assert.is_nil(extra)
    end)

    it("returns nil for comment line", function()
      local ctx = context_detector.detect_context("# this is a comment", nil, nil, nil)
      assert.is_nil(ctx)
    end)

    it("returns nil for URL line", function()
      local ctx = context_detector.detect_context("GET https://api.example.com/users", nil, nil, nil)
      assert.is_nil(ctx)
    end)
  end)

  describe("collect_request_vars", function()
    it("returns block vars", function()
      local buf = create_buf({
        "### Get",
        "@limit = 20",
        "GET /users",
      })
      local vars = cache.collect_request_vars(buf, 3)
      assert.is_true(vars["limit"], "limit should be in block vars")
      assert.equals(1, vim.tbl_count(vars), "should have exactly 1 var")
    end)

    it("returns empty for file-level line", function()
      local buf = create_buf({
        "@base_url = http://example.com",
        "### Get",
      })
      local vars = cache.collect_request_vars(buf, 1)
      assert.equals(0, vim.tbl_count(vars), "file-level line should have no block vars")
    end)
  end)
end)
