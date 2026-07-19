--- HTTP response body formatting.
---
--- Handles body rendering for HTTP responses, including JSON pretty-printing,
--- URL-encoded form display, binary file display, and large body truncation.
--- Extracted from the former format.lua god module.
local state = require("poste.state")

local M = {}

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------

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

--- Format a byte count as a human-readable string (e.g., "12.0 KB", "1.5 MB").
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

--- Return true if the body is too large to display inline.
local function is_large_body(body)
  if not body then return false end
  local cfg = state.config or {}
  local max_size = cfg.max_body_preview_size or (1024 * 1024) -- 1MB default
  return #body > max_size
end

--- Save body to a temp file and return truncated preview lines with a file link.
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

--- Simple JSON pretty-printer
local function json_pretty(value, indent)
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
      if #value == 0 then
        return "[]"
      end
      local items = {}
      for _, v in ipairs(value) do
        table.insert(items, indent_str_inner .. json_pretty(v, indent + 1))
      end
      return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent_str .. "]"
    else
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
function M.pretty_body(body, content_type)
  if not body or body == "" then return "" end

  if not body:find("\n") and (not content_type or content_type:find("json") or body:sub(1, 1) == "{" or body:sub(1, 1) == "[") then
    local ok, decoded = pcall(vim.json.decode, body)
    if ok and decoded then
      return json_pretty(decoded)
    end
  end
  return body
end

--- Format urlencoded form data (application/x-www-form-urlencoded) as key-value lines.
function M.format_urlencoded_body(body)
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

--- Format Redis response body.
function M.format_redis_body(r)
  local lines = {}

  local ok, data = pcall(vim.json.decode, r.body)
  if not ok or type(data) ~= "table" then
    return split_lines(r.body or "(empty)")
  end

  local rtype = data.type or "unknown"
  local value = data.value

  if r.metadata and r.metadata.command then
    table.insert(lines, "✓ " .. r.metadata.command)
    table.insert(lines, "")
  end

  table.insert(lines, string.format("[%s]", rtype))
  table.insert(lines, "")

  if rtype == "nil" then
    table.insert(lines, "(nil)")
  elseif rtype == "integer" then
    table.insert(lines, tostring(value))
  elseif rtype == "string" then
    if data.parsed then
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
  if r.latency_ms then
    table.insert(lines, string.format("time: %dms", r.latency_ms))
  end
  if r.url then
    table.insert(lines, string.format("db: %s", r.url))
  end

  return lines
end

--- Main body formatting entry point.
function M.format_body(r)
  if r._cached_body then return r._cached_body end

  -- Redis protocol: parse structured JSON and render with type-specific formatting
  if r.protocol == "redis" then
    local result = M.format_redis_body(r)
    r._cached_body = result
    return result
  end

  -- Binary file response: show file info instead of mangled raw content
  if r.metadata and r.metadata.file_path and r.metadata.file_content_type
    and not r.metadata.file_content_type:find("text")
    and not r.metadata.file_content_type:find("json")
    and not r.metadata.file_content_type:find("xml")
    and not r.metadata.file_content_type:find("html") then
    local lines = {}
    local ct = r.metadata.file_content_type or r.content_type or ""
    local image_mod = require("poste.http.format.image")
    local is_image = image_mod.is_image_content_type(ct)
    local can_inline = is_image and image_mod.has_image_nvim() and not ct:match("^image/svg%+xml")
    local pad_lines = image_mod.inline_image_padding_lines()
    if is_image then
      table.insert(lines, "▸ Image Response")
    else
      table.insert(lines, "▸ Binary File Response")
    end
    table.insert(lines, "")
    table.insert(lines, string.format("  Path:         %s", r.metadata.file_path))
    table.insert(lines, string.format("  Size:         %s  (%s bytes)", human_size(r.metadata.file_size), r.metadata.file_size or "?"))
    table.insert(lines, string.format("  Content-Type: %s", ct))
    table.insert(lines, "")
    if is_image then
      if can_inline then
        table.insert(lines, string.format("  Open file:    %s", r.metadata.file_path))
        for _ = 1, pad_lines do
          table.insert(lines, "")
        end
        r._cached_body = lines
        return lines
      else
        table.insert(lines, "  Preview:      press K to open externally")
      end
    end
    table.insert(lines, string.format("  Open file:    %s", r.metadata.file_path))
    r._cached_body = lines
    return lines
  end

  -- Large text response: truncate and save to file
  if is_large_body(r.body) then
    return save_body_to_file(r.body, r.content_type, r)
  end

  local body = M.pretty_body(r.body, r.content_type)
  local result = split_lines(body)
  r._cached_body = result
  return result
end

--- Clean up stale response cache files.
function M.clean_response_cache(max_age_minutes)
  local cfg = state.config or {}
  local cache_dir = cfg.response_cache_dir or vim.fn.stdpath("cache") .. "/poste_res"
  max_age_minutes = max_age_minutes or (24 * 60) -- default 24 hours

  if vim.fn.isdirectory(cache_dir) ~= 1 then return 0 end

  local now = vim.fn.localtime()
  local max_age_seconds = max_age_minutes * 60
  local count = 0

  local handle = vim.fn.readdir(cache_dir)
  for _, name in ipairs(handle) do
    local full = cache_dir .. "/" .. name
    local mtime = vim.fn.getftime(full)
    if mtime > 0 and (now - mtime) > max_age_seconds then
      os.remove(full)
      count = count + 1
    end
  end

  return count
end

return M