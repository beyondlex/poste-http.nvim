--- Response formatters: body, headers, verbose views + filetype detection.
--- Also includes Redis extmark-based syntax coloring.
local state = require("poste.state")

local redis_ns = vim.api.nvim_create_namespace("poste_redis")

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
  elseif value == nil then
    return "null"
  else
    return tostring(value)
  end
end

--- Try to pretty-print JSON body; return as-is if not JSON or if already formatted
local function pretty_body(body, content_type)
  if not body or body == "" then return "" end

  -- If body already has newlines, it's already formatted (curl does this)
  if body:find("\n") then
    return body
  end

  -- Only try to format compact JSON
  if content_type and content_type:find("json") then
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
-- Body view: the main response content
---------------------------------------------------------------------------

function M.format_body(r)
  -- Redis protocol: parse structured JSON and render with type-specific formatting
  if r.protocol == "redis" then
    return format_redis_body(r)
  end

  local body = pretty_body(r.body, r.content_type)
  return split_lines(body)
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
-- Verbose view: markdown-friendly layout with full details
---------------------------------------------------------------------------

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

function M.format_verbose(r)
  local lines = {}

  -- Error responses get a dedicated layout
  if r.protocol == "error" then
    table.insert(lines, "# Error")
    table.insert(lines, "")
    table.insert(lines, "**Request**: " .. (r.metadata and r.metadata.request_line or r.url or ""))
    table.insert(lines, "**Env**: " .. (r.metadata and r.metadata.env or ""))
    table.insert(lines, "**Exit code**: " .. (r.metadata and r.metadata.exit_code or ""))
    table.insert(lines, "**Status**: " .. (r.status_text or ""))

    -- Request headers
    if r.headers and #r.headers > 0 then
      table.insert(lines, "")
      table.insert(lines, "## Request Headers")
      table.insert(lines, "")
      for _, h in ipairs(r.headers) do
        table.insert(lines, string.format("**%s**: %s", h[1], h[2]))
      end
    end

    if r.body and r.body ~= "" then
      table.insert(lines, "")
      table.insert(lines, "## Details")
      table.insert(lines, "")
      table.insert(lines, "```")
      for l in r.body:gmatch("[^\r\n]+") do
        table.insert(lines, l)
      end
      table.insert(lines, "```")
    end

    return lines
  end

  -- HTTP protocol
  if r.protocol == "http" then
    local method = (r.metadata and r.metadata.method) or "GET"
    local duration = string.format("%.2f ms", r.latency_ms or 0)
    local timestamp = (r.metadata and r.metadata.timestamp) or ""
    local env_name = (r.metadata and r.metadata.env) or state.current_env

    -- Summary header
    table.insert(lines, string.format("# %s %s", method, r.url or ""))
    table.insert(lines, "")
    table.insert(lines, string.format("**%s** | %s | %s | %s",
      r.status_text or "", duration, env_name, timestamp))
    table.insert(lines, "")

    -- Request section
    table.insert(lines, "## Request")
    table.insert(lines, "")

    -- Request headers
    local req_headers = r.metadata and r.metadata.request_headers
    if req_headers and req_headers ~= "" then
      table.insert(lines, "### Headers")
      table.insert(lines, "")
      for l in req_headers:gmatch("[^\r\n]+") do
        -- Parse "Key: Value" format and convert to **Key**: Value
        local key, value = l:match("^([^:]+):%s*(.+)$")
        if key and value then
          table.insert(lines, string.format("**%s**: %s", key, value))
        else
          table.insert(lines, l)
        end
      end
      table.insert(lines, "")
    end

    -- Request body (payload)
    local req_body = r.metadata and r.metadata.request_body
    if req_body and req_body ~= "" then
      table.insert(lines, "### Body")
      table.insert(lines, "")
      -- Determine language for syntax highlighting
      local lang = ""
      if req_headers and req_headers:lower():find("application/json") then
        lang = "json"
      elseif req_headers and req_headers:lower():find("application/xml") then
        lang = "xml"
      end
      table.insert(lines, "```" .. lang)
      for l in req_body:gmatch("[^\r\n]+") do
        table.insert(lines, l)
      end
      table.insert(lines, "```")
      table.insert(lines, "")
    end

    -- Separator between Request and Response
    table.insert(lines, "---")
    table.insert(lines, "")

    -- Response section
    table.insert(lines, "## Response")
    table.insert(lines, "")

    -- Response headers
    if r.headers and #r.headers > 0 then
      table.insert(lines, "### Headers")
      table.insert(lines, "")
      for _, h in ipairs(r.headers) do
        table.insert(lines, string.format("**%s**: %s", h[1], h[2]))
      end
      table.insert(lines, "")
    end

    -- Response body
    if r.body and r.body ~= "" then
      table.insert(lines, "### Body")
      table.insert(lines, "")
      -- Determine language for syntax highlighting
      local lang = ""
      if (r.content_type or ""):find("json") then
        lang = "json"
      elseif (r.content_type or ""):find("html") then
        lang = "html"
      elseif (r.content_type or ""):find("xml") then
        lang = "xml"
      end
      -- Pretty-print JSON body
      local body = pretty_body(r.body, r.content_type)
      table.insert(lines, "```" .. lang)
      for l in body:gmatch("[^\r\n]+") do
        table.insert(lines, l)
      end
      table.insert(lines, "```")
      table.insert(lines, "")
    end

    -- Connection info (extracted from curl trace)
    local verbose = r.metadata and r.metadata.verbose
    if verbose and verbose ~= "" then
      local conn_info = extract_connection_info(verbose)
      if next(conn_info) then
        table.insert(lines, "---")
        table.insert(lines, "")
        table.insert(lines, "## Connection")
        table.insert(lines, "")
        if conn_info.proxy then
          table.insert(lines, "**Proxy**: " .. conn_info.proxy)
        end
        if conn_info.tls then
          table.insert(lines, "**TLS**: " .. conn_info.tls)
        end
        if conn_info.http then
          table.insert(lines, "**HTTP**: " .. conn_info.http)
        end
        if conn_info.exit then
          table.insert(lines, "**Exit Code**: " .. conn_info.exit)
        end
      end
    end

    return lines
  end

  -- Non-HTTP protocols: generic layout
  table.insert(lines, "# Request")
  table.insert(lines, "")
  table.insert(lines, "| Field | Value |")
  table.insert(lines, "|-------|-------|")
  table.insert(lines, "| **Protocol** | " .. (r.protocol or "unknown") .. " |")
  table.insert(lines, "| **URL** | " .. (r.url or "") .. " |")
  table.insert(lines, "| **Latency** | " .. (r.latency_ms or 0) .. "ms |")

  if r.metadata then
    if r.metadata.method then
      table.insert(lines, "| **Method** | " .. r.metadata.method .. " |")
    end
    if r.metadata.command then
      table.insert(lines, "| **Command** | " .. r.metadata.command .. " |")
    end
  end

  table.insert(lines, "")
  table.insert(lines, "## Response")
  table.insert(lines, "")
  table.insert(lines, "| Field | Value |")
  table.insert(lines, "|-------|-------|")
  table.insert(lines, "| **Status** | " .. (r.status_text or "") .. " |")
  table.insert(lines, "| **Content-Type** | " .. (r.content_type or "") .. " |")
  table.insert(lines, "| **Body size** | " .. #(r.body or "") .. " bytes |")

  if r.metadata and r.metadata.type then
    table.insert(lines, "| **Type** | " .. r.metadata.type .. " |")
  end

  return lines
end

return M
