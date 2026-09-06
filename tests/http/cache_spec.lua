--- Characterization tests for cache.lua public API.
--- Tests the four focused query functions: collect_file_vars, collect_request_vars,
--- collect_request_names, and get_line_type.
---
--- These are characterization tests: they capture the actual current behavior
--- of the code, not necessarily the ideal behavior. If the code changes, these
--- tests document what the code *does* — not what it *should* do.

local cache = require("poste-http.http.cache")

--- Create a scratch buffer with the given lines, return its number.
--- Cleaned up automatically by the test framework.
local function create_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("cache query functions", function()
  ----------------------------------------------------------------------------
  -- collect_file_vars
  ----------------------------------------------------------------------------
  describe("collect_file_vars", function()
    it("returns file-level @var definitions", function()
      local buf = create_buf({
        "@base_url = http://example.com",
        "@token = abc123",
        "### Get",
        "GET /users",
      })
      local vars = cache.collect_file_vars(buf)
      assert.is_true(vars["base_url"], "base_url should be in file_vars")
      assert.is_true(vars["token"], "token should be in file_vars")
      -- Block-level vars should not leak into file_vars
      assert.is_nil(vars["Get"], "Get should not be in file_vars")
    end)

    it("returns empty table when no @var at file level", function()
      local buf = create_buf({
        "### Get",
        "GET /users",
      })
      local vars = cache.collect_file_vars(buf)
      assert.equals(0, vim.tbl_count(vars), "file_vars should be empty")
    end)

    it("does not include block-level @var definitions", function()
      local buf = create_buf({
        "### Get",
        "@limit = 20",
        "GET /users",
      })
      local vars = cache.collect_file_vars(buf)
      assert.equals(0, vim.tbl_count(vars), "file_vars should not include block-level vars")
    end)

    it("includes prompt vars (<<var_name) at file level", function()
      local buf = create_buf({
        "<<username",
        "### Get",
        "GET /users",
      })
      local vars = cache.collect_file_vars(buf)
      assert.is_true(vars["username"], "username should be in file_vars as prompt var")
    end)
  end)

  ----------------------------------------------------------------------------
  -- collect_request_vars
  ----------------------------------------------------------------------------
  describe("collect_request_vars", function()
    it("returns block-level @var definitions for a specific line", function()
      local buf = create_buf({
        "### Get",
        "@limit = 20",
        "@offset = 10",
        "GET /users",
      })
      -- Cursor on the request line
      local vars = cache.collect_request_vars(buf, 4)
      assert.is_true(vars["limit"], "limit should be in block_vars")
      assert.is_true(vars["offset"], "offset should be in block_vars")
    end)

    it("returns empty table when no @var in block", function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "Content-Type: application/json",
      })
      local vars = cache.collect_request_vars(buf, 2)
      assert.equals(0, vim.tbl_count(vars), "block_vars should be empty")
    end)

    it("returns empty table when cursor is before first block (file area)", function()
      local buf = create_buf({
        "@base_url = http://example.com",
        "### Get",
        "GET /users",
      })
      local vars = cache.collect_request_vars(buf, 1)
      assert.equals(0, vim.tbl_count(vars), "file area should have no block vars")
    end)

    it("returns vars only for the block containing the cursor, not other blocks", function()
      local buf = create_buf({
        "### Block A",
        "GET /a",
        "",
        "### Block B",
        "@limit = 20",
        "POST /b",
      })
      -- Cursor in Block A (no vars)
      local vars_a = cache.collect_request_vars(buf, 1)
      assert.equals(0, vim.tbl_count(vars_a), "Block A should have no vars")

      -- Cursor in Block B (has vars)
      local vars_b = cache.collect_request_vars(buf, 5)
      assert.is_true(vars_b["limit"], "limit should be in Block B vars")
    end)

    it("returns a copy (deepcopy) so mutations do not affect cache", function()
      local buf = create_buf({
        "### Get",
        "@limit = 20",
        "GET /users",
      })
      local vars = cache.collect_request_vars(buf, 3)
      assert.is_true(vars["limit"], "limit should be present")

      -- Mutate the returned table
      vars["limit"] = nil
      vars["extra"] = true

      -- Re-fetch should still have the original contents
      local vars2 = cache.collect_request_vars(buf, 3)
      assert.is_true(vars2["limit"], "original should be unchanged after mutation")
      assert.is_nil(vars2["extra"], "extra should not leak into cache")
    end)
  end)

  ----------------------------------------------------------------------------
  -- collect_request_names
  ----------------------------------------------------------------------------
  describe("collect_request_names", function()
    it("returns names of all named blocks", function()
      local buf = create_buf({
        "### Get Users",
        "GET /users",
        "",
        "### Create User",
        "POST /users",
        "",
        "### Delete User",
        "DELETE /users/:id",
      })
      local names = cache.collect_request_names(buf)
      assert.equals(3, #names, "should have 3 names")
      -- Names are inserted in order of first occurrence
      assert.equals("Get Users", names[1])
      assert.equals("Create User", names[2])
      assert.equals("Delete User", names[3])
    end)

    it("returns empty array when no blocks", function()
      local buf = create_buf({
        "@base_url = http://example.com",
        "# some comment",
      })
      local names = cache.collect_request_names(buf)
      assert.equals(0, #names, "should have 0 names")
    end)

    it("includes unnamed blocks as empty string entries", function()
      local buf = create_buf({
        "###",
        "GET /api",
        "",
        "### Another",
        "POST /api",
      })
      local names = cache.collect_request_names(buf)
      -- Unnamed ### (no name after it) does not add a name entry;
      -- only "### Name" with a non-empty name is collected
      assert.equals(1, #names, "should have 1 named block")
      assert.equals("Another", names[1])
    end)

    it("deduplicates duplicate names (first occurrence wins)", function()
      local buf = create_buf({
        "### Duplicate",
        "GET /first",
        "",
        "### Duplicate",
        "GET /second",
      })
      local names = cache.collect_request_names(buf)
      assert.equals(1, #names, "duplicate names should be deduplicated")
      assert.equals("Duplicate", names[1])
    end)

    it("returns empty array for buffer with only file-level content", function()
      local buf = create_buf({
        "# This is a comment-only file",
        "# with no request blocks",
      })
      local names = cache.collect_request_names(buf)
      assert.equals(0, #names, "should have 0 names")
    end)
  end)

  ----------------------------------------------------------------------------
  -- get_line_type
  ----------------------------------------------------------------------------
  describe("get_line_type", function()
    it('returns "request" for HTTP method lines', function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "Content-Type: application/json",
        "",
        "POST /users",
      })
      assert.equals("request", cache.get_line_type(buf, 2), "GET should be request")
      -- Only the first method-like line after ### is "request";
      -- subsequent lines without empty separator are "header" or "body"
      assert.equals("header", cache.get_line_type(buf, 3), "Content-Type should be header")
      assert.equals("empty", cache.get_line_type(buf, 4), "blank line should be empty")
      assert.equals("body", cache.get_line_type(buf, 5), "POST after blank line should be body")
    end)

    it('returns "header" for header lines', function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "Content-Type: application/json",
        "Authorization: Bearer xyz",
        "X-Custom-Header: value",
      })
      assert.equals("header", cache.get_line_type(buf, 3), "Content-Type should be header")
      assert.equals("header", cache.get_line_type(buf, 4), "Authorization should be header")
      assert.equals("header", cache.get_line_type(buf, 5), "X-Custom-Header should be header")
    end)

    it('returns "body" for body lines (after empty line separator)', function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "Content-Type: application/json",
        "",
        '{"page":1}',
        "more body content",
      })
      -- Line 4 is the empty separator
      assert.equals("empty", cache.get_line_type(buf, 4), "line 4 (empty) should be empty")
      -- Lines after the empty separator are body
      assert.equals("body", cache.get_line_type(buf, 5), "line 5 should be body")
      assert.equals("body", cache.get_line_type(buf, 6), "line 6 should be body")
    end)

    it('returns "head" for ### separator lines', function()
      local buf = create_buf({
        "### Block A",
        "GET /a",
        "",
        "### Block B",
        "POST /b",
      })
      assert.equals("head", cache.get_line_type(buf, 1), "line 1 (###) should be head")
      assert.equals("head", cache.get_line_type(buf, 4), "line 4 (###) should be head")
    end)

    it('returns "file" for # comment lines before first block', function()
      local buf = create_buf({
        "# This is a comment at the top",
        "# Another comment",
        "### Get",
        "GET /users",
      })
      assert.equals("file", cache.get_line_type(buf, 1), "comment before first block should be file")
      assert.equals("file", cache.get_line_type(buf, 2), "comment before first block should be file")
    end)

    it('returns "body" for # comment lines inside a block', function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "",
        "# a comment in the body section",
      })
      -- After the empty separator, # comments are typed as body
      assert.equals("body", cache.get_line_type(buf, 4), "comment in block body should be body")
    end)

    it('returns "pre_script" for < {% %} lines', function()
      local buf = create_buf({
        "### Get",
        "< {% local x = 1 %}",
        "GET /users",
      })
      assert.equals("pre_script", cache.get_line_type(buf, 2), "< {% %} should be pre_script")
    end)

    it('returns "pre_script" for multi-line < {% ... %} blocks', function()
      local buf = create_buf({
        "### Get",
        "< {%",
        "  local x = 1",
        "  x = x + 1",
        "%}",
        "GET /users",
      })
      assert.equals("pre_script", cache.get_line_type(buf, 2), "< {% should be pre_script")
      assert.equals("pre_script", cache.get_line_type(buf, 3), "middle of pre_script block")
      assert.equals("pre_script", cache.get_line_type(buf, 4), "middle of pre_script block")
      assert.equals("pre_script", cache.get_line_type(buf, 5), "%} should be pre_script")
    end)

    it('returns "post_script" for > {% %} lines', function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "",
        "> {% client.test('status', function() end) %}",
      })
      assert.equals("post_script", cache.get_line_type(buf, 4), "> {% %} should be post_script")
    end)

    it('returns "post_script" for multi-line > {% ... %} blocks', function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "",
        "> {%",
        "  client.test('status', function()",
        "    client.assert(response.status == 200)",
        "  end)",
        "%}",
      })
      assert.equals("post_script", cache.get_line_type(buf, 4), "> {% should be post_script")
      assert.equals("post_script", cache.get_line_type(buf, 5), "middle of post_script block")
      assert.equals("post_script", cache.get_line_type(buf, 8), "%} should be post_script")
    end)

    it('returns "var" for @var definitions', function()
      local buf = create_buf({
        "### Get",
        "@limit = 20",
        "@offset = 10",
        "GET /users",
      })
      assert.equals("var", cache.get_line_type(buf, 2), "@limit should be var")
      assert.equals("var", cache.get_line_type(buf, 3), "@offset should be var")
    end)

    it('returns "empty" for blank lines', function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "",
        "Content-Type: application/json",
        "",
      })
      assert.equals("empty", cache.get_line_type(buf, 3), "blank line should be empty")
      assert.equals("empty", cache.get_line_type(buf, 5), "trailing blank line should be empty")
    end)

    it('returns "prompt" for << line', function()
      local buf = create_buf({
        "### Get",
        "<<username",
        "GET /users",
      })
      assert.equals("prompt", cache.get_line_type(buf, 2), "<< line should be prompt")
    end)

    it('returns "prompt" for # << line', function()
      local buf = create_buf({
        "### Get",
        "# <<username",
        "GET /users",
      })
      assert.equals("prompt", cache.get_line_type(buf, 2), "# << line should be prompt")
    end)

    it('returns "run" for run directive', function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "",
        "run #NextRequest",
      })
      assert.equals("run", cache.get_line_type(buf, 4), "run directive should be run")
    end)

    it('returns nil for out-of-range line', function()
      local buf = create_buf({
        "### Get",
        "GET /users",
      })
      -- Line 10 does not exist in the buffer
      assert.is_nil(cache.get_line_type(buf, 10), "out-of-range line should return nil")
    end)

    it('returns "file" for import lines before first block', function()
      local buf = create_buf({
        "import ./auth.http",
        "import ./orders.http as orders",
        "### Get",
        "GET /users",
      })
      assert.equals("file", cache.get_line_type(buf, 1), "import line should be file")
      assert.equals("file", cache.get_line_type(buf, 2), "import line should be file")
    end)

    it('returns "request" for SCRIPT keyword as request line', function()
      local buf = create_buf({
        "### Script Test",
        "SCRIPT",
        "< {% local x = 1 %}",
        "> {% client.test('pass', function() end) %}",
      })
      assert.equals("request", cache.get_line_type(buf, 2), "SCRIPT should be request")
    end)

    it('returns "request" for lowercase script keyword', function()
      local buf = create_buf({
        "### Script Test",
        "script",
        "> {% client.test('pass', function() end) %}",
      })
      assert.equals("request", cache.get_line_type(buf, 2), "script should be request")
    end)
  end)
end)

describe("get_semantic_blocks with no tree-sitter fallback", function()
  local function create_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  local sample_lines = {
    "### Get Users",
    "GET /users",
    "Authorization: Bearer token",
    "",
    '{"page":1}',
    "",
    "### Create User",
    "POST /users",
    "Content-Type: application/json",
    "",
    '{"name":"doge"}',
  }

  it("returns block array (not empty) when TS is unavailable", function()
    local buf = create_buf(sample_lines)

    local describe = require("poste-http.http.describe")
    local orig_describe = describe.describe_content
    describe.describe_content = function()
      return {}, "tree-sitter unavailable"
    end

    local blocks = cache.get_semantic_blocks(buf)

    describe.describe_content = orig_describe

    assert.is_true(
      type(blocks) == "table" and #blocks > 0,
      "get_semantic_blocks must not return empty table when TS is unavailable"
    )
    assert.equals(2, #blocks, "should have 2 blocks")
    assert.equals("Get Users", blocks[1].name)
    assert.equals("Create User", blocks[2].name)
  end)

  it("block_at_line works on fallback blocks", function()
    local buf = create_buf(sample_lines)

    local describe = require("poste-http.http.describe")
    local orig_describe = describe.describe_content
    describe.describe_content = function()
      return {}, "tree-sitter unavailable"
    end

    local b = cache.get_semantic_block_at_line(buf, 2)

    describe.describe_content = orig_describe

    assert.is_not_nil(b, "get_semantic_block_at_line should find block via fallback")
    assert.equals("Get Users", b.name)
  end)

  it("cached fallback is reused on subsequent calls", function()
    local buf = create_buf(sample_lines)

    local describe = require("poste-http.http.describe")
    local orig_describe = describe.describe_content
    describe.describe_content = function()
      return {}, "tree-sitter unavailable"
    end

    local blocks1 = cache.get_semantic_blocks(buf)
    local blocks2 = cache.get_semantic_blocks(buf)

    describe.describe_content = orig_describe

    assert.equals(blocks1, blocks2, "fallback blocks should be cached")
    assert.equals(2, #blocks2)
  end)

  it("buffer_caches and semantic_caches return same block data", function()
    local buf = create_buf(sample_lines)

    local describe = require("poste-http.http.describe")
    local orig_describe = describe.describe_content
    describe.describe_content = function()
      return {}, "tree-sitter unavailable"
    end

    local buffer_cache = cache.get_buffer_cache(buf)
    local sem_blocks = cache.get_semantic_blocks(buf)

    describe.describe_content = orig_describe

    assert.equals(#buffer_cache.blocks, #sem_blocks)
    for i = 1, #buffer_cache.blocks do
      local bc = buffer_cache.blocks[i]
      local sm = sem_blocks[i]
      assert.equals(bc.name, sm.name, "block " .. i .. " name mismatch")
      assert.equals(bc.start_line, sm.line, "block " .. i .. " line mismatch")
      assert.equals(bc.end_line, sm.end_line, "block " .. i .. " end_line mismatch")
    end
  end)
end)

describe("buffer cache var names", function()
  it("collects underscore-prefixed @var names for completion", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "@_base = https://api.example.com",
      "@_url = {{_base}}/users",
      "",
      "### Get",
      "@_token = abc",
      "GET {{_url}}",
    })
    local entry = require("poste-http.http.cache").get_buffer_cache(buf)
    assert.is_truthy(entry.file_vars._base, "file-level @_base must be indexed")
    assert.is_truthy(entry.blocks[1].block_vars._token,
      "block-level @_token must be indexed")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
