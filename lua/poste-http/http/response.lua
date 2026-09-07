--- Canonical response helpers shared by all protocol executors.
---
--- The canonical response shape (docs/dev/multi-protocol-design.md):
---   { protocol, status, status_text, latency_ms, url, content_type,
---     headers, body, cookies, metadata, ok }
---
--- `ok` is the protocol-aware success flag stamped by each response
--- builder: HTTP uses status > 0 and status < 400 (a no-response 0 is not
--- a success), gRPC uses status == 0 (codes 1-16 are errors), WebSocket
--- uses a normal close code (1000). `is_error` reads the stamped flag and
--- falls back to the historical HTTP-shaped rule for legacy responses that
--- never got stamped.

local M = {}

--- Protocol-aware error check.
--- Stamped `ok` wins; otherwise protocol "error" is an error, and the last
--- fallback is the historical HTTP rule: only status >= 400 is an error
--- (legacy status-0 stubs were never treated as errors by callers).
function M.is_error(response)
  if not response then return true end
  if response.ok ~= nil then return not response.ok end
  if response.protocol == "error" then return true end
  local status = response.status
  return type(status) == "number" and status >= 400
end

--- Shared canonical error response for protocol executors.
--- `method` is the request-line keyword ("GRAPHQL" / "GRPC" / "WEBSOCKET")
--- used for metadata.method and the request-line echo; `msg` is the
--- user-facing failure reason.
function M.error_response(req, method, msg)
  req = req or {}
  return {
    protocol = "error",
    status = 0,
    status_text = msg,
    latency_ms = 0,
    url = req.url or "",
    content_type = "text/plain",
    headers = req.headers or {},
    body = msg,
    cookies = {},
    ok = false,
    metadata = {
      method = method,
      error = msg,
      exit_code = "0",
      request_line = (req.method or method) .. " " .. (req.url or ""),
    },
  }
end

return M
