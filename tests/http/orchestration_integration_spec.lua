--- End-to-end orchestration test: client.run() goes through the real import
--- resolution and request pipeline (curl and describe are mocked).
local _ = require("poste-http.state")

local mock_describe = {
  describe_content = function()
    return {
      {
        name = "login",
        line = 1,
        end_line = 4,
        method = "POST",
        path = "/login",
        headers = { { "Content-Type", "application/json" } },
        body = '{"username": "{{username}}"}',
        request_line = "POST /login",
      },
    }, nil
  end,
  block_at_line = function(blocks, _)
    return blocks[1]
  end,
  to_req_block = function(meta)
    return {
      request_line = meta.request_line or "",
      headers = meta.headers or {},
      name = meta.name or "",
      method = meta.method or "",
      path = meta.path or "",
      body = meta.body or "",
    }
  end,
  headers_str = function(meta)
    local parts = {}
    for _, h in ipairs(meta.headers or {}) do
      table.insert(parts, h[1] .. ": " .. (h[2] or ""))
    end
    return table.concat(parts, "\n")
  end,
}

describe("client.run orchestration (real import pipeline)", function()
  local req_file
  local buf
  local orig_execute
  local _

  before_each(function()
    package.loaded["poste-http.http.import"] = nil
    package.loaded["poste-http.http.orchestration"] = nil
    package.loaded["poste-http.http.curl_exec"] = nil
    package.loaded["poste-http.http.describe"] = nil

    req_file = os.tmpname() .. ".http"
    local f = io.open(req_file, "w")
    f:write([[### login
POST /login
Content-Type: application/json

{"username": "{{username}}"}
]])
    f:close()

    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, os.tmpname() .. ".http")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "import " .. req_file .. " as alias",
      "",
      "### Run login",
      "SCRIPT",
      "> {%",
      '  local r = client.run("#alias.login", { username = "u" })',
      '  assert(r.status == 200, "login failed")',
      "  client.log(r.body.ok)",
      "%}",
    })

    -- Mock describe and curl so no real request is made
    package.loaded["poste-http.http.describe"] = mock_describe
    local curl_exec = require("poste-http.http.curl_exec")
    orig_execute = curl_exec.execute
    curl_exec.execute = function(_, callback)
      callback({
        status = 200,
        status_text = "OK",
        body = '{"ok": true}',
        headers = { { "Content-Type", "application/json" } },
        metadata = {},
      })
    end
  end)

  after_each(function()
    if orig_execute then
      package.loaded["poste-http.http.curl_exec"] = nil
    end
    package.loaded["poste-http.http.describe"] = nil
    package.loaded["poste-http.http.import"] = nil
    package.loaded["poste-http.http.orchestration"] = nil
    os.remove(req_file)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("resolves the import, passes args, and returns the typed response", function()
    local orchestration = require("poste-http.http.orchestration")

    local result
    orchestration.run_script([[
local r = client.run("#alias.login", { username = "u" })
assert(r.status == 200, "login failed")
client.log(r.body.ok)
]], { buf = buf }, function(r)
      result = r
    end)

    -- The prompt-free pipeline completes synchronously (curl/describe mocked)
    assert.is_not_nil(result, "orchestration script did not complete")
    assert.is_nil(result.error, result.error)
    assert.are_equal(1, #result.calls)
    assert.are_equal("login", result.calls[1].name)
    assert.are_equal(200, result.calls[1].response.status)
    assert.is_true(vim.json.decode(result.calls[1].response.body).ok)
    assert.are_equal("true", result.logs[1])
  end)
end)
