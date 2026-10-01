-- Tests for the GraphQL executor (docs/dev/multi-protocol-design.md).
--
-- The executor lowers GRAPHQL blocks to HTTP POST via curl:
-- body = query text, blank line, optional variables JSON; synthesized as
-- {"query": ..., "variables": ...} with Content-Type: application/json.

local graphql = require("poste-http.http.executors.graphql")

describe("graphql.split_body", function()
  it("returns the whole body as query when there is no variables block", function()
    local query, variables = graphql.split_body("query { user { id } }")
    assert.equals("query { user { id } }", query)
    assert.is_nil(variables)
  end)

  it("splits query and variables on the last blank line", function()
    local body = 'query User($id: ID!) {\n  user(id: $id) { name }\n}\n\n{\n  "id": "42"\n}'
    local query, variables = graphql.split_body(body)
    assert.equals("query User($id: ID!) {\n  user(id: $id) { name }\n}", query)
    assert.equals('{\n  "id": "42"\n}', variables)
  end)

  it("keeps a query with internal blank lines intact when the tail is not JSON-shaped", function()
    local body = "query A {\n  user {\n    id\n  }\n\n}\n\nsome trailing text"
    local query, variables = graphql.split_body(body)
    assert.equals(body, query)
    assert.is_nil(variables)
  end)

  it("errors when the tail looks like JSON but does not parse", function()
    local ok, err = graphql.split_body("query { user }\n\n{ not json }")
    assert.is_nil(ok)
    assert.matches("variables", err)
  end)

  it("rejects a JSON array tail — variables must be an object", function()
    -- The GraphQL spec requires `variables` to be a map; passing an array
    -- through only produced a server-side "variables must be an object"
    -- error after the round trip.
    local query, err = graphql.split_body("query { user }\n\n[1,2]")
    assert.is_nil(query)
    assert.matches("must be a JSON object", err)
  end)

  it("trims surrounding blank lines around the query", function()
    local query = graphql.split_body("\n\nquery { user }\n\n")
    assert.equals("query { user }", query)
  end)
end)

describe("graphql.build_request_body", function()
  it("synthesizes query-only JSON", function()
    local json, err = graphql.build_request_body("query { user }")
    assert.is_nil(err)
    local decoded = vim.json.decode(json)
    assert.equals("query { user }", decoded.query)
    assert.is_nil(decoded.variables)
  end)

  it("embeds decoded variables as a table", function()
    local json, err = graphql.build_request_body('query User($id: ID!) { user(id: $id) }\n\n{"id": "42"}')
    assert.is_nil(err)
    local decoded = vim.json.decode(json)
    assert.equals("query User($id: ID!) { user(id: $id) }", decoded.query)
    assert.same({ id = "42" }, decoded.variables)
  end)

  it("returns an error for an empty query", function()
    local json, err = graphql.build_request_body("")
    assert.is_nil(json)
    assert.matches("query is empty", err)
    json, err = graphql.build_request_body("   \n\n  ")
    assert.is_nil(json)
    assert.matches("query is empty", err)
  end)
end)

describe("graphql.run", function()
  local curl_exec = require("poste-http.http.curl_exec")
  local orig_execute
  local captured

  before_each(function()
    orig_execute = curl_exec.execute
    captured = {}
    curl_exec.execute = function(req, cb)
      captured.req = req
      captured.cb = cb
    end
  end)

  after_each(function()
    curl_exec.execute = orig_execute
  end)

  it("forces POST and sets Content-Type application/json", function()
    graphql.run({
      method = "GRAPHQL",
      url = "https://api.example.com/graphql",
      headers = { { "Authorization", "Bearer t" } },
      body = "query { user }",
    }, function() end)

    assert.equals("POST", captured.req.method)
    local content_type
    for _, h in ipairs(captured.req.headers) do
      if h[1]:lower() == "content-type" then content_type = h[2] end
    end
    assert.equals("application/json", content_type)

    local decoded = vim.json.decode(captured.req.body)
    assert.equals("query { user }", decoded.query)
  end)

  it("keeps a user-provided Content-Type", function()
    graphql.run({
      method = "GRAPHQL",
      url = "https://api.example.com/graphql",
      headers = { { "Content-Type", "application/json" } },
      body = "query { user }",
    }, function() end)

    local count = 0
    for _, h in ipairs(captured.req.headers) do
      if h[1]:lower() == "content-type" then count = count + 1 end
    end
    assert.equals(1, count)
  end)

  it("passes the raw body through for Content-Type application/graphql", function()
    graphql.run({
      method = "GRAPHQL",
      url = "https://api.example.com/graphql",
      headers = { { "Content-Type", "application/graphql" } },
      body = "query { user }",
    }, function() end)

    assert.equals("query { user }", captured.req.body)
  end)

  it("reports an error response when the body cannot be lowered", function()
    local response
    graphql.run({
      method = "GRAPHQL",
      url = "https://api.example.com/graphql",
      headers = {},
      body = "query { user }\n\n{ not json }",
    }, function(r) response = r end)

    assert.is_not_nil(response)
    assert.is_false(response.ok)
    assert.equals("error", response.protocol)
    assert.matches("variables", response.body)
    assert.equals("GRAPHQL", response.metadata.method)
  end)

  it("propagates url, buf_dir, timeout and the callback", function()
    local cb = function() end
    graphql.run({
      method = "GRAPHQL",
      url = "https://api.example.com/graphql",
      headers = {},
      body = "query { user }",
      buf_dir = "/tmp/x",
      timeout = 5000,
    }, cb)

    assert.equals("https://api.example.com/graphql", captured.req.url)
    assert.equals("/tmp/x", captured.req.buf_dir)
    assert.equals(5000, captured.req.timeout)
    assert.equals(cb, captured.cb)
  end)
end)
