--- Shared utilities for response formatters.
local state = require("poste-http.state")

local M = {}

function M.split_lines(str)
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

function M.human_size(bytes)
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

function M.is_large_body(body)
  if not body then return false end
  local cfg = state.config or {}
  local max_size = cfg.max_body_preview_size or (1024 * 1024)
  return #body > max_size
end

function M.save_body_to_file(body, content_type, r)
  local cfg = state.config or {}
  local preview_lines = tonumber(cfg.body_preview_lines) or 20
  local cache_dir = cfg.response_cache_dir or vim.fn.stdpath("cache") .. "/poste_res"
  vim.fn.mkdir(cache_dir, "p")
  -- Millisecond suffix from hrtime: strftime %6N is a glibc extension and
  -- yields a literal "6N" on macOS, collapsing the name to second precision
  -- so two responses in the same second would overwrite each other.
  local uv = vim.uv or vim.loop
  local ms = math.floor((uv.hrtime() / 1e6) % 1000)
  local tmp_file = string.format("%s/res_%s_%03d.txt", cache_dir, vim.fn.strftime("%Y%m%d_%H%M%S"), ms)
  local f = io.open(tmp_file, "wb")
  -- Keep the caller's contract (list of lines) even when the dump fails;
  -- returning nil would crash the render pipeline on ipairs().
  if not f then
    return { string.format("(failed to write body dump: %s)", tmp_file) }
  end
  f:write(body)
  f:close()
  if not r.metadata then r.metadata = {} end
  r.metadata.file_path = tmp_file
  r.metadata.file_size = #body
  r.metadata.file_content_type = content_type
  local lines = M.split_lines(body)
  local truncated = {}
  local preview_count = math.min(preview_lines, #lines)
  for i = 1, preview_count do
    table.insert(truncated, lines[i])
  end
  local remaining = #lines - preview_count
  table.insert(truncated, string.format("...  (%d more lines, %s total)", remaining, M.human_size(#body)))
  table.insert(truncated, string.format("  File:        %s", tmp_file))
  return truncated
end

--- Escape a string as a JSON string body: backslash, quote, explicit
--- escapes for the common whitespace controls, and \u00XX for the rest.
local function json_escape(s)
  return s:gsub('\\', '\\\\')
    :gsub('"', '\\"')
    :gsub('\n', '\\n')
    :gsub('\r', '\\r')
    :gsub('\t', '\\t')
    :gsub('%c', function(c) return string.format("\\u%04x", c:byte()) end)
end

function M.json_pretty(value, indent)
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
        table.insert(items, indent_str_inner .. M.json_pretty(v, indent + 1))
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
        -- Keys are strings too: an unescaped quote/backslash in a key
        -- emitted invalid JSON that broke the json treesitter parse.
        table.insert(items, indent_str_inner .. '"' .. json_escape(tostring(k)) .. '": ' .. M.json_pretty(v, indent + 1))
      end
      return "{\n" .. table.concat(items, ",\n") .. "\n" .. indent_str .. "}"
    end
  elseif type(value) == "string" then
    return '"' .. json_escape(value) .. '"'
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

--- Decode %XX escapes and '+' (space) in a urlencoded component.
--- '+' → space runs first so %2B decodes to a literal plus.
--- Exported for the verbose Query Parameters display (bug: it used to
--- decode %XX before '+', turning an encoded literal plus into a space).
function M.url_decode(s)
  s = s:gsub("+", " ")
  return s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
end

function M.format_urlencoded_body(body)
  if not body or body == "" then return nil end
  local lines = {}
  for pair in body:gmatch("[^&]+") do
    local key, val = pair:match("^([^=]+)=(.*)$")
    if key and val ~= nil then
      key = M.url_decode(key)
      val = M.url_decode(val)
      table.insert(lines, string.format("  %s: %s", key, val))
    end
  end
  if #lines == 0 then return nil end
  return lines
end

--- Try to pretty-print JSON body; return as-is if not JSON or if already formatted
function M.pretty_body(body, content_type)
  if not body or body == "" then return "" end
  if not body:find("\n") and (not content_type or content_type:find("json") or body:sub(1, 1) == "{" or body:sub(1, 1) == "[") then
    local ok, decoded = pcall(vim.json.decode, body)
    if ok and decoded then
      return M.json_pretty(decoded)
    end
  end
  return body
end

---------------------------------------------------------------------------
-- Content-type classification
---------------------------------------------------------------------------

-- Single source of truth for content-type → treesitter filetype. format.lua
-- and format/verbose.lua each used to keep a private copy that drifted.
M.content_type_map = {
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

--- Extract the bare mime (no parameters) from a Content-Type value.
function M.mime_of(content_type)
  if not content_type then return "" end
  local mime = content_type:match("^([^;]+)") or content_type
  return vim.trim(mime):lower()
end

--- Whether a response with this Content-Type should render as text rather
--- than being dumped to a file behind a "Binary File Response" card.
---
--- The legacy test was "mime mentions text/json/xml/html", which misrouted
--- textual types whose names carry none of those markers
--- (application/x-www-form-urlencoded, application/javascript, yaml
--- variants, …) to the binary path. Those are listed explicitly; the
--- structured +json/+xml suffixes are honored too. Unknown types still
--- default to binary — dumping mojibake into the buffer is worse than the
--- card. An empty type counts as text (same behavior as before).
function M.is_text_content_type(content_type)
  local mime = M.mime_of(content_type)
  if mime == "" then return true end
  if mime:find("text") or mime:find("json") or mime:find("xml") or mime:find("html") then
    return true
  end
  if mime:match("%+json$") or mime:match("%+xml$") then return true end
  local extra_text_mimes = {
    ["application/x-www-form-urlencoded"] = true,
    ["application/javascript"] = true,
    ["application/x-yaml"] = true,
    ["application/yaml"] = true,
    ["application/toml"] = true,
  }
  return extra_text_mimes[mime] or false
end

local content_type_ext = {
  ["application/vnd.ms-excel"] = ".xls",
  ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"] = ".xlsx",
  ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"] = ".docx",
  ["application/pdf"] = ".pdf",
  ["application/zip"] = ".zip",
  ["application/gzip"] = ".gz",
  ["image/png"] = ".png",
  ["image/jpeg"] = ".jpg",
  ["image/gif"] = ".gif",
  ["image/webp"] = ".webp",
  ["image/svg+xml"] = ".svg",
  ["text/csv"] = ".csv",
  ["text/plain"] = ".txt",
  ["application/json"] = ".json",
  ["application/octet-stream"] = ".bin",
}

function M.content_type_extension(content_type)
  if not content_type then return ".bin" end
  local mime = M.mime_of(content_type)
  return content_type_ext[mime] or ".bin"
end

function M.extract_disposition_filename(headers)
  for _, h in ipairs(headers or {}) do
    if h[1]:lower() == "content-disposition" then
      local val = h[2]
      if val:lower():find("attachment") then
        local fn = val:match('filename="([^"]*)"')
        if not fn then
          fn = val:match("filename=([^;]+)")
        end
        if fn then
          fn = vim.trim(fn)
          fn = fn:gsub("[/\\]", "_")
        end
        return fn
      end
    end
  end
  return nil
end

function M.has_attachment_disposition(headers)
  for _, h in ipairs(headers or {}) do
    if h[1]:lower() == "content-disposition" then
      return h[2]:lower():find("attachment") ~= nil
    end
  end
  return false
end

function M.save_binary_body(body, filename, content_type, r)
  local cfg = state.config or {}
  local cache_dir = cfg.response_cache_dir or vim.fn.stdpath("cache") .. "/poste_res"
  vim.fn.mkdir(cache_dir, "p")
  local file_path = cache_dir .. "/" .. filename
  local f = io.open(file_path, "wb")
  if not f then return nil end
  f:write(body)
  f:close()
  if not r.metadata then r.metadata = {} end
  r.metadata.file_path = file_path
  r.metadata.file_size = #body
  r.metadata.file_content_type = content_type
  r.metadata.content_disposition_attachment = true
  return file_path
end

function M.save_binary_file(body, filename, content_type, r)
  local cfg = state.config or {}
  local cache_dir = cfg.response_cache_dir or vim.fn.stdpath("cache") .. "/poste_res"
  vim.fn.mkdir(cache_dir, "p")
  local file_path = cache_dir .. "/" .. filename
  local f = io.open(file_path, "wb")
  if not f then return nil end
  f:write(body)
  f:close()
  if not r.metadata then r.metadata = {} end
  r.metadata.file_path = file_path
  r.metadata.file_size = #body
  r.metadata.file_content_type = content_type
  return file_path
end

function M.attachment_filename(r)
  local fn = M.extract_disposition_filename(r.headers)
  if fn and fn ~= "" then return fn end
  local ext = M.content_type_extension(r.content_type)
  local ms = math.floor(((vim.uv or vim.loop).hrtime() / 1e6) % 1000)
  return "download_" .. os.date("%Y%m%d_%H%M%S") .. string.format("_%03d", ms) .. ext
end

return M