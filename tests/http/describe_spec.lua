-- Tests for describe_content (tree-sitter block metadata).
--
-- Regression coverage for GRAPHQL blocks: the query text is not a grammar
-- node, so the body must come from the line-based assembly when a
-- json_body node (the variables block) starts after the query text.

local describe_mod = require("poste-http.http.describe")

describe("describe_content body extraction", function()
  it("keeps a plain HTTP JSON body via the json_body node", function()
    local blocks = describe_mod.describe_content([[
### Create user
POST http://api.example.com/users
Content-Type: application/json

{
  "name": "ada"
}
]], "t.http")
    assert.equals(1, #blocks)
    assert.is_truthy(blocks[1].body:find('"name": "ada"'),
      "plain HTTP JSON body must be preserved")
  end)

  it("keeps query text AND variables for a named GRAPHQL block", function()
    local blocks = describe_mod.describe_content([[
### GraphQL: variables
GRAPHQL http://localhost:8890

query User($id: ID!) {
  user(id: $id) { id name email }
}

{
  "id": "2"
}
]], "t.http")
    assert.equals("GRAPHQL", blocks[1].method)
    local body = blocks[1].body
    assert.is_truthy(body:find("query User%($id: ID!%)"),
      "query text must not be dropped from the body")
    assert.is_truthy(body:find('"id": "2"'), "variables block must stay in the body")
  end)

  it("keeps both segments for an anonymous GRAPHQL query with variables", function()
    local blocks = describe_mod.describe_content([[
### GraphQL: anonymous query with variables
GRAPHQL http://localhost:8890

{
  hello
}

{
  "name": "poste"
}
]], "t.http")
    local body = blocks[1].body
    assert.is_truthy(body:find("hello"), "the anonymous query segment must be in the body")
    assert.is_truthy(body:find('"name": "poste"'), "the variables segment must be in the body")
  end)

  it("keeps a mutation as the whole body, with no headers leaked from it", function()
    local blocks = describe_mod.describe_content([[
### GraphQL: mutation
GRAPHQL http://localhost:8890

mutation {
  add(a: 19, b: 23)
}
]], "t.http")
    assert.equals("GRAPHQL", blocks[1].method)
    local body = blocks[1].body
    assert.is_truthy(body:find("mutation"), "mutation keyword must stay in the body")
    assert.is_truthy(body:find("add%(a: 19, b: 23%)"),
      "mutation field must stay in the body")
    assert.equals(0, #blocks[1].headers,
      "mutation text must not be misparsed as request headers")
  end)
end)
