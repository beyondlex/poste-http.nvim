--- Response formatters: body, headers, verbose views + filetype detection.
--- Also includes Redis extmark-based syntax coloring.
local state = require("poste.state")

local redis_ns = vim.api.nvim_create_namespace("poste_redis")
local file_link_ns = vim.api.nvim_create_namespace("poste_file_link")

local M = {}

---------------------------------------------------------------------------
-- Content-type → filetype mapping (for treesitter syntax highlighting)
---------------------------------------------------------------------------
local content_type_map = {
  ["application/json"] = "json",
  ["application/ld+json"] = "json",
  ["application/vnd.api+json"] = "json",
  ["text/html"] = "html",
  ["application/xhtml+xml"] = "html",
  ["text/xml"] = "xml",
  ["application/xml"] = "xml",
  ["application/rss+xml"] = "xml",
  ["application/atom+xml"] = "xml",
  ["text/javascript"] = "javascript",
  ["application/javascript"] = "javascript",
  ["text/css"] = "css",
  ["text/markdown"] = "markdown",
  ["text/yaml"] = "yaml",
  ["application/x-yaml"] = "yaml",
  ["text/plain"] = "text",
}

function M.detect_filetype(content_type)
  if not content_type or content_type == "" then
    return "text"
  end
  -- Strip charset and other parameters: "application/json; charset=utf-8" → "application/json"
  local mime = content_type:match("^([^;]+)") or content_type
  mime = vim.trim(mime):lower()
  return content_type_map[mime] or "text"
end

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------

--- Split a string into lines
local function split_lines(str)
  if not str or str == "" then return { "" } end
  -- Normalize \r\n to \n, then strip any remaining \r
  str = str:gsub("\r\n", "\n"):gsub("\r", "")
  -- Remove trailing newline to avoid empty last line
  if str:sub(-1) == "\n" then
    str = str:sub(1, -2)
  end
  local lines = {}
  for line in str:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end
  -- Remove empty last line if present
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return #lines > 0 and lines or { "" }
end

--- Format a byte count as a human-readable string (e.g., "12.0 KB", "1.5 MB").
local function human_size(bytes)
  if not bytes then return "?" end
  local n = tonumber(bytes)
  if not n then return bytes end
  local units = { "B", "KB", "MB", "GB", "TB" }
  local idx = 1
  while n >= 1024 and idx < #units do
    n = n / 1024
    idx = idx + 1
  end
  if idx == 1 then
    return string.format("%d %s", n, units[idx])
  else
    return string.format("%.1f %s", n, units[idx])
  end
end

--- Return true if the body is too large to display inline.
local function is_large_body(body)
  if not body or type(body) ~= "string" then return false end
  local cfg = state.config or {}
  local max_bytes = tonumber(cfg.max_body_bytes) or 100 * 1024
  local max_lines = tonumber(cfg.max_body_lines) or 500
  if #body > max_bytes then return true end
  local line_count = 1
  for _ in body:gmatch("\n") do line_count = line_count + 1 end
  if line_count >= max_lines then return true end
  return false
end

--- Save body to a temp file and return truncated preview lines with a file link.
local function save_body_to_file(body, content_type, r)
  local cfg = state.config or {}
  local preview_lines = tonumber(cfg.body_preview_lines) or 20
  local cache_dir = cfg.response_cache_dir or vim.fn.stdpath("cache") .. "/poste_res"

  -- Ensure cache directory exists
  vim.fn.mkdir(cache_dir, "p")

  -- Save to file with timestamp-based name to avoid conflicts
  local tmp_file = string.format("%s/res_%s.txt", cache_dir, vim.fn.strftime("%Y%m%d_%H%M%S_%6N"))
  local f = io.open(tmp_file, "w")
  if not f then return nil end
  f:write(body)
  f:close()

  -- Store in response metadata for gd keymap
  if not r.metadata then r.metadata = {} end
  r.metadata.file_path = tmp_file
  r.metadata.file_size = #body
  r.metadata.file_content_type = content_type

  -- Build truncated preview
  local lines = split_lines(body)
  local truncated = {}
  local preview_count = math.min(preview_lines, #lines)
  for i = 1, preview_count do
    table.insert(truncated, lines[i])
  end
  local remaining = #lines - preview_count
  table.insert(truncated, string.format("...  (%d more lines, %s total)", remaining, human_size(#body)))
  table.insert(truncated, string.format("  File:        %s", tmp_file))

  return truncated
end

--- Simple JSON pretty-printer
local function json_pretty(value, indent)
  indent = indent or 0
  local indent_str = string.rep("  ", indent)
  local indent_str_inner = string.rep("  ", indent + 1)

  if type(value) == "table" then
    -- Check if it's an array (sequential integer keys)
    local is_array = true
    local max_idx = 0
    for k, _ in pairs(value) do
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
        is_array = false
        break
      end
      max_idx = math.max(max_idx, k)
    end
    is_array = is_array and max_idx == #value

    if is_array then
      if #value == 0 then
        return "[]"
      end
      local items = {}
      for _, v in ipairs(value) do
        table.insert(items, indent_str_inner .. json_pretty(v, indent + 1))
      end
      return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent_str .. "]"
    else
      -- Object
      local keys = {}
      for k in pairs(value) do
        table.insert(keys, k)
      end
      table.sort(keys)
      if #keys == 0 then
        return "{}"
      end
      local items = {}
      for _, k in ipairs(keys) do
        local v = value[k]
        table.insert(items, indent_str_inner .. '"' .. k .. '": ' .. json_pretty(v, indent + 1))
      end
      return "{\n" .. table.concat(items, ",\n") .. "\n" .. indent_str .. "}"
    end
  elseif type(value) == "string" then
    return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
  elseif type(value) == "number" then
    return tostring(value)
  elseif type(value) == "boolean" then
    return value and "true" or "false"
  elseif value == nil or value == vim.NIL then
    return "null"
  else
    return tostring(value)
  end
end

--- Try to pretty-print JSON body; return as-is if not JSON or if already formatted
local function pretty_body(body, content_type)
  if not body or body == "" then return "" end

  -- Try to format compact JSON: decode unicode escapes, pretty-print
  if not body:find("\n") and (not content_type or content_type:find("json") or body:sub(1, 1) == "{" or body:sub(1, 1) == "[") then
    local ok, decoded = pcall(vim.json.decode, body)
    if ok and decoded then
      local pretty = json_pretty(decoded)
      return pretty
    end
  end
  return body
end

---------------------------------------------------------------------------
-- Redis body renderer
---------------------------------------------------------------------------

local function format_redis_body(r)
  local lines = {}

  -- Parse the structured JSON body
  local ok, data = pcall(vim.json.decode, r.body)
  if not ok or type(data) ~= "table" then
    return split_lines(r.body or "(empty)")
  end

  local rtype = data.type or "unknown"
  local value = data.value

  -- Command echo
  if r.metadata and r.metadata.command then
    table.insert(lines, "✓ " .. r.metadata.command)
    table.insert(lines, "")
  end

  -- Type label
  table.insert(lines, string.format("[%s]", rtype))
  table.insert(lines, "")

  -- Type-specific rendering
  if rtype == "nil" then
    table.insert(lines, "(nil)")

  elseif rtype == "integer" then
    table.insert(lines, tostring(value))

  elseif rtype == "string" then
    if data.parsed then
      -- Pretty-print JSON using vim.json with indentation
      local pretty = vim.json.encode(data.parsed, { indent = "  " })
      for _, line in ipairs(split_lines(pretty)) do
        table.insert(lines, line)
      end
    else
      table.insert(lines, '"' .. tostring(value) .. '"')
    end

  elseif rtype == "hash" and type(value) == "table" then
    local max_key_len = 0
    local keys = {}
    for k, _ in pairs(value) do
      table.insert(keys, k)
      max_key_len = math.max(max_key_len, #tostring(k))
    end
    table.sort(keys)

    for _, k in ipairs(keys) do
      local v = value[k]
      local v_str = type(v) == "string" and ('"' .. v .. '"') or tostring(v)
      table.insert(lines, string.format("%-" .. max_key_len .. "s │ %s", k, v_str))
    end

  elseif rtype == "list" and type(value) == "table" then
    local max_idx_len = #tostring(math.max(0, #value - 1))
    for i, v in ipairs(value) do
      local v_str = type(v) == "string" and ('"' .. v .. '"') or tostring(v)
      table.insert(lines, string.format("%-" .. max_idx_len .. "d │ %s", i - 1, v_str))
    end

  elseif rtype == "set" and type(value) == "table" then
    for _, v in ipairs(value) do
      table.insert(lines, "• " .. (type(v) == "string" and v or tostring(v)))
    end

  elseif rtype == "zset" and type(value) == "table" and #value > 0 then
    table.insert(lines, "score │ member")
    table.insert(lines, "──────┼────────")
    table.sort(value, function(a, b) return (a.score or 0) > (b.score or 0) end)
    for _, item in ipairs(value) do
      table.insert(lines, string.format("%-5.1f │ %s", item.score or 0, item.member or ""))
    end

  elseif rtype == "stream" then
    table.insert(lines, "(stream rendering not yet implemented)")

  else
    table.insert(lines, vim.inspect(value))
  end

  table.insert(lines, "")

  -- Metadata footer
  if r.latency_ms then
    table.insert(lines, string.format("time: %dms", r.latency_ms))
  end
  if r.url then
    table.insert(lines, string.format("db: %s", r.url))
  end

  return lines
end

---------------------------------------------------------------------------
-- URL-encoded form body helper
---------------------------------------------------------------------------

--- Format urlencoded form data (application/x-www-form-urlencoded) as key-value lines.
--- Returns a list of lines like "  key: value".
local function format_urlencoded_body(body)
  if not body or body == "" then return nil end
  local lines = {}
  -- Parse key=value pairs separated by &
  for pair in body:gmatch("[^&]+") do
    local key, val = pair:match("^([^=]+)=(.*)$")
    if key and val ~= nil then
      -- Decode URL-encoded values
      val = val:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
      val = val:gsub("+", " ")
      table.insert(lines, string.format("  %s: %s", key, val))
    end
  end
  if #lines == 0 then return nil end
  return lines
end

local request_ns = vim.api.nvim_create_namespace("poste_request")

--- Apply highlights to the Request tab: key:value lines get key in bold, value in gray.
function M.apply_request_highlights(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, request_ns, 0, -1)
  for i, line in ipairs(lines) do
    local row = i - 1
if line:match("^[^*#][^:]*:%s") then
      local colon = line:find(":", 3)
      if not colon then break end
      if colon then
        vim.api.nvim_buf_set_extmark(buf, request_ns, row, 0, {
          end_row = row, end_col = colon + 1,
          hl_group = "PosteRequestKey", priority = 100,
        })
        local val_start = colon + 2
        if val_start <= #line then
          vim.api.nvim_buf_set_extmark(buf, request_ns, row, val_start - 1, {
            end_row = row, end_col = #line,
            hl_group = "PosteRequestValue", priority = 100,
          })
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Body view: the main response content
---------------------------------------------------------------------------

function M.format_body(r)
  -- Redis protocol: parse structured JSON and render with type-specific formatting
  if r.protocol == "redis" then
    return format_redis_body(r)
  end

  -- Binary file response: show file info instead of mangled raw content
  if r.metadata and r.metadata.file_path and r.metadata.file_content_type and not r.metadata.file_content_type:find("text") and not r.metadata.file_content_type:find("json") and not r.metadata.file_content_type:find("xml") and not r.metadata.file_content_type:find("html") then
    local lines = {}
    table.insert(lines, "▸ Binary File Response")
    table.insert(lines, "")
    table.insert(lines, string.format("  Path:         %s", r.metadata.file_path))
    table.insert(lines, string.format("  Size:         %s  (%s bytes)", human_size(r.metadata.file_size), r.metadata.file_size or "?"))
    table.insert(lines, string.format("  Content-Type: %s", r.metadata.file_content_type or r.content_type or "?"))
    table.insert(lines, "")
    table.insert(lines, string.format("  Open file:    %s", r.metadata.file_path))
    return lines
  end

  -- Large text response: truncate and save to file
  if is_large_body(r.body) then
    return save_body_to_file(r.body, r.content_type, r)
  end

  local body = pretty_body(r.body, r.content_type)
  return split_lines(body)
end

--- Apply extmark highlights on file path portions of "Open file:" and
--- "File:" lines.  Only the path itself is rendered as a blue, underlined link.
function M.apply_file_link_highlight(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, file_link_ns, 0, -1)
  for i, line in ipairs(lines) do
    -- Match both "  Open file:   /path" and "  File:        /path"
    local prefix
    if line:match("^  Open file:%s+") then
      prefix = line:match("^  Open file:%s+")
    elseif line:match("^  File:%s+") then
      prefix = line:match("^  File:%s+")
    end
    if prefix then
      local col = #prefix
      if col < #line then
        local row = i - 1
        vim.api.nvim_buf_set_extmark(buf, file_link_ns, row, col, {
          end_row = row, end_col = #line,
          hl_group = "PosteFileLink",
          priority = 150,
        })
        return
      end
    end
  end
end

---------------------------------------------------------------------------
-- Redis extmark highlighting
---------------------------------------------------------------------------

--- Apply extmark-based coloring to Redis response buffer
function M.apply_redis_highlights(buf, lines, rtype)
  vim.api.nvim_buf_clear_namespace(buf, redis_ns, 0, -1)

  local hl_map = {
    string = "PosteRedisString",
    hash = "PosteRedisHash",
    list = "PosteRedisList",
    set = "PosteRedisSet",
    zset = "PosteRedisZset",
    stream = "PosteRedisStream",
    ["nil"] = "PosteRedisNil",
    integer = "PosteRedisString",
  }

  local type_hl = hl_map[rtype] or "PosteRedisMeta"

  for i, line in ipairs(lines) do
    local row = i - 1

    -- Type label line
    if line:match("^%[.+%]$") then
      vim.api.nvim_buf_set_extmark(buf, redis_ns, row, 0, {
        end_row = row,
        end_col = #line,
        hl_group = type_hl,
        priority = 100,
      })

    -- Command echo
    elseif line:match("^✓") then
      vim.api.nvim_buf_set_extmark(buf, redis_ns, row, 0, {
        end_row = row,
        end_col = #line,
        hl_group = "PosteRedisOk",
        priority = 100,
      })

    -- Metadata footer
    elseif line:match("^(time:|db:)") then
      vim.api.nvim_buf_set_extmark(buf, redis_ns, row, 0, {
        end_row = row,
        end_col = #line,
        hl_group = "PosteRedisMeta",
        priority = 100,
      })

    -- Hash field names (before │)
    elseif line:match("│") and rtype == "hash" then
      local sep_pos = line:find("│")
      if sep_pos then
        vim.api.nvim_buf_set_extmark(buf, redis_ns, row, 0, {
          end_row = row,
          end_col = sep_pos - 1,
          hl_group = "PosteRedisField",
          priority = 100,
        })
      end

    -- List indices (before │)
    elseif line:match("^%d+%s*│") and rtype == "list" then
      local sep_pos = line:find("│")
      if sep_pos then
        vim.api.nvim_buf_set_extmark(buf, redis_ns, row, 0, {
          end_row = row,
          end_col = sep_pos - 1,
          hl_group = "PosteRedisIndex",
          priority = 100,
        })
      end

    -- Zset scores (before │)
    elseif line:match("^[%d%.]+%s*│") and rtype == "zset" then
      local sep_pos = line:find("│")
      if sep_pos then
        vim.api.nvim_buf_set_extmark(buf, redis_ns, row, 0, {
          end_row = row,
          end_col = sep_pos - 1,
          hl_group = "PosteRedisScore",
          priority = 100,
        })
      end
    end
  end
end

---------------------------------------------------------------------------
-- Headers view: protocol-aware metadata display
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Verbose view: redesigned with General/Request/Response/Connection sections
---------------------------------------------------------------------------

--- Format status text from a response object.
local function format_status_text(r)
  local status_text = r.status_text
  if not status_text or status_text == "" then
    local codes = {
      [200] = "200 OK", [201] = "201 Created", [204] = "204 No Content",
      [301] = "301 Moved", [302] = "302 Found", [304] = "304 Not Modified",
      [400] = "400 Bad Request", [401] = "401 Unauthorized", [403] = "403 Forbidden",
      [404] = "404 Not Found", [405] = "405 Method Not Allowed", [408] = "408 Timeout",
      [409] = "409 Conflict", [422] = "422 Unprocessable", [429] = "429 Too Many",
      [500] = "500 Internal Error", [502] = "502 Bad Gateway", [503] = "503 Unavailable",
      [504] = "504 Gateway Timeout",
    }
    status_text = codes[r.status] or (tostring(r.status) .. " Unknown")
  end
  return status_text
end

--- Format elapsed milliseconds.
local function format_elapsed(ms, pending_start_hires)
  local elapsed_ms = ms
  if not elapsed_ms and pending_start_hires then
    local ns = (vim.uv or vim.loop).hrtime() - pending_start_hires
    elapsed_ms = ns / 1e6
  end
  if elapsed_ms then
    if elapsed_ms >= 1000 then
      return string.format("%.2f s", elapsed_ms / 1000)
    end
    return string.format("%.2f ms", elapsed_ms)
  end
  return "-"
end

--- Extract connection info from curl verbose trace
local function extract_connection_info(verbose)
  if not verbose or verbose == "" then
    return {}
  end

  local info = {}
  local lines_list = {}
  for l in verbose:gmatch("[^\r\n]+") do
    table.insert(lines_list, l)
  end

  -- Find proxy info
  for _, l in ipairs(lines_list) do
    if l:match("Uses proxy env variable") then
      local proxy = l:match("'([^']+)'")
      if proxy then info.proxy = proxy end
      break
    end
  end

  -- Find TLS info
  for _, l in ipairs(lines_list) do
    if l:match("SSL connection using") then
      info.tls = l:gsub("^%*%s*", "")
      break
    end
  end

  -- Find HTTP version
  for _, l in ipairs(lines_list) do
    if l:match("HTTP/%d") then
      local http_ver = l:match("HTTP/(%d[.%d]*)")
      if http_ver then info.http = "HTTP/" .. http_ver end
      break
    end
  end

  -- Find exit code
  for _, l in ipairs(lines_list) do
    if l:match("Connection #%d+ left intact") then
      info.exit = "0"
      break
    end
  end

  return info
end

--- Unified verbose view: called with either a response object, a pending
--- request table, or both.  Response-dependent sections (Status Code,
--- Response Headers/Body, Connection) are shown only when `r` is provided.
function M.format_verbose(r, pending)
  local lines = {}

  -- Merge data from response (r) and/or pending request
  local method = ""
  local url = ""
  local request_headers = ""
  local request_body = ""
  local timestamp = ""
  local env = ""
  local elapsed_ms = nil

  if pending then
    method = pending.method or ""
    url = pending.url or ""
    request_headers = pending.headers_str or ""
    request_body = pending.body or ""
    timestamp = pending.timestamp or ""
    env = pending.env ~= "" and pending.env or state.current_env
  end
  if r then
    method = (r.metadata and r.metadata.method ~= "") and r.metadata.method or method
    url = (r.url and r.url ~= "") and r.url or url
    request_headers = (r.metadata and r.metadata.request_headers and r.metadata.request_headers ~= "") and r.metadata.request_headers or request_headers
    request_body = (r.metadata and r.metadata.request_body and r.metadata.request_body ~= "") and r.metadata.request_body or request_body
    timestamp = (r.metadata and r.metadata.timestamp and r.metadata.timestamp ~= "") and r.metadata.timestamp or timestamp
    env = (r.metadata and r.metadata.env and r.metadata.env ~= "") and r.metadata.env or env
    if env == "" then env = state.current_env end
    elapsed_ms = r.latency_ms
  end

  -- Compute elapsed for pending
  if not elapsed_ms and pending and pending.start_hires then
    elapsed_ms = ((vim.uv or vim.loop).hrtime() - pending.start_hires) / 1e6
  end

  -- URL at top (with padding)
  table.insert(lines, "")
  table.insert(lines, "  " .. (url ~= "" and url or "(no URL)"))
  table.insert(lines, string.rep("─", 60))

  -- ▸ General
  table.insert(lines, "▸ General")
  table.insert(lines, "  Request Method: " .. method)
  if r then
    local st = format_status_text(r)
    table.insert(lines, "  Status Code: " .. st)
  end
  table.insert(lines, "  Request Time: " .. (timestamp ~= "" and timestamp or "-"))
  table.insert(lines, "  Elapsed: " .. format_elapsed(elapsed_ms))
  table.insert(lines, "  Env: " .. (env ~= "" and env or "-"))
  table.insert(lines, string.rep("─", 60))

  -- ▸ Request Headers
  if request_headers ~= "" then
    table.insert(lines, "▸ Request Headers")
    for l in request_headers:gmatch("[^\r\n]+") do
      local k, v = l:match("^([^:]+):%s*(.+)$")
      if k and v then
        table.insert(lines, "  " .. k .. ": " .. v)
      else
        table.insert(lines, "  " .. l)
      end
    end
  end

  -- ▸ Request Body
  if request_body ~= "" then
    table.insert(lines, "▸ Request Body")
    local ct = ""
    for l in request_headers:gmatch("[^\r\n]+") do
      local k, v = l:match("^([^:]+):%s*(.+)$")
      if k and k:lower() == "content-type" then ct = v end
    end
    local ct_lower = ct:lower()
    if ct_lower:find("multipart/form%-data") then
      local display_body = M.condense_multipart_body(request_body, ct)
      for l in display_body:gmatch("[^\r\n]+") do
        table.insert(lines, "  " .. l)
      end
    elseif ct_lower:find("application/x%-www%-form%-urlencoded") then
      local form_lines = format_urlencoded_body(request_body)
      if form_lines then
        for _, fl in ipairs(form_lines) do
          table.insert(lines, fl)
        end
      else
        table.insert(lines, "  " .. request_body)
      end
    else
      for l in request_body:gmatch("[^\r\n]+") do
        table.insert(lines, "  " .. l)
      end
    end
  end

  -- ─── Response sections (only when response is available) ────────
  if r then
    -- Error protocol: compact error layout
    if r.protocol == "error" then
      table.insert(lines, string.rep("─", 60))
      if r.body and r.body ~= "" then
        table.insert(lines, "▸ Details")
        table.insert(lines, "  " .. r.body:gsub("\n", "\n  "))
      end
      return lines
    end

    table.insert(lines, string.rep("─", 60))

    -- ▸ Response Headers
    if r.headers and #r.headers > 0 then
      table.insert(lines, "▸ Response Headers")
      for _, h in ipairs(r.headers) do
        table.insert(lines, "  " .. h[1] .. ": " .. h[2])
      end
    end

    -- ▸ Response Body
    if r.body and r.body ~= "" then
      table.insert(lines, "▸ Response Body")
      if r.metadata and r.metadata.file_path then
        -- File saved by Rust executor (binary or large text)
        table.insert(lines, string.format("  Path:         %s", r.metadata.file_path))
        table.insert(lines, string.format("  Size:         %s  (%s bytes)", human_size(r.metadata.file_size), r.metadata.file_size or "?"))
        table.insert(lines, string.format("  Content-Type: %s", r.metadata.file_content_type or r.content_type or "?"))
      elseif is_large_body(r.body) then
        -- Large text body: truncate and save
        local truncated = save_body_to_file(r.body, r.content_type, r)
        for _, tl in ipairs(truncated) do
          table.insert(lines, "  " .. tl)
        end
      else
        local body = pretty_body(r.body, r.content_type)
        for l in body:gmatch("[^\r\n]+") do
          table.insert(lines, "  " .. l)
        end
      end
    end

    -- ▸ Connection
    local verbose = r.metadata and r.metadata.verbose
    if verbose and verbose ~= "" then
      local conn_info = extract_connection_info(verbose)
      if next(conn_info) then
        table.insert(lines, "▸ Connection")
        if conn_info.proxy then
          table.insert(lines, "  Proxy:     " .. conn_info.proxy)
        end
        if conn_info.tls then
          table.insert(lines, "  TLS:       " .. conn_info.tls)
        end
        if conn_info.http then
          table.insert(lines, "  HTTP:      " .. conn_info.http)
        end
        if conn_info.exit then
          table.insert(lines, "  Exit Code: " .. conn_info.exit)
        end
      end
    end
  end

  return lines
end

---------------------------------------------------------------------------
-- Multipart body helpers
---------------------------------------------------------------------------

--- Parse multipart/form-data boundary from Content-Type header.
local function extract_boundary(content_type)
  if not content_type then return nil end
  local b = content_type:match('boundary="([^"]+)"') or content_type:match("boundary=([^;%s]+)")
  return b
end

--- Split multipart body into parts. Each part is a table:
---   { headers = {"Key: Value", ...}, body = "raw content" }
local function parse_multipart_parts(body, boundary)
  if not body or not boundary then return nil end
  -- Normalize line endings so boundary searches are reliable even when
  -- file inclusion content brings in \r\n or mixed line endings.
  body = body:gsub("\r\n", "\n")
  local parts = {}
  local delim = "--" .. boundary
  local start = body:find(delim, 1, true)
  while start do
    local part_end = body:find("\n" .. delim, start + #delim, true)
    if not part_end then break end
    local raw = body:sub(start + #delim + 1, part_end - 1)
    raw = raw:gsub("^\n+", "")
    if raw == "--" then break end

    local header_end = raw:find("\n\n")
    if header_end then
      local hdr_str = raw:sub(1, header_end - 1)
      local body_str = raw:sub(header_end + 2)
      local hdrs = {}
      for h in hdr_str:gmatch("[^\n]+") do
        table.insert(hdrs, h)
      end
      table.insert(parts, { headers = hdrs, body = body_str })
    end
    start = body:find(delim, part_end, true)
  end
  return #parts > 0 and parts or nil
end

--- Condense a raw multipart body for verbose display.
--- Replaces file content with `[file: filename, N bytes]`.
local function condense_multipart_body(body, content_type)
  if not body or not content_type then return body end
  if not content_type:find("multipart/form%-data") then return body end
  local boundary = extract_boundary(content_type)
  if not boundary then return body end

  local delim = "--" .. boundary
  local result = {}
  local pos = 1
  while pos <= #body do
    local dstart = body:find(delim, pos)
    if not dstart then
      table.insert(result, body:sub(pos))
      break
    end
    if dstart > pos then
      table.insert(result, body:sub(pos, dstart - 1))
    end
    local dend = body:find("\n", dstart)
    if not dend then
      table.insert(result, body:sub(dstart))
      break
    end
    local boundary_line = body:sub(dstart, dend - 1):gsub("\r$", "")
    table.insert(result, boundary_line)

    local next_boundary = body:find(delim, dend)
    if not next_boundary then
      table.insert(result, (body:sub(dend + 1):gsub("^\r?\n", "")))
      break
    end
    local raw = body:sub(dend + 1, next_boundary - 1):gsub("^\r?\n", "")

    local hdr_end = raw:find("\r?\n\r?\n")
    if not hdr_end then hdr_end = raw:find("\n\n") end
    if hdr_end then
      local hdr_str = raw:sub(1, hdr_end - 1)
      local body_str = raw:sub(hdr_end + 1):gsub("^\r?\n", "")

      for h in hdr_str:gmatch("[^\r\n]+") do
        table.insert(result, h)
      end
      table.insert(result, "")

      if hdr_str:find('filename="') and hdr_str:find("Content%-Disposition") then
        local fn = hdr_str:match('filename="([^"]*)"') or "unknown"
        table.insert(result, string.format("[file: %s, %d bytes]", fn, #body_str))
      elseif #body_str > 500 then
        table.insert(result, body_str:sub(1, 500) .. "\n... [truncated, " .. #body_str .. " bytes]")
      else
        for l in body_str:gmatch("[^\r\n]+") do
          table.insert(result, l)
        end
      end
    else
      table.insert(result, raw)
    end
    pos = next_boundary
  end
  return table.concat(result, "\n")
end

M.condense_multipart_body = condense_multipart_body

--- Format the request payload for the dedicated Request tab.
--- Shows parsed structure: field name, type (file/text), value/size.
function M.format_request_payload(r)
  local req_body = r.metadata and r.metadata.request_body
  local req_headers = r.metadata and r.metadata.request_headers
  if not req_body or req_body == "" then
    return { "(no request body)" }
  end

  local lines = {}
  local ct = ""
  if req_headers then
    for l in req_headers:gmatch("[^\r\n]+") do
      local k, v = l:match("^([^:]+):%s*(.+)$")
      if k and k:lower() == "content-type" then ct = v end
    end
  end

  -- Multipart form-data: show parsed parts
  if ct:lower():find("multipart/form%-data") then
    local boundary = extract_boundary(ct)
    local parts = boundary and parse_multipart_parts(req_body, boundary)
    if parts then
      table.insert(lines, "## Multipart Form Data (" .. #parts .. " parts)")
      table.insert(lines, "")
      for i, part in ipairs(parts) do
        local disp = ""
        for _, h in ipairs(part.headers) do
          if h:lower():find("content%-disposition") then disp = h end
        end
        local name = disp:match('name="([^"]*)"') or ("part " .. i)
        local fn = disp:match('filename="([^"]*)"')
        if fn then
          table.insert(lines, string.format("%s: [file: %s, %d bytes]", name, fn, #part.body))
        else
          local val = part.body:gsub("[\r\n]+$", "")
          table.insert(lines, string.format("%s: %s", name, val))
        end
        table.insert(lines, "")
      end
      return lines
   end
   -- parsed nil → show raw body excerpt with boundary info
   table.insert(lines, "(multipart form data — parse failed)")
   table.insert(lines, "")
   local boundary_val = extract_boundary(ct)
   if boundary_val then
     table.insert(lines, string.format("  boundary: %s", boundary_val))
   end
   table.insert(lines, "")
   -- Show first ~10 lines of raw body for debugging
   local raw_lines = split_lines(req_body)
   for j = 1, math.min(10, #raw_lines) do
     table.insert(lines, "  " .. raw_lines[j])
   end
   if #raw_lines > 10 then
     table.insert(lines, string.format("  ... (%d more lines)", #raw_lines - 10))
   end
   return lines
 end

-- URL-encoded form data: key-value pairs
 if ct:lower():find("application/x%-www%-form%-urlencoded") then
   local form_lines = format_urlencoded_body(req_body)
   if form_lines then
     table.insert(lines, "## Form Data")
     table.insert(lines, "")
     for _, fl in ipairs(form_lines) do
       table.insert(lines, (fl:gsub("^  ", "")))
     end
     return lines
   end
 end

 -- JSON: pretty-print
 if ct:find("json") or req_body:sub(1, 1) == "{" or req_body:sub(1, 1) == "[" then
    local ok, decoded = pcall(vim.json.decode, req_body)
    if ok and decoded then
      for l in pretty_body(req_body, "application/json"):gmatch("[^\r\n]+") do
        table.insert(lines, l)
      end
      return lines
    end
  end

  -- Fallback: raw body (truncated over 5KB)
  if #req_body > 5120 then
    for l in req_body:sub(1, 5120):gmatch("[^\r\n]+") do
      table.insert(lines, l)
    end
    table.insert(lines, "")
    table.insert(lines, string.format("... [truncated, %d bytes total]", #req_body))
  else
    for l in req_body:gmatch("[^\r\n]+") do
      table.insert(lines, l)
    end
  end
  return lines
end

local verbose_ns = vim.api.nvim_create_namespace("poste_verbose")

function M.apply_verbose_highlights(buf, lines, r)
  vim.api.nvim_buf_clear_namespace(buf, verbose_ns, 0, -1)

  for i, line in ipairs(lines) do
    local row = i - 1

    -- Separator lines (─ repeated)
    if line:match("^[─—]+$") then
      vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, 0, {
        end_row = row, end_col = #line,
        hl_group = "PosteVerboseSeparator", priority = 100,
      })

    -- Section headers: ▸ General, ▸ Request Headers, etc.
    elseif line:match("^▸ ") then
      vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, 0, {
        end_row = row, end_col = #line,
        hl_group = "PosteVerboseSection", priority = 100,
      })

    -- URL line: indent + "http(s)://..." — highlight the query string (?...) in grey
    elseif line:match("^  %w+://") then
      local qmark = line:find("?", 3)
      if qmark then
        vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, qmark - 1, {
          end_row = row, end_col = #line,
          hl_group = "PosteVerboseValue", priority = 100,
        })
      end

    -- Label: value lines in General section or header/body sections
    elseif line:match("^  [^:]+:%s") then
      local colon = line:find(":", 3)
      if colon then
        -- Key (label) — magenta
        vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, 0, {
          end_row = row, end_col = colon + 1,
          hl_group = "PosteVerboseKey", priority = 100,
        })
        -- Value (after colon+space) — grey, unless special-cased below
        local val_start = colon + 2
        if val_start <= #line then
          local value = line:sub(val_start)
          local matched = false

          -- Highlight Request Method value (POST, GET, etc.)
          if line:match("^  Request Method:") then
            local hl_map = {
              GET = "PosteMethodGET", POST = "PosteMethodPOST", PUT = "PosteMethodPUT",
              DELETE = "PosteMethodDELETE", PATCH = "PosteMethodPATCH",
              HEAD = "PosteMethodHEAD", OPTIONS = "PosteMethodOPTIONS",
            }
            local meth = value:match("^(%S+)")
            if meth and hl_map[meth] then
              vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, val_start - 1, {
                end_col = val_start - 1 + #meth,
                hl_group = hl_map[meth], priority = 200,
              })
              matched = true
            end

          -- Highlight Status Code value (200, 404, etc.)
          elseif line:match("^  Status Code:") then
            local code = value:match("^(%d+)")
            if code then
              local sc = tonumber(code)
              local hl_group
              if sc < 300 then hl_group = "PosteStatus2xx"
              elseif sc < 400 then hl_group = "PosteStatus3xx"
              elseif sc < 500 then hl_group = "PosteStatus4xx"
              else hl_group = "PosteStatus5xx"
              end
              vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, val_start - 1, {
                end_col = val_start - 1 + #code,
                hl_group = hl_group, priority = 200,
              })
              matched = true
            end

          -- Highlight Elapsed value (latency)
          elseif line:match("^  Elapsed:") then
            local s, e = value:find("^[%d%.]+")
            if s then
              vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, val_start - 1 + s - 1, {
                end_col = val_start - 1 + e,
                hl_group = "PosteLatency", priority = 200,
              })
              matched = true
            end
          end

          -- Default value highlight (grey) for unmatched label:value lines
          if not matched then
            vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, val_start - 1, {
              end_row = row, end_col = #line,
              hl_group = "PosteVerboseValue", priority = 100,
            })
          end
        end
      end
    end
  end
end

M.pretty_body = pretty_body

--- Clean up old response files from the cache directory.
--- @param max_age_minutes number  Remove files older than this (default: 60 min)
--- @return number cleaned_count  Number of files removed
function M.clean_response_cache(max_age_minutes)
  max_age_minutes = tonumber(max_age_minutes) or 60
  local cache_dir = state.config.response_cache_dir
  if not cache_dir or cache_dir == "" then return 0 end
  if not vim.fn.isdirectory(cache_dir) then return 0 end

  local uv = vim.uv or vim.loop
  local now = uv.gettimeofday() -- milliseconds
  local cutoff_ms = max_age_minutes * 60 * 1000
  local cleaned = 0

  local fd = uv.fs_opendir(cache_dir, nil, 0)
  if not fd then return 0 end

  local entries = uv.fs_readdir(fd)
  while entries and #entries > 0 do
    for _, entry in ipairs(entries) do
      local path = cache_dir .. "/" .. entry.name
      local stat = uv.fs_stat(path)
      if stat and stat.mtime then
        -- mtime is a table with {sec, nsec}
        local mtime_ms = stat.mtime.sec * 1000 + stat.mtime.nsec / 1000000
        if now - mtime_ms > cutoff_ms then
          uv.fs_unlink(path)
          cleaned = cleaned + 1
        end
      end
    end
    entries = uv.fs_readdir(fd)
  end
  uv.fs_closedir(fd)

  -- Remove empty cache directory
  if cleaned > 0 then
    local remaining = uv.fs_readdir(uv.fs_opendir(cache_dir, nil, 0))
    if not remaining or #remaining == 0 then
      uv.fs_rmdir(cache_dir)
    end
  end

  return cleaned
end

return M
