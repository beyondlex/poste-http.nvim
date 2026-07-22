--- Multipart/form-data body parsing and display.
---
--- Extracted from the former format.lua god module.
local M = {}

--- Split a string into lines
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

--- Parse multipart/form-data boundary from Content-Type header.
function M.extract_boundary(content_type)
  if not content_type then return nil end
  local b = content_type:match('boundary="([^"]+)"') or content_type:match("boundary=([^;%s]+)")
  return b
end

--- Split multipart body into parts. Each part is a table:
---   { headers = {"Key: Value", ...}, body = "raw content" }
function M.parse_multipart_parts(body, boundary)
  if not body or not boundary then return nil end
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
function M.condense_multipart_body(body, content_type)
  if not body or not content_type then return body end
  if not content_type:find("multipart/form%-data") then return body end
  local boundary = M.extract_boundary(content_type)
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

--- Strip the HTTP request line and headers from a raw request body.
--- Used to extract body-only content from a full HTTP request string.
function M.strip_request_preamble(raw_body, _raw_headers)
  if not raw_body or raw_body == "" then return raw_body end
  local all_lines = split_lines(raw_body)

  local body_start = nil
  for i, line in ipairs(all_lines) do
    if line == "" then
      body_start = i + 1
      while body_start <= #all_lines and all_lines[body_start] == "" do
        body_start = body_start + 1
      end
      break
    end
  end

  if body_start and body_start <= #all_lines then
    return table.concat(all_lines, "\n", body_start)
  end
return ""
end

return M