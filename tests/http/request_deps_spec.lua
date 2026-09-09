local request_deps = require("poste-http.http.request_deps")
local state = require("poste-http.state")

local function resolve_deps(content, block_line)
  local result
  request_deps._resolve_content_dependencies_impl(0, "/tmp/test.http", "dev", content, block_line, function(resolved)
    result = resolved
  end)
  vim.wait(100, function() return result ~= nil end)
  return result
end

local function request_b_block()
  return table.concat({
    "### request_a",
    "GET {{host}}/path/a",
    "",
    "### request_b",
    "POST {{host}}/path/b",
    "Content-Type: application/json",
    "",
    "{",
    '  "clothClassMaskMap": {{request_a.response.body.info.a_json_obj}},',
    '  "sourceImgUrl": "{{request_a.response.body.info.a_string}}"',
    "}",
  }, "\n")
end

describe("request_deps value substitution into body", function()
  after_each(function()
    request_deps.cache_response("request_a", nil)
  end)

  it("substitutes a nested JSON object from a response as inline JSON (not a Lua table)", function()
    request_deps.cache_response("request_a", {
      body = vim.json.encode({ info = { a_json_obj = { foo = "bar", num = 1 }, a_string = "hello world" } }),
    })

    local result = resolve_deps(request_b_block(), 4)
    assert.truthy(result)
    assert.is_falsy(result:match("table: 0x"))
    assert.truthy(result:match("clothClassMaskMap"))
    local obj = result:match('"clothClassMaskMap":%s*(%b{})')
    assert.truthy(obj, "nested JSON object should be inlined into the body")
    local parsed = vim.json.decode(obj)
    assert.equals("bar", parsed.foo)
    assert.equals(1, parsed.num)
  end)

  it("substitutes a nested string from a response", function()
    request_deps.cache_response("request_a", {
      body = vim.json.encode({ info = { a_json_obj = {}, a_string = "hello world" } }),
    })

    local result = resolve_deps(request_b_block(), 4)
    assert.truthy(result)
    assert.truthy(result:match('"sourceImgUrl": "hello world"'))
    assert.is_falsy(result:match("%{%%request_a%.response%."))
  end)

  it("substitutes false (falsy) values instead of leaving the ref untouched", function()
    request_deps.cache_response("request_a", {
      body = vim.json.encode({ info = { a_json_obj = {}, a_string = false } }),
    })

    local result = resolve_deps(request_b_block(), 4)
    assert.truthy(result)
    assert.truthy(result:match('"sourceImgUrl": "false"'))
    assert.is_falsy(result:match("%{%%request_a%.response%."))
  end)
end)

describe("resolve_request_variable with spaced request name", function()
  it("resolves a nested path from a cached response with a spaced request name", function()
    local cache = {
      ["recolor detail"] = {
        body = vim.json.encode({ info = { clothClassImgMap = { tops = "https://img/tops.jpg" } } }),
      },
    }
    local v = request_deps._resolve_request_variable("recolor detail.response.body.info.clothClassImgMap.tops", cache)
    assert.equals("https://img/tops.jpg", v)
  end)

  it("resolves a whole body object ref", function()
    local cache = {
      recolor = {
        body = vim.json.encode({ info = { assetId = "A-1", moderationId = "M-1" } }),
      },
    }
    local v = request_deps._resolve_request_variable("recolor.response.body.info", cache)
    assert.truthy(type(v) == "table" or type(v) == "string")
  end)
end)

describe("resolve_request_variable with dotted request name", function()
  it("resolves a nested path when the request name contains a dot", function()
    local cache = {
      ["order.submit"] = {
        body = vim.json.encode({ id = "ORD-123" }),
      },
    }
    local v = request_deps._resolve_request_variable("order.submit.response.body.id", cache)
    assert.equals("ORD-123", v)
  end)

  it("finds refs when the request name contains a dot", function()
    local refs = request_deps.find_request_variable_refs("{{order.submit.response.body.id}}")
    assert.equals(1, #refs)
    assert.equals("order.submit", refs[1].request_name)
  end)
end)

describe("request_deps dep post-scripts", function()
  before_each(function()
    state.global_vars = {}
  end)

  after_each(function()
    state.global_vars = {}
  end)

  it("runs client.global.set from a dep post-script against the dep response", function()
    local response = {
      status = 200,
      body = vim.json.encode({ info = { assetId = "A-1", moderationId = "M-1" } }),
    }
    local block = table.concat({
      "GET {{host}}/cloth/recolor",
      '> {% client.global.set("assetId", response.body.info.assetId) %}',
      '> {% client.global.set("moderationId", response.body.info.moderationId) %}',
    }, "\n")
    request_deps.run_dep_post_scripts(response, block)
    assert.equal("A-1", state.global_vars.assetId)
    assert.equal("M-1", state.global_vars.moderationId)
  end)

  it("leaves globals untouched when a dep has no post-script", function()
    local response = { status = 200, body = "{}" }
    request_deps.run_dep_post_scripts(response, "GET /plain")
    assert.same({}, state.global_vars)
  end)

  it("exposes block-local vars to the dep post-script", function()
    local response = {
      status = 200,
      body = vim.json.encode({ ok = true }),
    }
    local block = table.concat({
      "@base_url = https://api.example.com",
      "GET {{base_url}}/cloth/recolor",
      '> {% client.global.set("derived", variables.base_url .. "/x") %}',
    }, "\n")
    request_deps.run_dep_post_scripts(response, block)
    assert.equal("https://api.example.com/x", state.global_vars.derived)
  end)
end)

describe("request_deps execute_dependent_request_async", function()
  local orig_execute
  local orig_describe

  before_each(function()
    local curl_exec = require("poste-http.http.curl_exec")
    local describe = require("poste-http.http.describe")
    orig_execute = curl_exec.execute
    orig_describe = describe.describe_content
    curl_exec.execute = function(_, callback)
      vim.schedule(function()
        callback({ status = 200, status_text = "200 OK", body = "ok", headers = {}, metadata = { method = "GET" } })
      end)
    end
    describe.describe_content = function()
      return { { method = "GET", path = "https://example.com/x", headers = {}, body = "" } }
    end
    request_deps.cache_response("dep_a", nil)
  end)

  after_each(function()
    local curl_exec = require("poste-http.http.curl_exec")
    local describe = require("poste-http.http.describe")
    if orig_execute then curl_exec.execute = orig_execute end
    if orig_describe then describe.describe_content = orig_describe end
    request_deps.cache_response("dep_a", nil)
  end)

  it("records request timestamp metadata on the cached dependency response", function()
    local got
    request_deps.execute_dependent_request_async(0, "/tmp/test.http", "dev", { name = "dep_a", start_line = 1, end_line = 1 }, "GET https://example.com/x", function(response)
      got = response
    end)
    vim.wait(100, function() return got ~= nil end)
    assert.truthy(got)
    assert.truthy(got.metadata.timestamp, "dependency response should carry metadata.timestamp")
    assert.matches("^%d%d%d%d%-%d%d%-%d%d ", got.metadata.timestamp)
    assert.truthy(request_deps.is_response_cached("dep_a"))
  end)
end)

describe("request_deps file-level @var referencing a response", function()
  after_each(function()
    request_deps.cache_response("request_a", nil)
  end)

  local function file_vars_content()
    return table.concat({
      "@assetId = {{request_a.response.body.info.assetId}}",
      "@moderationId = {{request_a.response.body.info.moderationId}}",
      "",
      "### request_a",
      "GET {{host}}/path/a",
      "",
      "### request_b",
      "POST {{host}}/path/b",
      "Content-Type: application/json",
      "",
      "{",
      '  "merchantAssertLibraryId": {{assetId}},',
      '  "colorPickImgModificationId": {{moderationId}}',
      "}",
    }, "\n")
  end

  it("substitutes request refs in file-level @var lines", function()
    request_deps.cache_response("request_a", {
      body = vim.json.encode({ info = { assetId = "A-1", moderationId = "M-1" } }),
    })

    local result = resolve_deps(file_vars_content(), 7)
    assert.truthy(result)
    assert.truthy(result:match("@assetId = A%-1"))
    assert.truthy(result:match("@moderationId = M%-1"))
    assert.is_falsy(result:match("@assetId = %{%%request_a%.response%."))
  end)

  it("makes {{assetId}} in the body resolve from the substituted file-level @var", function()
    request_deps.cache_response("request_a", {
      body = vim.json.encode({ info = { assetId = "A-1", moderationId = "M-1" } }),
    })

    local resolved = resolve_deps(file_vars_content(), 7)
    local resolver = require("poste-http.http.vars").build_resolver_from_state({
      lines = vim.split(resolved, "\n", { plain = true }),
      file_path = "/tmp/test.http",
      env_name = "dev",
    })
    local body = resolver:substitute(table.concat({
      "{",
      '  "merchantAssertLibraryId": {{assetId}},',
      '  "colorPickImgModificationId": {{moderationId}}',
      "}",
    }, "\n"))
    assert.truthy(body:match('"merchantAssertLibraryId": A%-1'))
    assert.truthy(body:match('"colorPickImgModificationId": M%-1'))
    assert.is_falsy(body:match("%{%%assetId%%}"))
  end)
end)

describe("request_deps substitution with % in the value", function()
  after_each(function()
    request_deps.cache_response("request_a", nil)
  end)

  -- Same shape as the file-level @var fixture above, re-declared here
  -- because that one is local to its describe block.
  local function file_vars_content()
    return table.concat({
      "@assetId = {{request_a.response.body.info.assetId}}",
      "@moderationId = {{request_a.response.body.info.moderationId}}",
      "",
      "### request_a",
      "GET {{host}}/path/a",
      "",
      "### request_b",
      "POST {{host}}/path/b",
      "Content-Type: application/json",
      "",
      "{",
      '  "merchantAssertLibraryId": {{assetId}},',
      '  "colorPickImgModificationId": {{moderationId}}',
      "}",
    }, "\n")
  end

  it("substitutes a response value containing % into the body verbatim", function()
    -- A string replacement would read the % as a capture reference and
    -- raise "invalid use of '%' in replacement string" (or mangle it).
    request_deps.cache_response("request_a", {
      body = vim.json.encode({ info = { a_json_obj = {}, a_string = "100% done %1 tok%2Fen" } }),
    })

    local result = resolve_deps(request_b_block(), 4)
    assert.truthy(result)
    assert.truthy(result:match('"sourceImgUrl": "100%% done %%1 tok%%2Fen"'),
      "percent signs must survive substitution verbatim")
  end)

  it("substitutes a response value containing % into a file-level @var verbatim", function()
    request_deps.cache_response("request_a", {
      body = vim.json.encode({ info = { assetId = "A%2F1", moderationId = "M%1" } }),
    })

    local result = resolve_deps(file_vars_content(), 7)
    assert.truthy(result)
    assert.truthy(result:match("@assetId = A%%2F1"))
    assert.truthy(result:match("@moderationId = M%%1"))
  end)
end)
