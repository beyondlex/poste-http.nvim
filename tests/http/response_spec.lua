-- Tests for the canonical response helpers shared by all protocol executors.
--
-- `ok` is the protocol-aware success flag on the canonical response shape
-- (docs/dev/multi-protocol-design.md): HTTP stamps 0 < status < 400, gRPC
-- stamps status == 0 (codes 1-16 are errors), WebSocket stamps a normal
-- close code.

local response_mod = require("poste-http.http.response")
local parser = require("poste-http.http.response_parser")

describe("response.is_error", function()
  it("returns true for nil response", function()
    assert.is_true(response_mod.is_error(nil))
  end)

  it("prefers the stamped ok flag over the HTTP status rule", function()
    -- gRPC UNAVAILABLE (status 14): below 400 but still an error.
    assert.is_true(response_mod.is_error({ ok = false, status = 14, protocol = "grpc" }))
    -- WebSocket normal close (1000): above 399 but still OK.
    assert.is_false(response_mod.is_error({ ok = true, status = 1000, protocol = "websocket" }))
  end)

  it("returns true for ok=false and false for ok=true", function()
    assert.is_true(response_mod.is_error({ ok = false, status = 500 }))
    assert.is_false(response_mod.is_error({ ok = true, status = 200 }))
  end)

  it("falls back to status >= 400 for legacy responses without ok", function()
    assert.is_false(response_mod.is_error({ status = 200 }))
    assert.is_false(response_mod.is_error({ status = 302 }))
    assert.is_true(response_mod.is_error({ status = 404 }))
    assert.is_true(response_mod.is_error({ status = 500 }))
  end)

  it("keeps the historical success verdict for legacy status 0", function()
    -- Legacy failure stubs like { status = 0, status_text = "Failed" }
    -- (import.lua) were never routed through the error branch, so the
    -- fallback must keep calling them non-errors.
    assert.is_false(response_mod.is_error({ status = 0, status_text = "Failed" }))
  end)

  it("treats protocol='error' as an error in the fallback", function()
    assert.is_true(response_mod.is_error({ protocol = "error", status = 0 }))
  end)
end)

describe("response ok stamping", function()
  local function write_headers_file(text)
    local path = vim.fn.tempname() .. "_headers"
    local fd = io.open(path, "w")
    fd:write(text)
    fd:close()
    return path
  end

  it("parse_response stamps ok=true for 2xx", function()
    local f = write_headers_file("HTTP/1.1 200 OK\nContent-Type: application/json\n\n")
    local r = parser.parse_response(f, {}, {}, nil, "GET", "https://x", nil)
    os.remove(f)
    assert.equals(200, r.status)
    assert.is_true(r.ok)
  end)

  it("parse_response stamps ok=false for 4xx/5xx", function()
    local f = write_headers_file("HTTP/1.1 404 Not Found\n\n")
    local r = parser.parse_response(f, {}, {}, nil, "GET", "https://x", nil)
    os.remove(f)
    assert.equals(404, r.status)
    assert.is_false(r.ok)
  end)

  it("parse_response stamps ok=false for status 0 (no response)", function()
    -- Exit-0-with-no-headers is not a success: the historical
    -- `status < 400` stamp called it ok. The is_error fallback for
    -- UNSTAMPED legacy stubs (import.lua failure shapes) is unchanged.
    local f = write_headers_file("")
    local r = parser.parse_response(f, {}, {}, nil, "GET", "https://x", nil)
    os.remove(f)
    assert.equals(0, r.status)
    assert.is_false(r.ok)
    assert.is_true(response_mod.is_error(r))
  end)

  it("parse_error stamps ok=false", function()
    local r = parser.parse_error(nil, {}, { "Connection refused" }, nil, "GET", 7, nil)
    assert.equals("error", r.protocol)
    assert.is_false(r.ok)
    assert.is_true(response_mod.is_error(r))
  end)
end)

describe("response.error_response", function()
  it("builds the shared canonical error shape for protocol executors", function()
    local r = response_mod.error_response({
      url = "localhost:50051/pkg.Svc/Method",
      headers = { { "X-Trace-Id", "t" } },
    }, "GRPC", "grpcurl not found")
    assert.equals("error", r.protocol)
    assert.equals(0, r.status)
    assert.is_false(r.ok)
    assert.equals("grpcurl not found", r.body)
    assert.equals("grpcurl not found", r.status_text)
    assert.equals("GRPC", r.metadata.method)
    assert.equals("grpcurl not found", r.metadata.error)
    assert.equals("GRPC localhost:50051/pkg.Svc/Method", r.metadata.request_line)
    assert.same({ { "X-Trace-Id", "t" } }, r.headers)
    -- The pre-request shape callers route on must hold.
    assert.is_true(response_mod.is_error(r))
  end)

  it("tolerates a request without url or headers", function()
    local r = response_mod.error_response({}, "WEBSOCKET", "boom")
    assert.equals("WEBSOCKET", r.metadata.method)
    assert.equals("WEBSOCKET ", r.metadata.request_line)
    assert.is_false(r.ok)
  end)
end)
