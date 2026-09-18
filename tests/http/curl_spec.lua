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

  it("concatenates multiple -d pieces with & in command order", function()
    -- curl 8.7.1 sends `a=1&b=2` for -d a=1 -d b=2; the importer used to
    -- keep only the LAST piece.
    local parsed = curl.parse_curl("curl https://api.example.com -d a=1 -d b=2")
    assert.equals("a=1&b=2", parsed.body)
  end)

  it("interleaves -d and --data-urlencode pieces in command order", function()
    -- curl 8.7.1 sends `a=1&b=x%20y&c=3` for this sequence.
    local parsed = curl.parse_curl(
      "curl https://api.example.com -d a=1 --data-urlencode 'b=x y' -d c=3")
    assert.equals("a=1&b=x%20y&c=3", parsed.body)
    assert.equals("application/x-www-form-urlencoded", parsed.headers[1][2])
  end)

  it("moves data to the query string with -G/--get", function()
    local short = curl.parse_curl("curl -G https://api.example.com/search -d q=abc")
    assert.equals("GET", short.method)
    assert.equals("https://api.example.com/search?q=abc", short.url)
    assert.is_nil(short.body)
    local long = curl.parse_curl(
      "curl --get 'https://api.example.com/search?lang=en' --data-urlencode 'q=x y'")
    assert.equals("GET", long.method)
    assert.equals("https://api.example.com/search?lang=en&q=x%20y", long.url)
    assert.is_nil(long.body)
    -- --get moves the data even under -X (curl sends `PUT /?a=1`);
    -- -X only overrides the method token
    local forced = curl.parse_curl("curl --get -X PUT https://api.example.com -d a=1")
    assert.equals("PUT", forced.method)
    assert.equals("https://api.example.com?a=1", forced.url)
    assert.is_nil(forced.body)
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

  it("honors backslash-quote escapes inside double quotes (Windows-style -d)", function()
    -- Before the fix the `"` in `\"` closed the quote early and the body
    -- arrived mangled as {\name\:\test\}.
    local parsed = curl.parse_curl(
      'curl -X POST https://api.example.com -H "Content-Type: application/json" -d "{\\"name\\":\\"test\\"}"')
    assert.equals('{"name":"test"}', parsed.body)
    assert.equals("application/json", parsed.headers[1][2])
  end)

  it("keeps literal backslashes that don't escape a quote inside double quotes", function()
    local parsed = curl.parse_curl([[curl https://api.example.com -d "{\"re\\n\": 1}"]])
    -- shell word: {"re\\n": 1} — `\\` is an escaped backslash, kept as one
    assert.equals('{"re\\n": 1}', parsed.body)
  end)

  it("keeps backslashes literal inside single quotes (shell rules)", function()
    local parsed = curl.parse_curl([[curl https://api.example.com -d '{"a": "b\c"}']])
    assert.equals('{"a": "b\\c"}', parsed.body)
  end)

  it("takes the FIRST bare argument as the URL", function()
    -- curl sends the first bare arg; -o out.txt after the URL must not
    -- replace it (previously the LAST bare arg won, so the output file
    -- name became the request target).
    local parsed = curl.parse_curl("curl https://api.example.com/users -o out.txt")
    assert.equals("https://api.example.com/users", parsed.url)
  end)

  it("consumes values of unmapped flags instead of leaking them as URL/body", function()
    local parsed = curl.parse_curl(
      "curl https://api.example.com -u alice:s3cret -o out.txt -m 30 --connect-timeout 5 -A curl/8 -x http://proxy:8080 --retry 2")
    assert.equals("https://api.example.com", parsed.url)
    assert.is_nil(parsed.body)
  end)

  it("consumes the long tail of value flags (-c -P -r -t -U -z and long forms)", function()
    local parsed = curl.parse_curl(
      "curl https://api.example.com -c /tmp/jar.txt --cookie-jar jar2 -P 21 -r 0-99 -t TTYPE=vt100 -U puser:ppass -z 'yesterday' --range 0-9 --time-cond now --upload-file f --proto https --request-target /x --engine openssl --trace out")
    assert.equals("https://api.example.com", parsed.url)
    assert.is_nil(parsed.body)
  end)

  it("consumes attached short flag values: -m10, -ooutline", function()
    local parsed = curl.parse_curl("curl -m10 -sS https://api.example.com -oout.txt")
    assert.equals("https://api.example.com", parsed.url)
  end)

  it("accepts --url and --url= long forms", function()
    local separated = curl.parse_curl("curl --url https://api.example.com")
    local attached = curl.parse_curl("curl --url=https://api.example.com")
    assert.equals("https://api.example.com", separated.url)
    assert.equals("https://api.example.com", attached.url)
  end)

  describe("-F/--form multipart import", function()
    it("imports value parts with a generated boundary and form content-type", function()
      local parsed = curl.parse_curl("curl https://api.example.com -F 'name=lex' -F 'role=admin'")
      assert.equals("POST", parsed.method)
      assert.matches("^multipart/form%-data; boundary=", parsed.headers[#parsed.headers][2])
      local boundary = parsed.headers[#parsed.headers][2]:match("boundary=(.+)$")
      assert.equals(table.concat({
        "--" .. boundary,
        'Content-Disposition: form-data; name="name"',
        "",
        "lex",
        "--" .. boundary,
        'Content-Disposition: form-data; name="role"',
        "",
        "admin",
        "--" .. boundary .. "--",
      }, "\n"), parsed.body)
    end)

    it("imports @file parts as live `< path` refs, keeping filename", function()
      local parsed = curl.parse_curl("curl https://api.example.com -F 'avatar=@~/pics/avatar.png;type=image/png'")
      assert.truthy(parsed.body:find('; name="avatar"; filename="avatar.png"\n\n< ~/pics/avatar.png\n', 1, true))
      -- the ;type= directive must not leak into the path or a second line
      assert.falsy(parsed.body:find("image/png", 1, true))
    end)

    it("reuses the boundary from an explicit multipart Content-Type", function()
      local parsed = curl.parse_curl(
        "curl https://api.example.com -H 'Content-Type: multipart/form-data; boundary=MyB' -F 'a=1'")
      local ct_count = 0
      for _, h in ipairs(parsed.headers) do
        if h[1]:lower() == "content-type" then ct_count = ct_count + 1 end
      end
      assert.equals(1, ct_count, "must not add a second content-type")
      assert.truthy(parsed.body:find("--MyB\n", 1, true))
      assert.equals("--MyB--", parsed.body:sub(-#"--MyB--"))
    end)

    it("strips RFC 2045 quotes from an explicit boundary", function()
      -- A quoted boundary is one value; delimiter lines must carry the
      -- unquoted token or no server can match them to the header.
      local parsed = curl.parse_curl(
        'curl https://api.example.com -H \'Content-Type: multipart/form-data; boundary="My B"\' -F \'a=1\'')
      assert.truthy(parsed.body:find("--My B\n", 1, true))
      assert.equals("--My B--", parsed.body:sub(-#"--My B--"))
    end)

    it("keeps --form-string @ literal and supports attached -F forms", function()
      local str = curl.parse_curl("curl https://api.example.com --form-string 'a=@lit'")
      assert.truthy(str.body:find('; name="a"\n\n@lit\n', 1, true))
      local attached = curl.parse_curl("curl https://api.example.com -Fb=2")
      assert.truthy(attached.body:find('; name="b"\n\n2\n', 1, true))
    end)
  end)

  describe("-u/--user basic auth import", function()
    it("emits an Authorization: Basic header from -u", function()
      local parsed = curl.parse_curl("curl -u alice:s3cret https://api.example.com")
      local expected = "Basic " .. vim.base64.encode("alice:s3cret")
      assert.same({ { "Authorization", expected } }, parsed.headers)
      -- the raw credentials must not surface anywhere else
      assert.falsy(parsed.url:find("alice", 1, true))
    end)

    it("supports --user= and attached -u forms", function()
      local long = curl.parse_curl("curl --user=b:c https://api.example.com")
      local attached = curl.parse_curl("curl -ub:c https://api.example.com")
      assert.equals("Basic " .. vim.base64.encode("b:c"), long.headers[1][2])
      assert.equals("Basic " .. vim.base64.encode("b:c"), attached.headers[1][2])
    end)
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
