--- Tests for outline/symbol request collection (method column).
local symbols = require("poste-http.http.symbols")

local function collect(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local requests = symbols.collect_requests(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  return requests
end

describe("symbols.collect_requests method column", function()
  it("shows SCRIPT for script-only orchestration blocks", function()
    local requests = collect({
      "import ./requests.http as api",
      "",
      "### Orchestration: login flow",
      "SCRIPT",
      "> {%",
      '  local r = client.run("#api.Login", {})',
      "%}",
    })
    assert.are_equal(1, #requests)
    assert.are_equal("SCRIPT", requests[1].method)
    assert.are_equal("Orchestration: login flow", requests[1].name)
  end)

  it("keeps GET for normal request blocks", function()
    local requests = collect({
      "### Get users",
      "GET /api/users",
    })
    assert.are_equal("GET", requests[1].method)
  end)

  it("keeps run for run directives", function()
    local requests = collect({
      "### Run login",
      "run #api.Login (@username=alice)",
    })
    assert.are_equal("RUN", requests[1].method)
  end)

  it("finds GET after pre-script with space in tag", function()
    local requests = collect({
      "### Session test",
      "< {% client.global.set('x', '1') %}",
      "GET /anything/session-test",
      "Authorization: Bearer {{session_token}}",
    })
    assert.are_equal(1, #requests)
    assert.are_equal("GET", requests[1].method)
    assert.are_equal("/anything/session-test", requests[1].url_path)
  end)

  it("skips non-HTTP lines and finds the actual request", function()
    local requests = collect({
      "### Multiline var",
      "# Tests: multi-line variable",
      "@headers_block=>>>",
      "X-Custom-Auth: Bearer token123",
      "X-Client-Id: poste-test",
      "<<<",
      "GET {{host}}/anything/multiline-var",
      "{{headers_block}}",
    })
    assert.are_equal(1, #requests)
    assert.are_equal("GET", requests[1].method)
    -- extract_url_path strips {{var}} wrappers, leaving just the path
    assert.are_equal("/anything/multiline-var", requests[1].url_path)
  end)

  it("finds the request line beyond 20 lines into the block", function()
    local lines = { "### Deep block" }
    for i = 1, 30 do
      lines[#lines + 1] = "@var" .. i .. " = " .. i
    end
    lines[#lines + 1] = "POST /deep"
    local requests = collect(lines)
    assert.are_equal(1, #requests)
    assert.are_equal("POST", requests[1].method)
    assert.are_equal("/deep", requests[1].url_path)
  end)

  it("survives long CJK request names without truncation errors", function()
    local long_name = string.rep("请求", 20)
    local requests = collect({
      "### " .. long_name,
      "GET /cjk",
    })
    assert.are_equal(1, #requests)
    assert.are_equal("GET", requests[1].method)
    assert.are_equal(long_name, requests[1].name)
  end)
end)

describe("symbols.current_index", function()
  local reqs = { { line = 4 }, { line = 10 }, { line = 20 } }

  it("picks the last request whose start line is at or before the cursor", function()
    assert.are_equal(1, symbols.current_index(reqs, 4))
    assert.are_equal(2, symbols.current_index(reqs, 15))
    assert.are_equal(3, symbols.current_index(reqs, 100))
  end)

  it("returns nil when the cursor is above every request or there are none", function()
    assert.is_nil(symbols.current_index(reqs, 3))
    assert.is_nil(symbols.current_index({}, 1))
  end)
end)

describe("symbols.show_symbols picker preselect", function()
  local saved_snacks
  local stub

  -- 1-based fixture: blocks at lines 1/4/7
  local THREE_BLOCKS = {
    "### One",     -- 1
    "GET /one",    -- 2
    "",            -- 3
    "### Two",     -- 4
    "GET /two",    -- 5
    "",            -- 6
    "### Three",   -- 7
    "GET /three",  -- 8
  }

  local function stub_snacks()
    saved_snacks = package.loaded["snacks"]
    stub = { select_calls = {}, views = {}, centers = 0 }
    package.loaded["snacks"] = {
      picker = {
        select = function(items, opts, on_choice)
          table.insert(stub.select_calls, { items = items, opts = opts, on_choice = on_choice })
        end,
        actions = {
          list_scroll_center = function() stub.centers = stub.centers + 1 end,
        },
      },
    }
  end

  -- Mimics the real picker contract enough to drive opts.snacks.on_show.
  local function fake_picker()
    local last = stub.select_calls[#stub.select_calls]
    return {
      items = function() return last.items end,
      list = { view = function(_, i) table.insert(stub.views, i) end },
    }
  end

  local function open_fixture(lines, cursor_line)
    local prev_buf = vim.api.nvim_win_get_buf(0)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { cursor_line, 0 })
    return buf, prev_buf
  end

  after_each(function()
    package.loaded["snacks"] = saved_snacks
    saved_snacks = nil
    stub = nil
  end)

  it("preselects the request containing the cursor, not the first one", function()
    stub_snacks()
    local buf, prev_buf = open_fixture(THREE_BLOCKS, 6)  -- blank line inside block Two
    local requests = symbols.collect_requests(buf)
    assert.are_equal(4, requests[2].line)  -- fixture sanity: block.start_line is the ### line

    symbols.show_symbols()

    assert.are_equal(1, #stub.select_calls)
    local items = stub.select_calls[1].items
    local current = {}
    for i, item in ipairs(items) do
      if item.current then table.insert(current, i) end
    end
    assert.are_equal("Two", items[current[1]].key.name)

    stub.select_calls[1].opts.snacks.on_show(fake_picker())
    assert.are_equal(2, stub.views[1])
    assert.are_equal(1, stub.centers)

    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_win_set_buf(0, prev_buf)
  end)

  it("marks the request when the cursor sits exactly on its ### line", function()
    stub_snacks()
    local buf, prev_buf = open_fixture(THREE_BLOCKS, 7)  -- "### Three"

    symbols.show_symbols()

    local items = stub.select_calls[1].items
    local current = {}
    for i, item in ipairs(items) do
      if item.current then table.insert(current, i) end
    end
    assert.are_equal(1, #current)
    assert.are_equal("Three", items[current[1]].key.name)

    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_win_set_buf(0, prev_buf)
  end)

  it("keeps the picker default when the cursor is above every request", function()
    stub_snacks()
    local buf, prev_buf = open_fixture({
      "@host = api.example.com",  -- 1: file-scope var, above all requests
      "",                          -- 2
      "### One",                   -- 3
      "GET {{host}}/one",          -- 4
    }, 1)

    symbols.show_symbols()

    local items = stub.select_calls[1].items
    for _, item in ipairs(items) do
      assert.is_not_truthy(item.current)
    end
    stub.select_calls[1].opts.snacks.on_show(fake_picker())
    assert.are_equal(0, #stub.views)

    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_win_set_buf(0, prev_buf)
  end)
end)
