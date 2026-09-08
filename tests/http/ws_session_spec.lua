-- Tests for the interactive WebSocket session (Phase 4 of
-- docs/dev/multi-protocol-design.md).
--
-- An interactive session keeps the websocat job alive: inbound frames
-- stream to req.on_progress as they arrive, `send` pushes a text frame,
-- `close` finalizes the canonical response and clears state.live_session.

local ws_session = require("poste-http.http.ws_session")
local state = require("poste-http.state")

describe("ws_session.start", function()
  local orig_jobstart, orig_chansend, orig_chanclose, orig_executable, orig_jobstop
  local captured_opts, sent

  before_each(function()
    orig_jobstart, orig_chansend, orig_chanclose, orig_executable, orig_jobstop =
      vim.fn.jobstart, vim.fn.chansend, vim.fn.chanclose, vim.fn.executable, vim.fn.jobstop
    captured_opts, sent = nil, nil
    vim.fn.executable = function(cmd) return cmd == "websocat" and 1 or 0 end
    vim.fn.jobstart = function(cmd, opts)
      captured_opts = opts
      return 900
    end
    vim.fn.chansend = function(_, data) sent = data return #data end
    vim.fn.chanclose = function() end
    vim.fn.jobstop = function(id) return 1 end
    state.live_session = nil
  end)

  after_each(function()
    vim.fn.jobstart, vim.fn.chansend, vim.fn.chanclose, vim.fn.executable, vim.fn.jobstop =
      orig_jobstart, orig_chansend, orig_chanclose, orig_executable, orig_jobstop
    -- A started session leaks into the next test unless closed here.
    if ws_session.is_active() then ws_session.close() end
    state.live_session = nil
  end)

  it("reports a canonical error when websocat is missing", function()
    vim.fn.executable = function() return 0 end
    local response
    ws_session.start({ url = "wss://x", headers = {}, body = "" }, function(r) response = r end)
    assert.is_false(response.ok)
    assert.matches("websocat", response.body)
    assert.is_nil(state.live_session)
  end)

  it("streams inbound frames through on_progress and registers live_session", function()
    local progress = {}
    ws_session.start({
      url = "wss://x", headers = {}, body = "",
      on_progress = function(r) table.insert(progress, r) end,
    }, function() end)

    -- A live session must receive frames in real time.
    assert.is_false(captured_opts.stdout_buffered)
    assert.is_not_nil(state.live_session)

    captured_opts.on_stdout(900, { '{"hello": 1}', '' }, nil)
    vim.wait(200, function() return #progress > 0 end)

    assert.equals(1, #progress)
    assert.equals("websocket", progress[1].protocol)
    assert.equals(1, #progress[1].metadata.frames.received)
    assert.equals('{"hello": 1}', progress[1].metadata.frames.received[1].data)
  end)

  it("send pushes a text frame over stdin and into the transcript", function()
    local progress = {}
    ws_session.start({
      url = "wss://x", headers = {}, body = "",
      on_progress = function(r) table.insert(progress, r) end,
    }, function() end)

    assert.is_true(ws_session.send("ping"))
    assert.equals("ping\n", sent)
    assert.equals(1, #state.live_session.frames.sent)

    captured_opts.on_stdout(900, { 'pong', '' }, nil)
    vim.wait(200, function() return #progress > 0 end)
    assert.equals(1, #state.live_session.frames.received)
  end)

  it("close finalizes the response and clears live_session", function()
    local responses = {}
    local progress = {}
    ws_session.start({
      url = "wss://x", headers = {}, body = "",
      on_progress = function(r) table.insert(progress, r) end,
    }, function(r) table.insert(responses, r) end)

    captured_opts.on_stdout(900, { 'a', '' }, nil)
    vim.wait(200, function() return #progress > 0 end)
    ws_session.close()

    vim.wait(200, function() return #responses > 0 end)
    assert.equals(1, #responses)
    assert.is_true(responses[1].ok)
    assert.equals(1, #responses[1].metadata.frames.received)
    assert.equals("a", responses[1].body)
    assert.is_nil(state.live_session)

    -- A late frame after close must not resurrect anything.
    captured_opts.on_stdout(900, { 'late', '' }, nil)
    assert.equals(1, #responses)
  end)

  it("finalizes with an abnormal closure when the process exits before frames", function()
    local responses = {}
    ws_session.start({
      url = "wss://x", headers = {}, body = "",
    }, function(r) table.insert(responses, r) end)

    captured_opts.on_stderr(900, { "websocat: Connection refused" }, nil)
    captured_opts.on_exit(900, 1)
    vim.wait(200, function() return #responses > 0 end)

    assert.equals(1, #responses)
    assert.is_false(responses[1].ok)
    assert.equals(1006, responses[1].status)
    assert.is_nil(state.live_session)
  end)

  it("fires the callback exactly once when websocat fails to spawn", function()
    local responses = {}
    vim.fn.jobstart = function() return -1 end
    ws_session.start({ url = "wss://x", headers = {}, body = "" }, function(r) table.insert(responses, r) end)
    assert.equals(1, #responses, "spawn failure must not double-fire the callback")
    assert.is_false(responses[1].ok)
    assert.matches("Failed to start", responses[1].body)
    assert.is_nil(state.live_session)
  end)

  it("labels a user-closed session as Session closed", function()
    local responses = {}
    ws_session.start({
      url = "wss://x", headers = {}, body = "",
      on_progress = function() end,
    }, function(r) table.insert(responses, r) end)
    captured_opts.on_stdout(900, { 'hi', '' }, nil)
    vim.wait(200, function() return ws_session.is_active() == false or true end)
    ws_session.close()
    vim.wait(200, function() return #responses > 0 end)
    assert.equals(1, #responses)
    assert.matches("Session closed", responses[1].status_text,
      1, true)
  end)

  it("labels a server-closed session as Server closed connection", function()
    local responses = {}
    ws_session.start({
      url = "wss://x", headers = {}, body = "",
      on_progress = function() end,
    }, function(r) table.insert(responses, r) end)
    captured_opts.on_stdout(900, { 'hi', '' }, nil)
    captured_opts.on_exit(900, 0)
    vim.wait(200, function() return #responses > 0 end)
    assert.equals(1, #responses)
    assert.matches("Server closed connection", responses[1].status_text, 1, true)
  end)

  it("closing twice is safe", function()
    local responses = {}
    ws_session.start({ url = "wss://x", headers = {}, body = "" }, function(r) table.insert(responses, r) end)
    ws_session.close()
    ws_session.close()
    vim.wait(200, function() return #responses > 0 end)
    assert.equals(1, #responses)
  end)

  it("deletes its response-buffer autocmd when the session finalizes", function()
    -- get_buf() only returns an already-created response buffer, which the
    -- headless spec never builds — point it at a scratch buffer instead.
    local buffer_mod = require("poste-http.http.buffer")
    local fake_buf = vim.api.nvim_create_buf(false, true)
    local orig_get_buf = buffer_mod.get_buf
    buffer_mod.get_buf = function() return fake_buf end

    local function close_autocmd_count()
      -- One nvim_create_autocmd call with an event list shows up as one
      -- entry per event; count distinct ids.
      local seen = {}
      for _, au in ipairs(vim.api.nvim_get_autocmds({ buffer = fake_buf })) do
        if au.event == "BufWipeout" or au.event == "BufDelete" then
          seen[au.id] = true
        end
      end
      local n = 0
      for _ in pairs(seen) do n = n + 1 end
      return n
    end

    local registered, ok, err
    ok, err = pcall(function()
      local progress = {}
      ws_session.start({
        url = "wss://x", headers = {}, body = "",
        on_progress = function(r) table.insert(progress, r) end,
      }, function() end)
      captured_opts.on_stdout(900, { 'hi', '' }, nil)
      vim.wait(200, function() return #progress > 0 end)
      -- open_ui registered exactly one close autocmd for this session.
      registered = close_autocmd_count()
      ws_session.close()
      vim.wait(200, function() return not ws_session.is_active() end)
    end)

    buffer_mod.get_buf = orig_get_buf
    if not ok then error(err) end
    assert.equals(1, registered)
    -- finalize must remove it again; otherwise one autocmd accumulates per
    -- interactive session on the shared response buffer.
    assert.equals(0, close_autocmd_count())
  end)
end)
