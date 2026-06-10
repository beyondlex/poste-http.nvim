--- Tests for DX completion enhancements:
--- - Expanded HTTP headers
--- - Expanded MIME types
--- - Auth scheme completion
--- - Cookie completion
--- - HTTP status code completion in assertions

local completion = require("poste.http.completion")
local test = completion._test

describe("expanded HTTP headers", function()
  it("includes security headers", function()
    local security_headers = {
      "Content-Security-Policy",
      "Strict-Transport-Security",
      "X-Content-Type-Options",
      "X-Frame-Options",
      "Referrer-Policy",
      "Permissions-Policy",
    }
    for _, h in ipairs(security_headers) do
      local found = false
      for _, name in ipairs(test.header_names) do
        if name == h then found = true; break end
      end
      assert.truthy(found, "Missing header: " .. h)
    end
  end)

  it("includes CORS request headers", function()
    local cors_headers = {
      "Access-Control-Request-Headers",
      "Access-Control-Request-Method",
    }
    for _, h in ipairs(cors_headers) do
      local found = false
      for _, name in ipairs(test.header_names) do
        if name == h then found = true; break end
      end
      assert.truthy(found, "Missing CORS header: " .. h)
    end
  end)

  it("includes proxy/CDN headers", function()
    local proxy_headers = {
      "Forwarded",
      "CF-Connecting-IP",
      "CF-Ray",
      "X-Forwarded-For",
      "X-Real-IP",
    }
    for _, h in ipairs(proxy_headers) do
      local found = false
      for _, name in ipairs(test.header_names) do
        if name == h then found = true; break end
      end
      assert.truthy(found, "Missing proxy header: " .. h)
    end
  end)

  it("includes gRPC headers", function()
    local grpc_headers = { "Grpc-Status", "Grpc-Message", "Grpc-Encoding" }
    for _, h in ipairs(grpc_headers) do
      local found = false
      for _, name in ipairs(test.header_names) do
        if name == h then found = true; break end
      end
      assert.truthy(found, "Missing gRPC header: " .. h)
    end
  end)

  it("includes auth token headers", function()
    local auth_headers = { "X-API-Key", "X-Auth-Token", "X-CSRF-Token" }
    for _, h in ipairs(auth_headers) do
      local found = false
      for _, name in ipairs(test.header_names) do
        if name == h then found = true; break end
      end
      assert.truthy(found, "Missing auth header: " .. h)
    end
  end)
end)

describe("expanded MIME types", function()
  it("includes JSON variants", function()
    local json_types = {
      "application/hal+json",
      "application/geo+json",
      "application/problem+json",
      "application/merge-patch+json",
    }
    for _, mt in ipairs(json_types) do
      local found = false
      for _, mime in ipairs(test.mime_types) do
        if mime == mt then found = true; break end
      end
      assert.truthy(found, "Missing MIME type: " .. mt)
    end
  end)

  it("includes text/event-stream for SSE", function()
    local found = false
    for _, mime in ipairs(test.mime_types) do
      if mime == "text/event-stream" then found = true; break end
    end
    assert.truthy(found)
  end)

  it("includes font types", function()
    local font_types = { "font/woff", "font/woff2", "font/ttf" }
    for _, ft in ipairs(font_types) do
      local found = false
      for _, mime in ipairs(test.mime_types) do
        if mime == ft then found = true; break end
      end
      assert.truthy(found, "Missing font MIME: " .. ft)
    end
  end)

  it("includes modern image types", function()
    local image_types = { "image/avif", "image/webp" }
    for _, it in ipairs(image_types) do
      local found = false
      for _, mime in ipairs(test.mime_types) do
        if mime == it then found = true; break end
      end
      assert.truthy(found, "Missing image MIME: " .. it)
    end
  end)
end)

describe("auth scheme completion", function()
  it("Authorization header has expanded schemes", function()
    local auth_values = test.header_values["authorization"]
    assert.truthy(auth_values)

    local schemes = { "Bearer ", "Basic ", "Digest ", "Negotiate ", "Hawk " }
    for _, scheme in ipairs(schemes) do
      local found = false
      for _, v in ipairs(auth_values) do
        if v == scheme then found = true; break end
      end
      assert.truthy(found, "Missing auth scheme: " .. scheme)
    end
  end)

  it("Proxy-Authorization has auth schemes", function()
    local proxy_auth = test.header_values["proxy-authorization"]
    assert.truthy(proxy_auth)

    local found_basic = false
    for _, v in ipairs(proxy_auth) do
      if v == "Basic " then found_basic = true; break end
    end
    assert.truthy(found_basic)
  end)
end)

describe("cookie completion", function()
  it("Cookie header provides common cookie name templates", function()
    local cookie_values = test.header_values["cookie"]
    assert.truthy(cookie_values)

    local templates = { "session_id=", "token=", "auth=", "csrf_token=" }
    for _, t in ipairs(templates) do
      local found = false
      for _, v in ipairs(cookie_values) do
        if v == t then found = true; break end
      end
      assert.truthy(found, "Missing cookie template: " .. t)
    end
  end)

  it("Set-Cookie header provides attribute templates", function()
    local set_cookie = test.header_values["set-cookie"]
    assert.truthy(set_cookie)
    assert.truthy(#set_cookie > 0)

    -- At least one should contain HttpOnly
    local has_httponly = false
    for _, v in ipairs(set_cookie) do
      if v:find("HttpOnly") then has_httponly = true; break end
    end
    assert.truthy(has_httponly)
  end)
end)

describe("HTTP status code completion in assertions", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("returns status_code context for response.status == pattern", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  client.test(\"check\", function()",
      "    client.assert(response.status == ",
      "  end)",
      "%}",
    })
    local ctx, _ = test.detect_context(
      "    client.assert(response.status == ", buf, 4, 36
    )
    assert.equals("status_code", ctx)
  end)

  it("returns status_code context for ~= operator", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  response.status ~= ",
      "%}",
    })
    local ctx, _ = test.detect_context(
      "  response.status ~= ", buf, 3, 21
    )
    assert.equals("status_code", ctx)
  end)

  it("returns status_code context for > comparison", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  response.status > ",
      "%}",
    })
    local ctx, _ = test.detect_context(
      "  response.status > ", buf, 3, 20
    )
    assert.equals("status_code", ctx)
  end)

  it("returns post_script when no status comparison", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  client.test(\"x\",",
      "%}",
    })
    local ctx, _ = test.detect_context(
      "  client.test(\"x\",", buf, 3, 18
    )
    assert.equals("post_script", ctx)
  end)

  it("returns status code items with descriptions", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  response.status == ",
      "%}",
    })
    local items = test.get_items_for_context(
      "  response.status == ", buf, 3, 21
    )
    assert.truthy(#items > 50, "Should have many status codes")

    -- Check 200 OK is present
    local found_200 = false
    local found_404 = false
    for _, item in ipairs(items) do
      if item.label == "200" and item.detail == "OK" then found_200 = true end
      if item.label == "404" and item.detail == "Not Found" then found_404 = true end
    end
    assert.truthy(found_200, "Should contain 200 OK")
    assert.truthy(found_404, "Should contain 404 Not Found")
  end)

  it("status code items have correct structure", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  response.status == ",
      "%}",
    })
    local items = test.get_items_for_context(
      "  response.status == ", buf, 3, 21
    )

    for _, item in ipairs(items) do
      assert.truthy(item.label)
      assert.truthy(item.kind)
      assert.truthy(item.insertText)
      assert.truthy(item.detail)
      -- label should be a 3-digit number
      assert.truthy(item.label:match("^%d%d%d$"), "Invalid status code: " .. item.label)
    end
  end)

  it("includes all 1xx/2xx/3xx/4xx/5xx classes", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "GET /api/users",
      "> {%",
      "  response.status == ",
      "%}",
    })
    local items = test.get_items_for_context(
      "  response.status == ", buf, 3, 21
    )

    local classes = { ["1"] = false, ["2"] = false, ["3"] = false, ["4"] = false, ["5"] = false }
    for _, item in ipairs(items) do
      local first = item.label:sub(1, 1)
      classes[first] = true
    end

    for class, found in pairs(classes) do
      assert.truthy(found, "Missing " .. class .. "xx status codes")
    end
  end)
end)

describe("security header value completion", function()
  it("X-Frame-Options provides common values", function()
    local values = test.header_values["x-frame-options"]
    assert.truthy(values)
    local found_deny = false
    local found_same = false
    for _, v in ipairs(values) do
      if v == "DENY" then found_deny = true end
      if v == "SAMEORIGIN" then found_same = true end
    end
    assert.truthy(found_deny)
    assert.truthy(found_same)
  end)

  it("Referrer-Policy provides common values", function()
    local values = test.header_values["referrer-policy"]
    assert.truthy(values)
    local found = false
    for _, v in ipairs(values) do
      if v == "strict-origin-when-cross-origin" then found = true; break end
    end
    assert.truthy(found)
  end)

  it("Strict-Transport-Security provides max-age templates", function()
    local values = test.header_values["strict-transport-security"]
    assert.truthy(values)
    assert.truthy(#values >= 2, "Should have multiple HSTS templates")
  end)
end)
