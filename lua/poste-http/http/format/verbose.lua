--- Verbose response rendering.
---
--- Handles the General/Request/Response/Connection sections of the verbose view,
--- including extmark-based syntax highlighting.
--- Extracted from the former format.lua god module.
local state = require("poste-http.state")
local fmt_util = require("poste-http.http.format.util")
local columns = require("poste-http.ui.columns")
local semantics = require("poste-http.ui.semantics")

local M = {}

local verbose_ns = vim.api.nvim_create_namespace("poste_verbose")
local json_ns = vim.api.nvim_create_namespace("poste_verbose_json")

local _sep_lines = nil
local _section_lines = nil

-- Content-type → filetype mapping (shared with format.lua via format/util)
local content_type_map = fmt_util.content_type_map

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

local function format_elapsed(ms)
  if ms then
    if ms >= 1000 then
      return string.format("%.2f s", ms / 1000)
    end
    return string.format("%.2f ms", ms)
  end
  return "-"
end

local function calc_response_size(r)
  if not r then return 0 end
  local body_size
  if r.metadata and r.metadata.file_size then
    body_size = r.metadata.file_size
  else
    body_size = #(r.body or "")
  end
  local headers_size = 0
  if r.headers then
    for _, h in ipairs(r.headers) do
      headers_size = headers_size + #h[1] + 2 + #h[2] + 2 -- "key: value\r\n"
    end
  end
  return body_size + headers_size
end

function M.format_response_size(r)
  local total = calc_response_size(r)
  if total == 0 then return "0 B" end
  local human = fmt_util.human_size(total)
  return string.format("%s  (%s bytes)", human, total)
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
function M.format_verbose(r, pending, opts)
  opts = opts or {}
  if r and r._cached_verbose then return r._cached_verbose end
  local lines = {}
  local sep_lines = {}
  local section_lines = {}
  local fmt_width = opts.width or 80
  if r then
    r._sep_lines = sep_lines
    r._section_lines = section_lines
    r._fmt_width = fmt_width
  else
    _sep_lines = sep_lines
    _section_lines = section_lines
    M._fmt_width = fmt_width
  end

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

  M._fmt_method = method
  M._fmt_method_line = #lines
  if r then
    r._fmt_method = method
    r._fmt_method_line = #lines
  end
  table.insert(lines, "  " .. (url ~= "" and url or "(no URL)"))

  local request_name = (r and r.request_name) or ""
  if request_name == "" and pending and pending.name and pending.name ~= "" then
    request_name = pending.name
  end
  table.insert(lines, "  ")
  sep_lines[#lines] = true

  -- General section: key-value pairs rendered with aligned columns
  local general_rows = {}
  if request_name ~= "" then
    table.insert(general_rows, { "  Name: ", request_name })
  end
  if r then
    table.insert(general_rows, { "  Status Code: ", format_status_text(r) })
  end
  table.insert(general_rows, { "  Request Time: ", timestamp ~= "" and timestamp or "-" })
  if r then
    table.insert(general_rows, { "  Response Size: ", M.format_response_size(r) })
  end
  table.insert(general_rows, { "  Elapsed: ", format_elapsed(elapsed_ms) })
  table.insert(general_rows, { "  Env: ", env ~= "" and env or "-" })

  if #general_rows > 0 then
    local general_lines, _ = columns.render(general_rows, {
      { max = 20, gap = 2 },
      { flex = true, pad = false },
    }, { width = fmt_width, gap = 1 })
    for _, line in ipairs(general_lines) do
      table.insert(lines, line)
    end
  end

  table.insert(lines, "  ")
  sep_lines[#lines] = true

  table.insert(lines, "  Request Headers")
  section_lines[#lines] = true
  if request_headers ~= "" then
    local header_rows = {}
    for l in request_headers:gmatch("[^\r\n]+") do
      local k, v = l:match("^([^:]+):%s*(.+)$")
      if k and v then
        table.insert(header_rows, { "  " .. k .. ": ", v })
      else
        table.insert(lines, "  " .. l)
      end
    end
    if #header_rows > 0 then
      local header_lines, _ = columns.render(header_rows, {
        { max = 30, gap = 2 },
        { flex = true, pad = false },
      }, { width = fmt_width, gap = 1 })
      for _, line in ipairs(header_lines) do
        table.insert(lines, line)
      end
    end
  else
    table.insert(lines, "  <empty>")
  end

  -- Query Parameters section
  table.insert(lines, "  Query Parameters")
  section_lines[#lines] = true
  if url ~= "" then
    local qmark = url:find("?")
    if qmark then
      local query_string = url:sub(qmark + 1)
      for pair in query_string:gmatch("[^&]+") do
        local key, val = pair:match("^([^=]+)=(.*)$")
        if key then
          -- Shared decoder: '+' → space BEFORE %XX, so an encoded literal
          -- plus (%2B) survives as '+' instead of collapsing into a space.
          key = fmt_util.url_decode(key)
          val = fmt_util.url_decode(val)
          table.insert(lines, string.format("  %s: %s", key, val))
        else
          table.insert(lines, "  " .. pair)
        end
      end
    else
      table.insert(lines, "  <empty>")
    end
  else
    table.insert(lines, "  <empty>")
  end

  -- Request Body section
  table.insert(lines, "  Request Body")
  section_lines[#lines] = true
  if request_body ~= "" then
    local multipart = require("poste-http.http.format.multipart")
    local verbose_body = multipart.strip_request_preamble(request_body, request_headers)
    if verbose_body ~= "" then
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
        local form_lines = fmt_util.format_urlencoded_body(verbose_body)
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
    else
      table.insert(lines, "  <empty>")
    end
  else
    table.insert(lines, "  <empty>")
  end

  if r then
    if r.protocol == "error" then
      table.insert(lines, "  ")
      sep_lines[#lines] = true
      if r.body and r.body ~= "" then
        table.insert(lines, "  Details")
      section_lines[#lines] = true
      table.insert(lines, "  " .. r.body:gsub("\n", "\n  "))
      end
      r._cached_verbose = lines
      r._sep_lines = sep_lines
      r._section_lines = section_lines
      return lines
    end

    table.insert(lines, "  ")
    sep_lines[#lines] = true

    if r.headers and #r.headers > 0 then
      table.insert(lines, "  Response Headers")
      section_lines[#lines] = true
      for _, h in ipairs(r.headers) do
        table.insert(lines, "  " .. h[1] .. ": " .. h[2])
      end
    end

    if r.body and r.body ~= "" then
      table.insert(lines, "  Response Body")
      section_lines[#lines] = true

      -- Content-Disposition: attachment → save body to file before display
      if not (r.metadata and r.metadata.file_path) and r.headers then
        if fmt_util.has_attachment_disposition(r.headers) then
          local fn = fmt_util.attachment_filename(r)
          fmt_util.save_binary_body(r.body, fn, r.content_type or "application/octet-stream", r)
        end
      end

      -- Image/binary response without Content-Disposition: save body to file for preview
      if r.body and r.body ~= "" and not (r.metadata and r.metadata.file_path) then
        if not fmt_util.is_text_content_type(r.content_type) then
          local ct = r.content_type or ""
          local ext = fmt_util.content_type_extension(ct)
          local ms = math.floor(((vim.uv or vim.loop).hrtime() / 1e6) % 1000)
          local fn = "res_" .. os.date("%Y%m%d_%H%M%S") .. string.format("_%03d", ms) .. ext
          fmt_util.save_binary_file(r.body, fn, ct, r)
        end
      end

      if r.metadata and r.metadata.file_path then
        table.insert(lines, string.format("  Path:         %s", r.metadata.file_path))
        table.insert(lines, string.format("  Size:         %s  (%s bytes)", fmt_util.human_size(r.metadata.file_size), r.metadata.file_size or "?"))
        table.insert(lines, string.format("  Content-Type: %s", r.metadata.file_content_type or r.content_type or "?"))
      elseif fmt_util.is_large_body(r.body) then
        local truncated = fmt_util.save_body_to_file(r.body, r.content_type, r)
        for _, tl in ipairs(truncated) do
          table.insert(lines, "  " .. tl)
        end
      else
        local body = fmt_util.pretty_body(r.body, r.content_type)
        for l in body:gmatch("[^\r\n]+") do
          table.insert(lines, "  " .. l)
        end
      end
    end

    local verbose = r.metadata and r.metadata.verbose
    if verbose and verbose ~= "" then
      local conn_info = extract_connection_info(verbose)
      if next(conn_info) then
        table.insert(lines, "  Connection")
        section_lines[#lines] = true
        local conn_rows = {}
        if conn_info.proxy then table.insert(conn_rows, { "  Proxy: ", conn_info.proxy }) end
        if conn_info.tls then table.insert(conn_rows, { "  TLS: ", conn_info.tls }) end
        if conn_info.http then table.insert(conn_rows, { "  HTTP: ", conn_info.http }) end
        if conn_info.exit then table.insert(conn_rows, { "  Exit Code: ", conn_info.exit }) end
        if #conn_rows > 0 then
          local conn_lines, _ = columns.render(conn_rows, {
            { max = 16, gap = 2 },
            { flex = true, pad = false },
          }, { width = fmt_width, gap = 1 })
          for _, line in ipairs(conn_lines) do
            table.insert(lines, line)
          end
        end
      end
    end
  end

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

  local multipart = require("poste-http.http.format.multipart")
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
    local raw_lines = fmt_util.split_lines(body_only)
    for j = 1, math.min(10, #raw_lines) do
      table.insert(lines, "  " .. raw_lines[j])
    end
    if #raw_lines > 10 then
      table.insert(lines, string.format("  ... (%d more lines)", #raw_lines - 10))
    end
    return lines
  end

  if ct:lower():find("application/x%-www%-form%-urlencoded") then
    local form_lines = fmt_util.format_urlencoded_body(body_only)
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
      local body = fmt_util.json_pretty(decoded)
      for l in body:gmatch("[^\r\n]+") do
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
  e = #raw_line
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
  local sep_lookup = (r and r._sep_lines) or _sep_lines or {}
  local section_lookup = (r and r._section_lines) or _section_lines or {}
  for i, line in ipairs(lines) do
    if line == "  Response Body" then
      in_body = true
      body_start = i + 1
    elseif line == "  Request Body" then
      in_req_body = true
      req_body_start = i + 1
    elseif line == "  Request Headers" then
      in_req_headers = true
    elseif section_lookup[i] or sep_lookup[i] then
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
      if line == "  <empty>" then
        vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, 0, {
          end_row = row, end_col = #line,
          hl_group = "PosteVerboseValue", priority = 100,
        })
      end
      goto next
    end

    local sep_lines = (r and r._sep_lines) or _sep_lines
    if sep_lines and sep_lines[i] then
      local width = (r and r._fmt_width) or M._fmt_width or 80
      vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, 0, {
        virt_text = {{string.rep("─", width), "PosteVerboseSeparator"}},
        virt_text_pos = "overlay",
        priority = 100,
      })
    elseif section_lookup[i] then
      vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, 0, {
        end_row = row, end_col = #line,
        hl_group = "PosteVerboseSection", priority = 100,
      })
    elseif line:match("^  %w+://") then
      local fmt_method = (r and r._fmt_method) or M._fmt_method
      local fmt_method_line = (r and r._fmt_method_line) or M._fmt_method_line
      if fmt_method and fmt_method ~= "" and row == fmt_method_line then
        local hl = semantics.method_hl(fmt_method)
        if hl == "PosteMethodOther" then hl = "PosteVerboseValue" end
        vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, 2, {
          virt_text = {{fmt_method .. " ", hl}},
          virt_text_pos = "inline",
          priority = 200,
        })
        M._fmt_method = nil
      end
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
          local raw_val = line:sub(val_start)
          local leading_ws = raw_val:match("^%s*") or ""
          local value = raw_val:sub(#leading_ws + 1)
          local content_start = val_start + #leading_ws
          local matched = false

          if line:match("^  Request Method:") then
            local meth = value:match("^(%S+)")
            local hl = meth and semantics.method_hl(meth)
            if meth and hl and hl ~= "PosteMethodOther" then
              vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, content_start - 1, {
                end_col = content_start - 1 + #meth,
                hl_group = hl, priority = 200,
              })
              matched = true
            end
          elseif line:match("^  Status Code:") then
            local code = value:match("^(%d+)")
            if code then
              vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, content_start - 1, {
                end_col = content_start - 1 + #code,
                hl_group = semantics.status_hl(code), priority = 200,
              })
              matched = true
            end
          elseif line:match("^  Elapsed:") then
            local s, e = value:find("^[%d%.]+")
            if s then
              vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, content_start - 1 + s - 1, {
                end_col = content_start - 1 + e,
                hl_group = "PosteLatency", priority = 200,
              })
              matched = true
            end
          end

          if not matched then
            vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, content_start - 1, {
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
  _sep_lines = nil
  _section_lines = nil
end

return M
