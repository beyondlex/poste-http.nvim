--- Completion source for blink.cmp and nvim-cmp.
--- Provides context-aware completions for HTTP requests:
---   - HTTP methods (GET, POST, PUT, ...)
---   - Header names (Content-Type, Accept, ...)
---   - Header values (application/json, text/html, ...)
---   - Variable references ({{var_name}} from file, request, env)
---   - Request name references ({{RequestName.response.body}})
---   - Magic variables ({{$timestamp}}, {{$uuid}}, ...)
---
--- For blink.cmp: this module IS the source (blink.cmp calls require("poste.completion").new())
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
-- Variable collection (for {{var}} completion)
---------------------------------------------------------------------------

--- Collect file-level variables (@var = value before the first ###).
local function collect_file_vars(buf)
  local vars = {}
  local line_count = vim.api.nvim_buf_line_count(buf)
  for i = 1, math.min(line_count, 200) do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if not line then break end
    if line:match("^%s*###") then break end
    local name = line:match("^%s*@(%w[%w_]*)%s*=")
    if name then vars[name] = true end
  end
  return vars
end

--- Collect request-level variables (@var = value in the current request block).
local function collect_request_vars(buf, cursor_line)
  local vars = {}
  local indicators = require("poste.indicators")
  local start_line, end_line = indicators.find_request_block_bounds(buf, cursor_line)
  if not start_line then return vars end

  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  for _, line in ipairs(lines) do
    if line:match("^%s*###") then goto continue end
    local name = line:match("^%s*@(%w[%w_]*)%s*=")
    if name then vars[name] = true end
    ::continue::
  end
  return vars
end

--- Load environment variables from env.json for the current environment.
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

  local ok, content = pcall(vim.fn.readfile, env_file)
  if not ok or not content then return {} end

  local json_ok, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
  if not json_ok or type(data) ~= "table" then return {} end

  local state = require("poste.state")
  local env_name = state.current_env or state.config.default_env
  local env_data = data[env_name]
  if type(env_data) ~= "table" then return {} end

  local vars = {}
  for k, _ in pairs(env_data) do
    vars[k] = true
  end
  return vars
end

--- Collect request names (### headers) from the buffer.
local function collect_request_names(buf)
  local names = {}
  local seen = {}
  local line_count = vim.api.nvim_buf_line_count(buf)
  for i = 1, line_count do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if line then
      local name = line:match("^%s*###%s+(.+)")
      if name then
        name = vim.trim(name)
        if name ~= "" and not seen[name] then
          seen[name] = true
          table.insert(names, name)
        end
      end
    end
  end
  return names
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

--- Detect the completion context from the line up to cursor.
--- Returns: context_type, extra_data
--- Context types:
---   "method"           - empty line, expecting HTTP method
---   "method_or_header" - single word, could be method or header name
---   "header_value"     - after "Header:" (extra_data = header name)
---   "variable"         - inside {{...}} (extra_data = text after {{)
---   nil                - no completion
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

  -- Check for variable reference: inside {{...}}
  -- Find last {{ and }} before cursor using reverse search
  local rev = line_before_cursor:reverse()
  local last_open = rev:find("{{")
  local last_close = rev:find("}}")
  if last_open and (not last_close or last_close > last_open) then
    -- Cursor is inside an unclosed {{...}}
    -- Convert reversed index to original: text after {{ starts at (#s - last_open + 2)
    local after_open = line_before_cursor:sub(#line_before_cursor - last_open + 2)
    return "variable", after_open
  end

  -- Check for URL (contains ://) → no completion
  if line_before_cursor:find("://") then
    return nil, nil
  end

  -- Check if this line already has a complete HTTP method followed by space
  -- e.g., "GET https://..." or "POST http://..."
  local method_match = trimmed:match("^(%u+)%s")
  if method_match then
    for _, method in ipairs(http_methods) do
      if method_match == method then
        -- Already have method, rest is URL → no completion
        return nil, nil
      end
    end
  end

  -- Check if we're in header value context (after colon)
  -- Match "Header-Name:" or "Header-Name: " (colon at end or colon+space)
  local header_name = line_before_cursor:match("^%s*([A-Za-z][A-Za-z0-9%-]*):")
  if header_name then
    return "header_value", header_name
  end

  -- No colon — single word being typed → method or header name
  if not line_before_cursor:find("%s") then
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

--- Get completion items for a given line context.
--- Shared between both engines.
local function get_items_for_context(line_before_cursor)
  -- LSP CompletionItemKind constants
  local KIND_KEYWORD = 14   -- Keyword
  local KIND_PROPERTY = 10  -- Property
  local KIND_VALUE = 12     -- Value
  local KIND_VARIABLE = 6   -- Variable
  local KIND_REFERENCE = 18 -- Reference

  local ctx, extra = detect_context(line_before_cursor)
  local items = {}

  if ctx == "variable" then
    -- Variable reference context: {{...}}
    local after_open = extra or ""
    local is_magic = after_open:sub(1, 1) == "$"
    local buf = vim.api.nvim_get_current_buf()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

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
    local all_vars = {}
    local file_vars = collect_file_vars(buf)
    local req_vars = collect_request_vars(buf, cursor_line)
    local env_vars = collect_env_vars()

    for name in pairs(req_vars) do
      all_vars[name] = "request"
    end
    for name in pairs(file_vars) do
      if not all_vars[name] then
        all_vars[name] = "file"
      end
    end
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

    -- Request name references (for {{RequestName.response.body}})
    local req_names = collect_request_names(buf)
    for _, name in ipairs(req_names) do
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

---------------------------------------------------------------------------
-- blink.cmp source (module-level interface)
---------------------------------------------------------------------------
-- blink.cmp calls require("poste.completion").new() to create a source.

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
  local col = (ctx.cursor and ctx.cursor[2]) or 0
  local line_before_cursor = line:sub(1, col)

  local items = get_items_for_context(line_before_cursor)

  callback({
    items = items,
    is_incomplete_forward = true,
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

  local ctx, extra = detect_context(line_before_cursor)
  local items = {}

  -- nvim-cmp kind IDs
  local Kind = require("cmp").lsp.CompletionItemKind or {}
  local KIND_KEYWORD = Kind.Keyword or Kind.Text or 1
  local KIND_PROPERTY = Kind.Property or Kind.Field or 2
  local KIND_VALUE = Kind.Value or Kind.EnumMember or 3
  local KIND_VARIABLE = Kind.Variable or 4
  local KIND_REFERENCE = Kind.Reference or 5

  if ctx == "variable" then
    -- Reuse the shared get_items_for_context for variable completions
    items = get_items_for_context(line_before_cursor)
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
    module = "poste.completion",
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

return M
