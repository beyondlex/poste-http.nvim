--- Highlighting for GRAPHQL request bodies.
--- Two halves are verified separately (nvim 0.12 does not expose injected
--- LanguageTree children):
---   1. wiring — the poste_http injections query maps graphql_body to
---      language "poste_graphql" (same contract tests/injection_spec.sh checks);
---   2. language — the poste_graphql parser + highlights query understand the
---      query text itself, including {{var}} template variables.

local function graphql_block_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "poste_http"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

--- Collect treesitter capture names per 0-based row from a query.
local function captures_by_row(lang, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local parser = vim.treesitter.get_parser(buf, lang)
  local root = parser:parse()[1]:root()
  local q = vim.treesitter.query.get(lang, "highlights")
  assert.is_not_nil(q, "highlights query for " .. lang .. " must resolve from rtp")

  local by_row = {}
  for capture, node in q:iter_captures(root, buf, 0, -1) do
    local name = type(capture) == "number" and q.captures[capture] or capture
    local sr, _, er = node:range()
    for row = sr, er do
      by_row[row] = by_row[row] or {}
      table.insert(by_row[row], name)
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  return by_row, q
end

local function has_capture(by_row, row, name)
  for _, n in ipairs(by_row[row] or {}) do
    if n == name then return true end
  end
  return false
end

--- Return a poste_graphql parser for the buffer, or nil when the parser
--- isn't installed (specs skip in that case).
local function graphql_parser(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "poste_graphql")
  if ok and parser then return parser end
  return nil
end

describe("graphql body highlighting", function()
  describe("injection wiring (poste_http -> poste_graphql)", function()
    it("maps graphql_body to injection language poste_graphql", function()
      local buf = graphql_block_buf({
        "### GraphQL",
        "GRAPHQL {{graphql_url}}",
        "",
        "query User($id: ID!) {",
        "  user(id: $id) { id name email }",
        "}",
        "",
        "{",
        '  "id": "1"',
        "}",
      })
      local ok, parser = pcall(vim.treesitter.get_parser, buf, "poste_http")
      if not ok then
        vim.api.nvim_buf_delete(buf, { force = true })
        return -- poste_http parser not installed, skip
      end
      local root = parser:parse()[1]:root()
      local q = vim.treesitter.query.get("poste_http", "injections")
      assert.is_not_nil(q)

      local found = nil
      for pattern, match, metadata in q:iter_matches(root, buf, 0, -1) do
        if metadata["injection.language"] == "poste_graphql" then
          for id, nodes in pairs(match) do
            if q.captures[id] == "injection.content" then
              for _, node in ipairs(nodes) do
                if node:type() == "graphql_body" then found = node end
              end
            end
          end
        end
      end
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.is_truthy(found,
        "injections query must map graphql_body content to poste_graphql")
    end)
  end)

  describe("poste_graphql language", function()
    it("parses a named query without errors", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "query User($id: ID!) {",
        "  user(id: $id) { id name email }",
        "}",
      })
      local parser = graphql_parser(buf)
      if not parser then
        vim.api.nvim_buf_delete(buf, { force = true })
        return -- parser not installed, skip
      end
      local root = parser:parse()[1]:root()
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.equals("document", root:type())
      assert.is_false(root:has_error(), "query text must parse without error nodes")
    end)

    it("highlights operation keyword, field and type", function()
      local probe = vim.api.nvim_create_buf(false, true)
      if not graphql_parser(probe) then
        vim.api.nvim_buf_delete(probe, { force = true })
        return -- parser not installed, skip
      end
      vim.api.nvim_buf_delete(probe, { force = true })

      local by_row = captures_by_row("poste_graphql", {
        "query User($id: ID!) {",
        "  user(id: $id) { id name email }",
        "}",
      })
      assert.is_true(has_capture(by_row, 0, "keyword"),
        "'query' must be @keyword")
      assert.is_true(has_capture(by_row, 0, "type"),
        "ID must be @type")
      assert.is_true(has_capture(by_row, 1, "property"),
        "field 'user' must be @property")
    end)

    it("highlights {{var}} template variables in value position", function()
      local probe = vim.api.nvim_create_buf(false, true)
      if not graphql_parser(probe) then
        vim.api.nvim_buf_delete(probe, { force = true })
        return -- parser not installed, skip
      end
      vim.api.nvim_buf_delete(probe, { force = true })

      local by_row = captures_by_row("poste_graphql", {
        "query User($id: ID!) {",
        "  user(id: {{user_id}}) { id }",
        "}",
      })
      assert.is_true(has_capture(by_row, 1, "variable"),
        "{{user_id}} must be @variable")
    end)

    it("keeps {{var}} inside strings as string content (poste_json parity)", function()
      local probe = vim.api.nvim_create_buf(false, true)
      if not graphql_parser(probe) then
        vim.api.nvim_buf_delete(probe, { force = true })
        return -- parser not installed, skip
      end
      vim.api.nvim_buf_delete(probe, { force = true })

      local by_row = captures_by_row("poste_graphql", {
        "query User($id: ID!) {",
        '  user(name: "{{name_prefix}}") { id }',
        "}",
      })
      assert.is_true(has_capture(by_row, 1, "string"),
        "the string argument must be @string")
      assert.is_false(has_capture(by_row, 1, "variable"),
        "in-string {{var}} must not split out of the string")
    end)

    it("highlights fragment definitions", function()
      local probe = vim.api.nvim_create_buf(false, true)
      if not graphql_parser(probe) then
        vim.api.nvim_buf_delete(probe, { force = true })
        return -- parser not installed, skip
      end
      vim.api.nvim_buf_delete(probe, { force = true })

      local by_row = captures_by_row("poste_graphql", {
        "fragment UserFields on User {",
        "  id",
        "  name",
        "}",
        "",
        "query Q {",
        "  user { ...UserFields }",
        "}",
      })
      assert.is_true(has_capture(by_row, 0, "keyword"),
        "'fragment'/'on' must be @keyword")
      assert.is_true(has_capture(by_row, 5, "keyword"),
        "operation 'query' must be @keyword")
    end)
  end)
end)
