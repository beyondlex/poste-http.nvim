--- Curl command parser: converts curl commands to HTTP request format.
local M = {}

--- Parse curl command and extract method, URL, headers, and body.
--- Supports: curl -X METHOD, -H header, -d/--data, --data-raw, --data-binary
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
  local idx = 1
  while idx <= #args do
    local arg = args[idx]

    if arg == "-X" or arg == "--request" then
      idx = idx + 1
      method = (args[idx] or "GET"):upper()
    elseif arg:match("^-H") or arg:match("^--header") then
      idx = idx + 1
      local header = args[idx]
      if header then
        local key, value = header:match("^([^:]+):%s*(.+)$")
        if key and value then
          table.insert(headers, { key, value })
        end
      end
    elseif arg == "-d" or arg == "--data" or arg == "--data-raw" or arg == "--data-binary" then
      idx = idx + 1
      body = args[idx]
      -- Default to POST if body is provided
      if method == "GET" then
        method = "POST"
      end
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

  -- Body (if present): split multi-line body into separate lines
  if parsed.body then
    table.insert(lines, "")  -- Empty line before body
    local normalized = parsed.body:gsub("\r\n", "\n"):gsub("\r", "\n")
    for body_line in normalized:gmatch("([^\n]+)") do
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

return M
