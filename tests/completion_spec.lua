-- Integration tests for completion module
-- Tests the full completion flow through get_completions() and get_items_for_context()

local completion = require("poste.http.completion")
local test = completion._test
local get_items_for_context = test.get_items_for_context

local function block_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("get_items_for_context", function()
  describe("method and header completion", function()
    it("returns HTTP methods for empty line inside block", function()
      local buf = block_buf({ "### Test", "" })
      local items = get_items_for_context("", buf, 2, 0)
      vim.api.nvim_buf_delete(buf, { force = true })

      assert.is_true(#items > 0)

      -- Should include common HTTP methods
      local labels = {}
      for _, item in ipairs(items) do
        labels[item.label] = true
      end

      assert.is_true(labels["GET"] or labels["POST"])
    end)

    it("returns SCRIPT as a method completion", function()
      local buf = block_buf({ "### Test", "" })
      local items = get_items_for_context("", buf, 2, 0)
      vim.api.nvim_buf_delete(buf, { force = true })

      local found = false
      for _, item in ipairs(items) do
        if item.label == "SCRIPT" then
          found = true
          break
        end
      end
      assert.is_true(found, "SCRIPT should appear in method completions")
    end)

    it("returns header names for partial input inside block", function()
      local buf = block_buf({ "### Test", "Con" })
      local items = get_items_for_context("Con", buf, 2, 3)
      vim.api.nvim_buf_delete(buf, { force = true })

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

  describe("namespace-aware variable completion", function()
    it("get_namespace_items returns namespace items for top-level prefix", function()
      local items = test.get_namespace_items("GetUser", "", { "GetUser", "CreateUser" })

      assert.is_true(#items > 0)
      local labels = {}
      for _, item in ipairs(items) do
        labels[item.label] = true
      end
      assert.is_true(labels["response."], "should show response namespace")
      assert.is_true(labels["request."], "should show request namespace")
    end)

    it("get_namespace_items returns leaf items for nested prefix", function()
      local items = test.get_namespace_items("GetUser.response", "", { "GetUser" })

      local labels = {}
      for _, item in ipairs(items) do
        labels[item.label] = true
      end
      assert.is_true(labels["body"], "should show body leaf")
      assert.is_true(labels["headers"], "should show headers leaf")
      assert.is_true(labels["status"], "should show status leaf")
    end)

    it("get_namespace_items filters children by partial match", function()
      local items = test.get_namespace_items("GetUser.response", "bo", { "GetUser" })

      assert.equals(1, #items)
      assert.equals("body", items[1].label)
    end)

    it("get_namespace_items returns nil for unknown prefix", function()
      local items = test.get_namespace_items("Unknown", "", { "GetUser" })
      assert.is_nil(items)
    end)

    it("namespace items have correct kind and sortText", function()
      local items = test.get_namespace_items("GetUser", "", { "GetUser" })

      for _, item in ipairs(items) do
        if item.label == "response." then
          assert.equals(9, item.kind) -- Module
          assert.is_true(item.sortText:sub(1, 2) == "00", "namespace sortText should start with 00")
        end
      end
    end)

    it("leaf items have correct kind and sortText", function()
      local items = test.get_namespace_items("GetUser.response", "", { "GetUser" })

      for _, item in ipairs(items) do
        assert.equals(6, item.kind) -- Variable
        assert.is_true(item.sortText:sub(1, 2) == "01", "leaf sortText should start with 01")
        assert.is_not_nil(item.detail)
      end
    end)

    it("variable completion falls back to normal vars for unknown namespace prefix", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### Test", "{{Unknown." })
      vim.api.nvim_set_current_buf(buf)

      local items = get_items_for_context("{{Unknown.", buf, 2, 10)

      -- Should fall back to normal variable completion (magic vars at minimum)
      assert.is_true(#items >= 4, "should fall back to normal variable completion")
      local labels = {}
      for _, item in ipairs(items) do
        labels[item.label] = true
      end
      assert.is_true(labels["$timestamp"] or labels["$uuid"])

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("variable completion uses namespace-aware items for valid prefix", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### GetUser", "GET /users", "### CreateUser", "{{GetUser." })
      vim.api.nvim_set_current_buf(buf)

      local items = get_items_for_context("{{GetUser.", buf, 4, 10)

      local labels = {}
      for _, item in ipairs(items) do
        labels[item.label] = true
      end
      assert.is_true(labels["response."], "should show response namespace")
      assert.is_true(labels["request."], "should show request namespace")
      -- Should NOT show flat request references or magic vars
      assert.is_nil(labels["$timestamp"], "should not show magic vars in namespace mode")

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)

describe("blink.cmp integration", function()
  it("get_completions calls callback with correct response shape", function()
    local buf = block_buf({ "### Test", "" })
    local response

    completion:get_completions(
      { line = "", cursor = { 2, 0 }, bufnr = buf },
      function(resp) response = resp end
    )
    vim.api.nvim_buf_delete(buf, { force = true })

    assert.is_not_nil(response)
    assert.is_not_nil(response.items)
    assert.is_table(response.items)
    assert.is_not_nil(response.is_incomplete_forward)
    assert.is_not_nil(response.is_incomplete_backward)
  end)

  it("get_completions returns items for method context", function()
    local buf = block_buf({ "### Test", "" })
    local response

    completion:get_completions(
      { line = "", cursor = { 2, 0 }, bufnr = buf },
      function(resp) response = resp end
    )
    vim.api.nvim_buf_delete(buf, { force = true })

    assert.is_true(#response.items > 0)
  end)

  it("get_completions returns items for header value context", function()
    local buf = block_buf({ "### Test", "Content-Type: " })
    local response

    completion:get_completions(
      { line = "Content-Type: ", cursor = { 2, 14 }, bufnr = buf },
      function(resp) response = resp end
    )
    vim.api.nvim_buf_delete(buf, { force = true })

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

    local buf = block_buf({ "### Test", "" })
    vim.api.nvim_set_current_buf(buf)
    local response

    local instance = source.new()
    instance:complete(
      {
        context = { cursor_before_line = "" },
        offset = 1,
      },
      function(resp) response = resp end
    )
    vim.api.nvim_buf_delete(buf, { force = true })

    assert.is_true(#response.items > 0)
  end)
end)
