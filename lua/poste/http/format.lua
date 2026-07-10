--- Response formatters: body, headers, verbose views + filetype detection.
--- Also includes Redis extmark-based syntax coloring.
local state = require("poste.state")

local redis_ns = vim.api.nvim_create_namespace("poste_redis")
local file_link_ns = vim.api.nvim_create_namespace("poste_file_link")

local M = {}
local image_preview_state = {
  image = nil,
  snacks_placement = nil,
}
local INLINE_IMAGE_PADDING_LINES = 2
local strip_request_preamble -- forward decl; defined below format_verbose

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

--- Image content type detection.
local image_content_types = {
  ["image/png"] = true,
  ["image/jpeg"] = true,
  ["image/gif"] = true,
  ["image/webp"] = true,
  ["image/svg+xml"] = true,
  ["image/avif"] = true,
  ["image/bmp"] = true,
  ["image/tiff"] = true,
  ["image/x-icon"] = true,
  ["image/vnd.microsoft.icon"] = true,
}

function M.is_image_content_type(content_type)
  if not content_type then return false end
  local mime = content_type:match("^([^;]+)") or content_type
  return image_content_types[mime] == true
end

--- Detect terminal support for Kitty graphics protocol.
function M.supports_kitty_protocol()
  if vim.env.KITTY_WINDOW_ID then return true end
  if (vim.env.TERM or ""):match("kitty") then return true end
  if vim.env.TERM_PROGRAM == "WezTerm" then return true end
  return false
end

--- Open an image file in the system viewer (macOS `open` / Linux `xdg-open`).
function M.open_image_external(file_path)
  if not file_path or vim.fn.filereadable(file_path) ~= 1 then
    vim.notify("Image file not found: " .. tostring(file_path), vim.log.levels.WARN, { title = "Poste" })
    return
  end
  local opener = vim.fn.has("mac") == 1 and "open" or "xdg-open"
  vim.fn.jobstart({ opener, file_path }, { detach = true })
  vim.notify(string.format("Opening image: %s", file_path), vim.log.levels.INFO, { title = "Poste" })
end

function M.close_image_preview()
  if image_preview_state.snacks_placement then
    local p = image_preview_state.snacks_placement
    image_preview_state.snacks_placement = nil
    pcall(function()
      if type(p.close) == "function" then
        p:close()
      end
    end)
  end
  if image_preview_state.image then
    local img = image_preview_state.image
    image_preview_state.image = nil
    pcall(function()
      if type(img) == "table" then
        if type(img.clear) == "function" then
          img:clear()
        elseif type(img.delete) == "function" then
          img:delete()
        end
      end
    end)
  end
end

local function try_snacks_image(buf, file_path, cursor_line)
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" then
    return false
  end
  if type(snacks.image) ~= "table" or type(snacks.image.supports) ~= "function" then
    return false
  end
  if not snacks.image.supports(file_path) then
    return false
  end
  local win = vim.fn.bufwinid(buf)
  if win < 0 then return false end

  local pos_row = (cursor_line or 1)

  M.close_image_preview()

  local placement_ok, placement = pcall(snacks.image.placement.new, buf, file_path, {
    pos = { pos_row, 0 },
    inline = true,
    conceal = false,
  })
  if not placement_ok or not placement then
    return false
  end

  image_preview_state.snacks_placement = placement
  return true
end

local function try_image_nvim(buf, file_path, cursor_line)
  local ok, image = pcall(require, "image")
  if not ok or type(image) ~= "table" or type(image.from_file) ~= "function" then
    return false
  end

  local win = vim.fn.bufwinid(buf)
  if win < 0 then
    return false
  end

  local restore_cursor = nil
  if cursor_line and vim.api.nvim_win_is_valid(win) then
    restore_cursor = vim.api.nvim_win_get_cursor(win)
    local line_count = vim.api.nvim_buf_line_count(buf)
    local target_line = math.max(1, math.min(cursor_line, math.max(1, line_count)))
    pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })
  end

  local opts = {
    buffer = buf,
    window = win,
    with_virtual_padding = true,
    inline = true,
    id = "poste_image_preview",
    overlap = 0,
    x = 0,
    y = cursor_line and math.max(cursor_line - 1, 0) or 0,
  }

  local image_obj
  local from_ok, from_err = pcall(function()
    image_obj = image.from_file(file_path, opts)
  end)
  if not from_ok or not image_obj then
    if restore_cursor then
      pcall(vim.api.nvim_win_set_cursor, win, restore_cursor)
    end
    return false, from_err
  end

  M.close_image_preview()
  image_preview_state.image = image_obj

  if type(image_obj) == "table" then
    if type(image_obj.render) == "function" then
      local render_ok = pcall(function() image_obj:render() end)
      if render_ok then
        if restore_cursor then
          pcall(vim.api.nvim_win_set_cursor, win, restore_cursor)
        end
        return true
      end
    end
    if type(image_obj.show) == "function" then
      local show_ok = pcall(function() image_obj:show() end)
      if show_ok then
        if restore_cursor then
          pcall(vim.api.nvim_win_set_cursor, win, restore_cursor)
        end
        return true
      end
    end
  end

  image_preview_state.image = nil
  if type(image.render) == "function" then
    local render_ok = pcall(function()
      image.render(image_obj)
    end)
    if render_ok then
      if restore_cursor then
        pcall(vim.api.nvim_win_set_cursor, win, restore_cursor)
      end
      return true
    end
  end

  if restore_cursor then
    pcall(vim.api.nvim_win_set_cursor, win, restore_cursor)
  end

  return false
end

function M.has_image_nvim()
  local ok, image = pcall(require, "image")
  return ok and type(image) == "table" and type(image.from_file) == "function"
end

function M.has_snacks_image()
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" then return false end
  if type(snacks.image) ~= "table" or type(snacks.image.supports) ~= "function" then return false end
  return snacks.image.supports_terminal()
end

function M.inline_image_padding_lines()
  return INLINE_IMAGE_PADDING_LINES
end

--- Render image inline in the current response buffer/window.
function M.render_image_preview(buf, file_path, content_type, cursor_line)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  if not file_path or vim.fn.filereadable(file_path) ~= 1 then return false end
  if not M.is_image_content_type(content_type) then return false end

  -- snacks supports SVG via imagemagick conversion, try it first
  if try_snacks_image(buf, file_path, cursor_line) then
    return true
  end

  -- image.nvim doesn't support SVG, skip those
  if content_type and content_type:match("^image/svg%+xml") then return false end
  if try_image_nvim(buf, file_path, cursor_line) then
    return true
  end
  return false
end

function M.render_response_image(buf, r, cursor_line)
  if not r or not r.metadata then return false end
  local file_path = r.metadata.file_path
  local content_type = r.metadata.file_content_type or r.content_type
  return M.render_image_preview(buf, file_path, content_type, cursor_line)
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
  if r._cached_body then return r._cached_body end

  -- Redis protocol: parse structured JSON and render with type-specific formatting
  if r.protocol == "redis" then
    local result = format_redis_body(r)
    r._cached_body = result
    return result
  end

  -- Binary file response: show file info instead of mangled raw content
  if r.metadata and r.metadata.file_path and r.metadata.file_content_type and not r.metadata.file_content_type:find("text") and not r.metadata.file_content_type:find("json") and not r.metadata.file_content_type:find("xml") and not r.metadata.file_content_type:find("html") then
    local lines = {}
    local ct = r.metadata.file_content_type or r.content_type or ""
    local is_image = M.is_image_content_type(ct)
    local can_inline = is_image and M.has_image_nvim() and not ct:match("^image/svg%+xml")
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
        for _ = 1, INLINE_IMAGE_PADDING_LINES do
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
    -- Don't cache large bodies (file-backed, not in memory)
    return save_body_to_file(r.body, r.content_type, r)
  end

  local body = pretty_body(r.body, r.content_type)
  local result = split_lines(body)
  r._cached_body = result
  return result
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
  if r and r._cached_verbose then return r._cached_verbose end
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
  -- Show request name below URL with gray highlight
  local request_name = (r and r.request_name) or ""
  if request_name == "" and pending and pending.name and pending.name ~= "" then
    request_name = pending.name
  end
  if request_name ~= "" then
    table.insert(lines, "  " .. request_name)
  end
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
    -- strip_request_preamble now finds the blank-line separator directly,
    -- so it works for both full HTTP requests (with preamble) and body-only
    -- content (e.g. pending requests).
    local verbose_body = strip_request_preamble(request_body, request_headers)
    local ct = ""
    for l in request_headers:gmatch("[^\r\n]+") do
      local k, v = l:match("^([^:]+):%s*(.+)$")
      if k and k:lower() == "content-type" then ct = v end
    end
    local ct_lower = ct:lower()
    if ct_lower:find("multipart/form%-data") then
      local display_body = M.condense_multipart_body(verbose_body, ct)
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

  -- ─── Response sections (only when response is available) ────────
  if r then
    -- Error protocol: compact error layout
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

  if r then r._cached_verbose = lines end
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

--- Strip the HTTP request line and headers from a raw request body.
--- Used by format_verbose and format_request_payload to extract body-only content.
--- Detects the header/body boundary by finding the first blank line in the raw
--- HTTP request text, rather than relying on raw_headers (which may be empty
--- or inconsistent with the raw body).
strip_request_preamble = function(raw_body, _raw_headers)
  if not raw_body or raw_body == "" then return raw_body end
  local all_lines = split_lines(raw_body)

  -- Find the first blank line — that's the separator between headers and body.
  local body_start = nil
  for i, line in ipairs(all_lines) do
    if line == "" then
      body_start = i + 1
      -- Skip any additional leading blank lines.
      while body_start <= #all_lines and all_lines[body_start] == "" do
        body_start = body_start + 1
      end
      break
    end
  end

  if body_start and body_start <= #all_lines then
    return table.concat(all_lines, "\n", body_start)
  end
  return raw_body
end

--- Format the request payload for the dedicated Request tab.
--- Shows parsed structure: field name, type (file/text), value/size.
function M.format_request_payload(r)
  local req_body = r.metadata and r.metadata.request_body
  local req_headers = r.metadata and r.metadata.request_headers
  if not req_body or req_body == "" then
    return { "(no request body)" }
  end

  local body_only = strip_request_preamble(req_body, req_headers)
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
    local parts = boundary and parse_multipart_parts(body_only, boundary)
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
   local boundary_val = extract_boundary(ct)
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

local verbose_ns = vim.api.nvim_create_namespace("poste_verbose")
local json_ns = vim.api.nvim_create_namespace("poste_verbose_json")

--- Compute the byte span within a (possibly continuation) line that contains the
--- JSON fragment.  Returns (start_byte, end_byte) — 0-based byte offsets within
--- `raw_line`.
local function json_byte_span(raw_line)
  local s, e = raw_line:find("^[%s]+") -- strip leading indent
  s = (s and e) or 0
  -- Remove trailing whitespace from the JSON fragment.
  local e = #raw_line
  while e > s and raw_line:sub(e, e) == " " do e = e - 1 end
  return s, e
end

--- Find the JSON highlight group for a single-codepoint fragment.
--- Returns a highlight group name or nil.
local function json_token_hl(ch)
  if ch == '"' then return "PosteJsonString"
  elseif ch == '{' or ch == '}' then return "PosteJsonBraces"
  elseif ch == '[' or ch == ']' then return "PosteJsonBrackets"
  elseif ch == ':' then return "PosteJsonColon"
  elseif ch == ',' then return "PosteJsonComma"
  else return nil
  end
end

--- Apply JSON extmark highlights inside the response body section of the
--- verbose view.
--- @param buf number Neovim buffer
--- @param lines table all verbose view lines (1-indexed)
--- @param body_start number 1-indexed line of the first body-content line
--- @param body_end number   1-indexed line of the last body-content line
local function apply_verbose_json_highlights(buf, lines, body_start, body_end)
  for i = body_start, body_end do
    local line = lines[i]
    local row = i - 1
    local s, e = json_byte_span(line)
    if s >= e then goto continue end

    -- Walk the JSON fragment byte by byte.
    local in_string = false
    local escape = false
    local j = s + 1 -- 1-based cursor over the byte stream
    local token_start = s + 1
    local token_hl = nil

    while j <= e do
      local ch = line:sub(j, j)
      -- Inside JSON strings, only quote toggles state; backslash escapes the next char.
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
      -- If a word token starts (key, number, bool, null), record it until delimiter/end.
      if not in_string and not new_hl and ch:match("%w") and not token_hl then
        -- peek: is the whole trailing fragment (minus trailing punctuation) a value?
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
        -- Close the prior word-token run.
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
        -- Single-char tokens are emitted immediately.
        vim.api.nvim_buf_set_extmark(buf, json_ns, row, j - 1, {
          end_row = row, end_col = j,
          hl_group = new_hl, priority = 200,
        })
      end

      j = j + 1
    end

    -- Flush a trailing word token.
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

  -- Pre-scan: locate the Response Body and Request Body sections (1-indexed
  -- start/end of the *content* lines), so we can skip them in the main loop
  -- and apply JSON highlighting below.  Also extract the request content-type
  -- from the Request Headers section.
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

    -- Response/Request body content: let JSON highlighting handle it (or leave plain).
    if in_body_section or in_req_body_section then
      goto next
    end

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

    -- Request name line: "  Name" (grey)
    elseif line:match("^  %S") and not line:match("^  %w+://") and not line:find(":", 3) then
      vim.api.nvim_buf_set_extmark(buf, verbose_ns, row, 0, {
        end_row = row, end_col = #line,
        hl_group = "PosteVerboseValue", priority = 100,
      })

    -- Label: value lines in General section or header sections
    -- (Response/Request Body content is skipped above so JSON lines don't get mangled.)
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
    ::next::
  end

  -- JSON highlighting for the response body section.
  if body_start and body_end and r and r.content_type then
    local mime = (r.content_type:match("^([^;]+)") or r.content_type):lower()
    if content_type_map[mime] == "json" then
      apply_verbose_json_highlights(buf, lines, body_start, body_end)
    end
  end

  -- JSON highlighting for the request body section.
  if req_body_start and req_body_end and req_content_type then
    local mime = (req_content_type:match("^([^;]+)") or req_content_type):lower()
    if content_type_map[mime] == "json" then
      apply_verbose_json_highlights(buf, lines, req_body_start, req_body_end)
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

--- Extract Content-Type from request headers metadata string.
--- Returns "" if not found.
function M.get_request_content_type(r)
  local req_headers = r.metadata and r.metadata.request_headers
  if not req_headers then return "" end
  for l in req_headers:gmatch("[^\r\n]+") do
    local k, v = l:match("^([^:]+):%s*(.+)$")
    if k and k:lower() == "content-type" then return v end
  end
  return ""
end

--- Format response data for a given view.
--- @param view string: "body", "verbose", "request", "assertions", "script_logs"
--- @param r table|nil: response table (nil for pending verbose)
--- @param opts table|nil: optional fields
---   .pending_request: request info for verbose pending mode
---   .assertion_results: assertion results (for assertions view)
---   .script_logs: script log entries (for script_logs view)
---   .jq_lines: pre-filtered jq lines (for body view in history)
--- @return table lines, string filetype
function M.format_view(view, r, opts)
  opts = opts or {}
  if view == "body" then
    if opts.jq_lines then
      return opts.jq_lines, "json"
    elseif not r or not r.body or r.body == "" then
      return { "(no response body)" }, "text"
    else
      return M.format_body(r), M.detect_filetype(r.content_type)
    end
  elseif view == "verbose" then
    return M.format_verbose(r, opts.pending_request), "text"
  elseif view == "assertions" then
    local ass = require("poste.http.assertions")
    return ass.format_assertions(opts.assertion_results), "poste_assertions"
  elseif view == "script_logs" then
    local scr = require("poste.http.scripts")
    return scr.format_script_logs(opts.script_logs), "markdown"
  elseif view == "request" then
    local lines = M.format_request_payload(r)
    local ct = M.get_request_content_type(r)
    local ft = (ct == "" or ct:lower():find("multipart/form%-data")) and "text" or M.detect_filetype(ct)
    return lines, ft
  end
  return { "Unknown view: " .. view }, "text"
end

--- Apply view-specific extmarks/highlights to a buffer.
--- @param buf number: buffer number
--- @param view string: "body", "verbose", "request", "assertions", "script_logs"
--- @param lines table: rendered lines
--- @param r table|nil: response table (nil for pending verbose)
function M.apply_view_highlights(buf, view, lines, r)
  -- Empty body hint
  if view == "body" and (not r or not r.body or r.body == "") then
    if lines[1] then
      local ns = vim.api.nvim_create_namespace("poste_response_hint")
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
        end_col = #lines[1],
        hl_group = "Comment",
      })
    end
  end

  -- File link highlight for binary/large responses
  if (view == "body" or view == "verbose") and r and r.metadata and r.metadata.file_path then
    M.apply_file_link_highlight(buf, lines)
  end

  -- Verbose highlights
  if view == "verbose" then
    pcall(vim.treesitter.stop, buf)
    M.apply_verbose_highlights(buf, lines, r)
  end

  -- Request highlights
  if view == "request" then
    M.apply_request_highlights(buf, lines)
  end

  -- Assertions highlights
  if view == "assertions" then
    pcall(vim.treesitter.stop, buf)
    local ass = require("poste.http.assertions")
    ass.apply_highlights(buf, lines)
  end
end

return M
