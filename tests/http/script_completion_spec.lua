--- Tests for pre/post script keyword completion.

local completion = require("poste.http.completion")
local test = completion._test

describe("detect_script_context", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("returns nil when not in script block", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "Content-Type: application/json",
    })
    local result = test.detect_script_context(buf, 1, 5)
    assert.equals(nil, result)
  end)

  it("detects pre-request script on single-line < {% ... %}", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {% request.variables.set(\"token\", \"abc\") %}",
      "GET /api/users",
    })
    -- Cursor after < {%
    local result = test.detect_script_context(buf, 1, 10)
    assert.equals("pre_script", result)
  end)

  it("detects pre-request script in multi-line block", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  local x = 1",
      "  client.log(\"test\")",
      "%}",
      "GET /api/users",
    })
    -- Cursor on line 3 (inside block)
    local result = test.detect_script_context(buf, 3, 5)
    assert.equals("pre_script", result)
  end)

  it("detects post-request script on single-line > {% ... %}", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {% client.test(\"status\", function() end) %}",
    })
    local result = test.detect_script_context(buf, 2, 15)
    assert.equals("post_script", result)
  end)

  it("detects post-request script in multi-line block", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  client.test(\"test\", function()",
      "    client.assert(response.status == 200)",
      "  end)",
      "%}",
    })
    -- Cursor on line 4 (inside block)
    local result = test.detect_script_context(buf, 4, 10)
    assert.equals("post_script", result)
  end)

  it("returns nil after script block closes", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  local x = 1",
      "%}",
      "GET /api/users",
    })
    -- Cursor on line 4 (after block)
    local result = test.detect_script_context(buf, 4, 5)
    assert.equals(nil, result)
  end)

  it("handles cursor on closing %} line", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  local x = 1",
      "%}",
    })
    -- Cursor before %} on closing line
    local result = test.detect_script_context(buf, 3, 0)
    assert.equals("pre_script", result)
  end)

  it("distinguishes pre from post scripts", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  request.variables.set(\"a\", 1)",
      "%}",
      "GET /api/users",
      "> {%",
      "  client.test(\"check\", function() end)",
      "%}",
    })
    -- In pre-request block
    local pre_result = test.detect_script_context(buf, 2, 5)
    assert.equals("pre_script", pre_result)

    -- In post-request block
    local post_result = test.detect_script_context(buf, 6, 5)
    assert.equals("post_script", post_result)
  end)
end)

describe("detect_context with script blocks", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("returns 'pre_script' inside pre-request block", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  req",
      "%}",
      "GET /api/users",
    })
    local ctx, _ = test.detect_context("  req", buf, 2, 5)
    assert.equals("pre_script", ctx)
  end)

  it("returns 'post_script' inside post-request block", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  cli",
      "%}",
    })
    local ctx, _ = test.detect_context("  cli", buf, 3, 5)
    assert.equals("post_script", ctx)
  end)

  it("script context takes precedence over method context", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "",
      "%}",
    })
    -- Empty line inside script block
    local ctx, _ = test.detect_context("", buf, 2, 0)
    assert.equals("pre_script", ctx)
  end)
end)

describe("get_items_for_context script completion", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("returns pre-request keywords in pre-request script", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  req",
      "%}",
      "GET /api/users",
    })
    local items = test.get_items_for_context("  req", buf, 2, 5)
    assert.truthy(#items > 0)

    -- Should contain request.variables.set
    local found = false
    for _, item in ipairs(items) do
      if item.label == "request.variables.set" then
        found = true
        break
      end
    end
    assert.truthy(found, "Should contain request.variables.set")
  end)

  it("returns assertion keywords in post-request script", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  cli",
      "%}",
    })
    local items = test.get_items_for_context("  cli", buf, 3, 5)
    assert.truthy(#items > 0)

    -- Should contain client.test and response.status
    local has_test = false
    local has_response = false
    for _, item in ipairs(items) do
      if item.label == "client.test" then has_test = true end
      if item.label == "response.status" then has_response = true end
    end
    assert.truthy(has_test, "Should contain client.test")
    assert.truthy(has_response, "Should contain response.status")
  end)

  it("pre-request keywords do not include assertion-specific items", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  ",
      "%}",
      "GET /api/users",
    })
    local items = test.get_items_for_context("  ", buf, 2, 2)

    -- Should NOT contain client.test or response.*
    for _, item in ipairs(items) do
      assert.is_not.equals("client.test", item.label)
      assert.is_not.equals("response.status", item.label)
      assert.is_not.equals("client.assert", item.label)
    end
  end)

  it("post-request keywords include pre-request keywords (client.global, etc)", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  cli",
      "%}",
    })
    local items = test.get_items_for_context("  cli", buf, 3, 5)

    -- Should contain client.global.set from pre-request API
    local has_global = false
    for _, item in ipairs(items) do
      if item.label == "client.global.set" then
        has_global = true
        break
      end
    end
    assert.truthy(has_global, "Should contain client.global.set")
  end)

  it("script items have correct structure", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  ",
      "%}",
    })
    local items = test.get_items_for_context("  ", buf, 2, 2)

    for _, item in ipairs(items) do
      assert.truthy(item.label)
      assert.truthy(item.kind)
      assert.truthy(item.insertText)
    end
  end)
end)

describe("script keyword data", function()
  it("pre_script_keywords contains request.variables.set", function()
    local found = false
    for _, kw in ipairs(test.pre_script_keywords) do
      if kw.name == "request.variables.set" then
        found = true
        break
      end
    end
    assert.truthy(found)
  end)

  it("post_script_keywords contains client.test", function()
    local found = false
    for _, kw in ipairs(test.post_script_keywords) do
      if kw.name == "client.test" then
        found = true
        break
      end
    end
    assert.truthy(found)
  end)

  it("post_script_keywords contains response object properties", function()
    local response_props = {
      "response.status",
      "response.headers",
      "response.body",
      "response.content_type",
      "response.latency_ms",
      "response.url",
    }

    for _, prop in ipairs(response_props) do
      local found = false
      for _, kw in ipairs(test.post_script_keywords) do
        if kw.name == prop then
          found = true
          break
        end
      end
      assert.truthy(found, "Missing: " .. prop)
    end
  end)
end)

describe("lua completion in script blocks", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("lua keywords are returned in pre-script context", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  lo",
      "%}",
      "GET /api/users",
    })
    local items = test.get_items_for_context("  lo", buf, 2, 4)
    assert.truthy(#items > 0)

    local found = false
    for _, item in ipairs(items) do
      if item.label == "local" then
        found = true
        break
      end
    end
    assert.truthy(found, "Should contain 'local' Lua keyword")
  end)

  it("lua keywords are returned in post-script context", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  fu",
      "%}",
    })
    local items = test.get_items_for_context("  fu", buf, 3, 4)
    assert.truthy(#items > 0)

    local found = false
    for _, item in ipairs(items) do
      if item.label == "function" then
        found = true
        break
      end
    end
    assert.truthy(found, "Should contain 'function' Lua keyword")
  end)

  it("lua sandbox functions are returned in pre-script context", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  tos",
      "%}",
      "GET /api/users",
    })
    local items = test.get_items_for_context("  tos", buf, 2, 5)
    assert.truthy(#items > 0)

    local found = false
    for _, item in ipairs(items) do
      if item.label == "tostring" then
        found = true
        break
      end
    end
    assert.truthy(found, "Should contain 'tostring' sandbox function")
  end)

  it("lua sandbox functions are returned in post-script context", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  pca",
      "%}",
    })
    local items = test.get_items_for_context("  pca", buf, 3, 5)
    assert.truthy(#items > 0)

    local found = false
    for _, item in ipairs(items) do
      if item.label == "pcall" then
        found = true
        break
      end
    end
    assert.truthy(found, "Should contain 'pcall' sandbox function")
  end)

  it("lua keyword 'if' appears in pre-script completion", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  ",
      "%}",
      "GET /api/users",
    })
    local items = test.get_items_for_context("  ", buf, 2, 2)
    assert.truthy(#items > 0)

    local found = false
    for _, item in ipairs(items) do
      if item.label == "if" then
        found = true
        break
      end
    end
    assert.truthy(found, "Should contain 'if' Lua keyword")
  end)

  it("module names use PROPERTY kind (no auto-())", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  str",
      "%}",
      "GET /api/users",
    })
    local items = test.get_items_for_context("  str", buf, 2, 5)
    local found = false
    for _, item in ipairs(items) do
      if item.label == "string" then
        found = true
        assert.equals(10, item.kind, "string should use PROPERTY kind (10), got " .. item.kind)
        break
      end
    end
    assert.truthy(found, "Should contain string module item")
  end)

  it("os. suggests os.time and os.date", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "os.",
      "%}",
      "GET /api/users",
    })
    local items = test.get_items_for_context("os.", buf, 2, 3)
    assert.truthy(#items > 0)

    local has_time = false
    local has_date = false
    for _, item in ipairs(items) do
      if item.label == "os.time" then has_time = true end
      if item.label == "os.date" then has_date = true end
    end
    assert.truthy(has_time, "Should contain os.time")
    assert.truthy(has_date, "Should contain os.date")
  end)

  it("os.ti filters to os.time", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "os.ti",
      "%}",
      "GET /api/users",
    })
    local items = test.get_items_for_context("os.ti", buf, 2, 5)
    assert.truthy(#items > 0)

    local found = false
    for _, item in ipairs(items) do
      if item.label == "os.time" then
        found = true
        break
      end
    end
    assert.truthy(found, "Should contain os.time")
  end)

  it("string. suggests string.find, string.match, etc.", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "string.",
      "%}",
      "GET /api/users",
    })
    local items = test.get_items_for_context("string.", buf, 2, 7)
    assert.truthy(#items > 0)

    local has_find = false
    local has_match = false
    local has_format = false
    for _, item in ipairs(items) do
      if item.label == "string.find" then has_find = true end
      if item.label == "string.match" then has_match = true end
      if item.label == "string.format" then has_format = true end
    end
    assert.truthy(has_find, "Should contain string.find")
    assert.truthy(has_match, "Should contain string.match")
    assert.truthy(has_format, "Should contain string.format")
  end)

  it("unknown module prefix returns regular script items", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "foo.",
      "%}",
      "GET /api/users",
    })
    local items = test.get_items_for_context("foo.", buf, 2, 4)
    assert.truthy(#items > 0)
    local has_if = false
    for _, item in ipairs(items) do
      if item.label == "if" then
        has_if = true
        break
      end
    end
    assert.truthy(has_if, "Should fall back to Lua keywords for unknown module")
  end)
end)
