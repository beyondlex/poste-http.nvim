local function strip(s)
  return s:gsub("^%s+", ""):gsub("%s+$", "")
end

local function find_request_variable_refs(block_text)
  local refs = {}
  for full_ref in block_text:gmatch("{{(.-)}}") do
    if full_ref:match("%.response%.") or full_ref:match("%.request%.") then
      local req_name = full_ref:match("^([^%.]+)%.")
      if req_name then
        table.insert(refs, { full = "{{" .. full_ref .. "}}", request_name = req_name })
      end
    end
  end
  return refs
end

describe("variable ref pattern matching", function()
  describe("{{...}} with } inside content", function()
    it("matches {{jq.response.body}} without special chars", function()
      local line = "GET {{base_url}}/get"
      local a, b, inner = line:find("{{(.-)}}")
      assert.not_nil(a)
      assert.equals("base_url", inner)
    end)

    it("matches {{...}} with single } inside (jq filter)", function()
      local line = [=[<<method [ {{jq.response.body | {name: .[].commit.author.name, email} }} ]]=]
      local a, b, inner = line:find("{{(.-)}}")
      assert.not_nil(a)
      assert.not_nil(inner:match("^jq%.response%.body"),
        "inner should start with jq.response.body, got: " .. tostring(inner))
    end)

    it("matches {{...}} with multiple } inside (nested objects)", function()
      local line = [=[{{jq.response.body | {a: {b: 1}} }}]=]
      local a, b, inner = line:find("{{(.-)}}")
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
      local a, b = line:find("{{(.-)}}")
      assert.not_nil(a, "new pattern (.-) should succeed")
    end)
  end)

  describe("find_request_variable_refs", function()
    it("finds ref with } inside jq expression", function()
      local block_text = [=[<<method [ {{jq.response.body | {name: .[].commit.author.name, email} }} ]]=]
      local refs = find_request_variable_refs(block_text)
      assert.equals(1, #refs)
      assert.equals("jq", refs[1].request_name)
    end)

    it("finds ref with space in request name", function()
      local block_text = "GET {{Get Items.response.body.args.items}}"
      local refs = find_request_variable_refs(block_text)
      assert.equals(1, #refs)
      assert.equals("Get Items", refs[1].request_name)
    end)

    it("finds multiple refs in one block", function()
      local block_text = [=[
{{jq.response.body.committer.name}}
{{Get Items.response.body.args}}
]=]
      local refs = find_request_variable_refs(block_text)
      assert.equals(2, #refs)
      assert.equals("jq", refs[1].request_name)
      assert.equals("Get Items", refs[2].request_name)
    end)

    it("ignores non-request variable refs (no .response. or .request.)", function()
      local block_text = "GET {{base_url}}/get?q={{query}}"
      local refs = find_request_variable_refs(block_text)
      assert.equals(0, #refs)
    end)
  end)

  describe("nav.lua goto_definition req_name extraction", function()
    it("extracts req_name from {{jq.response.body}}", function()
      local line = "{{jq.response.body}}"
      local ref_text = line:match("{{(.-)}}")
      assert.not_nil(ref_text)
      local req_name = strip(ref_text:match("^([^%.]+)%.") or ref_text)
      assert.equals("jq", req_name)
    end)

    it("extracts req_name from {{Get Items.response.body}}", function()
      local line = "{{Get Items.response.body.args.items}}"
      local ref_text = line:match("{{(.-)}}")
      assert.not_nil(ref_text)
      local req_name = strip(ref_text:match("^([^%.]+)%.") or ref_text)
      assert.equals("Get Items", req_name)
    end)

    it("extracts req_name from {{jq}} (no dot, bare ref)", function()
      local line = "{{jq}}"
      local ref_text = line:match("{{(.-)}}")
      assert.not_nil(ref_text)
      local req_name = strip(ref_text:match("^([^%.]+)%.") or ref_text)
      assert.equals("jq", req_name)
    end)
  end)
end)