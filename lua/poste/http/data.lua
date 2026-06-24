--- Data tables for HTTP completion.
--- Extracted from completion.lua for reuse and cleaner organization.

local M = {}

---------------------------------------------------------------------------
-- HTTP methods
---------------------------------------------------------------------------
M.http_methods = {
  "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "TRACE", "CONNECT"
}

---------------------------------------------------------------------------
-- Common HTTP header names
---------------------------------------------------------------------------
M.header_names = {
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
-- MIME types (shared by Content-Type, Accept, etc.)
---------------------------------------------------------------------------
M.mime_types = {
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
-- Header values (keyed by lowercase header name)
---------------------------------------------------------------------------
M.header_values = {
  ["content-type"] = M.mime_types,
  ["accept"] = M.mime_types,
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
-- HTTP status codes with descriptions (for assertion completion)
---------------------------------------------------------------------------
M.http_status_codes = {
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
-- Pre-request script keywords (< {% ... %})
---------------------------------------------------------------------------
M.pre_script_keywords = {
  { name = "variables",              desc = "File/request/block-level variables" },
  { name = "env",                    desc = "Environment variables from env.json" },
  { name = "request.variables.set",  desc = "Set variable for request" },
  { name = "request.variables.get",  desc = "Get variable value" },
  { name = "client.global.set",      desc = "Set persistent global variable" },
  { name = "client.global.get",      desc = "Get persistent global variable" },
  { name = "client.log",             desc = "Log message to script output" },
  { name = "md5",                    desc = "Compute MD5 hash" },
}

---------------------------------------------------------------------------
-- Post-request assertion keywords (> {% ... %})
---------------------------------------------------------------------------
M.post_script_keywords = {
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
  { name = "variables",              desc = "File/request/block-level variables" },
  { name = "env",                    desc = "Environment variables from env.json" },
  -- Also include pre-request keywords (client.global, client.log available)
  { name = "client.global.set",      desc = "Set persistent global variable" },
  { name = "client.global.get",      desc = "Get persistent global variable" },
  { name = "client.log",             desc = "Log message to script output" },
}

---------------------------------------------------------------------------
-- Magic variables
---------------------------------------------------------------------------
M.magic_var_defs = {
  { name = "timestamp", desc = "Unix epoch + random digits" },
  { name = "uuid",      desc = "UUID v4 (random)" },
  { name = "date",      desc = "ISO date (YYYY-MM-DD)" },
  { name = "randomInt", desc = "Random integer 0-9999999" },
}

return M
