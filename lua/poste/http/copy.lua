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

--- Walk up from directory looking for env.json and return current env's variables.
local function load_env_vars(file_path, env_name)
  if not file_path or file_path == "" then return {} end
  if not env_name or env_name == "" then return {} end
  local dir = vim.fn.fnamemodify(file_path, ":h")
  local seen = {}
  while true do
    local candidate = dir .. "/env.json"
    if not seen[dir] and vim.fn.filereadable(candidate) == 1 then
      seen[dir] = true
      local f = io.open(candidate, "r")
      if f then
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(vim.json.decode, content)
        if ok and type(data) == "table" then
          return data[env_name] or {}
        end
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return {}
end

--- Simple {{var}} substitution with iterative resolution (handles nested refs).
local function substitute_vars(text, vars)
  local result = text
  for _ = 1, 20 do
    local next = result:gsub("{{([^}]+)}}", function(var_name)
      return vars[var_name] or "{{" .. var_name .. "}}"
    end)
    if next == result then break end
    result = next
  end
  return result
end

--- Collect @var definitions from a list of lines (single-line: @name = value or @name value).
--- Returns a table of {name = value, ...}.
local function collect_var_defs(lines)
  local vars = {}
  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed:sub(1, 1) == "@" then
      local name, value = trimmed:match("^@(%S+)%s*=%s*(.+)")
      if not name then
        name, value = trimmed:match("^@(%S+)%s+(.+)")
      end
      if name and value then
        value = value:match("^'(.-)'$") or value:match('^"(.-)"$') or value
        vars[name] = value
      end
    end
  end
  return vars
end

--- Resolve variables in request block content:
--- 1. Collect file-level @var defs (before the block)
--- 2. Load env.json for current env
--- 3. Collect request-level @var defs (within the block)
--- 4. Resolve {{var}} iteratively
--- 5. Replace magic vars ({{$timestamp}}, {{$uuid}}, {{$date}}, {{$randomInt}})
--- 6. Handle file inclusion lines (< /path/to/file)
local function resolve_request_content(buf, raw_lines, block_start_line)
  local state = require("poste.state")

  -- 1. File-level @var definitions
  local file_lines = block_start_line > 1
    and vim.api.nvim_buf_get_lines(buf, 0, block_start_line - 2, false) or {}
  local vars = collect_var_defs(file_lines)

  -- 2. env.json variables
  local file_path = vim.api.nvim_buf_get_name(buf)
  local env_vars = load_env_vars(file_path, state.current_env)
  for k, v in pairs(env_vars) do
    vars[k] = v
  end

  -- 3. Resolve file-level vars (they may reference each other or env)
  vars = collect_var_defs(file_lines)
  for name, value in pairs(vars) do
    vars[name] = substitute_vars(value, vars)
  end
  -- Re-merge env vars after resolution (env takes lower priority)
  for k, v in pairs(env_vars) do
    if not vars[k] then vars[k] = v end
  end

  -- 4. Resolve content: join, substitute magic vars, substitute {{var}}, handle file includes
  local content = table.concat(raw_lines, "\n")

  -- Magic vars
  content = content:gsub("{{%$timestamp}}", tostring(os.time()) .. math.random(100000, 999999))
  content = content:gsub("{{%$uuid}}", function()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return template:gsub("[xy]", function(c)
      local r = math.random(0, 15)
      local v = c == "x" and r or (r % 4) + 8
      return string.format("%x", v)
    end)
  end)
  content = content:gsub("{{%$date}}", os.date("%Y-%m-%d"))
  content = content:gsub("{{%$randomInt}}", tostring(math.random(0, 9999999)))

  -- {{var}} substitution
  content = substitute_vars(content, vars)

  -- File inclusion lines: < /path/to/file
  local inc_lines = vim.split(content, "\n", { plain = true })
  local out_lines = {}
  for _, line in ipairs(inc_lines) do
    local file_path_inc = line:match("^%s*<%s+(.+)$")
    if file_path_inc then
      file_path_inc = vim.trim(file_path_inc)
      if file_path_inc:sub(1, 1) == "~" then
        file_path_inc = vim.fn.expand("~") .. file_path_inc:sub(2)
      end
      local f = io.open(file_path_inc, "rb")
      if f then
        table.insert(out_lines, f:read("*a"))
        f:close()
      else
        table.insert(out_lines, line)
      end
    else
      table.insert(out_lines, line)
    end
  end
  content = table.concat(out_lines, "\n")

  return vim.split(content, "\n", { plain = true })
end

--- Extract current request block and convert to curl command.
--- Returns curl command string or nil, error_msg.
function M.copy_as_curl()
  local indicators = require("poste.indicators")
  local _ = require("poste.state")

  local buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.fn.line(".")

  -- Find request block boundaries
  local start_line, end_line = indicators.find_request_block_bounds(buf, cursor_line)
  if not start_line then
    return nil, "No request block found at cursor"
  end

  -- Extract request block text
  local raw_lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local resolved_lines = resolve_request_content(buf, raw_lines, start_line)
  local request_lines = {}

  for _, line in ipairs(resolved_lines) do
    -- Skip ### separator, comments, and @var definitions
    if not line:match("^%s*###") and not line:match("^%s*#") and not line:match("^%s*@%S+") then
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
