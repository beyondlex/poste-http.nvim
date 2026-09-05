-- Contract for the nvim-facing highlights query (queries/poste_http/highlights.scm).
--
-- The grammar package copy (tree-sitter-poste-http/queries/) is not what
-- Neovim loads — the rtp resolves queries/poste_http/highlights.scm. When
-- the two copies drifted, GRAPHQL/GRPC/WEBSOCKET keywords lost their
-- highlights even though the parse tree was correct.

local function method_captures_by_row(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "poste_http"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local parser = vim.treesitter.get_parser(buf, "poste_http")
  local root = parser:parse()[1]:root()
  local q = vim.treesitter.query.get("poste_http", "highlights")
  assert.is_not_nil(q, "highlights query for poste_http must resolve from rtp")

  local by_row = {}
  for capture, node in q:iter_captures(root, buf, 0, -1) do
    local name = type(capture) == "number" and q.captures[capture] or capture
    if name:match("^PosteMethod") or name == "PosteRequestBody" then
      local row = node:range()
      by_row[row] = by_row[row] or {}
      table.insert(by_row[row], name)
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  return by_row
end

describe("highlights query captures protocol methods", function()
  it("captures GRAPHQL, GRPC and WEBSOCKET as PosteMethodScript", function()
    local lines = {
      "### Multi-protocol",
      "GRAPHQL {{graphql_url}}",
      "",
      "GRPC localhost:50051/pkg.Service/Method",
      "",
      "WEBSOCKET wss://stream.example.com/v1/feed",
    }
    local by_row = method_captures_by_row(lines)

    -- Method lines sit at 1-based lines 2, 4, 6 (0-indexed rows 1, 3, 5).
    for row = 1, #lines - 1, 2 do
      local names = by_row[row] or {}
      assert.is_true(vim.tbl_contains(names, "PosteMethodScript"),
        string.format("line %d (%s) must carry a PosteMethodScript capture, got: %s",
          row + 1, lines[row + 1], table.concat(names, ",")))
    end
  end)

  it("still captures GET as PosteMethodGET (control)", function()
    local by_row = method_captures_by_row({ "### T", "GET https://example.com" })
    assert.is_true(vim.tbl_contains(by_row[1] or {}, "PosteMethodGET"))
  end)

  it("captures graphql_body as PosteRequestBody", function()
    local by_row = method_captures_by_row({
      "### GraphQL",
      "GRAPHQL http://localhost:8890",
      "",
      "mutation {",
      "  add(a: 19, b: 23)",
      "}",
    })
    local names = {}
    for _, row_names in pairs(by_row) do
      vim.list_extend(names, row_names)
    end
    assert.is_true(vim.tbl_contains(names, "PosteRequestBody"),
      "graphql_body must carry the PosteRequestBody capture")
  end)
end)
