--- Completion support for GRAPHQL request bodies.
--- Context detection (TS + regex fallback) and the graphql_query keyword items.

local context_detector = require("poste-http.http.context_detector")
local item_builder = require("poste-http.http.item_builder")
local data = require("poste-http.http.data")

local function block_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function delete_buf(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end

--- The user's example: named query + variables JSON tail.
local function graphql_buf()
  return block_buf({
    "### GraphQL: query with variables",
    "GRAPHQL {{graphql_url}}",
    "",
    "query User($id: ID!) {",
    '  user(id: $id) { id name email }',
    "}",
    "",
    "{",
    '  "id": "1"',
    "}",
  })
end

describe("graphql body completion", function()
  local state = require("poste-http.state")
  local ts_query = require("poste-http.http.ts_query")
  local orig_ts_config
  local orig_is_available

  before_each(function()
    orig_ts_config = state.config.use_treesitter
    orig_is_available = ts_query.is_available
  end)

  after_each(function()
    state.config.use_treesitter = orig_ts_config
    ts_query.is_available = orig_is_available
  end)

  describe("tree-sitter mode", function()
    before_each(function()
      state.config.use_treesitter = { context_detector = true }
    end)

    it("returns 'graphql_query' inside the query text", function()
      local buf = graphql_buf()
      if not ts_query.is_available(buf) then
        delete_buf(buf)
        return -- parser not installed, skip
      end
      -- Cursor on line 5, inside `user(id: $id) ...`
      local ctx, extra = context_detector.detect_context(
        "  user(id: $id) { id name email }", buf, 5, 10)
      delete_buf(buf)
      assert.equals("graphql_query", ctx)
      assert.is_nil(extra)
    end)

    it("returns 'graphql_query' while typing a root keyword", function()
      local buf = graphql_buf()
      if not ts_query.is_available(buf) then
        delete_buf(buf)
        return
      end
      -- Cursor at the end of the query's first line
      local ctx = context_detector.detect_context(
        "query User($id: ID!) {", buf, 4, 22)
      delete_buf(buf)
      assert.equals("graphql_query", ctx)
    end)

    it("returns 'variable' inside {{...}} in the query text (regression)", function()
      local buf = block_buf({
        "### GraphQL",
        "GRAPHQL {{graphql_url}}",
        "",
        "query User($id: ID!) {",
        '  user(name: "{{name_prefix}}") { id }',
        "}",
      })
      if not ts_query.is_available(buf) then
        delete_buf(buf)
        return
      end
      -- Cursor after the unclosed {{: the TS parent list used to omit
      -- graphql_body, so {{var}} completion silently no-oped here while the
      -- regex fallback worked.
      local ctx, extra = context_detector.detect_context(
        '  user(name: "{{name_prefix', buf, 5, 27)
      delete_buf(buf)
      assert.equals("variable", ctx)
      assert.equals("name_prefix", extra)
    end)

    it("returns 'variable' inside {{...}} in the variables JSON tail", function()
      local buf = graphql_buf()
      if not ts_query.is_available(buf) then
        delete_buf(buf)
        return
      end
      local ctx, extra = context_detector.detect_context(
        '  "id": "{{us', buf, 9, 13)
      delete_buf(buf)
      assert.equals("variable", ctx)
      assert.equals("us", extra)
    end)
  end)

  describe("regex fallback mode", function()
    before_each(function()
      state.config.use_treesitter = { context_detector = true }
      ts_query.is_available = function() return false end
    end)

    it("returns 'graphql_query' inside the query text", function()
      local buf = graphql_buf()
      local ctx, extra = context_detector.detect_context(
        "  user(id: $id) { id name email }", buf, 5, 10)
      delete_buf(buf)
      assert.equals("graphql_query", ctx)
      assert.is_nil(extra)
    end)

    it("returns 'graphql_query' on a partial keyword line", function()
      local buf = graphql_buf()
      -- Simulates the user starting a new operation line in the query body
      local ctx = context_detector.detect_context("mutation", buf, 5, 8)
      delete_buf(buf)
      assert.equals("graphql_query", ctx)
    end)

    it("keeps {{...}} completion working inside the query text", function()
      local buf = block_buf({
        "### GraphQL",
        "GRAPHQL {{graphql_url}}",
        "",
        "query User($id: ID!) {",
        '  user(name: "{{name_prefix}}") { id }',
        "}",
      })
      local ctx, extra = context_detector.detect_context(
        '  user(name: "{{name_prefix', buf, 5, 27)
      delete_buf(buf)
      assert.equals("variable", ctx)
      assert.equals("name_prefix", extra)
    end)

    it("does not fire in non-GRAPHQL bodies", function()
      local buf = block_buf({
        "### Create",
        "POST /api/users",
        "Content-Type: application/json",
        "",
        "{",
        '  "name": "John"',
        "}",
      })
      local ctx = context_detector.detect_context(
        '  "name": "John"', buf, 6, 16)
      delete_buf(buf)
      assert.is_nil(ctx)
    end)

    it("does not fire on the GRAPHQL request line itself", function()
      local buf = graphql_buf()
      local ctx = context_detector.detect_context(
        "GRAPHQL {{graphql_url}}", buf, 2, 23)
      delete_buf(buf)
      assert.is_nil(ctx)
    end)
  end)

  describe("graphql_query items", function()
    -- End-to-end through the regex fallback: deterministic regardless of
    -- whether the poste_http parser is installed.
    before_each(function()
      state.config.use_treesitter = { context_detector = true }
      ts_query.is_available = function() return false end
    end)

    local function items_for_graphql_body()
      local buf = graphql_buf()
      local items = item_builder.get_items_for_context(
        "  user(id: $id) { id name email }", buf, 5, 10)
      delete_buf(buf)
      return items
    end

    it("offers root keywords, scalars and directives", function()
      local items = items_for_graphql_body()
      local labels = {}
      for _, item in ipairs(items) do labels[item.label] = true end

      for _, expected in ipairs({
        "query", "mutation", "subscription", "fragment", "on",
        "Int", "Float", "String", "Boolean", "ID",
        "@include", "@skip", "@deprecated",
      }) do
        assert.is_true(labels[expected],
          "graphql completion must offer " .. expected)
      end
    end)

    it("marks items as keywords with a description", function()
      local items = items_for_graphql_body()
      assert.is_true(#items > 0)
      for _, item in ipairs(items) do
        assert.equals(14, item.kind) -- KIND_KEYWORD
        assert.is_truthy(item.detail and item.detail ~= "",
          item.label .. " must carry a description")
      end
    end)

    it("keeps graphql keyword data well-formed", function()
      for _, kw in ipairs(data.graphql_keywords) do
        assert.is_truthy(type(kw.name) == "string" and kw.name ~= "")
        assert.is_truthy(type(kw.desc) == "string" and kw.desc ~= "")
      end
    end)
  end)
end)
