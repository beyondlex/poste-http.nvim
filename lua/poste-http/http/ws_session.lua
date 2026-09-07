--- Interactive WebSocket session (Phase 4 of docs/dev/multi-protocol-design.md).
---
--- Keeps the websocat job alive after the pipeline returns:
---   - inbound frames stream through req.on_progress as they arrive
---   - ws_session.send() pushes one text frame
---   - ws_session.close(), wiping the response buffer, or the process
---     exiting finalizes the canonical response and invokes the callback
---
--- state.live_session holds the single active session. The busy flag is
--- owned by run.lua's progress handler, which releases it once the session
--- is live — a session must not block other requests indefinitely.

local M = {}
local state = require("poste-http.state")
local util = require("poste-http.util")
local executor = require("poste-http.http.executors.websocket")

local uv = vim.uv or vim.loop

local active = nil

--- Is an interactive session currently alive?
function M.is_active()
  return active ~= nil
end

local function latency_ms(session)
  if session.start_hires then
    return math.floor((uv.hrtime() - session.start_hires) / 1e6)
  end
  return 0
end

--- Finalize the session and invoke the callback exactly once.
--- close_reason labels why the session ended ("Session closed" for user
--- close); without it, exit 0 means the server closed the connection.
--- deadline_reached stays false: interactive sessions have no wait window.
local function finalize(session, exit_code, close_reason)
  if session.finished then return end
  session.finished = true
  if active == session then active = nil end
  if state.live_session == session then state.live_session = nil end
  if session.job_id and session.job_id > 0 then
    pcall(vim.fn.jobstop, session.job_id)
  end
  if session.buf_autocmd then
    pcall(vim.api.nvim_del_autocmd, session.buf_autocmd)
    session.buf_autocmd = nil
  end
  if session.splitter then
    session.splitter.flush(function(line)
      if vim.trim(line) ~= "" then
        table.insert(session.frames.received, { direction = "recv", data = vim.trim(line) })
      end
    end)
  end
  session.callback(executor.build_response(session.req, session.stdout_buf, session.stderr_buf,
    exit_code, {
      frames = session.frames,
      deadline_reached = false,
      close_reason = close_reason,
      latency_ms = latency_ms(session),
    }))
end

local function progress(session)
  if session.finished then return end
  if session.req.on_progress then
    session.req.on_progress(executor.build_response(session.req, session.stdout_buf, session.stderr_buf,
      0, {
        frames = session.frames,
        deadline_reached = true,
        latency_ms = latency_ms(session),
      }))
  end
end

local function open_ui(session)
  local ok, buf_mod = pcall(require, "poste-http.http.buffer")
  if not ok or not buf_mod then return end
  local buf = buf_mod.get_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  session.buf = buf
  local keymaps = require("poste-http.ui.keymaps")
  keymaps.register(buf, "http_response", "ws_send", "s", function()
    M.send_prompt()
  end)
  keymaps.register(buf, "http_response", "ws_close", "c", function()
    M.close()
  end)
  session.buf_autocmd = vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    buffer = buf,
    callback = function() M.close() end,
  })
end

--- Start an interactive session for a WEBSOCKET request.
--- req.on_progress(response) is invoked on session open and after every
--- frame for live rendering; callback(response) fires exactly once, when
--- the session ends.
function M.start(req, callback)
  if active then
    callback(executor.error_response(req,
      "Another WebSocket session is live — close it first (press `c` in the Msgs tab)"))
    return
  end
  if vim.fn.executable("websocat") ~= 1 then
    callback(executor.error_response(req,
      "websocat executable not found — install it (e.g. `brew install websocat` or `cargo install websocat`) to run WEBSOCKET requests"))
    return
  end

  local args, _, err = executor.build_args(req)
  if err then
    callback(executor.error_response(req, err))
    return
  end

  state.log("INFO", "websocat (interactive): " .. util.redacted_cmd(args):sub(1, 500))

  local session
  session = {
    req = req,
    callback = callback,
    frames = { sent = {}, received = {} },
    stdout_buf = {},
    stderr_buf = {},
    start_hires = uv.hrtime(),
    finished = false,
  }
  -- websocat frames arrive as stdin-style lines; a frame can be split
  -- across multiple unbuffered stdout chunks, so reassemble before
  -- recording (see util.line_splitter). finalize() flushes any trailing
  -- partial line when the session ends.
  session.splitter = util.line_splitter()

  session.job_id = vim.fn.jobstart(args, {
    -- Unbuffered so inbound frames stream as they arrive.
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if session.finished then return end
      session.splitter.feed(data, function(line)
        if vim.trim(line) ~= "" then
          table.insert(session.frames.received, { direction = "recv", data = vim.trim(line) })
        end
      end)
      if not session.opened and #session.frames.received > 0 then
        session.opened = true
        open_ui(session)
      end
      progress(session)
    end,
    on_stderr = function(_, data)
      if session.finished then return end
      data = util.ensure_job_data(data)
      for _, l in ipairs(data) do
        table.insert(session.stderr_buf, l)
      end
    end,
    on_exit = function(_, exit_code)
      if exit_code ~= 0 then
        state.log("ERROR", string.format("websocat exit code %d", exit_code))
      end
      finalize(session, exit_code)
    end,
  })

  if not session.job_id or session.job_id <= 0 then
    -- Mark finished first: finalize would otherwise publish a fabricated
    -- success AND the error callback below would fire a second time.
    session.job_id = nil
    session.finished = true
    if active == session then active = nil end
    if state.live_session == session then state.live_session = nil end
    callback(executor.error_response(req, "Failed to start websocat process"))
    return
  end

  active = session
  state.live_session = session

  -- Body lines were already sent in batch mode; interactive sessions keep
  -- stdin open for ws_session.send, but still flush the initial frames.
  local outgoing = executor.split_messages(req.body)
  for _, msg in ipairs(outgoing) do
    table.insert(session.frames.sent, msg)
  end
  if #outgoing > 0 then
    vim.fn.chansend(session.job_id, table.concat(outgoing, "\n") .. "\n")
  end
end

--- Send one text frame on the active session (defaults to `active`).
--- Returns true when the frame was handed to the process.
function M.send(msg, session)
  session = session or active
  if not session or session.finished or not session.job_id or session.job_id <= 0 then
    return false
  end
  msg = vim.trim(tostring(msg))
  if msg == "" then return false end
  vim.fn.chansend(session.job_id, msg .. "\n")
  table.insert(session.frames.sent, msg)
  progress(session)
  return true
end

--- Prompt for a message and send it on the active session.
function M.send_prompt()
  if not active then
    vim.notify("No live WebSocket session", vim.log.levels.WARN, { title = "Poste" })
    return
  end
  vim.ui.input({ prompt = "WS send> " }, function(msg)
    if msg then M.send(msg) end
  end)
end

--- Close the given session (defaults to `active`) and finalize.
function M.close(session)
  session = session or active
  if not session then return false end
  finalize(session, 0, "Session closed")
  return true
end

return M
