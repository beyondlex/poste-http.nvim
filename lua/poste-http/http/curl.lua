--- Curl command parser: converts curl commands to HTTP request format.
local M = {}

--- Read a file for import-time expansion. Text-oriented on purpose: the
--- importer pastes into an editable buffer, so binary @file bodies are out
--- of scope.
local function read_import_file(path)
  if not path or path == "" then return nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then return nil end
  return table.concat(lines, "\n")
end

--- Percent-encode like curl --data-urlencode: everything outside the
--- RFC 3986 unreserved set, with space as %20.
local function urlencode(s)
  return (s:gsub("[^%w%-_.~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

--- curl --data-urlencode piece forms: `name=value`, `=content`, `content`,
--- and the file forms `name@file` / `@file` / `name>file` / `>file` whose
--- content is read and encoded now (the import bakes it in).
local function build_urlencode_piece(piece)
  local file_name, path = piece:match("^([^=@]*)[@>](.+)$")
  if file_name then
    local content = read_import_file(vim.trim(path))
    if not content then return nil end
    if file_name == "" then return urlencode(content) end
    return file_name .. "=" .. urlencode(content)
  end
  local key, value = piece:match("^([^=]+)=(.*)$")
  if key then return key .. "=" .. urlencode(value) end
  if piece:sub(1, 1) == "=" then return urlencode(piece:sub(2)) end
  return urlencode(piece)
end

--- Expand curl's `@file` data bodies (-d/--data/--data-binary; --data-raw
--- never expands). The import bakes the content in because the only .http
--- body file reference (`< path`) is multipart-only.
local function maybe_expand_data(value)
  if type(value) == "string" and value:sub(1, 1) == "@" then
    local content = read_import_file(value:sub(2))
    if content then return content end
  end
  return value
end

--- Parse curl command and extract method, URL, headers, and body.
--- Supports: curl -X METHOD, -H header (incl. empty-value `Name:`/`Name;`),
--- -d/--data/--data-binary (incl. @file), --data-raw, --data-urlencode
--- Returns: { method = "POST", url = "...", headers = {...}, body = "..." }
local function parse_curl(cmd)
  if not cmd or cmd == "" then
    return nil, "Empty curl command"
  end

  -- Remove leading/trailing whitespace and line continuations
  cmd = vim.trim(cmd)
  cmd = cmd:gsub("\\\n", " ")  -- Remove backslash-newline continuations
  cmd = cmd:gsub("\\\r\n", " ")

  -- Remove "curl" command itself
  cmd = cmd:gsub("^curl%s+", "")

  local method = "GET"
  local url = ""
  local headers = {}
  local body = nil

  -- Parse arguments
  local args = {}
  local current = ""
  local in_quotes = false
  local quote_char = nil
  local i = 1

  while i <= #cmd do
    local char = cmd:sub(i, i)

    if not in_quotes then
      if char == '"' or char == "'" then
        in_quotes = true
        quote_char = char
      elseif char == ' ' or char == '\t' then
        if #current > 0 then
          table.insert(args, current)
          current = ""
        end
      else
        current = current .. char
      end
    else
      if char == quote_char then
        in_quotes = false
        quote_char = nil
      else
        current = current .. char
      end
    end

    i = i + 1
  end

  if #current > 0 then
    table.insert(args, current)
  end

  -- Process arguments
  local urlencode_parts = {}
  local had_content_type = false

  local function promote_post()
    if method == "GET" then
      method = "POST"
    end
  end

  local function header_from_text(text)
    -- `Name:` (empty value) and curl's `Name;` no-value form are kept as
    -- empty-value headers instead of being dropped.
    local key, value = text:match("^([^:;]+):%s*(.*)$")
    if not key then
      key = vim.trim(text:match("^([^;]+);%s*$") or "")
      value = ""
    end
    if key and key ~= "" then
      table.insert(headers, { key, value })
      if key:lower() == "content-type" then
        had_content_type = true
      end
    end
  end

  local idx = 1
  while idx <= #args do
    local arg = args[idx]

    if arg == "-X" or arg == "--request" then
      idx = idx + 1
      method = (args[idx] or "GET"):upper()
    elseif arg:match("^%-X.") then
      -- Attached form: -XPOST
      method = arg:sub(3):upper()
    elseif arg:match("^%-%-request=") then
      method = arg:sub(#"--request=" + 1):upper()
    elseif arg == "-H" or arg == "--header" then
      idx = idx + 1
      local header = args[idx]
      if header then
        header_from_text(header)
      end
    elseif arg:match("^%-H.") then
      -- Attached form: -H'Content-Type: ...'
      header_from_text(arg:sub(3))
    elseif arg:match("^%-%-header=") then
      header_from_text(arg:sub(#"--header=" + 1))
    elseif arg == "--data-urlencode" then
      idx = idx + 1
      local piece = args[idx]
      if piece then
        local built = build_urlencode_piece(piece)
        if built then
          table.insert(urlencode_parts, built)
        end
      end
      promote_post()
    elseif arg:match("^%-%-data%-urlencode=") then
      local built = build_urlencode_piece(arg:sub(#"--data-urlencode=" + 1))
      if built then
        table.insert(urlencode_parts, built)
      end
      promote_post()
    elseif arg == "-d" or arg == "--data" or arg == "--data-binary" then
      idx = idx + 1
      body = maybe_expand_data(args[idx])
      promote_post()
    elseif arg:match("^%-d.") then
      -- Attached form: -d'{}', -d@file
      body = maybe_expand_data(arg:sub(3))
      promote_post()
    elseif arg == "--data-raw" then
      idx = idx + 1
      -- --data-raw never expands @file, matching curl
      body = args[idx]
      promote_post()
    elseif arg:match("^%-%-data=") then
      body = maybe_expand_data(arg:sub(#"--data=" + 1))
      promote_post()
    elseif arg:match("^%-%-data%-binary=") then
      body = maybe_expand_data(arg:sub(#"--data-binary=" + 1))
      promote_post()
    elseif arg:match("^%-%-data%-raw=") then
      -- --data-raw never expands @file, matching curl
      body = arg:sub(#"--data-raw=" + 1)
      promote_post()
    else
      -- Assume it's the URL
      if not arg:match("^-") then
        url = arg
      end
    end

    idx = idx + 1
  end

  if url == "" then
    return nil, "No URL found in curl command"
  end

  -- curl concatenates every data piece (-d, --data-binary,
  -- --data-urlencode) with & before sending; mirror that, and give the
  -- request the form content-type unless the command set one itself.
  if #urlencode_parts > 0 then
    if body then
      table.insert(urlencode_parts, 1, body)
    end
    body = table.concat(urlencode_parts, "&")
    if not had_content_type then
      table.insert(headers, { "Content-Type", "application/x-www-form-urlencoded" })
    end
  end

  return {
    method = method,
    url = url,
    headers = headers,
    body = body,
  }
end

--- Convert parsed curl to HTTP request format lines.
--- Returns array of lines to insert.
local function curl_to_http(parsed)
  local lines = {}

  -- Request separator
  table.insert(lines, "###")

  -- Request line
  table.insert(lines, string.format("%s %s", parsed.method, parsed.url))

  -- Headers
  for _, h in ipairs(parsed.headers) do
    table.insert(lines, string.format("%s: %s", h[1], h[2]))
  end

  -- Body (if present): split multi-line body into separate lines, keeping
  -- interior blank lines (they are part of the body); only trailing
  -- newlines are dropped.
  if parsed.body then
    table.insert(lines, "")  -- Empty line before body
    local normalized = parsed.body:gsub("\r\n", "\n"):gsub("\r", "\n")
    local body_lines = vim.split(normalized, "\n", { plain = true })
    while #body_lines > 0 and vim.trim(body_lines[#body_lines]) == "" do
      table.remove(body_lines)
    end
    for _, body_line in ipairs(body_lines) do
      table.insert(lines, body_line)
    end
  end

  return lines
end

--- Read curl command from clipboard and insert as HTTP request at cursor.
--- register: '+' for system clipboard, '*' for X11 primary, or any vim register
function M.paste_curl(register)
  register = register or "+"

  -- Read from register
  local content = vim.fn.getreg(register)
  if not content or content == "" then
    vim.notify("Clipboard is empty", vim.log.levels.WARN, { title = "Poste" })
    return
  end

  -- Parse curl command
  local parsed, err = parse_curl(content)
  if not parsed then
    vim.notify("Failed to parse curl: " .. err, vim.log.levels.ERROR, { title = "Poste" })
    return
  end

  -- Convert to HTTP format
  local lines = curl_to_http(parsed)

  -- Insert at current cursor position
  local row = vim.fn.line(".")
  vim.api.nvim_buf_set_lines(0, row, row, false, lines)

  vim.notify("Inserted HTTP request from clipboard", vim.log.levels.INFO, { title = "Poste" })
end

--- Exposed for tests and future importers; paste_curl is the user entry.
M.parse_curl = parse_curl

return M
