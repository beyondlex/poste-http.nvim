-- Tests for poste-http.ai.blocks — pure `.http` block helpers used by the
-- AI integration (mentions, auto_context, ask prefill).

local blocks = require("poste-http.ai.blocks")

local CONTENT = [[
### Get users
GET {{api_base}}/users
Authorization: Bearer {{api_token}}

### Login
# Login and stash a token
POST {{api_base}}/login
Content-Type: application/json

{"user": "alice", "pass": "secret"}

> {%
  client.test("ok", function() assert(response.status == 200) end)
%}

### Profile
GET {{api_base}}/me
{{Login.response.body.token}}
]]

---------------------------------------------------------------------------
-- list_requests
---------------------------------------------------------------------------

describe("ai.blocks.list_requests", function()
  it("finds named blocks with line bounds", function()
    local reqs = blocks.list_requests(CONTENT)
    assert.equals(3, #reqs)
    -- bounds reach to the line before the next header (matching
    -- request_deps.collect_requests_from_content), including the blank
    -- separator line
    assert.equals("Get users", reqs[1].name)
    assert.equals(1, reqs[1].start_line)
    assert.equals(4, reqs[1].end_line)
    assert.equals("Login", reqs[2].name)
    assert.equals(5, reqs[2].start_line)
    assert.equals(15, reqs[2].end_line)
    assert.equals("Profile", reqs[3].name)
    assert.equals(16, reqs[3].start_line)
    assert.equals(#vim.split(CONTENT, "\n", { plain = true }), reqs[3].end_line)
  end)

  it("extracts method and path", function()
    local reqs = blocks.list_requests(CONTENT)
    assert.equals("GET", reqs[1].method)
    assert.equals("{{api_base}}/users", reqs[1].path)
    assert.equals("POST", reqs[2].method)
  end)

  it("handles SCRIPT blocks", function()
    local script = "### Flow\nSCRIPT\n> {% client.run('#a.B') %}\n"
    local reqs = blocks.list_requests(script)
    assert.equals(1, #reqs)
    assert.equals("SCRIPT", reqs[1].method)
    assert.is_nil(reqs[1].path)
  end)

  it("returns an empty list for content without blocks", function()
    assert.equals(0, #blocks.list_requests("GET http://x\n"))
    assert.equals(0, #blocks.list_requests(""))
  end)

  it("treats any ### line as a block boundary", function()
    local content = "### A\nGET /a\n###\nGET /b\n"
    local reqs = blocks.list_requests(content)
    -- only named blocks are listed; the bare ### still ends block A
    assert.equals(1, #reqs)
    assert.equals("A", reqs[1].name)
    assert.equals(2, reqs[1].end_line)
  end)
end)

---------------------------------------------------------------------------
-- block slicing / lookup
---------------------------------------------------------------------------

describe("ai.blocks.block_text", function()
  it("slices a block including its header", function()
    local lines = vim.split(CONTENT, "\n", { plain = true })
    local reqs = blocks.list_requests(CONTENT)
    local text = blocks.block_text(lines, reqs[1])
    assert.equals("### Get users\nGET {{api_base}}/users\nAuthorization: Bearer {{api_token}}", text)
  end)

  it("excludes trailing blank separator lines", function()
    local lines = { "### A", "GET /a", "", "" }
    local text = blocks.block_text(lines, { start_line = 1, end_line = 4 })
    assert.equals("### A\nGET /a", text)
  end)
end)

describe("ai.blocks.block_at_line", function()
  it("finds the block containing a line", function()
    local reqs = blocks.list_requests(CONTENT)
    assert.equals("Login", blocks.block_at_line(reqs, 8).name)
    assert.equals("Login", blocks.block_at_line(reqs, 5).name)
  end)

  it("returns nil for nil lines and lines before the first block", function()
    local reqs = blocks.list_requests(CONTENT)
    assert.is_nil(blocks.block_at_line(reqs, nil))
    local content = "GET /loose\n\n### A\nGET /a\n"
    assert.is_nil(blocks.block_at_line(blocks.list_requests(content), 1))
  end)
end)

describe("ai.blocks.find_block", function()
  it("matches by exact name", function()
    local reqs = blocks.list_requests(CONTENT)
    assert.equals(5, blocks.find_block(reqs, "Login").start_line)
    assert.is_nil(blocks.find_block(reqs, "login"))
  end)
end)

describe("ai.blocks.block_text_at_line", function()
  it("returns the raw block text for a line", function()
    local text = blocks.block_text_at_line(CONTENT, 6)
    assert.truthy(text:match("^### Login\n"))
    assert.truthy(text:match("POST {{api_base}}/login"))
  end)

  it("returns nil when the line is not in a block", function()
    assert.is_nil(blocks.block_text_at_line("GET /loose\n\n### A\nGET /a\n", 1))
  end)
end)

---------------------------------------------------------------------------
-- method / title extraction
---------------------------------------------------------------------------

describe("ai.blocks.method_of_text", function()
  it("reads the first request line", function()
    assert.equals("POST", blocks.method_of_text("### X\npost /api\n"))
    assert.equals("GET", blocks.method_of_text("GET /x\n"))
  end)

  it("skips comments, scripts and headers", function()
    assert.equals("GET", blocks.method_of_text("### X\n# comment\n< {% script %}\nGET /x\n"))
  end)

  it("returns nil for non-request text", function()
    assert.is_nil(blocks.method_of_text("### X\n# nothing here\n"))
    assert.is_nil(blocks.method_of_text(nil))
  end)
end)

describe("ai.blocks.title_of_text", function()
  it("prefers METHOD path", function()
    assert.equals("POST /api/login", blocks.title_of_text("### X\nPOST /api/login\nbody"))
  end)

  it("falls back to the bare method", function()
    assert.equals("SCRIPT", blocks.title_of_text("SCRIPT\n> {% %}\n"))
  end)

  it("uses the fallback for unparseable text", function()
    assert.equals("AI request", blocks.title_of_text("# only comments", "AI request"))
  end)
end)

---------------------------------------------------------------------------
-- dep_names
---------------------------------------------------------------------------

describe("ai.blocks.dep_names", function()
  it("collects response and request refs, deduplicated and sorted", function()
    local text = "{{Login.response.body.token}} {{login.response.status}} {{A.request.header.X}}"
    assert.same({ "A", "Login", "login" }, blocks.dep_names(text))
  end)

  it("ignores non-chaining vars", function()
    assert.same({}, blocks.dep_names("{{api_base}} {{other}}"))
    assert.same({}, blocks.dep_names(nil))
  end)

  it("matches the executor's ref grammar: spaced/dotted names and .res. shorthand", function()
    -- request_deps.split_request_ref takes EVERYTHING before `.response.` /
    -- `.request.` as the request name (block names may carry spaces or
    -- dots) and normalizes `.res.` → `.response.`. dep_names feeds
    -- auto_context's dep lookup, so a grammar divergence here silently
    -- drops those deps from the chat context.
    local text = "{{Login User.response.body.token}} {{v1.2 Login.res.status}}"
    assert.same({ "Login User", "v1.2 Login" }, blocks.dep_names(text))
  end)
end)

---------------------------------------------------------------------------
-- focus (the stateful seam)
---------------------------------------------------------------------------

describe("ai.blocks.focus", function()
  local state = require("poste-http.state")
  local saved_last_request

  before_each(function()
    saved_last_request = state.last_request
  end)

  after_each(function()
    state.last_request = saved_last_request
  end)

  it("reads the focused block from state.last_request", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(CONTENT, "\n", { plain = true }))
    vim.bo[buf].filetype = "poste_http"
    state.last_request = { buf = buf, line = 6 }

    local focus = blocks.focus(nil)
    assert.truthy(focus)
    assert.equals(buf, focus.buf)
    assert.equals("Login", focus.block.name)
    assert.equals("dev", focus.env)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("falls back to (scratch) for unnamed last_request buffers", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### Ping", "GET /ping" })
    vim.bo[buf].filetype = "poste_http"
    state.last_request = { buf = buf, line = 1 }

    local focus = blocks.focus(nil)
    assert.truthy(focus)
    assert.equals("(scratch)", focus.file)
    assert.equals("Ping", focus.block.name)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("prefers the scope's named request in the scope file", function()
    local path = vim.fn.tempname() .. ".http"
    vim.fn.writefile(vim.split(CONTENT, "\n", { plain = true }), path)

    local focus = blocks.focus({ file = path, request = "Profile" })
    assert.truthy(focus)
    assert.equals("Profile", focus.block.name)

    vim.fn.delete(path)
  end)

  it("returns nil without any focus source", function()
    state.last_request = nil
    local cur = vim.api.nvim_get_current_buf()
    local saved_ft = vim.bo[cur].filetype
    vim.bo[cur].filetype = ""
    assert.is_nil(blocks.focus({}))
    vim.bo[cur].filetype = saved_ft
  end)
end)

---------------------------------------------------------------------------
-- truncate
---------------------------------------------------------------------------

describe("ai.blocks.truncate", function()
  it("passes short text through", function()
    assert.equals("abc", blocks.truncate("abc", 10))
  end)

  it("caps long text with a note", function()
    local out = blocks.truncate(string.rep("x", 100), 10)
    assert.equals(10 + #"\n… (truncated)", #out)
    assert.truthy(out:match("truncated"))
  end)
end)

---------------------------------------------------------------------------
-- truncate (UTF-8 safety)
---------------------------------------------------------------------------

describe("ai.blocks truncate UTF-8 safety", function()
  it("never splits a UTF-8 sequence at the byte cut", function()
    -- CJK bodies are the norm in AI context: every cut offset must leave
    -- the prefix valid UTF-8 (iconv round-trip returns "" on invalid input).
    local s = ("日"):rep(12) -- 36 bytes, 12 chars
    for cut = 1, #s - 1 do
      local out = blocks.truncate(s, cut)
      local head = out:gsub("\n… %(truncated%)$", "")
      assert.equals(head, vim.fn.iconv(head, "utf-8", "utf-8"),
        ("cut %d produced invalid UTF-8"):format(cut))
    end
  end)

  it("keeps byte-budget semantics and the truncation note", function()
    local ascii = ("a"):rep(100)
    assert.equals(ascii, blocks.truncate(ascii, 100))
    local cut = blocks.truncate(ascii, 50)
    assert.truthy(cut:find("truncated", 1, true), "note appended")
    assert.equals(50, #cut - #"\n… (truncated)")
    assert.equals("abc", blocks.truncate("abc", 10), "under budget: unchanged")
  end)
end)
