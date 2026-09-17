local state = require("poste-http.state")

describe("run.make_script_response", function()
  local run

  before_each(function()
    package.loaded["poste-http.http.run"] = nil
    run = require("poste-http.http.run")
  end)

  after_each(function()
    package.loaded["poste-http.http.run"] = nil
  end)

  it("returns a table with protocol = 'script'", function()
    local resp = run.make_script_response("SCRIPT", nil)
    assert.equal("script", resp.protocol)
  end)

  it("includes status 200 and status_text 'Script executed'", function()
    local resp = run.make_script_response("SCRIPT", nil)
    assert.equal(200, resp.status)
    assert.equal("Script executed", resp.status_text)
  end)

  it("stores trimmed req_text in url and metadata.request_line", function()
    local resp = run.make_script_response("  SCRIPT  ", nil)
    assert.equal("SCRIPT", resp.url)
    assert.equal("SCRIPT", resp.metadata.request_line)
  end)

  it("includes req_block.headers when req_block is provided", function()
    local req_block = { headers = { { "X-Custom", "val" } } }
    local resp = run.make_script_response("SCRIPT", req_block)
    assert.equal("X-Custom", resp.headers[1][1])
    assert.equal("val", resp.headers[1][2])
  end)

  it("defaults to empty headers when req_block is nil", function()
    local resp = run.make_script_response("SCRIPT", nil)
    assert.same({}, resp.headers)
  end)

  it("has a fixed body string", function()
    local resp = run.make_script_response("SCRIPT", nil)
    assert.equal("Script executed. See Assertions or Script Logs tab for details.", resp.body)
  end)

  it("sets metadata.method to 'SCRIPT' and exit_code to '0'", function()
    local resp = run.make_script_response("SCRIPT", nil)
    assert.equal("SCRIPT", resp.metadata.method)
    assert.equal("0", resp.metadata.exit_code)
  end)
end)

describe("run.make_error_response", function()
  local run

  before_each(function()
    package.loaded["poste-http.http.run"] = nil
    run = require("poste-http.http.run")
  end)

  after_each(function()
    package.loaded["poste-http.http.run"] = nil
  end)

  it("returns a table with protocol = 'error'", function()
    local resp = run.make_error_response("GET /fail", nil, "timeout", "Connection refused", 1)
    assert.equal("error", resp.protocol)
  end)

  it("includes body_text in the body field", function()
    local resp = run.make_error_response("GET /fail", nil, "timeout", "Connection refused", 1)
    assert.equal("timeout", resp.body)
  end)

  it("includes exit_code as string in metadata.exit_code", function()
    local resp = run.make_error_response("GET /fail", nil, "timeout", "Connection refused", 1)
    assert.equal("1", resp.metadata.exit_code)
  end)

  it("handles nil exit_code by using '?'", function()
    local resp = run.make_error_response("GET /fail", nil, "err", "msg", nil)
    assert.equal("?", resp.metadata.exit_code)
  end)

  it("includes err_msg as status_text", function()
    local resp = run.make_error_response("GET /fail", nil, "body content", "Not Found", 404)
    assert.equal("Not Found", resp.status_text)
  end)

  it("includes req_block.headers when req_block is provided", function()
    local req_block = { headers = { { "Content-Type", "text/plain" } } }
    local resp = run.make_error_response("GET /fail", req_block, "err", "msg", 1)
    assert.equal("Content-Type", resp.headers[1][1])
  end)
end)

describe("run.render_orchestration_result", function()
  local run

  before_each(function()
    package.loaded["poste-http.http.run"] = nil
    state.last_script_logs = nil
    state.last_response = nil
    state.last_responses = nil
    state.last_assertion_results = nil
    state._busy = true

    -- Stub UI/IO modules so the renderer is testable in isolation
    require("poste-http.http.view").show_view = function() end
    require("poste-http.http.buffer").reset_multi_response = function() end
    require("poste-http.http.buffer").prepare_multi_responses = function() end
    require("poste-http.http.history").add_entry = function() end
    require("poste-http.indicators").set_indicator = function() end
    require("poste-http.event").emit = function() end

    run = require("poste-http.http.run")
  end)

  after_each(function()
    package.loaded["poste-http.http.run"] = nil
    state.last_errors = nil
  end)

  local function ctx()
    return {
      src_buf = 1,
      req_line = 0,
      current_req_name = "flow",
      file = "/tmp/orchestration.http",
      req_text = "SCRIPT",
      req_block = nil,
    }
  end

  it("stores script logs exactly once and clears _busy", function()
    run.render_orchestration_result({ logs = { "a", "b" }, calls = {}, error = nil }, ctx())
    assert.same({ "a", "b" }, state.last_script_logs)
    assert.are_equal(1, state.last_assertion_results.total)
    assert.are_equal(0, state.last_assertion_results.failed)
    assert.is_false(state._busy)
  end)

  it("surfaces script errors as failed assertion results", function()
    run.render_orchestration_result({ logs = {}, calls = {}, error = "boom" }, ctx())
    assert.are_equal(1, state.last_assertion_results.failed)
    assert.are_equal("boom", state.last_assertion_results.error)
    assert.are_equal(0, state.last_response.status)
    assert.is_false(state._busy)
  end)

  it("stores the raw response chain for client.run calls", function()
    local chain = {
      { name = "Login", response = { status = 200, body = "{}" } },
      { name = "GetProfile", response = { status = 200, body = "{}" } },
    }
    run.render_orchestration_result({ logs = {}, calls = chain, error = nil }, ctx())
    assert.are_equal(2, #state.last_responses)
    assert.are_equal("Login", state.last_responses[1].name)
    assert.are_equal("GetProfile", state.last_responses[2].name)
    assert.are_equal(200, state.last_response.status)
    assert.is_false(state._busy)
  end)
end)

describe("run.make_ws_progress_handler", function()
  local run, show_calls

  before_each(function()
    package.loaded["poste-http.http.run"] = nil
    run = require("poste-http.http.run")
    show_calls = {}
    -- Stub the module table (not a local) so the handler's call-site
    -- lookup sees the stub; mimic show_view's current_view bookkeeping.
    require("poste-http.http.view").show_view = function(v)
      table.insert(show_calls, v)
      state.current_view = v
    end
    state.last_response = nil
    state._busy = true
  end)

  after_each(function()
    package.loaded["poste-http.http.run"] = nil
    state.last_response = nil
    state.current_view = "body"
  end)

  it("publishes the first progress response and switches to the Msgs tab", function()
    local handler = run.make_ws_progress_handler()
    local resp1 = { protocol = "websocket" }

    handler(resp1)

    assert.equal(resp1, state.last_response)
    assert.is_false(state._busy)
    assert.same({ "messages" }, show_calls)
  end)

  it("republishes every streamed response so Msgs refreshes after a send", function()
    local handler = run.make_ws_progress_handler()
    local resp1 = { protocol = "websocket" }
    local resp2 = { protocol = "websocket" }

    handler(resp1)
    handler(resp2)

    -- Each streaming response is a new table; the second must not be
    -- mistaken for "a newer response replaced ours".
    assert.equal(resp2, state.last_response)
    assert.equals(2, #show_calls)
  end)

  it("updates state without re-rendering once another tab is current", function()
    local handler = run.make_ws_progress_handler()
    handler({ protocol = "websocket" })
    state.set_current_view("body")

    local resp2 = { protocol = "websocket" }
    handler(resp2)

    assert.equal(resp2, state.last_response)
    assert.equals(1, #show_calls, "must not stomp a tab the user switched to")
  end)

  it("goes quiet once a newer response replaces the session's response", function()
    local handler = run.make_ws_progress_handler()
    handler({ protocol = "websocket" })

    -- Another request finished while the session was live.
    local newer = { protocol = "http" }
    state.set_response(newer)

    handler({ protocol = "websocket" })

    assert.equal(newer, state.last_response)
    assert.equals(1, #show_calls)
  end)
end)

describe("run.choose_view_tab", function()
  local run

  before_each(function()
    package.loaded["poste-http.http.run"] = nil
    run = require("poste-http.http.run")
    state.config.default_view = nil
    state.last_errors = nil
  end)

  after_each(function()
    package.loaded["poste-http.http.run"] = nil
  end)

  it("returns 'assertions' when assertion_results has failures", function()
    local parsed = { status = 200 }
    local results = { total = 3, passed = 1, failed = 2 }
    assert.equal("assertions", run.choose_view_tab(parsed, results))
  end)

  it("returns 'verbose' when status >= 400 and no assertion failures", function()
    local parsed = { status = 404 }
    assert.equal("verbose", run.choose_view_tab(parsed, nil))
  end)

  it("returns 'verbose' when status >= 400 even with all-passing assertions", function()
    local parsed = { status = 500 }
    local results = { total = 2, passed = 2, failed = 0 }
    assert.equal("verbose", run.choose_view_tab(parsed, results))
  end)

  it("returns 'body' by default when no assertions and status < 400", function()
    local parsed = { status = 200 }
    assert.equal("body", run.choose_view_tab(parsed, nil))
  end)

  it("returns 'verbose' when parsed is nil", function()
    assert.equal("verbose", run.choose_view_tab(nil, nil))
    assert.equal("verbose", run.choose_view_tab(nil, { total = 1, passed = 0, failed = 1 }))
  end)

  it("returns default_view from config when set (overrides 'body')", function()
    state.config.default_view = "headers"
    local parsed = { status = 200 }
    assert.equal("headers", run.choose_view_tab(parsed, nil))
  end)
end)

describe("scripts.inject_global_vars", function()
  local scripts

  before_each(function()
    package.loaded["poste-http.http.scripts"] = nil
    scripts = require("poste-http.http.scripts")
  end)

  after_each(function()
    package.loaded["poste-http.http.scripts"] = nil
  end)

  it("injects @var = value lines after block_start", function()
    local content = "GET /test\nHost: example.com"
    local vars = { host = "example.com", token = "abc123" }
    local result, count = scripts.inject_global_vars(content, 1, vars)
    assert.equal(2, count)
    local lines = vim.split(result, "\n", { plain = true })
    assert.equal(4, #lines)
    assert.equal("GET /test", lines[1])
    assert.matches("@host = example.com", result)
    assert.matches("@token = abc123", result)
    assert.equal("Host: example.com", lines[4])
  end)

  it("returns content unchanged and count 0 when global_vars is empty", function()
    local content = "GET /test\nHost: example.com"
    local result, count = scripts.inject_global_vars(content, 1, {})
    assert.equal(0, count)
    assert.equal("GET /test\nHost: example.com", result)
  end)

  it("returns content unchanged and count 0 when global_vars is nil", function()
    local content = "GET /test\nHost: example.com"
    local result, count = scripts.inject_global_vars(content, 1, nil)
    assert.equal(0, count)
    assert.equal("GET /test\nHost: example.com", result)
  end)

  it("returns content unchanged and count 0 when block_start is nil", function()
    local content = "GET /test\nHost: example.com"
    local result, count = scripts.inject_global_vars(content, nil, { key = "val" })
    assert.equal(0, count)
    assert.equal("GET /test\nHost: example.com", result)
  end)

  it("returns content unchanged and count 0 when block_start is nil and global_vars is empty", function()
    local content = "GET /test"
    local result, count = scripts.inject_global_vars(content, nil, {})
    assert.equal(0, count)
    assert.equal("GET /test", result)
  end)

  it("injects after a later block_start line, not just line 1", function()
    local content = "GET /a\nHost: a\n\n###\n\nGET /b\nHost: b"
    local vars = { env = "staging" }
    local result, count = scripts.inject_global_vars(content, 5, vars)
    assert.equal(1, count)
    local lines = vim.split(result, "\n", { plain = true })
    -- block_start=5 is the empty line before "GET /b"
    -- injection adds @env = staging after line 5, shifting subsequent lines
    assert.equal("", lines[5])
    assert.matches("@env = staging", lines[6])
    assert.equal("GET /b", lines[7])
  end)

  it("handles single-line content correctly", function()
    local content = "GET /ping"
    local vars = { debug = "true" }
    local result, count = scripts.inject_global_vars(content, 1, vars)
    assert.equal(1, count)
    local lines = vim.split(result, "\n", { plain = true })
    assert.equal(2, #lines)
    assert.equal("GET /ping", lines[1])
    assert.matches("@debug = true", lines[2])
  end)
end)

describe("scripts.scan_script_set_calls", function()
  local scripts

  before_each(function()
    package.loaded["poste-http.http.scripts"] = nil
    scripts = require("poste-http.http.scripts")
  end)

  after_each(function()
    package.loaded["poste-http.http.scripts"] = nil
  end)

  it("returns empty map when no set calls", function()
    local lines = { "GET /test", "Host: example.com" }
    local result = scripts.scan_script_set_calls(lines, 1, 2)
    assert.equal(0, vim.tbl_count(result))
  end)

  it("finds client.global.set calls with double quotes", function()
    local lines = { 'client.global.set("token", "abc")' }
    local result = scripts.scan_script_set_calls(lines, 1, 1)
    assert.equal(1, vim.tbl_count(result))
    assert.equal(1, result.token)
  end)

  it("finds client.global.set calls with single quotes", function()
    local lines = { "client.global.set('token', 'abc')" }
    local result = scripts.scan_script_set_calls(lines, 1, 1)
    assert.equal(1, vim.tbl_count(result))
    assert.equal(1, result.token)
  end)

  it("finds request.variables.set calls", function()
    local lines = { 'request.variables.set("user_id", "123")' }
    local result = scripts.scan_script_set_calls(lines, 1, 1)
    assert.equal(1, vim.tbl_count(result))
    assert.equal(1, result.user_id)
  end)

  it("scans only within block_start and block_end", function()
    local lines = {
      "GET /a",
      'client.global.set("first", "1")',
      "GET /b",
      'client.global.set("second", "2")',
    }
    local result = scripts.scan_script_set_calls(lines, 2, 3)
    assert.equal(1, vim.tbl_count(result))
    assert.equal(2, result.first)
  end)

  it("finds client.global.header.set calls with double quotes", function()
    local lines = { 'client.global.header.set("Authorization", "Bearer tok")' }
    local result = scripts.scan_script_set_calls(lines, 1, 1)
    assert.equal(1, vim.tbl_count(result))
    assert.equal(1, result.Authorization)
  end)

  it("finds client.global.header.set calls with single quotes", function()
    local lines = { "client.global.header.set('Authorization', 'Bearer tok')" }
    local result = scripts.scan_script_set_calls(lines, 1, 1)
    assert.equal(1, vim.tbl_count(result))
    assert.equal(1, result.Authorization)
  end)
end)

describe("run.start_curl_exec", function()
  local run, executors, view
  local orig_exec_run, orig_show_view

  before_each(function()
    package.loaded["poste-http.http.run"] = nil
    run = require("poste-http.http.run")
    state = require("poste-http.state")
    executors = require("poste-http.http.executors")
    view = require("poste-http.http.view")
    orig_exec_run = executors.run
    orig_show_view = view.show_view
  end)

  after_each(function()
    package.loaded["poste-http.http.run"] = nil
    state.set_pending_request(nil)
    executors.run = orig_exec_run
    view.show_view = orig_show_view
  end)

  it("falls back to ctx.req_block when describe finds no block meta", function()
    -- Regression: start_curl_exec read an undefined global `req_block`
    -- instead of ctx.req_block, so when tree-sitter describe produced no
    -- meta the method/url fallback stayed dead ("Could not determine
    -- request URL" for a valid request line).
    local captured
    executors.run = function(req, _cb) captured = req end
    view.show_view = function() end

    run.start_curl_exec({
      file = "",
      buf_content = "", -- nothing to describe -> describe_content returns {}
      req_line = 1,
      src_buf = vim.api.nvim_get_current_buf(),
      block_start = nil,
      block_end = nil,
      req_block = {
        request_line = "GET https://fallback.example.com/ping",
        headers = { { "X-Fallback", "1" } },
        name = "Fallback",
        method = "GET",
        path = "https://fallback.example.com/ping",
        body = "",
      },
    })

    assert.is_not_nil(captured, "executor should receive the req_block-derived request")
    assert.equal("GET", captured.method)
    assert.equal("https://fallback.example.com/ping", captured.url)
    assert.not_nil(state.pending_request)
    assert.equal("Fallback", state.pending_request.name)
  end)
end)

describe("run.run_request run-directive assertions", function()
  local run, import, cache, assertions, view

  local originals

  before_each(function()
    package.loaded["poste-http.http.run"] = nil
    run = require("poste-http.http.run")
    state = require("poste-http.state")
    import = require("poste-http.http.import")
    cache = require("poste-http.http.cache")
    assertions = require("poste-http.http.assertions")
    view = require("poste-http.http.view")

    originals = {
      resolve = import.resolve_run_at_cursor,
      execute = import.execute_run_directive,
      bounds = cache.find_request_block_bounds,
      extract = assertions.extract_assertion_blocks,
      run_assertions = assertions.run_assertions,
      show_view = view.show_view,
    }
    state._busy = false
  end)

  after_each(function()
    package.loaded["poste-http.http.run"] = nil
    import.resolve_run_at_cursor = originals.resolve
    import.execute_run_directive = originals.execute
    cache.find_request_block_bounds = originals.bounds
    assertions.extract_assertion_blocks = originals.extract
    assertions.run_assertions = originals.run_assertions
    view.show_view = originals.show_view
    state._busy = false
  end)

  it("passes extracted assertion code to handle_directive_response", function()
    -- Regression: `local _, assertion_code = extract_assertion_blocks(...)`
    -- shadowed the outer variable, so run directives always passed nil and
    -- their `> {% %}` blocks silently never ran.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "### R", "run ./other.http#Named" })
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    import.resolve_run_at_cursor = function()
      return { action = "run", path = "./other.http", line = 1 }
    end
    cache.find_request_block_bounds = function() return 1, 2 end
    assertions.extract_assertion_blocks = function(_, _s, _e, _dir)
      return "STRIPPED", "ASSERT_SENTINEL"
    end
    local captured_code, captured_vars
    assertions.run_assertions = function(_parsed, code, vars)
      captured_code = code
      captured_vars = vars
      return { tests = {}, passed = 0, failed = 0, total = 0 }
    end
    view.show_view = function() end
    import.execute_run_directive = function(_resolved, cb)
      cb(true, { protocol = "http", status = 200, ok = true, headers = {}, body = "", metadata = {} })
    end

    run.run_request()
    vim.wait(100, function() return captured_code ~= nil end)

    assert.equal("ASSERT_SENTINEL", captured_code,
      "the run directive's assertion block must reach run_assertions")
    assert.is_table(captured_vars, "script_vars flow through alongside the assertion code")
  end)
end)

describe("run.unresolved_var_parts", function()
  local run = require("poste-http.http.run")
  local errors = require("poste-http.http.errors")

  it("scans the URL, body, header values AND header names", function()
    -- The gate used to collect header values only, so a literal {{var}} in
    -- a header NAME slipped past the fail-fast check and went to curl.
    local parts = run.unresolved_var_parts(
      "https://api.example.com/{{base}}", "body {{bvar}}",
      { { "X-{{hname}}", "v {{hval}}" } })
    local names = errors.find_unresolved_vars(parts)
    table.sort(names)
    assert.same({ "base", "bvar", "hname", "hval" }, names)
  end)

  it("tolerates nil bodies, nil headers and nil header halves", function()
    assert.same({}, errors.find_unresolved_vars(
      run.unresolved_var_parts("https://api.example.com", nil, { { "X-A", nil }, {} })))
  end)
end)
