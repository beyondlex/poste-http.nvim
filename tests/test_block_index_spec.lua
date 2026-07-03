--- Tests for block index (Phase 1).
--- Tests cache.lua extensions: line_type, blocks, file_imports, and query functions.

local cache = require("poste.http.cache")

--- Create a scratch buffer with the given lines, return its number.
--- Cleaned up automatically by the test framework.
local function create_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("block index", function()
  ----------------------------------------------------------------------------
  -- 1. file_vars
  ----------------------------------------------------------------------------
  it("file_vars", function()
    local buf = create_buf({
      "@base_url = http://example.com",
      "@token = abc123",
      "### Get",
    })
    local c = cache.get_buffer_cache(buf)
    assert.is_true(c.file_vars["base_url"], "base_url should be in file_vars")
    assert.is_true(c.file_vars["token"], "token should be in file_vars")
    assert.is_nil(c.file_vars["Get"], "Get should not be in file_vars")
  end)

  ----------------------------------------------------------------------------
  -- 2. block_vars
  ----------------------------------------------------------------------------
  it("block_vars", function()
    local buf = create_buf({
      "### Get",
      "@limit = 20",
      "GET /users",
    })
    local c = cache.get_buffer_cache(buf)
    assert.equals(1, #c.blocks, "should have 1 block")
    assert.is_true(c.blocks[1].block_vars["limit"], "limit should be in block_vars")
  end)

  ----------------------------------------------------------------------------
  -- 3. line_type basic
  ----------------------------------------------------------------------------
  it("line_type basic", function()
    local buf = create_buf({
      "### Get",
      "@page = 1",
      "GET /users",
      "Content-Type: application/json",
      "",
      '{"page":1}',
    })
    local c = cache.get_buffer_cache(buf)
    local lt = c.line_type
    assert.equals("head", lt[1], "line 1 should be head")
    assert.equals("var", lt[2], "line 2 should be var")
    assert.equals("request", lt[3], "line 3 should be request")
    assert.equals("header", lt[4], "line 4 should be header")
    assert.equals("empty", lt[5], "line 5 should be empty")
    assert.equals("body", lt[6], "line 6 should be body")
  end)

  ----------------------------------------------------------------------------
  -- 4. pre_script multi-line
  ----------------------------------------------------------------------------
  it("pre_script multi-line", function()
    local buf = create_buf({
      "### Get",
      "< {%",
      "  local x = 1",
      "  x = x + 1",
      "%}",
      "GET /users",
    })
    local c = cache.get_buffer_cache(buf)
    local lt = c.line_type
    assert.equals("pre_script", lt[2], "line 2 (< {%) should be pre_script")
    assert.equals("pre_script", lt[3], "line 3 should be pre_script")
    assert.equals("pre_script", lt[4], "line 4 should be pre_script")
    assert.equals("pre_script", lt[5], "line 5 (%}) should be pre_script")
    assert.equals("request", lt[6], "line 6 should be request")
    assert.is_true(c.blocks[1].has_pre, "block should have has_pre=true")
  end)

  ----------------------------------------------------------------------------
  -- 5. pre_script single-line
  ----------------------------------------------------------------------------
  it("pre_script single-line", function()
    local buf = create_buf({
      "### Get",
      "< {% local x = 1 %}",
      "GET /users",
    })
    local c = cache.get_buffer_cache(buf)
    local lt = c.line_type
    assert.equals("pre_script", lt[2], "single-line pre_script should be pre_script")
    assert.is_true(c.blocks[1].has_pre, "block should have has_pre=true")
  end)

  ----------------------------------------------------------------------------
  -- 6. post_script
  ----------------------------------------------------------------------------
  it("post_script", function()
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
    local c = cache.get_buffer_cache(buf)
    local lt = c.line_type
    -- line 1: head, line 2: request, line 3: empty, line 4: body
    -- line 5: post_script start, lines 6-8: post_script, line 9: post_script end
    assert.equals("post_script", lt[5], "line 5 (> {% ) should be post_script")
    assert.equals("post_script", lt[6], "line 6 should be post_script")
    assert.equals("post_script", lt[9], "line 9 (%}) should be post_script")
    assert.is_true(c.blocks[1].has_post, "block should have has_post=true")
  end)

  ----------------------------------------------------------------------------
  -- 7. interleave: @var and pre-script interleaved in block head
  ----------------------------------------------------------------------------
  it("interleave", function()
    local buf = create_buf({
      "### Get",
      "@page = 1",
      "< {% do_something() %}",
      "@limit = 20",
      "GET /users",
    })
    local c = cache.get_buffer_cache(buf)
    local lt = c.line_type
    assert.equals("var", lt[2], "@page should be var")
    assert.equals("pre_script", lt[3], "< {%%} should be pre_script")
    assert.equals("var", lt[4], "@limit should be var")
    assert.is_true(c.blocks[1].block_vars["page"], "page should be in block_vars")
    assert.is_true(c.blocks[1].block_vars["limit"], "limit should be in block_vars")
    assert.is_true(c.blocks[1].has_pre, "block should have has_pre=true")
  end)

  ----------------------------------------------------------------------------
  -- 8. SCRIPT keyword: line_type detection
  ----------------------------------------------------------------------------
  it("SCRIPT keyword as request line (uppercase)", function()
    local buf = create_buf({
      "### Test Script",
      "SCRIPT",
      "< {% local x = 1 %}",
      "> {% client.test('pass', function() end) %}",
    })
    local c = cache.get_buffer_cache(buf)
    assert.equals("head", c.line_type[1], "line 1 should be head")
    assert.equals("request", c.line_type[2], "line 2 (SCRIPT) should be request")
    assert.equals("pre_script", c.line_type[3], "line 3 should be pre_script")
    assert.equals("post_script", c.line_type[4], "line 4 should be post_script")
  end)

  it("SCRIPT keyword as request line (lowercase)", function()
    local buf = create_buf({
      "### Test Script",
      "script",
      "> {% client.test('pass', function() end) %}",
    })
    local c = cache.get_buffer_cache(buf)
    assert.equals("head", c.line_type[1], "line 1 should be head")
    assert.equals("request", c.line_type[2], "line 2 (script) should be request")
    assert.equals("post_script", c.line_type[3], "line 3 should be post_script")
  end)

  it("SCRIPT keyword as request line (mixed case)", function()
    local buf = create_buf({
      "### Test Script",
      "Script",
    })
    local c = cache.get_buffer_cache(buf)
    assert.equals("request", c.line_type[2], "line 2 (Script) should be request")
  end)

  ----------------------------------------------------------------------------
  -- 11. no_blocks: file without ###
  ----------------------------------------------------------------------------
  it("no_blocks", function()
    local buf = create_buf({
      "@base_url = http://example.com",
      "# this is a comment",
      "",
      "some other text",
    })
    local c = cache.get_buffer_cache(buf)
    assert.equals("var", c.line_type[1], "line 1 (@var) should be var")
    assert.equals("file", c.line_type[2], "line 2 (# comment) should be file")
    assert.equals("file", c.line_type[3], "line 3 (empty) should be file")
    assert.equals("file", c.line_type[4], "line 4 should be file")
    assert.is_true(c.file_vars["base_url"], "base_url should be in file_vars")
    assert.equals(0, #c.blocks, "should have 0 blocks")
  end)

  ----------------------------------------------------------------------------
  -- 12. empty_block: buffer with ### then next ###
  ----------------------------------------------------------------------------
  it("empty_block", function()
    local buf = create_buf({
      "### Block 1",
      "### Block 2",
    })
    local c = cache.get_buffer_cache(buf)
    assert.equals(2, #c.blocks, "should have 2 blocks")
    assert.equals("head", c.line_type[1], "line 1 should be head")
    assert.equals("head", c.line_type[2], "line 2 should be head")
    assert.equals(1, c.blocks[1].start_line)
    assert.equals(1, c.blocks[1].end_line, "block 1 should end at line 1")
    assert.equals(2, c.blocks[2].start_line)
    assert.equals(2, c.blocks[2].end_line, "block 2 should end at line 2")
  end)

  ----------------------------------------------------------------------------
  -- 13. prompt: <<var_name
  ----------------------------------------------------------------------------
  it("prompt", function()
    local buf = create_buf({
      "### Get",
      '<<username',
      "GET /users",
    })
    local c = cache.get_buffer_cache(buf)
    assert.equals("prompt", c.line_type[2], "<< line should be prompt")
  end)

  it("prompt commented with #", function()
    local buf = create_buf({
      "### Get",
      '# <<username',
      "GET /users",
    })
    local c = cache.get_buffer_cache(buf)
    assert.equals("prompt", c.line_type[2], "# << line should also be prompt by line_type")
  end)

  ----------------------------------------------------------------------------
  -- 14. run directive
  ----------------------------------------------------------------------------
  it("run", function()
    local buf = create_buf({
      "### Login",
      "POST /login",
      "",
      '{"user":"me"}',
      "run #GetProfile",
    })
    local c = cache.get_buffer_cache(buf)
    assert.equals("run", c.line_type[5], "run directive should be run")
    assert.is_true(c.blocks[1].has_run, "block should have has_run=true")
  end)

  ----------------------------------------------------------------------------
  -- 15. import
  ----------------------------------------------------------------------------
  it("import", function()
    local buf = create_buf({
      "import ./auth.http",
      "import ./orders.http as orders",
      "### Get",
    })
    local c = cache.get_buffer_cache(buf)
    assert.equals(2, #c.file_imports, "should have 2 imports")
    assert.equals("bare", c.file_imports[1].type)
    assert.equals("./auth.http", c.file_imports[1].path)
    assert.equals("aliased", c.file_imports[2].type)
    assert.equals("./orders.http", c.file_imports[2].path)
    assert.equals("orders", c.file_imports[2].alias)
    -- File area lines should be "file" type
    assert.equals("file", c.line_type[1], "import line should be file type")
    assert.equals("file", c.line_type[2], "import line should be file type")
  end)

  ----------------------------------------------------------------------------
  -- 16. multiple blocks: 3 ### blocks
  ----------------------------------------------------------------------------
  it("multiple blocks", function()
    local buf = create_buf({
      "### Block A",
      "GET /a",
      "",
      "### Block B",
      "POST /b",
      "",
      "body b",
      "### Block C",
      "DELETE /c",
    })
    local c = cache.get_buffer_cache(buf)
    assert.equals(3, #c.blocks, "should have 3 blocks")

    -- Block A: lines 1-3 (end_line = line before next ###)
    assert.equals("Block A", c.blocks[1].name)
    assert.equals(1, c.blocks[1].start_line)
    assert.equals(3, c.blocks[1].end_line)

    -- Block B: lines 4-7
    assert.equals("Block B", c.blocks[2].name)
    assert.equals(4, c.blocks[2].start_line)
    assert.equals(7, c.blocks[2].end_line)

    -- Block C: lines 8-9
    assert.equals("Block C", c.blocks[3].name)
    assert.equals(8, c.blocks[3].start_line)
    assert.equals(9, c.blocks[3].end_line)
  end)

  ----------------------------------------------------------------------------
  -- 17. body after empty: lines after headers empty line are "body"
  ----------------------------------------------------------------------------
  it("body after empty", function()
    local buf = create_buf({
      "### Get",
      "GET /users",
      "Authorization: Bearer xyz",
      "",
      '{"page":1}',
      "# a comment in body",
      "",
      "more body",
    })
    local c = cache.get_buffer_cache(buf)
    local lt = c.line_type
    -- line 4 is the empty separator
    assert.equals("empty", lt[4], "line 4 (empty) should be empty")
    -- lines after empty should be body (or empty)
    assert.equals("body", lt[5], "line 5 should be body")
    assert.equals("body", lt[6], "line 6 (comment in body) should be body")
    assert.equals("empty", lt[7], "line 7 (empty in body) should be empty")
    assert.equals("body", lt[8], "line 8 should be body")
  end)

  ----------------------------------------------------------------------------
  -- 18. get_block_at_line
  ----------------------------------------------------------------------------
  it("get_block_at_line", function()
    local buf = create_buf({
      "### Block A",
      "GET /a",
      "",
      "### Block B",
      "POST /b",
    })
    -- Query lines in block A
    local b1 = cache.get_block_at_line(buf, 1)
    assert.is_not_nil(b1, "line 1 should be in a block")
    assert.equals("Block A", b1.name)

    local b1line2 = cache.get_block_at_line(buf, 2)
    assert.equals("Block A", b1line2.name, "line 2 should be in Block A")

    -- Query lines in block B
    local b2 = cache.get_block_at_line(buf, 4)
    assert.is_not_nil(b2, "line 4 should be in a block")
    assert.equals("Block B", b2.name)

    local b2line5 = cache.get_block_at_line(buf, 5)
    assert.equals("Block B", b2line5.name, "line 5 should be in Block B")

    -- File area (before first ###) should return nil
    local no_block = cache.get_block_at_line(buf, 1)
    assert.is_not_nil(no_block, "line 1 is ### so should be in a block")
  end)

  ----------------------------------------------------------------------------
  -- 19. get_block_vars
  ----------------------------------------------------------------------------
  it("get_block_vars", function()
    local buf = create_buf({
      "### Block A",
      "GET /a",
      "",
      "### Block B",
      "@limit = 20",
      "@offset = 10",
      "POST /b",
    })
    -- Block A has no vars
    local vars_a = cache.get_block_vars(buf, 1)
    assert.is_not_nil(vars_a)
    assert.equals(0, vim.tbl_count(vars_a), "Block A should have 0 vars")

    -- Block B has vars
    local vars_b = cache.get_block_vars(buf, 5)
    assert.is_true(vars_b["limit"], "limit should be in Block B vars")
    assert.is_true(vars_b["offset"], "offset should be in Block B vars")

    -- Query via body line
    local vars_b_body = cache.get_block_vars(buf, 7)
    assert.is_true(vars_b_body["limit"], "limit should be in Block B vars (via body line)")
  end)
end)
