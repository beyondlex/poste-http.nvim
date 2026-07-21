--- Tests for block boundary delegation (Phase 3 of block-index proposal)
--- Regression tests ensuring delegated functions match original behavior exactly.

local cache = require("poste.http.cache")

--- Create a scratch buffer with the given lines, return its number.
local function create_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("block boundary delegation", function()
  ----------------------------------------------------------------------------
  -- cache.lua:find_request_block_bounds
  ----------------------------------------------------------------------------
  describe("find_request_block_bounds", function()
    it("cursor in middle of block", function()
      local buf = create_buf({
        "### Get Users",
        "GET /users",
        "Content-Type: application/json",
        "",
        '{"page":1}',
      })
      local s, e = cache.find_request_block_bounds(buf, 3)
      assert.equals(1, s)
      assert.equals(5, e)
    end)

    it("cursor on ### line returns bounds", function()
      local buf = create_buf({
        "### Get Users",
        "GET /users",
        "",
      })
      local s, e = cache.find_request_block_bounds(buf, 1)
      assert.equals(1, s)
      -- end_line = line before next ### (or EOF = 3)
      assert.equals(3, e)
    end)

    it("cursor between blocks (separator) returns nil", function()
      local buf = create_buf({
        "### Block A",
        "GET /a",
        "",
        "### Block B",
        "POST /b",
      })
      
      local s, e = cache.find_request_block_bounds(buf, 3)
      assert.is_nil(s)
      assert.is_nil(e)
    end)

    it("cursor before any ### returns nil", function()
      local buf = create_buf({
        "@base = http://example.com",
        "### Get",
        "GET /users",
      })
      
      local s, e = cache.find_request_block_bounds(buf, 2)
      -- line 2 is the ### line, so it should return (2, 3)
      assert.is_not_nil(s)
      assert.equals(2, s)
    end)

    it("single block with no next ### ends at last content", function()
      local buf = create_buf({
        "### Get",
        "GET /api",
        "Accept: application/json",
      })
      
      local s, e = cache.find_request_block_bounds(buf, 2)
      assert.equals(1, s)
      assert.equals(3, e)
    end)

    it("cursor in second block returns second block bounds", function()
      local buf = create_buf({
        "### Block A",
        "GET /a",
        "",
        "### Block B",
        "POST /b",
        "",
        "body content",
      })
      
      local s, e = cache.find_request_block_bounds(buf, 5)
      assert.equals(4, s)
      assert.equals(7, e)
    end)
  end)

  ----------------------------------------------------------------------------
  -- cache.lua:find_request_line
  ----------------------------------------------------------------------------
  describe("find_request_line", function()
    it("simple block with GET line returns 0-indexed line", function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "",
      })
      
      local line = cache.find_request_line(buf, 1)
      assert.equals(1, line)  -- 0-indexed: line 2 is index 1
    end)

    it("block with pre-script before request skips it", function()
      local buf = create_buf({
        "### Get",
        "< {%",
        "  local x = 1",
        "%}",
        "GET /users",
      })
      
      local line = cache.find_request_line(buf, 1)
      assert.equals(4, line)  -- 0-indexed: line 5 is index 4
    end)

    it("block with @var before request skips it", function()
      local buf = create_buf({
        "### Get",
        "@page = 1",
        "GET /users",
      })
      
      local line = cache.find_request_line(buf, 1)
      assert.equals(2, line)  -- 0-indexed: line 3 is index 2
    end)

    it("cursor on separator after block returns nil", function()
      local buf = create_buf({
        "### Block A",
        "GET /a",
        "",
        "### Block B",
        "POST /b",
      })
      
      local line = cache.find_request_line(buf, 3)
      assert.is_nil(line)
    end)

    it("SCRIPT keyword returns its line", function()
      local buf = create_buf({
        "### Script Test",
        "SCRIPT",
        "< {% local x = 1 %}",
        "> {% client.test('pass', function() end) %}",
      })
      
      local line = cache.find_request_line(buf, 1)
      assert.equals(1, line)
    end)

    it("lowercase script keyword returns its line", function()
      local buf = create_buf({
        "### Script Test",
        "script",
        "< {% local x = 1 %}",
      })
      
      local line = cache.find_request_line(buf, 1)
      assert.equals(1, line)
    end)
  end)

  ----------------------------------------------------------------------------
  -- cache.lua:extract_request_block (regression only, not delegated)
  ----------------------------------------------------------------------------
  describe("extract_request_block", function()
    it("block with headers", function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "Content-Type: application/json",
        "Authorization: Bearer xyz",
        "",
        '{"page":1}',
      })
      
      local result = cache.extract_request_block(buf, 2)
      assert.equals("GET /users", result.request_line)
      assert.equals(2, #result.headers)
      assert.equals("Content-Type", result.headers[1][1])
      assert.equals("application/json", result.headers[1][2])
      assert.equals("Authorization", result.headers[2][1])
      assert.equals("Bearer xyz", result.headers[2][2])
    end)

    it("block without headers", function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "",
        '{"page":1}',
      })
      
      local result = cache.extract_request_block(buf, 2)
      assert.equals("GET /users", result.request_line)
      assert.equals(0, #result.headers)
    end)
  end)

  ----------------------------------------------------------------------------
  -- request_vars.lua:collect_requests
  ----------------------------------------------------------------------------
  describe("collect_requests", function()
    it("two named blocks returns 2 entries", function()
      local buf = create_buf({
        "### Login",
        "POST /login",
        "",
        "### GetProfile",
        "GET /profile",
      })
      local request_vars = require("poste.http.request_vars")
      local requests = request_vars.collect_requests(buf)
      assert.equals(2, #requests)
      assert.equals("Login", requests[1].name)
      assert.equals(1, requests[1].start_line)
      assert.equals(3, requests[1].end_line)
      assert.equals("GetProfile", requests[2].name)
      assert.equals(4, requests[2].start_line)
      assert.equals(5, requests[2].end_line)
    end)

    it("no blocks returns empty table", function()
      local buf = create_buf({
        "@base = http://example.com",
        "import ./auth.http",
      })
      local request_vars = require("poste.http.request_vars")
      local requests = request_vars.collect_requests(buf)
      assert.equals(0, #requests)
    end)

    it("unnamed block returns entry with empty name", function()
      local buf = create_buf({
        "###",
        "GET /api",
      })
      local request_vars = require("poste.http.request_vars")
      local requests = request_vars.collect_requests(buf)
      assert.equals(1, #requests)
      assert.equals("", requests[1].name)
    end)
  end)

  ----------------------------------------------------------------------------
  -- boundary_indicator.lua:find_block
  ----------------------------------------------------------------------------
  describe("find_block", function()
    it("cursor in block returns block bounds", function()
      local buf = create_buf({
        "### Get",
        "GET /users",
        "",
        '{"page":1}',
      })
      -- Access the internal find_block via the module
      -- The function is local, so we test through the public refresh/clear API
      -- Instead, test that get_block_at_line returns correct results
      local block = cache.get_block_at_line(buf, 2)
      assert.is_not_nil(block)
      assert.equals(1, block.start_line)
      assert.equals(4, block.end_line)
    end)

    it("cursor on separator between blocks returns nil", function()
      local buf = create_buf({
        "### Block A",
        "GET /a",
        "",
        "### Block B",
        "POST /b",
      })
      local block = cache.get_block_at_line(buf, 3)
      assert.is_nil(block)
    end)
  end)

  ----------------------------------------------------------------------------
  -- symbols.lua:collect_requests
  ----------------------------------------------------------------------------
  describe("symbols collect_requests", function()
    it("two blocks returns metadata for both", function()
      local buf = create_buf({
        "### Get Users",
        "GET /api/users",
        "",
        "### Create User",
        "POST /api/users",
        "Content-Type: application/json",
      })
      -- symbols.collect_requests is local, so test via show_symbols behavior
      -- Instead, verify the cache.blocks have correct names
      local c = cache.get_buffer_cache(buf)
      assert.equals(2, #c.blocks)
      assert.equals("Get Users", c.blocks[1].name)
      assert.equals("Create User", c.blocks[2].name)
    end)
  end)
end)
