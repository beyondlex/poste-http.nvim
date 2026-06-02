--- Completion source for nvim-cmp.
--- Provides context-aware completions for HTTP requests:
---   - HTTP methods (GET, POST, PUT, ...)
---   - Header names (Content-Type, Accept, ...)
---   - Header values (application/json, text/html, ...)

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
  -- Common custom
  "X-Requested-With",
  "X-Forwarded-For",
  "X-Forwarded-Host",
  "X-Forwarded-Proto",
  "X-Real-IP",
  "X-Correlation-ID",
  "X-Request-ID",
}

---------------------------------------------------------------------------
-- Data: MIME types (shared by Content-Type, Accept, etc.)
---------------------------------------------------------------------------
local mime_types = {
  -- Application
  "application/json",
  "application/xml",
  "application/javascript",
  "application/x-www-form-urlencoded",
  "application/octet-stream",
  "application/pdf",
  "application/zip",
  "application/gzip",
  "application/x-tar",
  "application/graphql",
  "application/ld+json",
  "application/vnd.api+json",
  "application/x-protobuf",
  "application/msgpack",
  "application/cbor",
  -- Text
  "text/html",
  "text/plain",
  "text/xml",
  "text/css",
  "text/javascript",
  "text/markdown",
  "text/csv",
  "text/yaml",
  -- Multipart
  "multipart/form-data",
  "multipart/byteranges",
  -- Image
  "image/jpeg",
  "image/png",
  "image/gif",
  "image/webp",
  "image/svg+xml",
  -- Wildcard
  "*/*",
}

---------------------------------------------------------------------------
-- Data: Header values (keyed by lowercase header name)
---------------------------------------------------------------------------
local header_values = {
  ["content-type"] = mime_types,
  ["accept"] = mime_types,
  ["accept-charset"] = { "utf-8", "iso-8859-1", "us-ascii" },
  ["accept-encoding"] = { "gzip", "deflate", "br", "identity", "gzip, deflate, br" },
  ["accept-language"] = { "en", "en-US", "zh-CN", "zh-TW", "ja", "ko", "fr", "de", "es" },
  ["authorization"] = { "Bearer ", "Basic ", "Digest ", "AWS4-HMAC-SHA256 " },
  ["cache-control"] = {
    "no-cache", "no-store", "max-age=0", "must-revalidate",
    "public", "private", "no-transform", "immutable",
  },
  ["connection"] = { "keep-alive", "close", "upgrade" },
  ["content-encoding"] = { "gzip", "deflate", "br", "identity" },
  ["content-disposition"] = { "inline", "attachment" },
  ["expect"] = { "100-continue" },
  ["transfer-encoding"] = { "chunked", "compress", "deflate", "gzip", "identity" },
  ["upgrade"] = { "websocket", "h2c", "TLS/1.0" },
  ["x-requested-with"] = { "XMLHttpRequest" },
  ["access-control-allow-methods"] = {
    "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS",
    "GET, POST, PUT, DELETE, PATCH, OPTIONS",
  },
  ["access-control-allow-credentials"] = { "true", "false" },
}

---------------------------------------------------------------------------
-- nvim-cmp source
---------------------------------------------------------------------------
local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source.get_keyword_pattern()
  -- Match any word character sequence (letters, digits, hyphens, dots, slashes, etc.)
  -- This needs to be broad enough to match methods, headers, and MIME types
  return [=[[\w\-*/+.]+]=]
end

function source:get_trigger_characters()
  return { " ", ":", "/", "-" }
end

function source:get_debug_name()
  return "poste"
end

function source:is_available()
  return vim.bo.filetype == "poste_http" or vim.bo.filetype == "poste_redis"
end

--- Detect the completion context from the line up to cursor.
--- Returns: "method" | "header_name" | "header_value" | nil
--- For header_value, also returns the header name.
local function detect_context(line_before_cursor)
  -- Trim leading whitespace for analysis
  local trimmed = vim.trim(line_before_cursor)

  -- Empty line or only whitespace → could be method
  if trimmed == "" then
    return "method", nil
  end

  -- After ### (request name line) → no completion
  if trimmed:match("^###") then
    return nil, nil
  end

  -- Comment lines → no completion
  if trimmed:match("^#") or trimmed:match("^%-%-") then
    return nil, nil
  end

  -- @var definition → no completion
  if trimmed:match("^@") then
    return nil, nil
  end

  -- Check if this is a method line (starts with HTTP method keyword)
  local first_word = trimmed:match("^(%S+)")
  if first_word then
    for _, method in ipairs(http_methods) do
      if first_word:upper() == method then
        -- This is a method line, already have the method → no completion
        return nil, nil
      end
    end
  end

  -- Check if we're after a colon (header value context)
  -- But only if it's a proper header (Header-Name: value), not a URL
  local colon_pos = line_before_cursor:find(":%s")  -- colon followed by space
  if colon_pos then
    -- Extract header name (before the colon)
    local header_name = vim.trim(line_before_cursor:sub(1, colon_pos - 1))
    -- Make sure it's a valid header (not empty, starts with letter, no spaces)
    if header_name ~= "" and header_name:match("^[A-Za-z][A-Za-z0-9%-]*$") then
      return "header_value", header_name
    end
  end

  -- Check for URL (contains ://)
  if line_before_cursor:find("://") then
    -- This is a URL line, no completion
    return nil, nil
  end

  -- No colon yet — check if it looks like a header name or method
  -- If the line has a space, it's likely not a header name being typed
  if line_before_cursor:find("%s") and not line_before_cursor:match("^%s*$") then
    return nil, nil
  end

  -- Single word, no space, no colon → could be method or header name
  -- We'll return both possibilities — the caller can provide both sets
  return "method_or_header", nil
end

--- Build completion items from a list of strings.
local function make_items(words, kind)
  local items = {}
  for _, word in ipairs(words) do
    table.insert(items, {
      label = word,
      kind = kind,
    })
  end
  return items
end

--- Filter items by prefix.
local function filter_items(items, prefix)
  if not prefix or prefix == "" then
    return items
  end
  local lower_prefix = prefix:lower()
  local filtered = {}
  for _, item in ipairs(items) do
    if item.label:lower():find(lower_prefix, 1, true) == 1 then
      table.insert(filtered, item)
    end
  end
  return filtered
end

function source:complete(request, callback)
  local line = request.context.cursor_before_line
  local col = request.offset
  local line_before_cursor = line:sub(1, col - 1)

  -- Get the word being typed (for filtering)
  local word = request.context.cursor_before_line:sub(request.offset)

  local ctx, header_name = detect_context(line_before_cursor)
  local items = {}

  -- nvim-cmp kind IDs (best effort, may vary by nvim-cmp version)
  local Kind = require("cmp").lsp.CompletionItemKind or {}
  local KIND_KEYWORD = Kind.Keyword or Kind.Text or 1
  local KIND_PROPERTY = Kind.Property or Kind.Field or 2
  local KIND_VALUE = Kind.Value or Kind.EnumMember or 3

  if ctx == "method" then
    items = make_items(http_methods, KIND_KEYWORD)
  elseif ctx == "method_or_header" then
    -- Could be either: provide both methods and header names
    local method_items = make_items(http_methods, KIND_KEYWORD)
    local header_items = make_items(header_names, KIND_PROPERTY)
    for _, item in ipairs(method_items) do
      table.insert(items, item)
    end
    for _, item in ipairs(header_items) do
      table.insert(items, item)
    end
  elseif ctx == "header_name" then
    items = make_items(header_names, KIND_PROPERTY)
  elseif ctx == "header_value" and header_name then
    local values = header_values[header_name:lower()]
    if values then
      items = make_items(values, KIND_VALUE)
    end
  end

  -- Filter by prefix
  items = filter_items(items, word)

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

function M.register()
  if registered then return end

  local ok, cmp = pcall(require, "cmp")
  if ok then
    -- cmp is already loaded, register immediately
    cmp.register_source("poste", source.new())
    registered = true
    vim.notify("poste: cmp source registered", vim.log.levels.DEBUG)
  else
    -- cmp not loaded yet (e.g., lazy-loaded by LazyVim)
    -- Register when user enters insert mode (cmp will be loaded by then)
    local group = vim.api.nvim_create_augroup("PosteCmpRegister", { clear = true })
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = group,
      callback = function()
        if registered then return end
        local ok2, cmp2 = pcall(require, "cmp")
        if ok2 then
          cmp2.register_source("poste", source.new())
          registered = true
          -- Set up buffer for current buffer if it's an HTTP file
          if vim.bo.filetype == "poste_http" or vim.bo.filetype == "poste_redis" then
            cmp2.setup.buffer({
              sources = cmp2.config.sources({
                { name = "poste" },
              }, {
                { name = "buffer" },
              }),
            })
          end
          -- Remove autocmd after successful registration
          vim.api.nvim_del_augroup_by_name("PosteCmpRegister")
        end
      end,
    })
  end
end

-- Diagnostic function to check completion status
function M.status()
  local ok, cmp = pcall(require, "cmp")
  if not ok then
    return "cmp not loaded"
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
    "cmp loaded: yes, registered: %s, buffer has poste: %s, filetype: %s",
    tostring(registered),
    tostring(has_poste),
    vim.bo.filetype
  )
end

return M
