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

describe("curl.parse_curl combined short flags", function()
  it("consumes the value that rides after a trailing value flag in a blob", function()
    -- Regression: the generic branch treated every letter as boolean, so
    -- `out.txt` leaked out as a bare arg and won the first-bare-arg-is-URL
    -- scan, replacing the real request target.
    local parsed = curl.parse_curl("curl -sSo out.txt https://api.example.com/users")
    assert.equals("https://api.example.com/users", parsed.url)
  end)

  it("consumes an attached value inside a blob (-sofile)", function()
    local parsed = curl.parse_curl("curl -soresp.txt https://api.example.com/users")
    assert.equals("https://api.example.com/users", parsed.url)
  end)

  it("keeps boolean-only blobs working", function()
    local parsed = curl.parse_curl("curl -sSLk https://api.example.com/users")
    assert.equals("https://api.example.com/users", parsed.url)
    assert.equals("GET", parsed.method)
  end)

  it("does not let a blob value hijack the URL before the real target", function()
    -- URL first, output flag after: the blob's value must be consumed even
    -- though the URL scan already matched.
    local parsed = curl.parse_curl("curl https://api.example.com/users -sSo out.txt -X POST")
    assert.equals("https://api.example.com/users", parsed.url)
    assert.equals("POST", parsed.method)
  end)

  it("dispatches a semantic value letter in a blob to its real handler (-sd)", function()
    -- curl reads `-sd v` as `-s -d v`; the old walk swallowed the value, so
    -- the body vanished AND the request stayed a GET.
    local parsed = curl.parse_curl("curl -sd '{\"a\":1}' https://api.example.com/users")
    assert.equals("POST", parsed.method)
    assert.equals('{"a":1}', parsed.body)
  end)

  it("dispatches an attached semantic value inside a blob (-sd'{..}')", function()
    local parsed = curl.parse_curl("curl -sd'{\"a\":1}' https://api.example.com/users")
    assert.equals("POST", parsed.method)
    assert.equals('{"a":1}', parsed.body)
  end)

  it("dispatches -H inside a blob instead of dropping the header", function()
    local parsed = curl.parse_curl("curl -sH 'Accept: application/json' https://api.example.com/users")
    assert.equals("GET", parsed.method)
    local found = false
    for _, h in ipairs(parsed.headers) do
      if h[1] == "Accept" and h[2] == "application/json" then
        found = true
      end
    end
    assert.truthy(found, "Accept header must survive the blob")
  end)

  it("dispatches -X inside a blob so -sXGET -d is not promoted to POST", function()
    -- The dedicated branches never see -sXGET (it starts "-s"), so without
    -- X handling here the later -d promotion made it POST, which is not
    -- what curl sends.
    local parsed = curl.parse_curl("curl -sXGET -d a=1 https://api.example.com/users")
    assert.equals("GET", parsed.method)
    assert.equals("a=1", parsed.body)
  end)

  it("dispatches -u inside a blob to the Basic auth header", function()
    local parsed = curl.parse_curl("curl -su bob:secret https://api.example.com/users")
    local auth
    for _, h in ipairs(parsed.headers) do
      if h[1] == "Authorization" then
        auth = h[2]
      end
    end
    assert.truthy(auth and auth:match("^Basic "), "Basic Authorization expected")
  end)
end)

describe("curl.parse_curl tokenizer edges (2026-09-24 round)", function()
  it("treats a bare newline as an argument separator, not URL content", function()
    -- A hard-wrapped paste (no backslash) used to glue both lines into one
    -- url arg: "http://x.y/a\nhttp://z.z".
    local parsed = curl.parse_curl("curl 'http://x.y/a'\n'http://z.z'")
    assert.equals("http://x.y/a", parsed.url)
  end)

  it("keeps a newline inside quotes as part of the argument", function()
    local parsed = curl.parse_curl("curl -d 'a\nb' http://x.y")
    assert.equals("a\nb", parsed.body)
  end)

  it("delivers an empty quoted argument as an empty argv (-d '')", function()
    -- The tokenizer used to drop it, so -d ate the URL and the import
    -- failed with "No URL found".
    local parsed = curl.parse_curl("curl -d '' http://x.y")
    assert.equals("http://x.y", parsed.url)
    assert.equals("POST", parsed.method)
    assert.equals("", parsed.body)
  end)

  it("rejects the bare `curl` instead of importing curl as the URL", function()
    local parsed, err = curl.parse_curl("curl")
    assert.is_nil(parsed)
    assert.matches("No URL", err)
  end)
end)

describe("curl.parse_curl --json", function()
  it("imports --json as a JSON body with both implied headers", function()
    -- curl ≥7.82: --json is data-raw + Content-Type + Accept. The value used
    -- to win the first-bare-arg URL scan and the real URL vanished.
    local parsed = curl.parse_curl("curl --json '{\"a\":1}' https://api.example.com/x")
    assert.equals("POST", parsed.method)
    assert.equals("https://api.example.com/x", parsed.url)
    assert.equals('{"a":1}', parsed.body)
    local ct, accept
    for _, h in ipairs(parsed.headers) do
      if h[1] == "Content-Type" then ct = h[2] end
      if h[1] == "Accept" then accept = h[2] end
    end
    assert.equals("application/json", ct)
    assert.equals("application/json", accept)
  end)

  it("supports --json= and keeps an explicit Accept untouched", function()
    local parsed = curl.parse_curl(
      "curl --json='{\"a\":1}' -H 'Accept: text/plain' https://api.example.com/x")
    local ct, accept
    for _, h in ipairs(parsed.headers) do
      if h[1] == "Content-Type" then ct = h[2] end
      if h[1] == "Accept" then accept = h[2] end
    end
    assert.equals('{"a":1}', parsed.body)
    assert.equals("application/json", ct)
    assert.equals("text/plain", accept)
  end)
end)

describe("curl.parse_curl -I/--head", function()
  it("imports -I as HEAD, not GET", function()
    local parsed = curl.parse_curl("curl -I https://api.example.com/health")
    assert.equals("HEAD", parsed.method)
    assert.equals("https://api.example.com/health", parsed.url)
  end)

  it("supports --head and the -sI blob form", function()
    assert.equals("HEAD", curl.parse_curl("curl --head https://x.dev/a").method)
    local blobbed = curl.parse_curl("curl -sI https://x.dev/a")
    assert.equals("HEAD", blobbed.method)
    assert.equals("https://x.dev/a", blobbed.url) -- -s must not eat the URL
  end)

  it("an explicit -X wins over -I in BOTH orders (wire-verified)", function()
    -- `curl -X POST -I` and `curl -I -X POST` both send `POST` on the wire
    -- (captured against curl 8.7.1: the -X request token beats --head no
    -- matter which comes first). The old import turned the -X-first order
    -- into HEAD — the -I branch clobbered the method it had no right to.
    assert.equals("POST", curl.parse_curl("curl -I -X POST https://x.dev/a").method)
    assert.equals("POST", curl.parse_curl("curl -X POST -I https://x.dev/a").method)
    assert.equals("POST", curl.parse_curl("curl -XPOST -I https://x.dev/a").method)
    assert.equals("POST", curl.parse_curl("curl --request=POST -I https://x.dev/a").method)
    assert.equals("GET", curl.parse_curl("curl -X GET -I https://x.dev/a").method)
  end)

  it("data flags do not promote a -I HEAD to POST", function()
    local parsed = curl.parse_curl("curl -I -d a=1 https://x.dev/a")
    assert.equals("HEAD", parsed.method)
  end)
end)

describe("curl.parse_curl -u/--user", function()
  it("appends the colon curl sends for a bare user name", function()
    -- -u bob sends Basic base64("bob:") — the imported header used to
    -- authenticate as base64("bob"), a different credential on the wire.
    local parsed = curl.parse_curl("curl -u bob https://x.dev/a")
    local auth
    for _, h in ipairs(parsed.headers) do
      if h[1] == "Authorization" then auth = h[2] end
    end
    assert.equals("Basic " .. vim.base64.encode("bob:"), auth)
  end)

  it("keeps user:pass unchanged", function()
    local parsed = curl.parse_curl("curl -u bob:s3cret https://x.dev/a")
    local auth
    for _, h in ipairs(parsed.headers) do
      if h[1] == "Authorization" then auth = h[2] end
    end
    assert.equals("Basic " .. vim.base64.encode("bob:s3cret"), auth)
  end)
end)

describe("curl.parse_curl header-carrying flags", function()
  it("maps --oauth2-bearer to an Authorization: Bearer header", function()
    -- The token used to win the URL scan instead.
    local parsed = curl.parse_curl("curl --oauth2-bearer tok123 https://x.dev/a")
    assert.equals("https://x.dev/a", parsed.url)
    local auth
    for _, h in ipairs(parsed.headers) do
      if h[1] == "Authorization" then auth = h[2] end
    end
    assert.equals("Bearer tok123", auth)
    parsed = curl.parse_curl("curl --oauth2-bearer=tok123 https://x.dev/a")
    for _, h in ipairs(parsed.headers) do
      if h[1] == "Authorization" then assert.equals("Bearer tok123", h[2]) end
    end
  end)

  it("maps -A/--user-agent and -e/--referer to headers (last wins)", function()
    local parsed = curl.parse_curl(
      "curl -A 'my-agent/1.0' -e https://ref.dev/ --user-agent=ua2 https://x.dev/a")
    local ua, referer
    for _, h in ipairs(parsed.headers) do
      if h[1] == "User-Agent" then ua = h[2] end
      if h[1] == "Referer" then referer = h[2] end
    end
    -- one User-Agent header carrying the LAST value: these flags are
    -- engine-set on the wire (replaced, never repeated like -H)
    assert.equals("ua2", ua)
    assert.equals("https://ref.dev/", referer)
  end)

  it("maps a -b cookie STRING to a Cookie header; a cookie FILE is consumed", function()
    local parsed = curl.parse_curl("curl -b 'sid=42; theme=dark' https://x.dev/a")
    local cookie
    for _, h in ipairs(parsed.headers) do
      if h[1] == "Cookie" then cookie = h[2] end
    end
    assert.equals("sid=42; theme=dark", cookie)
    -- jar-file form: no "=" → nothing mappable, but the URL must still win
    parsed = curl.parse_curl("curl -b /tmp/jar.txt https://x.dev/a")
    assert.equals("https://x.dev/a", parsed.url)
    for _, h in ipairs(parsed.headers) do
      assert.is_not_equal("Cookie", h[1])
    end
  end)
end)
