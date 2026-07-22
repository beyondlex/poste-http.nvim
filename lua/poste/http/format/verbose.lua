--- Verbose response rendering.
---
--- Handles the General/Request/Response/Connection sections of the verbose view,
--- including extmark-based syntax highlighting.
--- Extracted from the former format.lua god module.
local state = require("poste.state")

local M = {}

local verbose_ns = vim.api.nvim_create_namespace("poste_verbose")
local json_ns = vim.api.nvim_create_namespace("poste_verbose_json")

-- Content-type → filetype mapping
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
  local mime = content_type:match("^([^;]+)") or content_type
  mime = vim.trim(mime):lower()
  return content_type_map[mime] or "text"
end

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------

local function split_lines(str)
  if not str or str == "" then return {} end
  local lines = {}
  local idx = 1
  while idx <= #str do
    local next_idx = str:find("\n", idx)
    if not next_idx then
      table.insert(lines, str:sub(idx))
      break
    end
    table.insert(lines, str:sub(idx, next_idx - 1))
    idx = next_idx + 1
  end
  return lines
end

local function human_size(bytes)
  if not bytes or bytes == 0 then return "0 B" end
  local units = { "B", "KB", "MB", "GB", "TB" }
  local magnitude = math.floor(math.log(math.abs(bytes), 1024))
  local unit = units[magnitude + 1] or "TB"
  local value = bytes / (1024 ^ magnitude)
  if magnitude == 0 then
    return string.format("%d %s", bytes, unit)
  end
  return string.format("%.1f %s", value, unit)
end

local function is_large_body(body)
  if not body then return false end
  local cfg = state.config or {}
  local max_size = cfg.max_body_preview_size or (1024 * 1024)
  return #body > max_size
end

local function save_body_to_file(body, content_type, r)
  local cfg = state.config or {}
  local preview_lines = tonumber(cfg.body_preview_lines) or 20
  local cache_dir = cfg.response_cache_dir or vim.fn.stdpath("cache") .. "/poste_res"
  vim.fn.mkdir(cache_dir, "p")
  local tmp_file = string.format("%s/res_%s.txt", cache_dir, vim.fn.strftime("%Y%m%d_%H%M%S_%6N"))
  local f = io.open(tmp_file, "w")
  if not f then return nil end
  f:write(body)
  f:close()
  if not r.metadata then r.metadata = {} end
  r.metadata.file_path = tmp_file
  r.metadata.file_size = #body
  r.metadata.file_content_type = content_type
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

local function pretty_body(body, content_type)
  if not body or body == "" then return "" end
  if not body:find("\n") and (not content_type or content_type:find("json") or body:sub(1, 1) == "{" or body:sub(1, 1) == "[") then
    local ok, decoded = pcall(vim.json.decode, body)
    if ok and decoded then
      local json_pretty
      json_pretty = function(value, indent)
        indent = indent or 0
        local indent_str = string.rep("  ", indent)
        local indent_str_inner = string.rep("  ", indent + 1)
        if type(value) == "table" then
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
            if #value == 0 then return "[]" end
            local items = {}
            for _, v in ipairs(value) do
              table.insert(items, indent_str_inner .. json_pretty(v, indent + 1))
            end
            return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent_str .. "]"
          else
            local keys = {}
            for k in pairs(value) do table.insert(keys, k) end
            table.sort(keys)
            if #keys == 0 then return "{}" end
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
      return json_pretty(decoded)
    end
  end
  return body
end

local function format_urlencoded_body(body)
  if not body or body == "" then return nil end
  local lines = {}
  for pair in body:gmatch("[^&]+") do
    local key, val = pair:match("^([^=]+)=(.*)$")
    if key and val ~= nil then
      val = val:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
      val = val:gsub("+", " ")
      table.insert(lines, string.format("  %s: %s", key, val))
    end
  end
  if #lines == 0 then return nil end
  return lines
end

---------------------------------------------------------------------------
-- Verbose formatting
---------------------------------------------------------------------------

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

local function extract_connection_info(verbose)
  if not verbose or verbose == "" then return {} end
  local info = {}
  local lines_list = {}
  for l in verbose:gmatch("[^\r\n]+") do
    table.insert(lines_list, l)
  end
  for _, l in ipairs(lines_list) do
    if l:match("Uses proxy env variable") then
      local proxy = l:match("'([^']+)'")
      if proxy then info.proxy = proxy end
      break
    end
  end
  for _, l in ipairs(lines_list) do
    if l:match("SSL connection using") then
      info.tls = l:gsub("^%*%s*", "")
      break
    end
  end
  for _, l in ipairs(lines_list) do
    if l:match("HTTP/%d") then
      local http_ver = l:match("HTTP/(%d[.%d]*)")
      if http_ver then info.http = "HTTP/" .. http_ver end
      break
    end
  end
  for _, l in ipairs(lines_list) do
    if l:match("Connection #%d+ left intact") then
      info.exit = "0"
      break
    end
  end
  return info
end

--- Unified verbose view: called with either a response object, a pending
--- request table, or both.
function M.format_verbose(r, pending)
  if r and r._cached_verbose then return r._cached_verbose end
  local lines = {}

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

  if not elapsed_ms and pending and pending.start_hires then
    elapsed_ms = ((vim.uv or vim.loop).hrtime() - pending.start_hires) / 1e6
  end

  table.insert(lines, "")
  table.insert(lines, "  " .. (url ~= "" and url or "(no URL)"))
  local request_name = (r and r.request_name) or ""
  if request_name == "" and pending and pending.name and pending.name ~= "" then
    request_name = pending.name
  end
  if request_name ~= "" then
    table.insert(lines, "  " .. request_name)
  end
  table.insert(lines, string.rep("─", 60))

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

  -- Query Parameters section
  if url ~= "" then
    local qmark = url:find("?")
    if qmark then
      local query_string = url:sub(qmark + 1)
      table.insert(lines, "▸ Query Parameters")
      for pair in query_string:gmatch("[^&]+") do
        local key, val = pair:match("^([^=]+)=(.*)$")
        if key then
          val = val:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
          val = val:gsub("+", " ")
          table.insert(lines, string.format("  %s: %s", key, val))
        else
          table.insert(lines, "  " .. pair)
        end
      end
    end
  end

  -- Request Body section (only when there's actual body content)
  if request_body ~= "" then
    local multipart = require("poste.http.format.multipart")
    local verbose_body = multipart.strip_request_preamble(request_body, request_headers)
    if verbose_body ~= "" then
      table.insert(lines, "▸ Request Body")
      local ct = ""
      for l in request_headers:gmatch("[^\r\n]+") do
        local k, v = l:match("^([^:]+):%s*(.+)$")
        if k and k:lower() == "content-type" then ct = v end
      end
      local ct_lower = ct:lower()
      if ct_lower:find("multipart/form%-data") then
        local display_body = multipart.condense_multipart_body(verbose_body, ct)
        for l in display_body:gmatch("[^\r\n]+") do
          table.insert(lines, "  " .. l)
        end
      elseif ct_lower:find("application/x%-www%-form%-urlencoded") then
        local form_lines = format_urlencoded_body(verbose_body)
        if form_lines then
          for _, fl in ipairs(form_lines) do
            table.insert(lines, fl)
          end
        else
          for l in verbose_body:gmatch("[^\r\n]+") do
            table.insert(lines, "  " .. l)
          end
        end
      else
        for l in verbose_body:gmatch("[^\r\n]+") do
          table.insert(lines, "  " .. l)
        end
      end
    end
  end

  if r then
    if r.protocol == "error" then
      table.insert(lines, string.rep("─", 60))
      if r.body and r.body ~= "" then
        table.insert(lines, "▸ Details")
        table.insert(lines, "  " .. r.body:gsub("\n", "\n  "))
      end
      r._cached_verbose = lines
      return lines
    end

    table.insert(lines, string.rep("─", 60))

    if r.headers and #r.headers > 0 then
      table.insert(lines, "▸ Response Headers")
      for _, h in ipairs(r.headers) do
        table.insert(lines, "  " .. h[1] .. ": " .. h[2])
      end
    end

    if r.body and r.body ~= "" then
      table.insert(lines, "▸ Response Body")
      if r.metadata and r.metadata.file_path then
        table.insert(lines, string.format("  Path:         %s", r.metadata.file_path))
        table.insert(lines, string.format("  Size:         %s  (%s bytes)", human_size(r.metadata.file_size), r.metadata.file_size or "?"))
        table.insert(lines, string.format("  Content-Type: %s", r.metadata.file_content_type or r.content_type or "?"))
      elseif is_large_body(r.body) then
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

  if r then r._cached_verbose = lines end
  return lines
end

---------------------------------------------------------------------------
-- Format request payload
---------------------------------------------------------------------------

function M.format_request_payload(r)
  local req_body = r.metadata and r.metadata.request_body
  local req_headers = r.metadata and r.metadata.request_headers
  if not req_body or req_body == "" then
    return { "(no request body)" }
  end

  local multipart = require("poste.http.format.multipart")
  local body_only = multipart.strip_request_preamble(req_body, req_headers)
  if not body_only or body_only == "" then
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

  if ct:lower():find("multipart/form%-data") then
    local boundary = multipart.extract_boundary(ct)
    local parts = boundary and multipart.parse_multipart_parts(body_only, boundary)
    if parts then
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
      end
      return lines
    end
    table.insert(lines, "(multipart form data — parse failed)")
    local boundary_val = multipart.extract_boundary(ct)
    if boundary_val then
      table.insert(lines, string.format("  boundary: %s", boundary_val))
    end
    local raw_lines = split_lines(body_only)
    for j = 1, math.min(10, #raw_lines) do
      table.insert(lines, "  " .. raw_lines[j])
    end
    if #raw_lines > 10 then
      table.insert(lines, string.format("  ... (%d more lines)", #raw_lines - 10))
    end
    return lines
  end

  if ct:lower():find("application/x%-www%-form%-urlencoded") then
    local form_lines = format_urlencoded_body(body_only)
    if form_lines then
      for _, fl in ipairs(form_lines) do
        table.insert(lines, (fl:gsub("^  ", "")))
      end
      return lines
    end
  end

  if ct:find("json") or body_only:sub(1, 1) == "{" or body_only:sub(1, 1) == "[" then
    local ok, decoded = pcall(vim.json.decode, body_only)
    if ok and decoded then
      for l in pretty_body(body_only, "application/json"):gmatch("[^\r\n]+") do
        table.insert(lines, l)
      end
      return lines
    end
  end

  if #body_only > 5120 then
    for l in body_only:sub(1, 5120):gmatch("[^\r\n]+") do
      table.insert(lines, l)
    end
    table.insert(lines, "")
    table.insert(lines, string.format("... [truncated, %d bytes total]", #body_only))
  else
    for l in body_only:gmatch("[^\r\n]+") do
      table.insert(lines, l)
    end
  end
  return lines
end

---------------------------------------------------------------------------
-- Highlight helpers
---------------------------------------------------------------------------

local function json_byte_span(raw_line)
  local s, e = raw_line:find("^[%s]+")
  s = (s and e) or 0
  local e = #raw_line
  while e > s and raw_line:sub(e, e) == " " do e = e - 1 end
  return s, e
end

local function json_token_hl(ch)
  if ch == '"' then return "PosteJsonString"
  elseif ch == '{' or ch == '}' then return "PosteJsonBraces"
  elseif ch == '[' or ch == ']' then return "PosteJsonBrackets"
  elseif ch == ':' then return "PosteJsonColon"
  elseif ch == ',' then return "PosteJsonComma"
  else return nil
  end
end

local function apply_verbose_json_highlights(buf, lines, body_start, body_end)
  for i = body_start, body_end do
    local line = lines[i]
    local row = i - 1
    local s, e = json_byte_span(line)
    if s >= e then goto continue end

    local in_string = false
    local escape = false
    local j = s + 1
    local token_start = s + 1
    local token_hl = nil

    while j <= e do
      local ch = line:sub(j, j)
      if in_string then
        if escape then
          escape = false
        elseif ch == "\\" then
          escape = true
        elseif ch == '"' then
          in_string = false
        end
      else
        if ch == '"' then
          in_string = true
        end
      end

      local new_hl = in_string and "PosteJsonString" or json_token_hl(ch)
      if not in_string and not new_hl and ch:match("%w") and not token_hl then
        local rest = line:sub(j)
        local hl
        if rest:match("^true") or rest:match("^false") or rest:match("^null") then
          hl = "PosteJsonBoolean"
        else
          hl = "PosteJsonNumber"
        end
        token_hl = hl
        token_start = j
      end

      if token_hl and (in_string or new_hl) then
        local prev_e = j - 1
        if prev_e >= token_start then
          vim.api.nvim_buf_set_extmark(buf, json_ns, row, token_start - 1, {
            end_row = row, end_col = prev_e,
            hl_group = token_hl, priority = 200,
          })
        end
        token_hl = nil
      end

      if new_hl then
        vim.api.nvim_buf_set_extmark(buf, json_ns, row, j - 1, {
          end_row = row, end_col = j,
          hl_group = new_hl, priority = 200,
        })
      end
      j = j + 1
    end

    if token_hl and e >= token_start then
      vim.api.nvim_buf_set_extmark(buf, json_ns, row, token_start - 1, {
        end_row = row, end_col = e,
        hl_group = token_hl, priority = 200,
      })
    end

    ::continue::
  end
end

function M.apply_verbose_highlights(buf, lines, r)
  vim.api.nvim_buf_clear_namespace(buf, verbose_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, json_ns, 0, -1)

  local body_start = nil
  local body_end = nil
  local in_body = false
  local req_body_start = nil
  local req_body_end = nil
  local in_req_body = false
  local in_req_headers = false
  local req_content_type = nil
  for i, line in ipairs(lines) do
    if line == "▸ Response Body" then
      in_body = true
      body_start = i + 1
    elseif line == "▸ Request Body" then
      in_req_body = true
      req_body_start = i + 1
    elseif line == "▸ Request Headers" then
      in_req_headers = true
    elseif line:match("^▸ ") or line:match("^[─—]+$") then
      if in_body then
        body_end = i - 1
        in_body = false
      end
      if in_req_body then
        req_body_end = i - 1
        in_req_body = false
      end
      if in_req_headers then
        in_req_headers = false
      end
    elseif in_req_headers and not req_content_type then
      local k, v = line:match("^  ([^:]+):%s*(.+)$")
      if k and k:lower() == "content-type" then
        req_content_type = v
      end
    end
  end
  if in_body then
    body_end = #lines
  end
  if in_req_body then
    req_body_end = #lines
  end

  for i, line in ipairs(lines) do
    local row = i - 1
    local in_body_section = body_start and i >= body_start and i <= body_end
    local in_req_body_section = req_body_start and i >= req_body_start and i <= req_body_end

    if in_body_section or in_req_body_section then
      goto next
    end

    if line:match("^[─—]+$") then
      vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, 0, {
        end_row = row, end_col = #line,
        hl_group = "PosteVerboseSeparator", priority = 100,
      })
    elseif line:match("^▸ ") then
      vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, 0, {
        end_row = row, end_col = #line,
        hl_group = "PosteVerboseSection", priority = 100,
      })
    elseif line:match("^  %w+://") then
      local qmark = line:find("?", 3)
      if qmark then
        vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, qmark - 1, {
          end_row = row, end_col = #line,
          hl_group = "PosteVerboseValue", priority = 100,
        })
      end
    elseif line:match("^  %S") and not line:match("^  %w+://") and not line:find(":", 3) then
      vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, 0, {
        end_row = row, end_col = #line,
        hl_group = "PosteVerboseValue", priority = 100,
      })
    elseif line:match("^  [^:]+:%s") then
      local colon = line:find(":", 3)
      if colon then
        vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, 0, {
          end_row = row, end_col = colon + 1,
          hl_group = "PosteVerboseKey", priority = 100,
        })
        local val_start = colon + 2
        if val_start <= #line then
          local value = line:sub(val_start)
          local matched = false

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

          if not matched then
            vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, val_start - 1, {
              end_row = row, end_col = #line,
              hl_group = "PosteVerboseValue", priority = 100,
            })
          end
        end
      end
    end
    ::next::
  end

  if body_start and body_end and r and r.content_type then
    local mime = (r.content_type:match("^([^;]+)") or r.content_type):lower()
    if content_type_map[mime] == "json" then
      apply_verbose_json_highlights(buf, lines, body_start, body_end)
    end
  end

  if req_body_start and req_body_end and req_content_type then
    local mime = (req_content_type:match("^([^;]+)") or req_content_type):lower()
    if content_type_map[mime] == "json" then
      apply_verbose_json_highlights(buf, lines, req_body_start, req_body_end)
    end
  end
end

return M