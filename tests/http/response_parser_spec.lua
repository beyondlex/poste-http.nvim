local parser = require("poste-http.http.response_parser")

describe("parse_headers_file", function()
  local parse = parser.parse_headers_file

  it("parses headers with LF line endings", function()
    local text = "HTTP/1.1 200 OK\nContent-Type: application/json\nContent-Length: 42\n"
    local r = parse(text)
    assert.equals(200, r.status)
    assert.equals("200 OK", r.status_text)
    assert.equals(2, #r.headers)
    assert.equals("Content-Type", r.headers[1][1])
    assert.equals("application/json", r.headers[1][2])
    assert.equals("Content-Length", r.headers[2][1])
    assert.equals("42", r.headers[2][2])
    assert.equals("application/json", r.content_type)
  end)

  it("parses headers with CRLF line endings", function()
    local text = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 42\r\n"
    local r = parse(text)
    assert.equals(200, r.status)
    assert.equals(2, #r.headers)
    assert.equals("Content-Type", r.headers[1][1])
  end)

  it("parses headers with trailing CR at end of file", function()
    local text = "HTTP/1.1 200 OK\nContent-Length: 546\nConnection: keep-alive\nContent-Type: application/json\nServer: uvicorn\r"
    local r = parse(text)
    assert.equals(200, r.status)
    assert.equals(4, #r.headers)
    assert.equals("Server", r.headers[4][1])
    assert.equals("uvicorn", r.headers[4][2])
  end)

  it("takes the last block when multiple responses (redirects)", function()
    local text = "HTTP/1.1 301 Moved\r\nLocation: /new\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
    local r = parse(text)
    assert.equals(200, r.status)
    assert.equals("200 OK", r.status_text)
    assert.equals(1, #r.headers)
    assert.equals("Content-Type", r.headers[1][1])
  end)

  it("returns status 0 for empty input (no response)", function()
    local r = parse("")
    assert.equals(0, r.status)
    assert.equals("No Response", r.status_text)
    assert.equals(0, #r.headers)
  end)

  it("returns status 0 for nil input (no response)", function()
    local r = parse(nil)
    assert.equals(0, r.status)
    assert.equals(0, #r.headers)
  end)

  it("handles mixed CRLF and LF in blocks", function()
    local text = "HTTP/1.1 200 OK\nContent-Type: text/plain\n\n"
    local r = parse(text)
    assert.equals(200, r.status)
    assert.equals(1, #r.headers)
    assert.equals("text/plain", r.content_type)
  end)

  it("extracts content-type case-insensitively", function()
    local text = "HTTP/1.1 200 OK\ncontent-type: application/json\n"
    local r = parse(text)
    assert.equals("application/json", r.content_type)
  end)

  it("handles status reason phrases", function()
    local text = "HTTP/1.1 404 Not Found\nContent-Type: text/plain\n"
    local r = parse(text)
    assert.equals(404, r.status)
    assert.equals("404 Not Found", r.status_text)
  end)

  it("fills in the reason phrase when the status line omits it (HTTP/2)", function()
    local text = "HTTP/2 200\nContent-Type: application/json\n"
    local r = parse(text)
    assert.equals(200, r.status)
    assert.equals("200 OK", r.status_text)
  end)

  it("maps unknown codes via reason table when status line omits reason", function()
    local text = "HTTP/2 503\nContent-Type: text/plain\n"
    local r = parse(text)
    assert.equals(503, r.status)
    assert.equals("503 Service Unavailable", r.status_text)
  end)
end)

describe("parse_error", function()
  it("returns status 0 for error responses", function()
    local r = parser.parse_error(nil, {}, {}, nil, "GET", 7, nil)
    assert.equals(0, r.status)
    assert.equals("error", r.protocol)
    assert.equals("Failed (exit 7)", r.status_text)
    assert.equals("GET", r.metadata.method)
    assert.equals("7", r.metadata.exit_code)
  end)

  it("uses stderr as body when stdout is empty", function()
    local r = parser.parse_error(nil, {}, {"Connection refused"}, nil, "GET", 7, nil)
    assert.equals(0, r.status)
    assert.equals("Connection refused", r.body)
    assert.equals("Connection refused", r.metadata.error)
  end)

  it("falls back to text/plain when no headers arrived", function()
    -- parse_headers_file returns content_type = "" (not nil) when no
    -- headers arrived; the previous `or` fallback never fired.
    local r = parser.parse_error(nil, {}, {}, nil, "GET", 7, nil)
    assert.equals("text/plain", r.content_type)
  end)
end)

describe("parse_response redirect_count", function()
  local function write_count_file(content)
    local path = vim.fn.tempname() .. "_redirects"
    local fd = io.open(path, "w")
    fd:write(content)
    fd:close()
    return path
  end

  it("prefers the curl --write-out num_redirects file over the verbose grep", function()
    local f = write_count_file("2\n")
    local r = parser.parse_response(nil, {}, {
      "< HTTP/1.1 200 OK",
    }, nil, "GET", "https://x", nil, f)
    os.remove(f)
    assert.equals("2", r.metadata.redirect_count)
  end)

  it("falls back to the verbose grep when no usable count file exists", function()
    -- no file at all
    local r = parser.parse_response(nil, {}, {
      "* example 3 redirects logged here",
      "< HTTP/1.1 200 OK",
    }, nil, "GET", "https://x", nil, nil)
    assert.equals("3", r.metadata.redirect_count)

    -- a path that cannot be opened
    local r2 = parser.parse_response(nil, {}, { "< HTTP/1.1 200 OK" },
      nil, "GET", "https://x", nil, "/nonexistent/poste_redirects")
    assert.equals("0", r2.metadata.redirect_count)

    -- old curl writes an unknown write-out variable literally
    local junk = write_count_file("%{num_redirects}")
    local r3 = parser.parse_response(nil, {}, { "< HTTP/1.1 200 OK" },
      nil, "GET", "https://x", nil, junk)
    os.remove(junk)
    assert.equals("0", r3.metadata.redirect_count)
  end)
end)

describe("parse_response effective URL", function()
  it("uses the last Location header as the final URL across a redirect chain", function()
    -- curl -v logs one "< Location:" line per followed hop; the final URL is
    -- the target of the LAST redirect, not the first.
    local r = parser.parse_response(nil, {}, {
      "< HTTP/1.1 301 Moved Permanently",
      "< Location: https://example.com/first-hop",
      "< HTTP/1.1 302 Found",
      "< Location: https://example.com/final",
      "< HTTP/1.1 200 OK",
    }, nil, "GET", "https://example.com/start", nil)
    assert.equals("https://example.com/final", r.url)
  end)

  it("falls back to the request URL when verbose has no Location header", function()
    local r = parser.parse_response(nil, {}, {
      "< HTTP/1.1 200 OK",
      "< Content-Type: text/plain",
    }, nil, "GET", "https://example.com/start", nil)
    assert.equals("https://example.com/start", r.url)
  end)

  it("ignores relative Location headers (keeps the request URL)", function()
    -- A relative Location can't be resolved without replaying each hop's
    -- base URL; a bare `/path` used to replace the request URL verbatim.
    local r = parser.parse_response(nil, {}, {
      "< HTTP/1.1 302 Found",
      "< Location: /final",
      "< HTTP/1.1 200 OK",
    }, nil, "GET", "https://example.com/start", nil)
    assert.equals("https://example.com/start", r.url)
  end)
end)

describe("parse_response cookies", function()
  local function write_headers_file(text)
    local path = vim.fn.tempname() .. "_headers"
    local fd = io.open(path, "w")
    fd:write(text)
    fd:close()
    return path
  end

  it("keeps a Set-Cookie header with an empty value (cookie clearing)", function()
    local f = write_headers_file("HTTP/1.1 200 OK\nSet-Cookie: sid=; Path=/\nSet-Cookie: theme=dark\n\n")
    local r = parser.parse_response(f, {}, {}, nil, "GET", "https://x", nil)
    os.remove(f)
    assert.equals(2, #r.cookies)
    assert.equals("sid", r.cookies[1].name)
    assert.equals("", r.cookies[1].value)
    assert.equals("/", r.cookies[1].path)
    assert.equals("theme", r.cookies[2].name)
    assert.equals("dark", r.cookies[2].value)
  end)

  it("collects Set-Cookie headers from intermediate redirect hops", function()
    -- curl -D dumps one header block per followed hop; only the last block
    -- is the final response, but a cookie set by a 3xx hop still applies.
    local f = write_headers_file(
      "HTTP/1.1 302 Found\nLocation: /final\nSet-Cookie: hop=intermediate\n\n" ..
      "HTTP/1.1 200 OK\nSet-Cookie: final=done\n\n")
    local r = parser.parse_response(f, {}, {}, nil, "GET", "https://x", nil)
    os.remove(f)
    assert.equals(200, r.status, "final response still comes from the last block")
    assert.equals(2, #r.cookies)
    assert.equals("hop", r.cookies[1].name)
    assert.equals("intermediate", r.cookies[1].value)
    assert.equals("final", r.cookies[2].name)
    assert.equals("done", r.cookies[2].value)
  end)

  it("lets a later hop override a Set-Cookie with the same name", function()
    local f = write_headers_file(
      "HTTP/1.1 302 Found\nSet-Cookie: sid=old\n\n" ..
      "HTTP/1.1 200 OK\nSet-Cookie: sid=new\n\n")
    local r = parser.parse_response(f, {}, {}, nil, "GET", "https://x", nil)
    os.remove(f)
    assert.equals(1, #r.cookies)
    assert.equals("sid", r.cookies[1].name)
    assert.equals("new", r.cookies[1].value)
  end)
end)