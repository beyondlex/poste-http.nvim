--- WebSocket executor v1: declarative batch over websocat
--- (docs/dev/multi-protocol-design.md).
---
--- Block translation:
---   request line  WEBSOCKET wss://host/path
---   header lines  --header (Sec-WebSocket-Protocol etc.)
---   body lines    one outgoing text frame per non-empty line
---   # @ws-wait-ms <n>   collection window (default 3000)
---   # @ws-flags <raw>   extra websocat args (repeatable, shell-split)
---
--- v1 lifecycle: connect → send all frames → collect inbound frames until
--- the wait window elapses or the server closes → render. Incoming frames
--- are rendered once at completion; live append arrives with the
--- interactive session (v2). Frames are line-based: a frame containing
--- newlines shows as multiple rows (documented limitation).

local M = {}
local state = require("poste-http.state")
local util = require("poste-http.util")

local uv = vim.uv or vim.loop

local DEFAULT_WAIT_MS = 3000

--- Resolve the collection window from # @ws-wait-ms, else the default.
function M.resolve_wait_ms(operators)
  local values = operators and operators["ws-wait-ms"] or nil
  if values then
    local n = tonumber(values[1])
    if n and n > 0 then
      return math.floor(n)
    end
  end
  return DEFAULT_WAIT_MS
end

--- Split the body into outgoing messages: one per non-empty line.
function M.split_messages(body)
  local messages = {}
  if not body then return messages end
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    if vim.trim(line) ~= "" then
      table.insert(messages, vim.trim(line))
    end
  end
  return messages
end

--- Map inbound stdout lines to received frames.
function M.parse_frames(stdout_lines)
  local frames = {}
  for _, l in ipairs(stdout_lines or {}) do
    if vim.trim(l) ~= "" then
      table.insert(frames, { direction = "recv", data = vim.trim(l) })
    end
  end
  return frames
end

--- Build the websocat argv. Simple mode: each stdin line is one text
--- frame; incoming frames print one per stdout line.
function M.build_args(req)
  local args = { "websocat" }
  for _, h in ipairs(req.headers or {}) do
    table.insert(args, "--header")
    table.insert(args, h[1] .. ": " .. (h[2] or ""))
  end
  local ops = req.operators or {}
  for _, v in ipairs(ops["ws-flags"] or {}) do
    if v ~= "" then
      for _, flag in ipairs(vim.split(v, "%s+")) do
        if flag ~= "" then table.insert(args, flag) end
      end
    end
  end
  table.insert(args, req.url or "")
  return args, nil, nil
end

--- Build the canonical response.
--- opts.deadline_reached distinguishes "collection window elapsed" from
--- "process exited": a non-zero exit before the deadline is an abnormal
--- closure (status 1006). opts.frames overrides the transcript for
--- interactive sessions, which accumulate frames outside stdin/stdout.
function M.build_response(req, stdout, stderr, exit_code, opts)
  opts = opts or {}
  local frames
  local received
  if opts.frames then
    frames = opts.frames
    received = frames.received or {}
  else
    frames = { sent = M.split_messages(req.body), received = M.parse_frames(stdout) }
    received = frames.received
  end
  local stderr_text = table.concat(stderr or {}, "\n")

  local body_parts = {}
  for _, f in ipairs(received) do
    table.insert(body_parts, type(f) == "table" and f.data or f)
  end
  local body = table.concat(body_parts, "\n")
  if body == "" and stderr_text ~= "" and exit_code ~= 0 then
    body = stderr_text
  end

  local status_text
  if opts.close_reason then
    -- Interactive sessions label why they ended ("Session closed"); keep
    -- the exit-code-derived status otherwise.
    status_text = opts.close_reason
  elseif opts.deadline_reached then
    status_text = "Collection window elapsed"
  elseif exit_code == 0 then
    status_text = "Server closed connection"
  else
    status_text = "Failed (exit " .. tostring(exit_code) .. ")"
    local first_line = stderr_text:match("[^\r\n]+")
    if first_line and vim.trim(first_line) ~= "" then
      status_text = vim.trim(first_line)
    end
  end

  local ok = opts.deadline_reached or exit_code == 0
  return {
    protocol = "websocket",
    status = ok and 1000 or 1006,
    status_text = status_text,
    latency_ms = opts.latency_ms or 0,
    url = req.url or "",
    content_type = "text/plain",
    headers = req.headers or {},
    body = body,
    cookies = {},
    ok = ok,
    metadata = {
      method = "WEBSOCKET",
      request_line = (req.method or "WEBSOCKET") .. " " .. (req.url or ""),
      exit_code = tostring(exit_code),
      verbose = stderr_text,
      frames = frames,
      wait_ms = opts.wait_ms,
    },
  }
end

local response_mod = require("poste-http.http.response")
local function error_response(req, msg)
  return response_mod.error_response(req, "WEBSOCKET", msg)
end

M.error_response = error_response

--- Run the session through websocat. `# @ws-interactive` keeps the job
--- alive (see http/ws_session.lua); the default is a batch session.
function M.run(req, callback)
  if req.operators and req.operators["ws-interactive"] then
    local session = require("poste-http.http.ws_session")
    session.start(req, callback)
    return
  end

  if vim.fn.executable("websocat") ~= 1 then
    callback(error_response(req,
      "websocat executable not found — install it (e.g. `brew install websocat` or `cargo install websocat`) to run WEBSOCKET requests"))
    return
  end

  local args, _, err = M.build_args(req)
  if err then
    callback(error_response(req, err))
    return
  end

  local wait_ms = req.wait_ms or M.resolve_wait_ms(req.operators)
  local outgoing = M.split_messages(req.body)
  state.log("INFO", "websocat: " .. util.redacted_cmd(args):sub(1, 500)
    .. string.format(" (wait %dms, %d outgoing frames)", wait_ms, #outgoing))

  local stdout_buf, stderr_buf = {}, {}
  -- A frame can be split across multiple unbuffered stdout chunks; only
  -- complete lines go into stdout_buf (see util.line_splitter).
  local splitter = util.line_splitter()
  local start_hires = uv.hrtime()
  local timer
  local job_id
  local finished = false

  local function collect_line(line)
    if vim.trim(line) ~= "" then
      table.insert(stdout_buf, line)
    end
  end

  local function finish(response, stop_job)
    if finished then return end
    finished = true
    if timer then
      pcall(function() timer:stop() end)
      pcall(function() timer:close() end)
    end
    if stop_job and job_id and job_id > 0 then
      pcall(vim.fn.jobstop, job_id)
    end
    callback(response)
  end

  job_id = vim.fn.jobstart(args, {
    -- Unbuffered: frames must arrive live (we kill the job at the
    -- deadline, and buffered stdout never flushes for a killed process).
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      splitter.feed(data, collect_line)
    end,
    on_stderr = function(_, data)
      data = util.ensure_job_data(data)
      for _, l in ipairs(data) do
        table.insert(stderr_buf, l)
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code ~= 0 then
          state.log("ERROR", string.format("websocat exit code %d", exit_code))
        end
        splitter.flush(collect_line)
        finish(M.build_response(req, stdout_buf, stderr_buf, exit_code, {
          deadline_reached = false,
          latency_ms = math.floor((uv.hrtime() - start_hires) / 1e6),
          wait_ms = wait_ms,
        }), false)
      end)
    end,
  })

  if not job_id or job_id <= 0 then
    finish(error_response(req, "Failed to start websocat process"))
    return
  end

  if #outgoing > 0 then
    vim.fn.chansend(job_id, table.concat(outgoing, "\n") .. "\n")
    -- stdin stays open: closing it EOFs websocat, which closes the
    -- websocket before the responses arrive. The deadline jobstops us.
  end

  timer = uv.new_timer()
  timer:start(wait_ms, 0, vim.schedule_wrap(function()
    splitter.flush(collect_line)
    finish(M.build_response(req, stdout_buf, stderr_buf, 0, {
      deadline_reached = true,
      latency_ms = math.floor((uv.hrtime() - start_hires) / 1e6),
      wait_ms = wait_ms,
    }), true)
  end))
end

return M
