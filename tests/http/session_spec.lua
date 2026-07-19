--- Phase 2b: HTTP/SQL session lifecycle tests.

local state = require("poste.state")
local http_session = require("poste.http.session")
local sql_session = require("poste.sql.session")

describe("http.session", function()
  before_each(function()
    -- Seed stale state as if a previous request left residue
    state.last_response = { status = 200 }
    state.last_responses = { { name = "old", response = {} } }
    state.response_index = 2
    state.last_assertion_results = { total = 1, passed = 1, failed = 0 }
    state.last_script_logs = { "old log" }
    state.pending_request = { method = "GET", url = "/stale" }
    state._json.query = ".foo"
    state._json.original_lines = { "a" }
    state._json.is_filtered = true
    state._json.pretty_mode = false
    state.global_vars = { keep = "me" }
    state.script_variables = { also = "keep" }
  end)

  it("begin() clears request-scoped state", function()
    local s = http_session.begin({ buf = 1, line = 5, file = "t.http" })
    assert.is_not_nil(s)
    assert.is_nil(state.last_response)
    assert.is_nil(state.last_responses)
    assert.is_nil(state.response_index)
    assert.is_nil(state.last_assertion_results)
    assert.is_nil(state.last_script_logs)
    assert.is_nil(state.pending_request)
    assert.is_nil(state._json.query)
    assert.is_nil(state._json.original_lines)
    assert.is_false(state._json.is_filtered)
    -- pretty_mode is a user preference — preserved
    assert.is_false(state._json.pretty_mode)
    -- Persistent vars survive
    assert.equal("me", state.global_vars.keep)
    assert.equal("keep", state.script_variables.also)
  end)

  it("begin() sets active session and state._http_session", function()
    local s = http_session.begin({ line = 1 })
    assert.equals(s, http_session.active())
    assert.equals(s, state._http_session)
    assert.equal(1, s.meta.line)
  end)

  it("second begin() replaces previous session", function()
    local s1 = http_session.begin({ line = 1 })
    state.last_response = { status = 201 }
    local s2 = http_session.begin({ line = 2 })
    assert.is_not.equals(s1, s2)
    assert.is_nil(state.last_response)
    assert.equals(s2, http_session.active())
  end)

  it("finish() clears active reference", function()
    http_session.begin({})
    http_session.finish()
    assert.is_nil(http_session.active())
    assert.is_nil(state._http_session)
  end)
end)

describe("sql.session", function()
  before_each(function()
    state.last_response = { status = 200 }
    state.sql.last_dataset = { columns = {}, rows = {} }
    state.sql.pagination = { page = 3 }
    state.sql.cell = { row = 5, col = 2 }
    state.sql._raw_mode = true
    state.sql.context.connection = "local"
    state.sql.context.database = "mydb"
  end)

  it("begin() clears request-scoped SQL state", function()
    local s = sql_session.begin({ file = "q.sql" })
    assert.is_not_nil(s)
    assert.is_nil(state.last_response)
    assert.is_nil(state.sql.last_dataset)
    assert.is_true(vim.tbl_isempty(state.sql.pagination))
    assert.equal(1, state.sql.cell.row)
    assert.equal(1, state.sql.cell.col)
    assert.is_false(state.sql._raw_mode)
    -- Context persists
    assert.equal("local", state.sql.context.connection)
    assert.equal("mydb", state.sql.context.database)
  end)

  it("begin() sets active SQL session", function()
    local s = sql_session.begin({ line = 10 })
    assert.equals(s, sql_session.active())
    assert.equals(s, state._sql_session)
  end)
end)

describe("describe helpers", function()
  local describe = require("poste.http.describe")

  it("block_at_line finds containing block", function()
    local blocks = {
      { name = "A", line = 1, end_line = 5, method = "GET", path = "/a", headers = {}, body = "", request_line = "GET /a" },
      { name = "B", line = 6, end_line = 10, method = "POST", path = "/b", headers = {}, body = "", request_line = "POST /b" },
    }
    assert.equal("A", describe.block_at_line(blocks, 3).name)
    assert.equal("B", describe.block_at_line(blocks, 6).name)
    assert.equal("B", describe.block_at_line(blocks, 10).name)
  end)

  it("to_req_block maps BlockMeta shape", function()
    local meta = {
      name = "X",
      method = "GET",
      path = "/x",
      headers = { { "Accept", "json" } },
      body = "{}",
      request_line = "GET /x",
    }
    local rb = describe.to_req_block(meta)
    assert.equal("GET /x", rb.request_line)
    assert.equal("X", rb.name)
    assert.equal("Accept", rb.headers[1][1])
  end)

  it("headers_str joins pairs", function()
    local s = describe.headers_str({
      headers = { { "A", "1" }, { "B", "2" } },
    })
    assert.equal("A: 1\nB: 2", s)
  end)
end)
