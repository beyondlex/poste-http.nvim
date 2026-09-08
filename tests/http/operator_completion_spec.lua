-- Block operator completion: "# @name value" comment operators complete
-- their name while typing (# @g → comment_operator) and their value
-- afterwards (graphql_schema_path / grpc_proto_path). The operator name
-- list mirrors every operator the executors consume.

local context_detector = require("poste-http.http.context_detector")
local item_builder = require("poste-http.http.item_builder")

local function block_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function labels(items)
  local out = {}
  for _, it in ipairs(items or {}) do out[it.label] = true end
  return out
end

describe("comment operator name context (tree-sitter path)", function()
  local state, ts_query
  local orig_ts_config, orig_is_available

  before_each(function()
    state = require("poste-http.state")
    ts_query = require("poste-http.http.ts_query")
    orig_ts_config = state.config.use_treesitter
    orig_is_available = ts_query.is_available
    state.config.use_treesitter = { context_detector = true }
  end)

  after_each(function()
    state.config.use_treesitter = orig_ts_config
    ts_query.is_available = orig_is_available
  end)

  it("reaches the operator checks through the comment node's parents", function()
    if not ts_query.is_available(vim.api.nvim_get_current_buf()) then
      pending("poste_http parser not installed")
      return
    end
    local buf = block_buf({
      "### Req",                  -- 1
      "# @graphql-schema ./s",    -- 2
      "GRAPHQL {{u}}",            -- 3
      "",                         -- 4
      "query {",                  -- 5
      "  x",                      -- 6
      "}",                        -- 7
      "# @gr",                    -- 8
    })
    local ctx, extra = context_detector.detect_context("# @gr", buf, 8, 5)
    local path_ctx = context_detector.detect_context("# @graphql-schema ./s", buf, 2, 21)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.equals("comment_operator", ctx)
    assert.equals("gr", extra)
    assert.equals("graphql_schema_path", path_ctx)
  end)
end)

describe("comment operator name context", function()
  it("detects a partial operator name after '# @'", function()
    local buf = block_buf({ "### Req", "GRAPHQL {{u}}", "", "query { x }", "# @g" })
    local ctx, extra = context_detector.detect_context("# @g", buf, 5, 4)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.equals("comment_operator", ctx)
    assert.equals("g", extra)
  end)

  it("detects a bare '# @' with an empty partial", function()
    local buf = block_buf({ "### Req", "GRAPHQL {{u}}", "", "query { x }", "# @" })
    local ctx, extra = context_detector.detect_context("# @", buf, 5, 3)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.equals("comment_operator", ctx)
    assert.equals("", extra)
  end)

  it("does not fire once a value is present (path contexts own that)", function()
    local buf = block_buf({ "### Req", "GRAPHQL {{u}}", "", "query { x }", "# @graphql-schema ./s" })
    local ctx = context_detector.detect_context("# @graphql-schema ./s", buf, 5, 21)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.equals("graphql_schema_path", ctx)
  end)

  it("serves an empty value partial right after the operator name + space", function()
    local buf = block_buf({ "### Req", "GRAPHQL {{u}}", "", "query { x }", "# @graphql-schema " })
    local ctx, extra = context_detector.detect_context("# @graphql-schema ", buf, 5, 18)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.equals("graphql_schema_path", ctx)
    assert.equals("", extra)
  end)

  it("keeps plain prose comments at nil", function()
    local buf = block_buf({ "### Req", "GRAPHQL {{u}}", "", "query { x }", "# just a note" })
    local ctx = context_detector.detect_context("# just a note", buf, 5, 13)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_nil(ctx)
  end)
end)

describe("comment operator items", function()
  it("offers every known operator for a bare '# @'", function()
    local buf = block_buf({ "### Req", "GRAPHQL {{u}}", "", "query { x }", "# @" })
    local items = item_builder.get_items_for_context("# @", buf, 5, 3)
    vim.api.nvim_buf_delete(buf, { force = true })

    local l = labels(items)
    assert.is_truthy(l["@graphql-schema"])
    assert.is_truthy(l["@grpc-proto"])
    assert.is_truthy(l["@grpc-proto-set"])
    assert.is_truthy(l["@grpc-import-path"])
    assert.is_truthy(l["@grpc-plaintext"])
    assert.is_truthy(l["@grpc-tls"])
    assert.is_truthy(l["@ws-wait-ms"])
    assert.is_truthy(l["@ws-interactive"])
  end)

  it("filters by the typed partial prefix", function()
    local buf = block_buf({ "### Req", "GRAPHQL {{u}}", "", "query { x }", "# @gr" })
    local items = item_builder.get_items_for_context("# @gr", buf, 5, 5)
    vim.api.nvim_buf_delete(buf, { force = true })

    local l = labels(items)
    assert.is_truthy(l["@graphql-schema"], "gr matches graphql-schema")
    assert.is_truthy(l["@grpc-proto"], "gr matches grpc-proto")
    assert.is_falsy(l["@ws-wait-ms"], "ws-* must be filtered out")
  end)

  it("inserts without the @ (it is already typed) and carries a detail", function()
    local buf = block_buf({ "### Req", "GRAPHQL {{u}}", "", "query { x }", "# @gr" })
    local items = item_builder.get_items_for_context("# @gr", buf, 5, 5)
    vim.api.nvim_buf_delete(buf, { force = true })

    local by_label = {}
    for _, it in ipairs(items) do by_label[it.label] = it end
    assert.equals("graphql-schema", by_label["@graphql-schema"].insertText)
    assert.is_truthy(by_label["@graphql-schema"].detail)
  end)
end)
