-- Integration tests for completion module
-- Tests the full completion flow through get_completions() and get_items_for_context()

local completion = require("poste.completion")
local get_items_for_context = completion._test.get_items_for_context

describe("get_items_for_context", function()
  describe("method and header completion", function()
    it("returns HTTP methods for empty line", function()
      local items = get_items_for_context("")

      assert.is_true(#items > 0)

      -- Should include common HTTP methods
      local labels = {}
      for _, item in ipairs(items) do
        labels[item.label] = true
      end

      assert.is_true(labels["GET"] or labels["POST"])
    end)

    it("returns header names for partial input", function()
      local items = get_items_for_context("Con")

      assert.is_true(#items > 0)

      -- Should include headers starting with "Con"
      local found = false
      for _, item in ipairs(items) do
        if item.label:find("^Con") then
          found = true
          break
        end
      end

      assert.is_true(found)
    end)
  end)

  describe("header value completion", function()
    it("returns MIME types for Content-Type header", function()
      local items = get_items_for_context("Content-Type: ")

      assert.is_true(#items > 0)

      -- Should include common MIME types
      local labels = {}
      for _, item in ipairs(items) do
        labels[item.label] = true
      end

      assert.is_true(labels["application/json"] or labels["text/html"])
    end)

    it("returns encoding values for Accept-Encoding header", function()
      local items = get_items_for_context("Accept-Encoding: ")

      assert.is_true(#items > 0)

      local labels = {}
      for _, item in ipairs(items) do
        labels[item.label] = true
      end

      assert.is_true(labels["gzip"] or labels["deflate"])
    end)

    it("returns empty for unknown header", function()
      local items = get_items_for_context("X-Unknown-Header: ")
      assert.equals(0, #items)
    end)
  end)

  describe("variable completion", function()
    -- Note: Variable completion requires a buffer with content.
    -- These tests focus on the context detection part.

    it("detects variable context with {{", function()
      local items = get_items_for_context("GET {{")

      -- Should return magic variables at minimum
      assert.is_true(#items >= 4) -- $timestamp, $uuid, $date, $randomInt
    end)

    it("returns only magic variables for {{$", function()
      local items = get_items_for_context("{{$")

      -- All items should start with $
      for _, item in ipairs(items) do
        assert.equals("$", item.label:sub(1, 1))
      end
    end)

    it("includes all four magic variables", function()
      local items = get_items_for_context("{{$")

      local labels = {}
      for _, item in ipairs(items) do
        labels[item.label] = true
      end

      assert.is_true(labels["$timestamp"])
      assert.is_true(labels["$uuid"])
      assert.is_true(labels["$date"])
      assert.is_true(labels["$randomInt"])
    end)
  end)

  describe("item structure", function()
    it("all items have required fields", function()
      local items = get_items_for_context("")

      for _, item in ipairs(items) do
        assert.is_not_nil(item.label)
        assert.is_not_nil(item.kind)
        assert.is_not_nil(item.insertText)
      end
    end)

    it("header value items have correct kind", function()
      local items = get_items_for_context("Content-Type: ")

      for _, item in ipairs(items) do
        assert.equals(12, item.kind) -- KIND_VALUE
      end
    end)
  end)
end)

describe("blink.cmp integration", function()
  it("get_completions calls callback with correct response shape", function()
    local response

    completion:get_completions(
      { line = "", cursor = { 1, 0 }, bufnr = 0 },
      function(resp) response = resp end
    )

    assert.is_not_nil(response)
    assert.is_not_nil(response.items)
    assert.is_table(response.items)
    assert.is_not_nil(response.is_incomplete_forward)
    assert.is_not_nil(response.is_incomplete_backward)
  end)

  it("get_completions returns items for method context", function()
    local response

    completion:get_completions(
      { line = "", cursor = { 1, 0 }, bufnr = 0 },
      function(resp) response = resp end
    )

    assert.is_true(#response.items > 0)
  end)

  it("get_completions returns items for header value context", function()
    local response

    completion:get_completions(
      { line = "Content-Type: ", cursor = { 1, 14 }, bufnr = 0 },
      function(resp) response = resp end
    )

    assert.is_true(#response.items > 0)
  end)

  it("enabled() returns true for poste_http filetype", function()
    -- Save current filetype
    local old_ft = vim.bo.filetype

    vim.bo.filetype = "poste_http"
    assert.is_true(completion:enabled())

    -- Restore
    vim.bo.filetype = old_ft
  end)

  it("get_trigger_characters() returns expected characters", function()
    local chars = completion:get_trigger_characters()

    assert.is_table(chars)
    assert.is_true(vim.tbl_contains(chars, " "))
    assert.is_true(vim.tbl_contains(chars, ":"))
    assert.is_true(vim.tbl_contains(chars, "{"))
  end)
end)

describe("nvim-cmp integration", function()
  local source = completion.source

  it("source.new() creates instance", function()
    local instance = source.new()
    assert.is_not_nil(instance)
  end)

  it("source:get_debug_name() returns 'poste'", function()
    local instance = source.new()
    assert.equals("poste", instance:get_debug_name())
  end)

  it("source:get_trigger_characters() returns expected characters", function()
    local instance = source.new()
    local chars = instance:get_trigger_characters()

    assert.is_table(chars)
    assert.is_true(vim.tbl_contains(chars, " "))
    assert.is_true(vim.tbl_contains(chars, ":"))
  end)

  it("source:is_available() returns true for poste_http", function()
    local old_ft = vim.bo.filetype
    vim.bo.filetype = "poste_http"

    local instance = source.new()
    assert.is_true(instance:is_available())

    vim.bo.filetype = old_ft
  end)

  it("source:complete() calls callback with items", function()
    -- Skip if nvim-cmp is not installed
    local ok, _ = pcall(require, "cmp")
    if not ok then
      pending("nvim-cmp not installed, skipping")
      return
    end

    local response

    local instance = source.new()
    instance:complete(
      {
        context = { cursor_before_line = "" },
        offset = 1,
      },
      function(resp) response = resp end
    )

    assert.is_not_nil(response)
    assert.is_not_nil(response.items)
    assert.is_table(response.items)
  end)

  it("source:complete() returns items for method context", function()
    -- Skip if nvim-cmp is not installed
    local ok, _ = pcall(require, "cmp")
    if not ok then
      pending("nvim-cmp not installed, skipping")
      return
    end

    local response

    local instance = source.new()
    instance:complete(
      {
        context = { cursor_before_line = "" },
        offset = 1,
      },
      function(resp) response = resp end
    )

    assert.is_true(#response.items > 0)
  end)
end)
