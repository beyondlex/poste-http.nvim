-- Tests for poste-http.ai.auto_context — focused block + dependency chain
-- rendering (pure seams).

local auto_context = require("poste-http.ai.auto_context")
local blocks = require("poste-http.ai.blocks")

local CONTENT = [[
### Login
POST {{api_base}}/login
Content-Type: application/json

{"user": "alice"}

### Profile
GET {{api_base}}/me
Authorization: Bearer {{Login.response.body.token}}
]]

local function focus_for(block_name)
  local lines = vim.split(CONTENT, "\n", { plain = true })
  local reqs = blocks.list_requests(CONTENT)
  return {
    file = "requests/api.http",
    env = "dev",
    lines = lines,
    blocks = reqs,
    block = block_name and blocks.find_block(reqs, block_name) or nil,
  }
end

describe("ai.auto_context.render", function()
  it("renders the focused block with file and env", function()
    local md = auto_context.render(focus_for("Profile"))
    assert.truthy(md:match("## Request context %(auto%)"))
    assert.truthy(md:match("File `requests/api%.http` env `dev`"))
    assert.truthy(md:match("```http\n### Profile\nGET {{api_base}}/me"))
    -- placeholders stay raw
    assert.truthy(md:match("{{Login%.response%.body%.token}}"))
  end)

  it("includes referenced dependency blocks", function()
    local md = auto_context.render(focus_for("Profile"))
    assert.truthy(md:match("Referenced request `Login`"))
    assert.truthy(md:match("POST {{api_base}}/login"))
  end)

  it("falls back to a request list when nothing is focused", function()
    local md = auto_context.render(focus_for(nil))
    assert.truthy(md:match("Requests in this file:"))
    assert.truthy(md:match("%- Login — POST"))
    assert.truthy(md:match("%- Profile — GET"))
    assert.falsy(md:match("```http"))
  end)

  it("does not include the focused block as its own dependency", function()
    local content = "### A\nGET /a\n{{A.response.body.x}}\n"
    local lines = vim.split(content, "\n", { plain = true })
    local reqs = blocks.list_requests(content)
    local md = auto_context.render({
      file = "x.http", env = "dev", lines = lines, blocks = reqs, block = reqs[1],
    })
    assert.falsy(md:match("Referenced request"))
  end)

  it("caps the number of dependency blocks", function()
    local lines = { "### Target", "GET /t" }
    for i = 1, auto_context._test.MAX_DEPS + 2 do
      table.insert(lines, "{{D" .. i .. ".response.body.x}}")
    end
    for i = 1, auto_context._test.MAX_DEPS + 2 do
      table.insert(lines, "### D" .. i)
      table.insert(lines, "GET /d" .. i)
    end
    local content = table.concat(lines, "\n")
    local reqs = blocks.list_requests(content)
    local md = auto_context.render({
      file = "x.http", env = "dev", lines = lines, blocks = reqs, block = reqs[1],
    })
    local _, count = md:gsub("Referenced request", "")
    assert.equals(auto_context._test.MAX_DEPS, count)
  end)

  it("truncates oversized output", function()
    local big = { "### Big", "GET /big" }
    for i = 1, 600 do
      table.insert(big, string.rep("x", 40))
    end
    local content = table.concat(big, "\n")
    local lines = vim.split(content, "\n", { plain = true })
    local md = auto_context.render({
      file = "x.http", env = "dev", lines = lines,
      blocks = blocks.list_requests(content), block = blocks.list_requests(content)[1],
    })
    assert.truthy(md:match("%(truncated%)"))
    assert.equals(auto_context._test.MAX_CHARS + #"\n… (truncated)", #md)
  end)

  it("truncation never splits a UTF-8 sequence", function()
    local big = { "### 大请求", "GET /big" }
    for _ = 1, 600 do
      table.insert(big, string.rep("汉", 20)) -- 60 bytes of CJK per line
    end
    local content = table.concat(big, "\n")
    local lines = vim.split(content, "\n", { plain = true })
    local md = auto_context.render({
      file = "x.http", env = "dev", lines = lines,
      blocks = blocks.list_requests(content), block = blocks.list_requests(content)[1],
    })
    local head = md:gsub("\n… %(truncated%)$", "")
    assert.equals(head, vim.fn.iconv(head, "utf-8", "utf-8"), "context cut produced invalid UTF-8")
  end)
end)
