--- Copy HTTP request as curl command.
local M = {}

--- Shell-escape a string for curl argument
local function shell_escape(s)
  if not s or s == "" then
    return ""
  end
  -- If contains special chars, wrap in single quotes
  if s:match("['\"\\$`!#&|;(){}<>*?~]") or s:match("%s") then
    -- Escape single quotes within the string
    s = s:gsub("'", "'\\''")
    return "'" .. s .. "'"
  end
  return s
end

--- Extract current request block and convert to curl command.
--- Returns curl command string or nil, error_msg.
function M.copy_as_curl()
  local indicators = require("poste.indicators")
  local state = require("poste.state")

  local buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.fn.line(".")

  -- Find request block boundaries
  local start_line, end_line = indicators.find_request_block_bounds(buf, cursor_line)
  if not start_line then
    return nil, "No request block found at cursor"
  end

  -- Extract request block text
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local request_lines = {}

  for _, line in ipairs(lines) do
    -- Skip ### separator and comments
    if not line:match("^%s*###") and not line:match("^%s*#") then
      table.insert(request_lines, line)
    end
  end

  if #request_lines == 0 then
    return nil, "Empty request block"
  end

  -- First non-empty line is the request line (METHOD URL [HTTP/version])
  local request_line = nil
  local request_line_idx = nil
  for i, line in ipairs(request_lines) do
    if line:match("%S") then
      request_line = vim.trim(line)
      request_line_idx = i
      break
    end
  end

  if not request_line then
    return nil, "No request line found"
  end

  -- Parse METHOD URL
  local method, url = request_line:match("^(%S+)%s+(%S+)")
  if not method or not url then
    return nil, "Invalid request line: " .. request_line
  end

  -- Parse headers and body
  local headers = {}
  local body_lines = {}
  local in_headers = true

  for i = request_line_idx + 1, #request_lines do
    local line = request_lines[i]

    if in_headers then
      -- Empty line separates headers from body
      if not line:match("%S") then
        in_headers = false
      else
        -- Parse header line
        local key, value = line:match("^([^:]+):%s*(.+)$")
        if key and value then
          table.insert(headers, { vim.trim(key), vim.trim(value) })
        end
      end
    else
      -- Body content
      table.insert(body_lines, line)
    end
  end

  -- Remove trailing empty lines from body
  while #body_lines > 0 and not body_lines[#body_lines]:match("%S") do
    table.remove(body_lines)
  end

  -- Build curl command
  local parts = { "curl" }

  -- Method (only if not GET)
  if method:upper() ~= "GET" then
    table.insert(parts, "-X " .. method:upper())
  end

  -- URL
  table.insert(parts, shell_escape(url))

  -- Headers
  for _, h in ipairs(headers) do
    table.insert(parts, "-H " .. shell_escape(h[1] .. ": " .. h[2]))
  end

  -- Body
  if #body_lines > 0 then
    local body = table.concat(body_lines, "\n")
    table.insert(parts, "-d " .. shell_escape(body))
  end

  local curl_cmd = table.concat(parts, " \\\n  ")

  return curl_cmd
end

--- Copy current request as curl command to clipboard and notify.
--- register: '+' for system clipboard (default), '*' for X11 primary
function M.copy_to_clipboard(register)
  register = register or "+"

  local curl_cmd, err = M.copy_as_curl()
  if not curl_cmd then
    vim.notify("Failed to copy as curl: " .. err, vim.log.levels.ERROR, { title = "Poste" })
    return
  end

  -- Copy to register
  vim.fn.setreg(register, curl_cmd)

  -- Count lines for notification
  local line_count = 1
  for _ in curl_cmd:gmatch("\n") do
    line_count = line_count + 1
  end

  vim.notify(
    string.format("Copied curl command (%d lines) to %s clipboard", line_count, register == "+" and "system" or "X11"),
    vim.log.levels.INFO,
    { title = "Poste" }
  )
end

return M
