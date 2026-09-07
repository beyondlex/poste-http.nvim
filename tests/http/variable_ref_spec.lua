local request_deps = require("poste-http.http.request_deps")

describe("variable ref pattern matching", function()
  describe("{{...}} with } inside content", function()
    it("matches {{jq.response.body}} without special chars", function()
      local line = "GET {{base_url}}/get"
      local a, _, inner = line:find("{{(.-)}}")
      assert.not_nil(a)
      assert.equals("base_url", inner)
    end)

    it("matches {{...}} with single } inside (jq filter)", function()
      local line = [=[<<method [ {{jq.response.body | {name: .[].commit.author.name, email} }} ]]=]
      local a, _, inner = line:find("{{(.-)}}")
      assert.not_nil(a)
      assert.not_nil(inner:match("^jq%.response%.body"),
        "inner should start with jq.response.body, got: " .. tostring(inner))
    end)

    it("matches {{...}} with multiple } inside (nested objects)", function()
      local line = [=[{{jq.response.body | {a: {b: 1}} }}]=]
      local a, _, inner = line:find("{{(.-)}}")
      assert.not_nil(a)
      assert.not_nil(inner:match("^jq%.response%.body"),
        "inner should start with jq.response.body, got: " .. tostring(inner))
    end)
  end)

  describe("first_comp extraction (request name before .)", function()
    it("extracts simple name: jq.response.body", function()
      local inner = "jq.response.body"
      local first_comp = inner:match("^%s*([^%.]+)")
      assert.equals("jq", first_comp)
    end)

    it("extracts name with space: Get Items.response.body", function()
      local inner = "Get Items.response.body.args.items"
      local first_comp = inner:match("^%s*([^%.]+)")
      assert.equals("Get Items", first_comp)
    end)

    it("extracts plain var without dot: base_url", function()
      local inner = "base_url"
      local first_comp = inner:match("^%s*([^%.]+)")
      assert.equals("base_url", first_comp)
    end)

    it("extracts name with underscore: prompt_enhance.response.body", function()
      local inner = "prompt_enhance.response.body.url"
      local first_comp = inner:match("^%s*([^%.]+)")
      assert.equals("prompt_enhance", first_comp)
    end)
  end)

  describe("before: [^}]+ would fail on } inside", function()
    it("old pattern [^}]+ fails on single } inside", function()
      local line = [=[{{jq.response.body | {name: email} }}]=]
      local a = line:find("{{[^}]+}}")
      assert.is_nil(a, "old pattern [^}]+ should fail on } inside")
    end)

    it("new pattern (.-) succeeds on same input", function()
      local line = [=[{{jq.response.body | {name: email} }}]=]
      local a, _ = line:find("{{(.-)}}")
      assert.not_nil(a, "new pattern (.-) should succeed")
    end)
  end)

  describe("find_request_variable_refs (real module)", function()
    it("finds ref with } inside jq expression", function()
      local block_text = [=[<<method [ {{jq.response.body | {name: .[].commit.author.name, email} }} ]]=]
      local refs = request_deps.find_request_variable_refs(block_text)
      assert.equals(1, #refs)
      assert.equals("jq", refs[1].request_name)
    end)

    it("finds ref with space in request name", function()
      local block_text = "GET {{Get Items.response.body.args.items}}"
      local refs = request_deps.find_request_variable_refs(block_text)
      assert.equals(1, #refs)
      assert.equals("Get Items", refs[1].request_name)
    end)

    it("finds multiple refs in one block", function()
      local block_text = [=[
{{jq.response.body.committer.name}}
{{Get Items.response.body.args}}
]=]
      local refs = request_deps.find_request_variable_refs(block_text)
      assert.equals(2, #refs)
      assert.equals("jq", refs[1].request_name)
      assert.equals("Get Items", refs[2].request_name)
    end)

    it("ignores non-request variable refs (no .response. or .request.)", function()
      local block_text = "GET {{base_url}}/get?q={{query}}"
      local refs = request_deps.find_request_variable_refs(block_text)
      assert.equals(0, #refs)
    end)

    it("normalizes {{Name.res.body.X}} to .response.", function()
      local block_text = "GET {{jq.res.body.args.items}}"
      local refs = request_deps.find_request_variable_refs(block_text)
      assert.equals(1, #refs)
      assert.equals("jq", refs[1].request_name)
    end)
  end)

  describe("request_deps req_name extraction", function()
    it("extracts req_name from {{jq.response.body}}", function()
      local refs = request_deps.find_request_variable_refs("{{jq.response.body}}")
      assert.equals(1, #refs)
      assert.equals("jq", refs[1].request_name)
    end)

    it("extracts req_name from {{Get Items.response.body}}", function()
      local refs = request_deps.find_request_variable_refs("{{Get Items.response.body.args.items}}")
      assert.equals(1, #refs)
      assert.equals("Get Items", refs[1].request_name)
    end)

    it("extracts req_name from {{jq}} (no dot, bare ref)", function()
      local refs = request_deps.find_request_variable_refs("{{jq}}")
      assert.equals(0, #refs)
    end)
  end)
end)