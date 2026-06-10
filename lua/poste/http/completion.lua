--- Completion source for blink.cmp and nvim-cmp.
--- Provides context-aware completions for HTTP requests:
---   - HTTP methods (GET, POST, PUT, ...)
---   - Header names (Content-Type, Accept, ...)
---   - Header values (application/json, text/html, ...)
---   - Variable references ({{var_name}} from file, request, env)
---   - Request name references ({{RequestName.response.body}})
---   - Magic variables ({{$timestamp}}, {{$uuid}}, ...)
---   - Pre-request script keywords (request.variables, client.global, ...)
---   - Post-request assertion keywords (client.test, client.assert, response, ...)
---
--- For blink.cmp: this module IS the source (blink.cmp calls require("poste.http.completion").new())
--- For nvim-cmp:  use M.source subtable + M.register()

local M = {}

---------------------------------------------------------------------------
-- Data: HTTP methods
---------------------------------------------------------------------------
local http_methods = {
  "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "TRACE", "CONNECT"
}

---------------------------------------------------------------------------
-- Data: Common HTTP header names
---------------------------------------------------------------------------
local header_names = {
  -- General
  "Cache-Control",
  "Connection",
  "Date",
  "Pragma",
  "Trailer",
  "Transfer-Encoding",
  "Upgrade",
  "Via",
  "Warning",
  -- Request
  "Accept",
  "Accept-Charset",
  "Accept-Encoding",
  "Accept-Language",
  "Authorization",
  "Cookie",
  "Expect",
  "From",
  "Host",
  "If-Match",
  "If-Modified-Since",
  "If-None-Match",
  "If-Range",
  "If-Unmodified-Since",
  "Max-Forwards",
  "Origin",
  "Proxy-Authorization",
  "Range",
  "Referer",
  "TE",
  "User-Agent",
  -- Response
  "Accept-Ranges",
  "Age",
  "Allow",
  "Content-Disposition",
  "Content-Encoding",
  "Content-Language",
  "Content-Length",
  "Content-Location",
  "Content-MD5",
  "Content-Range",
  "Content-Type",
  "ETag",
  "Expires",
  "Last-Modified",
  "Link",
  "Location",
  "Proxy-Authenticate",
  "Retry-After",
  "Server",
  "Set-Cookie",
  "Vary",
  "WWW-Authenticate",
  -- CORS
  "Access-Control-Allow-Credentials",
  "Access-Control-Allow-Headers",
  "Access-Control-Allow-Methods",
  "Access-Control-Allow-Origin",
  "Access-Control-Expose-Headers",
  "Access-Control-Max-Age",
  "Access-Control-Request-Headers",
  "Access-Control-Request-Method",
  -- Security
  "Content-Security-Policy",
  "Content-Security-Policy-Report-Only",
  "Cross-Origin-Embedder-Policy",
  "Cross-Origin-Opener-Policy",
  "Cross-Origin-Resource-Policy",
  "Permissions-Policy",
  "Referrer-Policy",
  "Strict-Transport-Security",
  "X-Content-Type-Options",
  "X-Frame-Options",
  "X-XSS-Protection",
  -- Proxy / CDN
  "Forwarded",
  "X-Forwarded-For",
  "X-Forwarded-Host",
  "X-Forwarded-Proto",
  "X-Real-IP",
  "X-Correlation-ID",
  "X-Request-ID",
  "X-Requested-With",
  "CF-Connecting-IP",
  "CF-Ray",
  -- Caching
  "Surrogate-Control",
  -- gRPC
  "Grpc-Status",
  "Grpc-Message",
  "Grpc-Encoding",
  -- WebDAV
  "DAV",
  "Depth",
  "Destination",
  "If",
  "Overwrite",
  "Status-URI",
  -- WebSocket
  "Sec-WebSocket-Key",
  "Sec-WebSocket-Protocol",
  "Sec-WebSocket-Version",
  "Sec-WebSocket-Accept",
  -- Auth
  "X-API-Key",
  "X-Auth-Token",
  "X-CSRF-Token",
}

---------------------------------------------------------------------------
-- Data: MIME types (shared by Content-Type, Accept, etc.)
---------------------------------------------------------------------------
local mime_types = {
  -- JSON / structured data
  "application/json",
  "application/ld+json",
  "application/vnd.api+json",
  "application/hal+json",
  "application/geo+json",
  "application/problem+json",
  "application/json-patch+json",
  "application/merge-patch+json",
  "application/manifest+json",
  -- XML
  "application/xml",
  "application/soap+xml",
  "application/xhtml+xml",
  "application/atom+xml",
  "application/rss+xml",
  -- Web / JS
  "application/javascript",
  "application/x-javascript",
  "application/ecmascript",
  "application/wasm",
  "application/x-www-form-urlencoded",
  "application/graphql",
  -- Binary / archive
  "application/octet-stream",
  "application/pdf",
  "application/zip",
  "application/gzip",
  "application/x-tar",
  "application/x-bzip2",
  "application/x-7z-compressed",
  "application/x-rar-compressed",
  "application/java-archive",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.ms-powerpoint",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  -- Serialization
  "application/x-protobuf",
  "application/msgpack",
  "application/cbor",
  "application/x-ndjson",
  "application/grpc",
  -- Text
  "text/html",
  "text/plain",
  "text/xml",
  "text/css",
  "text/javascript",
  "text/markdown",
  "text/csv",
  "text/yaml",
  "text/event-stream",
  "text/cache-manifest",
  "text/tab-separated-values",
  -- Multipart
  "multipart/form-data",
  "multipart/byteranges",
  "multipart/mixed",
  "multipart/alternative",
  -- Image
  "image/jpeg",
  "image/png",
  "image/gif",
  "image/webp",
  "image/svg+xml",
  "image/avif",
  "image/bmp",
  "image/tiff",
  "image/x-icon",
  -- Audio
  "audio/mpeg",
  "audio/ogg",
  "audio/wav",
  "audio/webm",
  "audio/aac",
  "audio/flac",
  -- Video
  "video/mp4",
  "video/mpeg",
  "video/ogg",
  "video/webm",
  "video/quicktime",
  "video/x-msvideo",
  -- Font
  "font/ttf",
  "font/otf",
  "font/woff",
  "font/woff2",
  "application/font-woff2",
  -- Wildcard
  "*/*",
}

---------------------------------------------------------------------------
-- Data: Header values (keyed by lowercase header name)
---------------------------------------------------------------------------
local header_values = {
  ["content-type"] = mime_types,
  ["accept"] = mime_types,
  ["accept-charset"] = { "utf-8", "iso-8859-1", "us-ascii", "windows-1252", "shift_jis" },
  ["accept-encoding"] = {
    "gzip", "deflate", "br", "identity", "zstd",
    "gzip, deflate, br",
  },
  ["accept-language"] = {
    "en", "en-US", "en-GB",
    "zh-CN", "zh-TW",
    "ja", "ko", "fr", "de", "es", "pt", "it", "ru", "ar",
  },
  ["authorization"] = {
    -- RFC 6750
    "Bearer ",
    -- RFC 7617
    "Basic ",
    -- RFC 7616
    "Digest ",
    -- AWS
    "AWS4-HMAC-SHA256 ",
    -- RFC 4559 (Kerberos / SPNEGO)
    "Negotiate ",
    -- RFC 5802 (SCRAM)
    "SCRAM-SHA-256 ",
    -- RFC 7804 (Hawk)
    "Hawk ",
    -- RFC 6750 + OAuth2
    "OAuth ",
    -- RFC 9110 (HOBA)
    "HOBA ",
    -- RFC 8120 (Mutual)
    "Mutual ",
    -- RFC 6750 variant
    "Token ",
  },
  ["proxy-authorization"] = {
    "Bearer ", "Basic ", "Digest ", "Negotiate ",
  },
  ["cache-control"] = {
    "no-cache", "no-store", "max-age=", "max-age=0",
    "must-revalidate", "proxy-revalidate",
    "public", "private",
    "no-transform", "immutable",
    "s-maxage=",
    "stale-while-revalidate=",
    "stale-if-error=",
  },
  ["connection"] = { "keep-alive", "close", "upgrade" },
  ["content-encoding"] = { "gzip", "deflate", "br", "identity", "zstd" },
  ["content-disposition"] = {
    "inline",
    "attachment",
    'attachment; filename=""',
    "form-data",
    'form-data; name=""',
  },
  ["expect"] = { "100-continue" },
  ["transfer-encoding"] = { "chunked", "compress", "deflate", "gzip", "identity" },
  ["upgrade"] = { "websocket", "h2c", "TLS/1.0", "h2" },
  ["x-requested-with"] = { "XMLHttpRequest" },
  ["x-content-type-options"] = { "nosniff" },
  ["x-frame-options"] = { "DENY", "SAMEORIGIN", "ALLOW-FROM " },
  ["x-xss-protection"] = { "0", "1", "1; mode=block" },
  ["referrer-policy"] = {
    "no-referrer",
    "no-referrer-when-downgrade",
    "origin",
    "origin-when-cross-origin",
    "same-origin",
    "strict-origin",
    "strict-origin-when-cross-origin",
    "unsafe-url",
  },
  ["cross-origin-embedder-policy"] = { "unsafe-none", "require-corp" },
  ["cross-origin-opener-policy"] = {
    "unsafe-none", "same-origin-allow-popups", "same-origin",
  },
  ["cross-origin-resource-policy"] = { "same-site", "same-origin", "cross-origin" },
  ["permissions-policy"] = {
    "geolocation=(), camera=(), microphone=()",
    "geolocation=(self), camera=(), microphone=()",
  },
  ["strict-transport-security"] = {
    "max-age=31536000",
    "max-age=31536000; includeSubDomains",
    "max-age=31536000; includeSubDomains; preload",
  },
  ["access-control-allow-methods"] = {
    "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS",
    "GET, POST", "GET, POST, PUT, DELETE", "GET, POST, PUT, DELETE, PATCH, OPTIONS",
  },
  ["access-control-allow-credentials"] = { "true", "false" },
  ["access-control-allow-origin"] = { "*", "null" },
  -- Cookie (value is the cookie content)
  ["cookie"] = {
    -- Common cookie names as templates
    "session_id=",
    "session=",
    "token=",
    "auth=",
    "csrf_token=",
    "_ga=",
    "_gid=",
    "PHPSESSID=",
    "JSESSIONID=",
    "ASP.NET_SessionId=",
  },
  ["set-cookie"] = {
    -- Common templates
    'name=value; Path=/; HttpOnly; Secure; SameSite=Strict',
    'name=value; Path=/; HttpOnly; Secure; SameSite=Lax',
    'name=value; Path=/; Max-Age=3600; HttpOnly; Secure',
    'name=value; Path=/; Expires=',
    'name=value; Domain=',
  },
  -- gRPC
  ["grpc-status"] = {
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10",
    "11", "12", "13", "14", "15", "16",
  },
  ["grpc-encoding"] = { "identity", "gzip", "deflate", "compress" },
  -- WebDAV
  ["depth"] = { "0", "1", "infinity" },
  ["overwrite"] = { "T", "F" },
}

---------------------------------------------------------------------------
-- Data: HTTP status codes with descriptions (for assertion completion)
---------------------------------------------------------------------------
local http_status_codes = {
  -- 1xx Informational
  { code = "100", desc = "Continue" },
  { code = "101", desc = "Switching Protocols" },
  { code = "102", desc = "Processing" },
  { code = "103", desc = "Early Hints" },
  -- 2xx Success
  { code = "200", desc = "OK" },
  { code = "201", desc = "Created" },
  { code = "202", desc = "Accepted" },
  { code = "203", desc = "Non-Authoritative Information" },
  { code = "204", desc = "No Content" },
  { code = "205", desc = "Reset Content" },
  { code = "206", desc = "Partial Content" },
  { code = "207", desc = "Multi-Status" },
  { code = "208", desc = "Already Reported" },
  { code = "226", desc = "IM Used" },
  -- 3xx Redirection
  { code = "300", desc = "Multiple Choices" },
  { code = "301", desc = "Moved Permanently" },
  { code = "302", desc = "Found" },
  { code = "303", desc = "See Other" },
  { code = "304", desc = "Not Modified" },
  { code = "305", desc = "Use Proxy" },
  { code = "307", desc = "Temporary Redirect" },
  { code = "308", desc = "Permanent Redirect" },
  -- 4xx Client Error
  { code = "400", desc = "Bad Request" },
  { code = "401", desc = "Unauthorized" },
  { code = "402", desc = "Payment Required" },
  { code = "403", desc = "Forbidden" },
  { code = "404", desc = "Not Found" },
  { code = "405", desc = "Method Not Allowed" },
  { code = "406", desc = "Not Acceptable" },
  { code = "407", desc = "Proxy Authentication Required" },
  { code = "408", desc = "Request Timeout" },
  { code = "409", desc = "Conflict" },
  { code = "410", desc = "Gone" },
  { code = "411", desc = "Length Required" },
  { code = "412", desc = "Precondition Failed" },
  { code = "413", desc = "Payload Too Large" },
  { code = "414", desc = "URI Too Long" },
  { code = "415", desc = "Unsupported Media Type" },
  { code = "416", desc = "Range Not Satisfiable" },
  { code = "417", desc = "Expectation Failed" },
  { code = "418", desc = "I'm a teapot" },
  { code = "421", desc = "Misdirected Request" },
  { code = "422", desc = "Unprocessable Entity" },
  { code = "423", desc = "Locked" },
  { code = "424", desc = "Failed Dependency" },
  { code = "425", desc = "Too Early" },
  { code = "426", desc = "Upgrade Required" },
  { code = "428", desc = "Precondition Required" },
  { code = "429", desc = "Too Many Requests" },
  { code = "431", desc = "Request Header Fields Too Large" },
  { code = "451", desc = "Unavailable For Legal Reasons" },
  -- 5xx Server Error
  { code = "500", desc = "Internal Server Error" },
  { code = "501", desc = "Not Implemented" },
  { code = "502", desc = "Bad Gateway" },
  { code = "503", desc = "Service Unavailable" },
  { code = "504", desc = "Gateway Timeout" },
  { code = "505", desc = "HTTP Version Not Supported" },
  { code = "506", desc = "Variant Also Negotiates" },
  { code = "507", desc = "Insufficient Storage" },
  { code = "508", desc = "Loop Detected" },
  { code = "510", desc = "Not Extended" },
  { code = "511", desc = "Network Authentication Required" },
}

---------------------------------------------------------------------------
-- Data: Pre-request script keywords (< {% ... %})
---------------------------------------------------------------------------
local pre_script_keywords = {
  { name = "request.variables.set",  desc = "Set variable for request" },
  { name = "request.variables.get",  desc = "Get variable value" },
  { name = "client.global.set",      desc = "Set persistent global variable" },
  { name = "client.global.get",      desc = "Get persistent global variable" },
  { name = "client.log",             desc = "Log message to script output" },
  { name = "md5",                    desc = "Compute MD5 hash" },
}

---------------------------------------------------------------------------
-- Data: Post-request assertion keywords (> {% ... %})
---------------------------------------------------------------------------
local post_script_keywords = {
  -- Assertion API
  { name = "client.test",            desc = "Define named test block" },
  { name = "client.assert",          desc = "Assert condition (throws on false)" },
  { name = "assert",                 desc = "Top-level assert shorthand" },
  -- Response object
  { name = "response.status",        desc = "HTTP status code" },
  { name = "response.headers",       desc = "Response headers (case-insensitive)" },
  { name = "response.body",          desc = "Parsed JSON body" },
  { name = "response.content_type",  desc = "Content-Type header" },
  { name = "response.latency_ms",    desc = "Request duration in milliseconds" },
  { name = "response.url",           desc = "Request URL" },
  -- Also include pre-request keywords (client.global, client.log available)
  { name = "client.global.set",      desc = "Set persistent global variable" },
  { name = "client.global.get",      desc = "Get persistent global variable" },
  { name = "client.log",             desc = "Log message to script output" },
}

---------------------------------------------------------------------------
-- Caching infrastructure
---------------------------------------------------------------------------
-- Buffer-level caches (invalidated on text change via changedtick)
local buffer_caches = {}     -- bufnr → { changedtick, file_vars, req_names }
local env_cache = {}         -- path → { mtime, env_name, vars }
local cache_autocmds = {}    -- bufnr → true

--- Set up text-change autocmd for a buffer to invalidate cache.
local function ensure_cache_autocmd(buf)
  if cache_autocmds[buf] then return end
  cache_autocmds[buf] = true
  local group = vim.api.nvim_create_augroup("PosteCompletionCache_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      buffer_caches[buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    buffer = buf,
    callback = function()
      buffer_caches[buf] = nil
      cache_autocmds[buf] = nil
    end,
  })
end

--- Get buffer-level cache, rescanning if buffer has changed.
local function get_buffer_cache(buf)
  local ct = vim.api.nvim_buf_get_changedtick(buf)
  local cached = buffer_caches[buf]
  if cached and cached.changedtick == ct then
    return cached
  end

  -- Rescan entire buffer for file vars and request names in one pass
  local file_vars = {}
  local req_names = {}
  local seen_names = {}
  local past_file_vars = false
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for _, line in ipairs(lines) do
    if line:match("^%s*###") then
      past_file_vars = true
      local name = line:match("^%s*###%s+(.+)")
      if name then
        name = vim.trim(name)
        if name ~= "" and not seen_names[name] then
          seen_names[name] = true
          table.insert(req_names, name)
        end
      end
    elseif not past_file_vars then
      local var_name = line:match("^%s*@(%w[%w_]*)%s*=")
      if var_name then file_vars[var_name] = true end
    end
  end

  local entry = {
    changedtick = ct,
    file_vars = file_vars,
    req_names = req_names,
  }
  buffer_caches[buf] = entry
  ensure_cache_autocmd(buf)
  return entry
end

---------------------------------------------------------------------------
-- Variable collection (for {{var}} completion)
---------------------------------------------------------------------------

--- Get file-level variables from cache.
local function collect_file_vars(buf)
  return get_buffer_cache(buf).file_vars
end

--- Collect request-level variables (current request block only, not cached).
local function collect_request_vars(buf, cursor_line)
  local vars = {}
  local ok, indicators = pcall(require, "poste.indicators")
  if not ok then return vars end
  local start_line, end_line = indicators.find_request_block_bounds(buf, cursor_line)
  if not start_line then return vars end

  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  for _, line in ipairs(lines) do
    if not line:match("^%s*###") then
      local name = line:match("^%s*@(%w[%w_]*)%s*=")
      if name then vars[name] = true end
    end
  end
  return vars
end

--- Get environment variables from env.json (cached by path + mtime + env).
local function collect_env_vars()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then return {} end

  local dir = vim.fn.fnamemodify(bufname, ":h")
  local env_file

  while dir and dir ~= "" and dir ~= "/" do
    local candidate = dir .. "/env.json"
    if vim.fn.filereadable(candidate) == 1 then
      env_file = candidate
      break
    end
    dir = vim.fn.fnamemodify(dir, ":h")
  end

  if not env_file then return {} end

  -- Check cache: skip re-read if mtime and env name unchanged
  local info = vim.uv.fs_stat(env_file)
  local mtime = info and info.mtime and info.mtime.sec or 0

  local state = require("poste.state")
  local env_name = state.current_env or state.config.default_env

  local cached = env_cache[env_file]
  if cached and cached.mtime == mtime and cached.env_name == env_name then
    return cached.vars
  end

  local ok, content = pcall(vim.fn.readfile, env_file)
  if not ok or not content then return {} end

  local json_ok, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
  if not json_ok or type(data) ~= "table" then
    env_cache[env_file] = nil
    return {}
  end

  local env_data = data[env_name]
  if type(env_data) ~= "table" then
    env_cache[env_file] = nil
    return {}
  end

  local vars = {}
  for k, _ in pairs(env_data) do
    vars[k] = true
  end

  env_cache[env_file] = { mtime = mtime, env_name = env_name, vars = vars }
  return vars
end

--- Get request names from buffer cache.
local function collect_request_names(buf)
  return get_buffer_cache(buf).req_names
end

--- Magic variables matching request_vars.lua definitions.
local magic_var_defs = {
  { name = "timestamp", desc = "Unix epoch + random digits" },
  { name = "uuid",      desc = "UUID v4 (random)" },
  { name = "date",      desc = "ISO date (YYYY-MM-DD)" },
  { name = "randomInt", desc = "Random integer 0-9999999" },
}

---------------------------------------------------------------------------
-- Shared logic: context detection and item building
---------------------------------------------------------------------------

--- Detect if cursor is inside a script block (< {% ... %} or > {% ... %}).
--- Scans buffer for script markers to determine context.
--- Returns: "pre_script", "post_script", or nil
local function detect_script_context(buf, cursor_line, cursor_col)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, cursor_line, false)

  -- Track whether we're inside a script block and what type
  local in_script = nil  -- "pre" or "post"
  local script_start = nil

  for i, line in ipairs(lines) do
    if in_script then
      -- Check if this line closes the script block
      if line:find("%%}") then
        -- If we're on the closing line, check if cursor is before %}
        if i == cursor_line then
          local close_pos = line:find("%%}")
          if cursor_col <= close_pos then
            return in_script == "pre" and "pre_script" or "post_script"
          end
        end
        in_script = nil
        script_start = nil
      elseif i == cursor_line then
        -- We're inside the script block on this line
        return in_script == "pre" and "pre_script" or "post_script"
      end
    else
      -- Check for script block start
      local pre_start = line:find("<%s*{%%")
      local post_start = line:find(">%s*{%%")

      if pre_start or post_start then
        local start_pos = pre_start or post_start
        in_script = pre_start and "pre" or "post"
        script_start = i

        -- Check if script closes on same line
        local close_pos = line:find("%%}")
        if close_pos then
          -- Single-line script: < {% ... %} or > {% ... %}
          if i == cursor_line and cursor_col > start_pos and cursor_col <= close_pos then
            return in_script == "pre" and "pre_script" or "post_script"
          end
          in_script = nil
          script_start = nil
        elseif i == cursor_line then
          -- Cursor is on the opening line, after the marker
          if cursor_col > start_pos then
            return in_script == "pre" and "pre_script" or "post_script"
          end
          in_script = nil
          script_start = nil
        end
      end
    end
  end

  -- If we're still in a script at the end, cursor must be inside it
  if in_script then
    return in_script == "pre" and "pre_script" or "post_script"
  end

  return nil
end

--- Detect the completion context from the line up to cursor.
--- Optimized with direct string ops instead of pattern matching where possible.
--- Returns: context_type, extra_data
--- Context types:
---   "method"           - empty line, expecting HTTP method
---   "method_or_header" - single word, could be method or header name
---   "header_value"     - after "Header:" (extra_data = header name)
---   "variable"         - inside {{...}} (extra_data = text after {{)
---   "pre_script"       - inside < {% ... %} block
---   "post_script"      - inside > {% ... %} block
---   nil                - no completion
local function detect_context(line_before_cursor, buf, cursor_line, cursor_col)
  -- Check if we're inside a script block (takes precedence over all other contexts)
  if buf and cursor_line and cursor_col then
    local script_ctx = detect_script_context(buf, cursor_line, cursor_col)
    if script_ctx then
      -- Inside a script block: check for status code comparison pattern
      if script_ctx == "post_script" then
        local status_pat = "response%.status%s*[=!~<>]=?%s*"
        if line_before_cursor:match(status_pat) then
          return "status_code", line_before_cursor
        end
      end
      return script_ctx, line_before_cursor
    end
  end

  -- Fast-path: empty or whitespace-only → method completion
  local trimmed = vim.trim(line_before_cursor)
  if trimmed == "" then
    return "method", nil
  end

  -- Direct string prefix checks (faster than :match)
  local first_char = trimmed:sub(1, 1)
  if first_char == "#" then
    -- After ### (request name line) → no completion
    if trimmed:sub(2, 2) == "#" then return nil, nil end
    -- Comment lines → no completion
    return nil, nil
  end

  -- Comment: -- (direct check instead of pattern)
  if first_char == "-" and trimmed:sub(2, 2) == "-" then
    return nil, nil
  end

  -- @var definition → no completion
  if first_char == "@" then
    return nil, nil
  end

  -- Variable reference: check for unclosed {{ before cursor
  local rev = line_before_cursor:reverse()
  local last_open = rev:find("{{", 1, true)   -- plain string find
  local last_close = rev:find("}}", 1, true)  -- plain string find
  if last_open and (not last_close or last_close > last_open) then
    -- Cursor is inside an unclosed {{...}}
    local after_open = line_before_cursor:sub(#line_before_cursor - last_open + 2)
    return "variable", after_open
  end

  -- URL check (direct string find instead of pattern)
  if line_before_cursor:find("://", 1, true) then
    return nil, nil
  end

  -- Check if line already has a complete HTTP method followed by space
  local method_match = trimmed:match("^(%u+)%s")
  if method_match then
    for _, method in ipairs(http_methods) do
      if method_match == method then
        return nil, nil  -- already have method, rest is URL
      end
    end
  end

  -- Header value context: extract header name before colon
  -- Manual parsing is faster than pattern for short lines
  local colon_pos = line_before_cursor:find(":", 1, true)
  if colon_pos then
    -- Extract header name (letters, digits, hyphens) before colon
    local header_part = line_before_cursor:sub(1, colon_pos - 1)
    local header_name = header_part:match("^%s*([A-Za-z][A-Za-z0-9%-]*)$")
    if header_name then
      return "header_value", header_name
    end
  end

  -- No colon, no space → single word being typed (method or header name)
  if not line_before_cursor:find(" ", 1, true) then
    return "method_or_header", nil
  end

  -- Has space but no colon and no method → no completion
  return nil, nil
end

--- Build completion items from a list of strings (used by both engines).
--- kind: LSP CompletionItemKind number
local function build_items(words, kind)
  local items = {}
  for _, word in ipairs(words) do
    table.insert(items, {
      label = word,
      kind = kind,
      insertText = word,
      filterText = word,
      sortText = word,
      detail = nil,
    })
  end
  return items
end

--- Build completion items from keyword definitions (name + desc).
local function build_keyword_items(keywords, kind)
  local items = {}
  for _, kw in ipairs(keywords) do
    table.insert(items, {
      label = kw.name,
      kind = kind,
      insertText = kw.name,
      filterText = kw.name,
      sortText = kw.name,
      detail = kw.desc,
    })
  end
  return items
end

--- Get completion items for a given line context.
--- Shared between both engines.
local function get_items_for_context(line_before_cursor, buf, cursor_line, cursor_col)
  -- LSP CompletionItemKind constants
  local KIND_KEYWORD = 14   -- Keyword
  local KIND_PROPERTY = 10  -- Property
  local KIND_VALUE = 12     -- Value
  local KIND_VARIABLE = 6   -- Variable
  local KIND_REFERENCE = 18 -- Reference
  local KIND_FUNCTION = 3   -- Function

  local ctx, extra = detect_context(line_before_cursor, buf, cursor_line, cursor_col)
  local items = {}

  if ctx == "pre_script" then
    -- Pre-request script context: provide request.* and client.* keywords
    items = build_keyword_items(pre_script_keywords, KIND_FUNCTION)
    return items
  elseif ctx == "post_script" then
    -- Post-request assertion context: provide client.test, response.*, etc.
    items = build_keyword_items(post_script_keywords, KIND_FUNCTION)
    return items
  elseif ctx == "status_code" then
    -- HTTP status code completion inside assertion (response.status == ...)
    for _, sc in ipairs(http_status_codes) do
      table.insert(items, {
        label = sc.code,
        kind = KIND_VALUE,
        insertText = sc.code,
        filterText = sc.code .. " " .. sc.desc,
        sortText = sc.code,
        detail = sc.desc,
      })
    end
    return items
  end

  if ctx == "variable" then
    -- Variable reference context: {{...}}
    local after_open = extra or ""
    local is_magic = after_open:sub(1, 1) == "$"
    buf = buf or vim.api.nvim_get_current_buf()
    cursor_line = cursor_line or vim.api.nvim_win_get_cursor(0)[1]

    -- Magic variables (only when $ prefix is present)
    if is_magic then
      for _, mv in ipairs(magic_var_defs) do
        table.insert(items, {
          label = "$" .. mv.name,
          kind = KIND_KEYWORD,
          insertText = "$" .. mv.name,
          detail = mv.desc,
          sortText = "0" .. mv.name,
        })
      end
      return items
    end

    -- Regular variables (file + request + env)
    -- Merge all sources: file vars from cache, request vars computed, env vars from cache
    local all_vars = {}
    local cache = get_buffer_cache(buf)

    -- File-level vars (cached)
    for name in pairs(cache.file_vars) do
      all_vars[name] = "file"
    end

    -- Request-level vars (computed on-demand, scoped to current block)
    local req_vars = collect_request_vars(buf, cursor_line)
    for name in pairs(req_vars) do
      all_vars[name] = "request"
    end

    -- Environment vars (cached by mtime)
    local env_vars = collect_env_vars()
    for name in pairs(env_vars) do
      if not all_vars[name] then
        all_vars[name] = "env"
      end
    end

    -- Sort variable names for consistent ordering
    local var_names = {}
    for name in pairs(all_vars) do
      table.insert(var_names, name)
    end
    table.sort(var_names)

    for _, name in ipairs(var_names) do
      table.insert(items, {
        label = name,
        kind = KIND_VARIABLE,
        insertText = name,
        detail = all_vars[name],
        sortText = "1" .. name,
      })
    end

    -- Request name references (cached)
    for _, name in ipairs(cache.req_names) do
      table.insert(items, {
        label = name .. ".response.body",
        kind = KIND_REFERENCE,
        insertText = name .. ".response.body",
        filterText = name,
        detail = "request reference",
        sortText = "2" .. name,
      })
    end

    -- Also offer magic variables without $ prefix (user can type $ to filter)
    for _, mv in ipairs(magic_var_defs) do
      table.insert(items, {
        label = "$" .. mv.name,
        kind = KIND_KEYWORD,
        insertText = "$" .. mv.name,
        detail = mv.desc .. " (magic)",
        sortText = "3" .. mv.name,
      })
    end

    return items
  elseif ctx == "method" or ctx == "method_or_header" then
    local method_items = build_items(http_methods, KIND_KEYWORD)
    local header_items = build_items(header_names, KIND_PROPERTY)
    for _, item in ipairs(method_items) do
      table.insert(items, item)
    end
    for _, item in ipairs(header_items) do
      table.insert(items, item)
    end
  elseif ctx == "header_value" and extra then
    local values = header_values[extra:lower()]
    if values then
      items = build_items(values, KIND_VALUE)
    end
  end

  return items
end

--- Profile completion performance (run manually with :PosteCmpProfile).
--- Measures latency of context detection and item generation.
local function profile_completion()
  local iterations = 100
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]
  local col = cursor[2]
  local line = vim.api.nvim_get_current_line()
  local line_before_cursor = line:sub(1, col)

  -- Warm up cache
  get_items_for_context(line_before_cursor, buf, cursor_line, col)

  local start = vim.loop.hrtime()
  for _ = 1, iterations do
    get_items_for_context(line_before_cursor, buf, cursor_line, col)
  end
  local elapsed_ms = (vim.loop.hrtime() - start) / 1e6

  local avg_us = (elapsed_ms * 1000) / iterations
  local status = string.format(
    "completion profile: %d iterations in %.2fms (avg %.1fμs per call) | context: %s",
    iterations, elapsed_ms, avg_us,
    vim.inspect({ detect_context(line_before_cursor, buf, cursor_line, col) })
  )
  vim.notify(status, vim.log.levels.INFO)
end

M.profile = profile_completion

---------------------------------------------------------------------------
-- blink.cmp source (module-level interface)
---------------------------------------------------------------------------
-- blink.cmp calls require("poste.http.completion").new() to create a source.

--- Constructor called by blink.cmp.
function M.new(opts, config)
  local self = setmetatable({}, { __index = M })
  self.opts = opts or {}
  return self
end

--- blink.cmp: whether this source is enabled for the current buffer.
function M:enabled()
  return vim.bo.filetype == "poste_http" or vim.bo.filetype == "poste_redis"
end

--- blink.cmp: trigger characters that activate this source.
function M:get_trigger_characters()
  return { " ", ":", "/", "-", "{" }
end

--- blink.cmp: get completion items.
--- @param ctx table  blink.cmp context with .line, .cursor, .bufnr
--- @param callback function  called with { items, is_incomplete_forward }
function M:get_completions(ctx, callback)
  local line = ctx.line or ""
  local cursor = ctx.cursor or { 0, 0 }
  local cursor_line = cursor[1]
  local col = cursor[2] or 0
  local buf = ctx.bufnr or vim.api.nvim_get_current_buf()
  local line_before_cursor = line:sub(1, col)

  local items = get_items_for_context(line_before_cursor, buf, cursor_line, col)

  callback({
    items = items,
    is_incomplete_forward = false,
    is_incomplete_backward = false,
  })
end

--- blink.cmp: resolve additional item details (no-op for now).
function M:resolve(item, callback)
  callback(item)
end

--- blink.cmp: called after user accepts a completion (no-op for now).
function M:execute(ctx, item, callback, default_implementation)
  if default_implementation then
    default_implementation()
  end
  callback()
end

---------------------------------------------------------------------------
-- nvim-cmp source (legacy, kept for backward compatibility)
---------------------------------------------------------------------------
local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source.get_keyword_pattern()
  return [=[\k\+]=]
end

function source:get_trigger_characters()
  return { " ", ":", "/", "-", "{" }
end

function source:get_debug_name()
  return "poste"
end

function source:is_available()
  return vim.bo.filetype == "poste_http" or vim.bo.filetype == "poste_redis"
end

function source:complete(request, callback)
  local line = request.context.cursor_before_line
  local col = request.offset
  local line_before_cursor = line:sub(1, col - 1)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]

  local ctx, extra = detect_context(line_before_cursor, buf, cursor_line, col - 1)
  local items = {}

  -- nvim-cmp kind IDs
  local Kind = require("cmp").lsp.CompletionItemKind or {}
  local KIND_KEYWORD = Kind.Keyword or Kind.Text or 1
  local KIND_PROPERTY = Kind.Property or Kind.Field or 2
  local KIND_VALUE = Kind.Value or Kind.EnumMember or 3
  local KIND_VARIABLE = Kind.Variable or 4
  local KIND_REFERENCE = Kind.Reference or 5
  local KIND_FUNCTION = Kind.Function or 6

  if ctx == "pre_script" then
    -- Pre-request script keywords
    for _, kw in ipairs(pre_script_keywords) do
      table.insert(items, {
        label = kw.name,
        kind = KIND_FUNCTION,
        insertText = kw.name,
        filterText = kw.name,
        sortText = kw.name,
        detail = kw.desc,
      })
    end
  elseif ctx == "post_script" then
    -- Post-request assertion keywords
    for _, kw in ipairs(post_script_keywords) do
      table.insert(items, {
        label = kw.name,
        kind = KIND_FUNCTION,
        insertText = kw.name,
        filterText = kw.name,
        sortText = kw.name,
        detail = kw.desc,
      })
    end
  elseif ctx == "status_code" then
    -- HTTP status codes in assertion context
    for _, sc in ipairs(http_status_codes) do
      table.insert(items, {
        label = sc.code,
        kind = KIND_VALUE,
        insertText = sc.code,
        filterText = sc.code .. " " .. sc.desc,
        sortText = sc.code,
        detail = sc.desc,
      })
    end
  elseif ctx == "variable" then
    -- Reuse the shared get_items_for_context for variable completions
    items = get_items_for_context(line_before_cursor, buf, cursor_line, col - 1)
  elseif ctx == "method" or ctx == "method_or_header" then
    -- For nvim-cmp, strip hyphens for its weaker fuzzy matcher
    local function make_cmp_items(words, kind)
      local result = {}
      for _, word in ipairs(words) do
        local no_hyphen = word:gsub("-", "")
        table.insert(result, {
          label = no_hyphen,
          kind = kind,
          filterText = no_hyphen,
          sortText = word,
          insertText = word,
          detail = word ~= no_hyphen and word or nil,
        })
      end
      return result
    end
    local method_items = make_cmp_items(http_methods, KIND_KEYWORD)
    local header_items = make_cmp_items(header_names, KIND_PROPERTY)
    for _, item in ipairs(method_items) do
      table.insert(items, item)
    end
    for _, item in ipairs(header_items) do
      table.insert(items, item)
    end
  elseif ctx == "header_value" and extra then
    local values = header_values[extra:lower()]
    if values then
      items = build_items(values, KIND_VALUE)
    end
  end

  callback({ items = items, isIncomplete = true })
end

function source:resolve(completion_item, callback)
  callback(completion_item)
end

function source:execute(completion_item, callback)
  callback(completion_item)
end

M.source = source

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------
local registered = false

--- Register with blink.cmp using its runtime API.
local function register_blink()
  local blink = require("blink.cmp")
  blink.add_source_provider("poste", {
    module = "poste.http.completion",
    name = "Poste",
    score_offset = 100,
  })
  blink.add_filetype_source("poste_http", "poste")
  blink.add_filetype_source("poste_redis", "poste")
  registered = "blink"
end

--- Register with nvim-cmp.
local function register_cmp()
  local cmp = require("cmp")
  cmp.register_source("poste", source.new())
  registered = "cmp"
end

function M.register()
  if registered then return end

  -- Try blink.cmp first (LazyVim default)
  local blink_ok = pcall(register_blink)
  if blink_ok then return end

  -- Fall back to nvim-cmp
  local cmp_ok = pcall(register_cmp)
  if cmp_ok then return end

  -- Neither loaded yet — register when user enters insert mode
  local group = vim.api.nvim_create_augroup("PosteCmpRegister", { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function()
      if registered then return end

      -- Try blink.cmp first
      if pcall(register_blink) then
        vim.api.nvim_del_augroup_by_name("PosteCmpRegister")
        return
      end

      -- Try nvim-cmp
      if pcall(register_cmp) then
        if vim.bo.filetype == "poste_http" or vim.bo.filetype == "poste_redis" then
          local cmp = require("cmp")
          cmp.setup.buffer({
            sources = cmp.config.sources({
              { name = "poste" },
            }, {
              { name = "buffer" },
            }),
          })
        end
        vim.api.nvim_del_augroup_by_name("PosteCmpRegister")
      end
    end,
  })
end

-- Diagnostic function to check completion status
function M.status()
  if registered == "blink" then
    local ok, config = pcall(require, "blink.cmp.config")
    local providers_str = ""
    if ok then
      local ids = {}
      for id, _ in pairs(config.sources.providers) do
        table.insert(ids, id)
      end
      providers_str = " [" .. table.concat(ids, ", ") .. "]"
    end
    return string.format("completion engine: blink.cmp%s, filetype: %s", providers_str, vim.bo.filetype)
  end

  if registered == "cmp" then
    local ok, cmp = pcall(require, "cmp")
    if not ok then
      return "nvim-cmp registered but not loadable"
    end

    local sources = cmp.get_config().sources or {}
    local has_poste = false
    for _, src in ipairs(sources) do
      if src.name == "poste" then
        has_poste = true
        break
      end
    end

    return string.format(
      "completion engine: nvim-cmp, buffer has poste: %s, filetype: %s",
      tostring(has_poste),
      vim.bo.filetype
    )
  end

  return "no completion engine registered"
end

---------------------------------------------------------------------------
-- Test interface (expose internals for unit tests)
---------------------------------------------------------------------------
M._test = {
  detect_context = detect_context,
  detect_script_context = detect_script_context,
  build_items = build_items,
  build_keyword_items = build_keyword_items,
  get_items_for_context = get_items_for_context,
  get_buffer_cache = get_buffer_cache,
  collect_file_vars = collect_file_vars,
  collect_env_vars = collect_env_vars,
  collect_request_vars = collect_request_vars,
  collect_request_names = collect_request_names,
  pre_script_keywords = pre_script_keywords,
  post_script_keywords = post_script_keywords,
  http_status_codes = http_status_codes,
  header_names = header_names,
  mime_types = mime_types,
  header_values = header_values,
}

return M
