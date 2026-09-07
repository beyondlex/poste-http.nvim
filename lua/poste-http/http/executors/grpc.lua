--- gRPC executor: wraps grpcurl (docs/dev/multi-protocol-design.md).
---
--- Block translation:
---   request line  GRPC host:port/pkg.Service/Method   (bare host = list)
---   header lines  -H metadata
---   body          JSON message, streamed over stdin via -d @
---   # @grpc-import-path <path>   (repeatable)
---   # @grpc-proto <file>         (repeatable)
---   # @grpc-proto-set <file>     (repeatable)
---   # @grpc-plaintext / # @grpc-tls
---   # @grpc-flags <raw args>     escape hatch, shell-split
---
--- grpcurl exit 0 means OK (gRPC status 0); failures carry a
--- `Code: <Name>` block on stderr which maps onto gRPC status codes 0-16
--- in the canonical response's `status`.

local M = {}
local state = require("poste-http.state")
local util = require("poste-http.util")

local uv = vim.uv or vim.loop

--- gRPC status codes by name. Keys use the CamelCase spelling grpcurl
--- prints on stderr (`Code: NotFound`, `Code: Unavailable`, ...).
local GRPC_CODES = {
  OK = 0,
  Canceled = 1,
  Unknown = 2,
  InvalidArgument = 3,
  DeadlineExceeded = 4,
  NotFound = 5,
  AlreadyExists = 6,
  PermissionDenied = 7,
  ResourceExhausted = 8,
  FailedPrecondition = 9,
  Aborted = 10,
  OutOfRange = 11,
  Unimplemented = 12,
  Internal = 13,
  Unavailable = 14,
  DataLoss = 15,
  Unauthenticated = 16,
}

--- Map a grpcurl code name to its numeric status; nil when unknown.
function M.map_code(name)
  return GRPC_CODES[name]
end

--- Split a GRPC request-line target into host and method path.
--- A bare host (no `/pkg.Service/Method`) selects reflection list mode.
function M.parse_target(url)
  local host, method = url:match("^([^/]+)/(.+)$")
  if host and host ~= "" then
    return { host = host, method = method }
  end
  return { host = url, method = nil }
end

--- Mirror grpcurl's parseSymbol: split on the LAST "/" (or, when absent,
--- the LAST ".") and require both the service and method parts to be
--- non-empty. A trailing separator (`Service/`, `Service.`) or a name with
--- no separator cannot be invoked and would only surface as a confusing
--- grpcurl error, so bail out before spawning the process.
local function method_is_complete(method)
  local svc, mth = method:match("^(.*)/([^/]*)$")
  if svc == nil then
    svc, mth = method:match("^(.*)%.([^%.]*)$")
  end
  return svc ~= nil and svc ~= "" and mth ~= ""
end

local function op_values(req, name)
  local ops = req.operators
  if not ops or not ops[name] then return {} end
  return ops[name]
end

--- Build the grpcurl argv. Returns args, stdin_body (nil when the message
--- is empty), err.
function M.build_args(req)
  local target = M.parse_target(req.url or "")
  local args = { "grpcurl" }

  for _ in ipairs(op_values(req, "grpc-plaintext")) do
    table.insert(args, "-plaintext")
  end
  for _ in ipairs(op_values(req, "grpc-tls")) do
    table.insert(args, "-tls")
  end
  for _, v in ipairs(op_values(req, "grpc-import-path")) do
    table.insert(args, "-import-path")
    table.insert(args, v)
  end
  for _, v in ipairs(op_values(req, "grpc-proto")) do
    table.insert(args, "-proto")
    table.insert(args, v)
  end
  for _, v in ipairs(op_values(req, "grpc-proto-set")) do
    table.insert(args, "-proto-set")
    table.insert(args, v)
  end
  for _, v in ipairs(op_values(req, "grpc-flags")) do
    if v ~= "" then
      for _, flag in ipairs(vim.split(v, "%s+")) do
        if flag ~= "" then table.insert(args, flag) end
      end
    end
  end

  if req.timeout and req.timeout > 0 then
    table.insert(args, "-max-time")
    table.insert(args, tostring(math.max(1, math.ceil(req.timeout / 1000))))
  end

  for _, h in ipairs(req.headers or {}) do
    table.insert(args, "-H")
    table.insert(args, h[1] .. ": " .. (h[2] or ""))
  end

  local body = req.body or ""
  if target.method then
    if not method_is_complete(target.method) then
      return nil, nil, string.format(
        "incomplete gRPC method %q — expected 'service/method' or 'service.method'",
        target.method)
    end
    local has_body = vim.trim(body) ~= ""
    if has_body then
      table.insert(args, "-d")
      table.insert(args, "@")
    end
    table.insert(args, target.host)
    table.insert(args, target.method)
    return args, has_body and body or nil, nil
  end

  table.insert(args, target.host)
  -- grpcurl's reflection listing needs the explicit subcommand.
  table.insert(args, "list")
  return args, nil, nil
end

--- Build the canonical response from grpcurl output.
--- @param req table    original executor request
--- @param stdout table stdout lines
--- @param stderr table stderr lines
--- @param exit_code number
--- @param start_hires number|nil  uv.hrtime() at spawn (latency)
function M.build_response(req, stdout, stderr, exit_code, start_hires)
  local latency_ms = 0
  if start_hires then
    latency_ms = math.floor((uv.hrtime() - start_hires) / 1e6)
  end
  local stdout_text = table.concat(stdout or {}, "\n")
  local stderr_text = table.concat(stderr or {}, "\n")
  local target = M.parse_target(req.url or "")

  local metadata = {
    method = "GRPC",
    request_line = (req.method or "GRPC") .. " " .. (req.url or ""),
    exit_code = tostring(exit_code),
    verbose = stderr_text,
    target = target.method or target.host,
  }

  if exit_code == 0 then
    local content_type = "text/plain"
    if vim.trim(stdout_text):sub(1, 1) == "{" or vim.trim(stdout_text):sub(1, 1) == "[" then
      content_type = "application/json"
    end
    return {
      protocol = "grpc",
      status = 0,
      status_text = "OK",
      latency_ms = latency_ms,
      url = req.url or "",
      content_type = content_type,
      headers = req.headers or {},
      body = stdout_text,
      cookies = {},
      ok = true,
      metadata = metadata,
    }
  end

  local code_name = stderr_text:match("Code:%s*([%w_]+)")
  local code = code_name and M.map_code(code_name) or nil
  if code then
    local message = stderr_text:match("Message:%s*([^\n]*)") or ""
    return {
      protocol = "grpc",
      status = code,
      status_text = code_name .. " " .. vim.trim(message),
      latency_ms = latency_ms,
      url = req.url or "",
      content_type = "text/plain",
      headers = req.headers or {},
      body = stderr_text,
      cookies = {},
      ok = false,
      metadata = metadata,
    }
  end

  local body = stderr_text ~= "" and stderr_text or stdout_text
  return {
    protocol = "error",
    status = 0,
    status_text = "Failed (exit " .. tostring(exit_code) .. ")",
    latency_ms = latency_ms,
    url = req.url or "",
    content_type = "text/plain",
    headers = req.headers or {},
    body = body,
    cookies = {},
    ok = false,
    metadata = metadata,
  }
end

local response_mod = require("poste-http.http.response")
local function error_response(req, msg)
  return response_mod.error_response(req, "GRPC", msg)
end

--- Run the request through grpcurl.
function M.run(req, callback)
  if vim.fn.executable("grpcurl") ~= 1 then
    callback(error_response(req,
      "grpcurl executable not found — install it (e.g. `go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest` or `brew install grpcurl`) to run GRPC requests"))
    return
  end

  local args, stdin_body, err = M.build_args(req)
  if err then
    callback(error_response(req, err))
    return
  end

  state.log("INFO", "grpcurl: " .. util.redacted_cmd(args):sub(1, 500))

  local stdout_buf, stderr_buf = {}, {}
  local start_hires = uv.hrtime()

  local job_id = vim.fn.jobstart(args, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      data = util.ensure_job_data(data)
      for _, l in ipairs(data) do
        table.insert(stdout_buf, l)
      end
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
          state.log("ERROR", string.format("grpcurl exit code %d", exit_code))
        end
        callback(M.build_response(req, stdout_buf, stderr_buf, exit_code, start_hires))
      end)
    end,
  })

  if not job_id or job_id <= 0 then
    callback(error_response(req, "Failed to start grpcurl process"))
    return
  end

  if stdin_body then
    vim.fn.chansend(job_id, stdin_body)
    vim.fn.chanclose(job_id, "stdin")
  end
end

return M
