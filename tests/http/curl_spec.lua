-- Tests for curl.lua — paste-a-curl-command parsing (previously 0 coverage).

local curl = require("poste-http.http.curl")

describe("curl.parse_curl", function()
  it("rejects empty input", function()
    local parsed, err = curl.parse_curl("")
    assert.is_nil(parsed)
    assert.matches("Empty", err)
    parsed, err = curl.parse_curl(nil)
    assert.is_nil(parsed)
    assert.matches("Empty", err)
  end)

  it("rejects a command without a URL", function()
    local parsed, err = curl.parse_curl("curl -H 'Accept: json'")
    assert.is_nil(parsed)
    assert.matches("No URL", err)
  end)

  it("parses a bare GET", function()
    local parsed = curl.parse_curl("curl https://api.example.com/users")
    assert.equals("GET", parsed.method)
    assert.equals("https://api.example.com/users", parsed.url)
    assert.same({}, parsed.headers)
    assert.is_nil(parsed.body)
  end)

  it("parses method, headers and data with quote stripping", function()
    local parsed = curl.parse_curl([=[
curl -X POST 'https://api.example.com/login' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer tok' \
  -d '{"user": "admin"}']=])
    assert.equals("POST", parsed.method)
    assert.equals("https://api.example.com/login", parsed.url)
    assert.same({
      { "Content-Type", "application/json" },
      { "Authorization", "Bearer tok" },
    }, parsed.headers)
    assert.equals('{"user": "admin"}', parsed.body)
  end)

  it("promotes GET to POST when -d is present", function()
    local parsed = curl.parse_curl("curl https://api.example.com -d 'a=1'")
    assert.equals("POST", parsed.method)
    assert.equals("a=1", parsed.body)
  end)

  it("accepts --data-raw and --header long forms", function()
    local parsed = curl.parse_curl("curl --request PUT https://api.example.com --header 'X-A: b' --data-raw '{}'")
    assert.equals("PUT", parsed.method)
    assert.same({ { "X-A", "b" } }, parsed.headers)
    assert.equals("{}", parsed.body)
  end)

  it("keeps spaces inside single and double quoted args", function()
    local parsed = curl.parse_curl("curl 'https://api.example.com/q?a=b c' -d '{\"k\": \"v w\"}'")
    assert.equals("https://api.example.com/q?a=b c", parsed.url)
    assert.equals('{"k": "v w"}', parsed.body)
  end)

  it("supports attached short forms: -XPOST, -H'...', -dvalue", function()
    local parsed = curl.parse_curl(
      [[curl -XPOST https://api.example.com -H'Content-Type: application/json' -d'{ "a": 1 }']])
    assert.equals("POST", parsed.method)
    assert.same({ { "Content-Type", "application/json" } }, parsed.headers)
    assert.equals("{ \"a\": 1 }", parsed.body)
    assert.equals("https://api.example.com", parsed.url)
  end)

  it("supports attached long forms: --request=METHOD and --header=VALUE", function()
    local parsed = curl.parse_curl(
      "curl --request=DELETE https://api.example.com --header='X-A: b'")
    assert.equals("DELETE", parsed.method)
    assert.same({ { "X-A", "b" } }, parsed.headers)
  end)

  it("keeps empty-value headers instead of dropping them", function()
    -- curl's -H 'Name:' would remove the header, but imports of shared
    -- commands are lossy in the other direction; keep the empty value.
    local parsed = curl.parse_curl(
      "curl https://api.example.com -H 'X-Custom:' --header 'X-Other;'")
    assert.same({
      { "X-Custom", "" },
      { "X-Other", "" },
    }, parsed.headers)
  end)

  describe("--data-urlencode", function()
    it("urlencodes name=value pieces and promotes GET to POST", function()
      local parsed = curl.parse_curl(
        "curl https://api.example.com --data-urlencode 'name=va lue&x=1'")
      assert.equals("POST", parsed.method)
      assert.equals("name=va%20lue%26x%3D1", parsed.body)
    end)

    it("supports =content and bare-content forms", function()
      local parsed = curl.parse_curl(
        "curl https://api.example.com --data-urlencode '=a b' --data-urlencode 'q'")
      assert.equals("a%20b&q", parsed.body)
    end)

    it("joins multiple pieces with & and adds the form content-type", function()
      local parsed = curl.parse_curl(
        "curl https://api.example.com --data-urlencode 'a=1' --data-urlencode 'b=2'")
      assert.equals("a=1&b=2", parsed.body)
      local has_ct = false
      for _, h in ipairs(parsed.headers) do
        if h[1] == "Content-Type" then has_ct = true end
      end
      assert.is_true(has_ct, "form-urlencoded content-type must be added")
    end)

    it("respects an explicit Content-Type and reads @file pieces", function()
      local path = vim.fn.tempname() .. "_dude"
      local fd = io.open(path, "w")
      fd:write("va lue")
      fd:close()

      local parsed = curl.parse_curl(
        "curl https://api.example.com -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'name@"
        .. path .. "'")
      os.remove(path)
      assert.equals("name=va%20lue", parsed.body)
      local ct_count = 0
      for _, h in ipairs(parsed.headers) do
        if h[1] == "Content-Type" then ct_count = ct_count + 1 end
      end
      assert.equals(1, ct_count, "must not add a second content-type")
    end)
  end)

  describe("@file data bodies", function()
    it("bakes -d @file content in at import time", function()
      local path = vim.fn.tempname() .. "_data"
      local fd = io.open(path, "w")
      fd:write('{"k": "v"}')
      fd:close()

      local separated = curl.parse_curl("curl https://api.example.com -d @" .. path)
      local attached = curl.parse_curl("curl https://api.example.com -d@" .. path)
      local binary = curl.parse_curl("curl https://api.example.com --data-binary @" .. path)
      os.remove(path)

      assert.equals('{"k": "v"}', separated.body)
      assert.equals('{"k": "v"}', attached.body)
      assert.equals('{"k": "v"}', binary.body)
    end)

    it("keeps --data-raw @file literal (curl does not expand it either)", function()
      local parsed = curl.parse_curl(
        "curl https://api.example.com --data-raw '@/no/such/file'")
      assert.equals("@/no/such/file", parsed.body)
    end)
  end)

  it("keeps interior blank lines when converting a multi-line body", function()
    local orig_getreg = vim.fn.getreg
    vim.fn.getreg = function() return "curl https://api.example.com --data-raw 'a\n\nb\n'" end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.fn.cursor(1, 1)
    local orig_notify = vim.notify
    vim.notify = function() end
    curl.paste_curl("+")
    vim.notify = orig_notify
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.fn.getreg = orig_getreg
    vim.api.nvim_buf_delete(buf, { force = true })
    -- The blank line between "a" and "b" is part of the body and must survive.
    -- --data-raw also promotes GET to POST by design.
    assert.same({ "", "###", "POST https://api.example.com", "", "a", "", "b" }, lines)
  end)
end)

describe("curl.paste_curl (conversion shape)", function()
  local orig_getreg

  after_each(function()
    vim.fn.getreg = orig_getreg
  end)

  local function lines_from_clipboard(content)
    orig_getreg = vim.fn.getreg
    vim.fn.getreg = function() return content end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.fn.cursor(1, 1)
    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg) table.insert(notified, msg) end
    curl.paste_curl("+")
    vim.notify = orig_notify
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.api.nvim_buf_delete(buf, { force = true })
    return lines, notified
  end

  it("inserts separator, request line, headers and body", function()
    local lines = lines_from_clipboard("curl -X POST https://api.example.com -H 'A: b' -d '{\"x\": 1}'")
    -- paste inserts after the cursor line; the new buffer starts with one
    -- empty row, so the inserted block begins at index 2.
    assert.same({
      "",
      "###",
      "POST https://api.example.com",
      "A: b",
      "",
      '{"x": 1}',
    }, lines)
  end)

  it("warns on an empty clipboard without inserting", function()
    local lines, notified = lines_from_clipboard("")
    assert.equals(1, #lines, "buffer must stay at its initial empty row")
    assert.is_truthy(tostring(notified[1]):find("Clipboard is empty"))
  end)

  it("warns on an unparseable command without inserting", function()
    local lines, notified = lines_from_clipboard("curl -H 'A: b'")
    assert.equals(1, #lines, "buffer must stay at its initial empty row")
    assert.is_truthy(tostring(notified[1]):find("Failed to parse curl"))
  end)
end)
