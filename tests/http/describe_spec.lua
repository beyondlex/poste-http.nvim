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

  -- The grammar's json_body token ends at the first BLANK line (`\n[^\n]+`
  -- continuation), so anything after a blank line inside the braces used to be
  -- silently dropped from the request that goes on the wire.
  it("keeps the tail of a JSON body that contains a blank line", function()
    local blocks = describe_mod.describe_content([[
### Blank line inside the object
POST http://api.example.com/users
Content-Type: application/json

{
  "a": 1,

  "b": 2
}
]], "t.http")
    assert.equals('{\n  "a": 1,\n\n  "b": 2\n}', blocks[1].body)
  end)

  it("keeps the tail of an array body that contains a blank line", function()
    local blocks = describe_mod.describe_content([[
### Blank line inside the array
POST http://api.example.com/items
Content-Type: application/json

[
  1,

  2
]
]], "t.http")
    assert.equals("[\n  1,\n\n  2\n]", blocks[1].body)
  end)

  it("keeps the lines after a blank line when a comment sits between them", function()
    local blocks = describe_mod.describe_content([[
### Comment and blank line inside the object
POST http://api.example.com/users

{
  "a": 1,
  // why

  "b": 2
}
]], "t.http")
    local body = blocks[1].body
    assert.is_truthy(body:find('"b": 2', 1, true), "tail field must stay in the body")
  end)

  it("does not swallow a > {% %} assertion written right after the body", function()
    local blocks = describe_mod.describe_content([[
### Assertion without a separating blank line
POST http://api.example.com/users

{
  "a": 1
}
> {%
  client.test("ok", function() {})
%}
]], "t.http")
    assert.equals('{\n  "a": 1\n}', blocks[1].body)
  end)

  it("keeps a < path file include inside the body", function()
    local blocks = describe_mod.describe_content([[
### Body from a file
POST http://api.example.com/users

< ./payload.json
]], "t.http")
    assert.equals("< ./payload.json", blocks[1].body)
  end)

  it("keeps blank lines of a multipart body intact", function()
    local blocks = describe_mod.describe_content([[
### Multipart keeps its blank lines
POST http://api.example.com/upload
Content-Type: multipart/form-data; boundary=----X

------X
Content-Disposition: form-data; name="a"

1
------X--
]], "t.http")
    local body = blocks[1].body
    assert.is_truthy(body:find('name="a"\n\n1', 1, true),
      "the blank line between a part's headers and its value must survive")
  end)
end)
