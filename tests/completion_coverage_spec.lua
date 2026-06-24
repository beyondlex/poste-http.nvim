-- Additional coverage tests for poste.http.completion
-- Covers gaps: status_code, import/run directives, build_keyword_items, M.register, M.status

local completion = require("poste.http.completion")
local test = completion._test

---------------------------------------------------------------------------
-- build_keyword_items unit tests
---------------------------------------------------------------------------
describe("build_keyword_items", function()
  it("returns empty table for empty input", function()
    local items = test.build_keyword_items({}, 14)
    assert.equals(0, #items)
  end)

  it("builds items with correct structure for each keyword", function()
    local keywords = {
      { name = "client.test", desc = "Define named test block" },
      { name = "client.assert", desc = "Assert condition" },
    }
    local items = test.build_keyword_items(keywords, 3) -- KIND_FUNCTION

    assert.equals(2, #items)

    local item1 = items[1]
    assert.equals("client.test", item1.label)
    assert.equals(3, item1.kind)
    assert.equals("client.test", item1.insertText)
    assert.equals("client.test", item1.filterText)
    assert.equals("client.test", item1.sortText)
    assert.equals("Define named test block", item1.detail)
  end)

  it("preserves keyword order", function()
    local keywords = {
      { name = "alpha", desc = "first" },
      { name = "beta", desc = "second" },
      { name = "gamma", desc = "third" },
    }
    local items = test.build_keyword_items(keywords, 6)

    assert.equals("alpha", items[1].label)
    assert.equals("beta", items[2].label)
    assert.equals("gamma", items[3].label)
  end)

  it("uses the same kind for all items", function()
    local keywords = {
      { name = "a", desc = "x" },
      { name = "b", desc = "y" },
    }
    local items = test.build_keyword_items(keywords, 12)

    for _, item in ipairs(items) do
      assert.equals(12, item.kind)
    end
  end)
end)

---------------------------------------------------------------------------
-- status_code context tests
---------------------------------------------------------------------------
describe("status_code context", function()
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

  it("detects status_code context for response.status == 200", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api",
      "> {%",
      "  client.assert(response.status == 200)",
      "%}",
    })
    local ctx, extra = test.detect_context("  client.assert(response.status == 200", buf, 3, 40)
    assert.equals("status_code", ctx)
    assert.equals("  client.assert(response.status == 200", extra)
  end)

  it("detects status_code context for response.status ~= 404", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api",
      "> {%",
      "  client.assert(response.status ~= 404)",
      "%}",
    })
    local ctx = test.detect_context("  response.status ~= 4", buf, 3, 30)
    assert.equals("status_code", ctx)
  end)

  it("detects status_code context for response.status > 300", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api",
      "> {%",
      "  client.assert(response.status > 300)",
      "%}",
    })
    local ctx = test.detect_context("  response.status > 3", buf, 3, 30)
    assert.equals("status_code", ctx)
  end)

  it("detects status_code context for response.status < 500", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api",
      "> {%",
      "  client.assert(response.status < 500)",
      "%}",
    })
    local ctx = test.detect_context("  response.status < 5", buf, 3, 30)
    assert.equals("status_code", ctx)
  end)

  it("does NOT detect status_code for response.headers", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api",
      "> {%",
      "  response.headers",
      "%}",
    })
    local ctx = test.detect_context("  response.headers", buf, 3, 20)
    assert.equals("post_script", ctx)
  end)

  it("returns status code items with correct structure", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api",
      "> {%",
      "  client.assert(response.status == 200)",
      "%}",
    })
    local ctx = test.detect_context("  response.status == ", buf, 3, 30)
    assert.equals("status_code", ctx)

    local items = test.get_items_for_context("  response.status == ", buf, 3, 30)
    assert.is_true(#items > 0)

    -- Check a few specific status codes exist (items are sorted by code, so 100 is first)
    local labels = {}
    for _, item in ipairs(items) do
      labels[item.label] = item
    end

    assert.is_true(labels["200"] ~= nil)
    assert.is_true(labels["404"] ~= nil)
    assert.is_true(labels["500"] ~= nil)
    assert.is_true(labels["100"] ~= nil) -- 1xx
    assert.is_true(labels["403"] ~= nil) -- 4xx

    -- Status code items should have kind = KIND_VALUE (12)
    assert.equals(12, items[1].kind)
    assert.equals("100", items[1].label) -- First item is 100 (1xx class)
    assert.is_not_nil(items[1].detail) -- description should be present
  end)

  it("status code items include all major HTTP classes", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api",
      "> {%",
      "  client.assert(response.status == 200)",
      "%}",
    })
    local items = test.get_items_for_context("  response.status == ", buf, 3, 30)
    local labels = {}
    for _, item in ipairs(items) do
      labels[item.label] = true
    end

    -- 1xx
    assert.is_true(labels["100"] or labels["101"] or labels["102"] or labels["103"])
    -- 2xx
    assert.is_true(labels["200"] or labels["201"] or labels["204"])
    -- 3xx
    assert.is_true(labels["301"] or labels["302"] or labels["304"])
    -- 4xx
    assert.is_true(labels["400"] or labels["401"] or labels["403"] or labels["404"])
    -- 5xx
    assert.is_true(labels["500"] or labels["502"] or labels["503"] or labels["504"])
  end)
end)

---------------------------------------------------------------------------
-- import directive context tests
---------------------------------------------------------------------------
describe("import directive context", function()
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

  it("detects import_path context after 'import '", function()
    local ctx = test.detect_context("import ", buf, 1, 7)
    assert.equals("import_path", ctx)
  end)

  it("returns no context after 'import .' (path already specified)", function()
    local ctx = test.detect_context("import .", buf, 1, 8)
    assert.is_nil(ctx)
  end)

  it("returns no context after 'import ./path' (path already specified)", function()
    local ctx = test.detect_context("import ./auth.http", buf, 1, 19)
    assert.is_nil(ctx)
  end)

  it("detects import_alias context after 'import ./path a'", function()
    local ctx = test.detect_context("import ./auth.http a", buf, 1, 21)
    assert.equals("import_alias", ctx)
  end)

  it("detects import_alias context after 'import ./path as'", function()
    local ctx = test.detect_context("import ./auth.http as", buf, 1, 22)
    assert.equals("import_alias", ctx)
  end)

  it("returns no context after complete import with alias", function()
    local ctx = test.detect_context("import ./auth.http as auth", buf, 1, 27)
    assert.is_nil(ctx)
  end)

  it("returns import_path items suggesting ./ and ../", function()
    local items = test.get_items_for_context("import ", buf, 1, 7)
    local labels = {}
    for _, item in ipairs(items) do
      labels[item.label] = true
    end
    assert.is_true(labels["./"] or labels["../"])
  end)

  it("returns import_alias items suggesting 'as'", function()
    local items = test.get_items_for_context("import ./auth.http a", buf, 1, 21)
    assert.equals(1, #items)
    assert.equals("as", items[1].label)
    assert.equals(14, items[1].kind) -- KIND_KEYWORD
  end)
end)

---------------------------------------------------------------------------
-- run directive context tests
---------------------------------------------------------------------------
describe("run directive context", function()
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

  it("detects run_target context after 'run '", function()
    local ctx = test.detect_context("run ", buf, 1, 5)
    assert.equals("run_target", ctx)
  end)

  it("detects run_target_hash context after 'run #'", function()
    local ctx = test.detect_context("run #", buf, 1, 6)
    assert.equals("run_target_hash", ctx)
  end)

  it("detects run_target_hash context after 'run #Login'", function()
    local ctx = test.detect_context("run #Login", buf, 1, 12)
    assert.equals("run_target_hash", ctx)
  end)

  it("detects run_target context after 'run ./path'", function()
    local ctx = test.detect_context("run ./orders.http", buf, 1, 19)
    assert.equals("run_target", ctx)
  end)

  it("detects run_target_alias context after 'run #alias.Name'", function()
    local ctx = test.detect_context("run #auth.login", buf, 1, 16)
    assert.equals("run_target_alias", ctx)
  end)

  it("returns run_target items suggesting # and ./", function()
    local items = test.get_items_for_context("run ", buf, 1, 5)
    local labels = {}
    for _, item in ipairs(items) do
      labels[item.label] = true
    end
    assert.is_true(labels["#"] or labels["./"])
  end)
end)

---------------------------------------------------------------------------
-- nvim-cmp source:complete() detailed tests
---------------------------------------------------------------------------
describe("nvim-cmp source:complete() detailed", function()
  local source = completion.source

  it("returns items for method context in nvim-cmp", function()
    if not pcall(require, "cmp") then pending("nvim-cmp not installed"); return end
    local instance = source.new()
    local response

    instance:complete(
      { context = { cursor_before_line = "" }, offset = 1 },
      function(resp) response = resp end
    )

    assert.is_true(#response.items > 0)
    local labels = {}
    for _, item in ipairs(response.items) do
      labels[item.label] = true
    end
    assert.is_true(labels["GET"] or labels["POST"])
  end)

  it("returns items for header value context in nvim-cmp", function()
    if not pcall(require, "cmp") then pending("nvim-cmp not installed"); return end
    local instance = source.new()
    local response

    instance:complete(
      { context = { cursor_before_line = "Content-Type: " }, offset = 15 },
      function(resp) response = resp end
    )

    assert.is_true(#response.items > 0)
    local labels = {}
    for _, item in ipairs(response.items) do
      labels[item.label] = true
    end
    assert.is_true(labels["application/json"] or labels["text/html"])
  end)

  it("returns empty items for unknown header value", function()
    if not pcall(require, "cmp") then pending("nvim-cmp not installed"); return end
    local instance = source.new()
    local response

    instance:complete(
      { context = { cursor_before_line = "X-Unknown: " }, offset = 12 },
      function(resp) response = resp end
    )

    assert.equals(0, #response.items)
  end)

  it("returns items for variable context in nvim-cmp", function()
    if not pcall(require, "cmp") then pending("nvim-cmp not installed"); return end
    local instance = source.new()
    local response

    instance:complete(
      { context = { cursor_before_line = "GET {{host" }, offset = 10 },
      function(resp) response = resp end
    )

    assert.is_true(#response.items > 0)
  end)

  it("returns items for pre_script context in nvim-cmp", function()
    if not pcall(require, "cmp") then pending("nvim-cmp not installed"); return end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "< {%",
      "  req",
      "%}",
    })

    local instance = source.new()
    local response

    instance:complete(
      {
        context = { cursor_before_line = "  req" },
        offset = 5,
      },
      function(resp) response = resp end
    )

    -- Should contain pre-request keywords
    local found_test = false
    for _, item in ipairs(response.items) do
      if item.label == "request.variables.set" then
        found_test = true
        break
      end
    end
    assert.is_true(found_test, "Should contain request.variables.set")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns items for post_script context in nvim-cmp", function()
    if not pcall(require, "cmp") then pending("nvim-cmp not installed"); return end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api",
      "> {%",
      "  cli",
      "%}",
    })

    local instance = source.new()
    local response

    instance:complete(
      {
        context = { cursor_before_line = "  cli" },
        offset = 5,
      },
      function(resp) response = resp end
    )

    -- Should contain post-request keywords
    local found_test = false
    local found_assert = false
    for _, item in ipairs(response.items) do
      if item.label == "client.test" then found_test = true end
      if item.label == "client.assert" then found_assert = true end
    end
    assert.is_true(found_test, "Should contain client.test")
    assert.is_true(found_assert, "Should contain client.assert")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns items with correct kind IDs in nvim-cmp", function()
    if not pcall(require, "cmp") then pending("nvim-cmp not installed"); return end
    local instance = source.new()
    local response

    instance:complete(
      { context = { cursor_before_line = "" }, offset = 1 },
      function(resp) response = resp end
    )

    -- All items should have a valid kind (1-30 range for LSP kinds)
    for _, item in ipairs(response.items) do
      assert.is_true(item.kind >= 1 and item.kind <= 30,
        "Invalid kind " .. item.kind .. " for label " .. item.label)
    end
  end)
end)

---------------------------------------------------------------------------
-- M.register() and M.status() tests
---------------------------------------------------------------------------
describe("M.register() and M.status()", function()
  it("M.register() is a function", function()
    assert.is_true(type(completion.register) == "function")
  end)

  it("M.status() returns a string", function()
    local status = completion.status()
    assert.is_true(type(status) == "string")
    assert.is_not.equals("", status)
  end)

  it("M.status() returns 'no completion engine registered' when not registered", function()
    -- Reset registration state by requiring fresh module
    package.loaded["poste.http.completion"] = nil
    local fresh_completion = require("poste.http.completion")
    local status = fresh_completion.status()
    assert.equals("no completion engine registered", status)
  end)
end)

---------------------------------------------------------------------------
-- Edge cases and integration tests
---------------------------------------------------------------------------
describe("edge cases", function()
  it("handles nil buffer in get_items_for_context", function()
    local items = test.get_items_for_context("", nil, 1, 0)
    assert.is_true(type(items) == "table")
  end)

  it("handles nil cursor_line in get_items_for_context", function()
    local items = test.get_items_for_context("", 0, nil, 0)
    assert.is_true(type(items) == "table")
  end)

  it("handles empty string for all contexts", function()
    local items = test.get_items_for_context("")
    assert.is_true(#items > 0) -- Should return method + header + directive items
  end)

  it("detect_context returns nil for URL lines", function()
    local ctx = test.detect_context("https://api.example.com/users")
    assert.is_nil(ctx)
  end)

  it("detect_context returns nil for complete request line", function()
    local ctx = test.detect_context("GET /api/users")
    assert.is_nil(ctx)
  end)
end)
