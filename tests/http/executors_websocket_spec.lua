-- Tests for the WebSocket executor v1 (docs/dev/multi-protocol-design.md).
--
-- v1 is declarative batch: connect, send every body line as one text
-- frame, collect inbound frames until a wait window elapses or the server
-- closes, then render. Backend: websocat (stdin line = text frame).

local ws = require("poste-http.http.executors.websocket")

describe("websocket.split_messages", function()
  it("sends every non-empty body line as a text frame", function()
    local msgs = ws.split_messages('{"type": "subscribe"}\n\n{"type": "ping"}\n')
    assert.same({ '{"type": "subscribe"}', '{"type": "ping"}' }, msgs)
  end)

  it("returns an empty list for an empty body", function()
    assert.same({}, ws.split_messages(""))
    assert.same({}, ws.split_messages(nil))
  end)
end)

describe("websocket.parse_frames", function()
  it("maps non-empty stdout lines to received frames", function()
    local frames = ws.parse_frames({ 'hello', '', '{"ok": true}' })
    assert.same({
      { direction = "recv", data = "hello" },
      { direction = "recv", data = '{"ok": true}' },
    }, frames)
  end)

  it("returns an empty list for no output", function()
    assert.same({}, ws.parse_frames(nil))
    assert.same({}, ws.parse_frames({}))
  end)
end)

describe("websocket.build_args", function()
  it("puts headers as --header and the url last", function()
    local args = ws.build_args({
      url = "wss://stream.example.com/feed",
      headers = { { "Sec-WebSocket-Protocol", "chat.v1" } },
      body = "",
    })
    assert.equals("websocat", args[1])
    assert.equals("wss://stream.example.com/feed", args[#args])
    local found = false
    for i, a in ipairs(args) do
      if a == "--header" then
        assert.equals("Sec-WebSocket-Protocol: chat.v1", args[i + 1])
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("appends # @ws-flags verbatim", function()
    local args = ws.build_args({
      url = "wss://stream.example.com/feed",
      headers = {},
      body = "",
      operators = { ["ws-flags"] = { "--ping-interval 5" } },
    })
    local idx
    for i, a in ipairs(args) do
      if a == "--ping-interval" then idx = i end
    end
    assert.is_not_nil(idx)
    assert.equals("5", args[idx + 1])
    assert.equals("wss://stream.example.com/feed", args[#args])
  end)
end)

describe("websocket.resolve_wait_ms", function()
  it("prefers the # @ws-wait-ms operator", function()
    assert.equals(8000, ws.resolve_wait_ms({ ["ws-wait-ms"] = { "8000" } }))
  end)

  it("falls back to the built-in default", function()
    assert.equals(3000, ws.resolve_wait_ms(nil))
    assert.equals(3000, ws.resolve_wait_ms({}))
    assert.equals(3000, ws.resolve_wait_ms({ ["ws-wait-ms"] = { "bogus" } }))
  end)
end)

describe("websocket.build_response", function()
  it("builds an ok response with frames after the collection window", function()
    local r = ws.build_response({
      url = "wss://stream.example.com/feed",
      body = '{"type": "ping"}',
    }, { 'pong', '{"type": "message"}' }, {}, 0, { deadline_reached = true })
    assert.equals("websocket", r.protocol)
    assert.is_true(r.ok)
    assert.equals(1000, r.status)
    assert.equals(2, #r.metadata.frames.received)
    assert.same({ '{"type": "ping"}' }, r.metadata.frames.sent)
    assert.matches("pong", r.body)
  end)

  it("builds an ok response when the server closes first", function()
    local r = ws.build_response({
      url = "wss://stream.example.com/feed",
      body = "",
    }, { 'frame' }, {}, 0, { deadline_reached = false })
    assert.is_true(r.ok)
    assert.equals(1000, r.status)
  end)

  it("lets opts.close_reason override the status text", function()
    local r = ws.build_response({
      url = "wss://x", body = "",
    }, {}, {}, 0, { deadline_reached = true, close_reason = "Session closed" })
    assert.is_true(r.ok)
    assert.equals("Session closed", r.status_text)
  end)

  it("maps a non-zero exit to an abnormal-closure error", function()
    local r = ws.build_response({
      url = "wss://stream.example.com/feed",
      body = "",
    }, {}, { "websocat: Connection refused (os error 111)" }, 1, { deadline_reached = false })
    assert.equals("websocket", r.protocol)
    assert.is_false(r.ok)
    assert.equals(1006, r.status)
    assert.matches("Connection refused", r.status_text)
  end)
end)

describe("websocket.run", function()
  local orig_jobstart, orig_chansend, orig_chanclose, orig_executable, orig_jobstop
  local captured_opts, sent, stopped

  before_each(function()
    orig_jobstart, orig_chansend, orig_chanclose, orig_executable, orig_jobstop =
      vim.fn.jobstart, vim.fn.chansend, vim.fn.chanclose, vim.fn.executable, vim.fn.jobstop
    captured_opts, sent, stopped = nil, nil, nil
    vim.fn.executable = function(cmd) return cmd == "websocat" and 1 or 0 end
    vim.fn.jobstart = function(cmd, opts)
      captured_opts = opts
      return 777
    end
    vim.fn.chansend = function(_, data) sent = data return #data end
    vim.fn.chanclose = function() end
    vim.fn.jobstop = function(id) stopped = id return 1 end
  end)

  after_each(function()
    vim.fn.jobstart, vim.fn.chansend, vim.fn.chanclose, vim.fn.executable, vim.fn.jobstop =
      orig_jobstart, orig_chansend, orig_chanclose, orig_executable, orig_jobstop
  end)

  it("reports a canonical error when websocat is missing", function()
    vim.fn.executable = function() return 0 end
    local response
    ws.run({ url = "wss://x", headers = {}, body = "", wait_ms = 10 }, function(r) response = r end)
    assert.is_false(response.ok)
    assert.matches("websocat", response.body)
  end)

  it("sends the outgoing frames over stdin and keeps stdin open", function()
    ws.run({
      url = "wss://x", headers = {}, body = 'a\nb\n', wait_ms = 10,
    }, function() end)
    assert.equals("a\nb\n", sent)
    -- Closing stdin would EOF websocat, which closes the websocket before
    -- the responses arrive.
    assert.is_nil(closed)
    -- Frames must arrive live: buffered stdout would never flush for a
    -- process we kill at the deadline.
    assert.is_false(captured_opts.stdout_buffered)
  end)

  it("finishes once via the deadline timer", function()
    local responses = {}
    ws.run({
      url = "wss://x", headers = {}, body = "", wait_ms = 10,
    }, function(r) table.insert(responses, r) end)

    captured_opts.on_stdout(777, { 'frame1' }, nil)
    vim.wait(300, function() return #responses > 0 end)
    -- A late process exit after the deadline must not double-fire.
    captured_opts.on_exit(777, 0)

    assert.equals(1, #responses)
    assert.is_true(responses[1].ok)
    assert.equals(1, #responses[1].metadata.frames.received)
    assert.equals(777, stopped)
  end)

  it("finishes via on_exit when the server closes early", function()
    local responses = {}
    ws.run({
      url = "wss://x", headers = {}, body = "", wait_ms = 60000,
    }, function(r) table.insert(responses, r) end)

    captured_opts.on_stdout(777, { 'early' }, nil)
    captured_opts.on_exit(777, 0)
    vim.wait(300, function() return #responses > 0 end)

    assert.equals(1, #responses)
    assert.is_true(responses[1].ok)
    -- The process already exited: no jobstop needed.
    assert.is_nil(stopped)
  end)

  it("reports a failure when the job cannot start", function()
    vim.fn.jobstart = function() return -1 end
    local response
    ws.run({ url = "wss://x", headers = {}, body = "", wait_ms = 10 }, function(r) response = r end)
    assert.is_false(response.ok)
    assert.matches("Failed to start websocat", response.body)
  end)

  it("reassembles a frame delivered across multiple stdout chunks", function()
    local responses = {}
    ws.run({ url = "wss://x", headers = {}, body = "", wait_ms = 10 },
      function(r) table.insert(responses, r) end)
    -- One logical line split across three read callbacks.
    captured_opts.on_stdout(777, { 'hel' }, nil)
    captured_opts.on_stdout(777, { 'lo', '' }, nil)
    captured_opts.on_stdout(777, { 'next', '' }, nil)
    captured_opts.on_exit(777, 0)
    vim.wait(200, function() return #responses > 0 end)

    assert.equals(1, #responses)
    local frames = responses[1].metadata.frames.received
    local data = vim.tbl_map(function(f) return f.data end, frames)
    assert.same({ 'hello', 'next' }, data,
      "a line split across chunks must not become multiple frames")
  end)

  it("routes # @ws-interactive to the interactive session", function()
    local calls = {}
    local session_mod = {
      start = function(req, cb) calls[#calls + 1] = { req = req, cb = cb } end,
    }
    local orig = package.loaded["poste-http.http.ws_session"]
    package.loaded["poste-http.http.ws_session"] = session_mod

    local ok, err = pcall(ws.run, {
      url = "wss://x", headers = {}, body = "",
      operators = { ["ws-interactive"] = { "" } },
    }, function() end)

    package.loaded["poste-http.http.ws_session"] = orig
    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals(1, #calls)
  end)
end)
