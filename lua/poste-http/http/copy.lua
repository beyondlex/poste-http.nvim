--- Copy HTTP request as curl command.
local state = require("poste-http.state")
local util = require("poste-http.util")
local vars = require("poste-http.http.vars")
local request_deps = require("poste-http.http.request_deps")

local M = {}
-- Shell-escaping goes through util.shell_escape (the whitelist dialect).
-- This module used to keep its own blacklist-based variant and the two
-- drifted (util quoted more inputs); every caller below produces non-empty
-- strings, so util's `''`-for-empty contract never fires here.

--- Walk up from directory looking for env.json and return current env's variables.
local function load_env_vars(file_path, env_name)
  if not file_path or file_path == "" then return {} end
  if not env_name or env_name == "" then return {} end
  local dir = vim.fn.fnamemodify(file_path, ":h")
  local seen = {}
  while true do
    local candidate = vim.fs.joinpath(dir, "env.json")
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
--- `var_map` avoids shadowing the poste-http.http.vars module upvalue.
local function substitute_vars(text, var_map)
  local result = text
  for _ = 1, 20 do
    local next_result = result:gsub("{{([^}]+)}}", function(var_name)
      return var_map[var_name] or "{{" .. var_name .. "}}"
    end)
    if next_result == result then break end
    result = next_result
  end
  return result
end

--- Collect @var definitions from a list of lines (single-line: @name = value or @name value).
--- Returns a table of {name = value, ...}.
local function collect_var_defs(lines)
  local var_map = {}
  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed:sub(1, 1) == "@" then
      local name, value = trimmed:match("^@(%S+)%s*=%s*(.+)")
      if not name then
        name, value = trimmed:match("^@(%S+)%s+(.+)")
      end
      if name and value then
        value = value:match("^'(.-)'$") or value:match('^"(.-)"$') or value
        var_map[name] = value
      end
    end
  end
  return var_map
end

--- Collect variables from file-level @var defs, block-level @var defs,
--- env.json, and session vars (client.global + script_variables).
--- block_lines (optional) are the raw request-block lines; block defs
--- override file-level ones, matching the resolver's precedence.
local function collect_vars(buf, block_start_line, block_lines)
  -- File-level region: every line above the block's separator (the
  -- request's start_line). start_line - 1 is the 0-based exclusive end,
  -- so the line directly above the separator is included.
  local file_lines = block_start_line > 1
    and vim.api.nvim_buf_get_lines(buf, 0, block_start_line - 1, false) or {}
  local file_path = vim.api.nvim_buf_get_name(buf)
  local env_vars = load_env_vars(file_path, state.current_env)
  local var_map = collect_var_defs(file_lines)
  if block_lines then
    for k, v in pairs(collect_var_defs(block_lines)) do
      var_map[k] = v
    end
  end
  -- Env vars must be present BEFORE substituting, so file-level @vars can
  -- reference {{env_keys}} (the earlier code recomputed vars here, wiping
  -- the merge and leaving {{env_refs}} literal in the copied command).
  for k, v in pairs(env_vars) do
    var_map[k] = v
  end
  for name, value in pairs(var_map) do
    var_map[name] = substitute_vars(value, var_map)
  end
  for k, v in pairs(env_vars) do
    if not var_map[k] then var_map[k] = v end
  end
  -- Add session-scoped vars from client.global.set and request.variables.set
  if state.global_vars then
    for k, v in pairs(state.global_vars) do
      var_map[k] = v
    end
  end
  if state.script_variables then
    for k, v in pairs(state.script_variables) do
      var_map[k] = v
    end
  end
  return var_map
end

--- Resolve a relative file path against the buffer directory.
local function resolve_file_path(path, buf_dir)
  if not path or path == "" then return nil end
  path = vim.trim(path)
  if path:sub(1, 1) == "~" then
    return vim.fn.expand("~") .. path:sub(2)
  elseif path:sub(1, 1) ~= "/" then
    return vim.fn.simplify(buf_dir .. "/" .. path)
  end
  return path
end

--- Build -F flags from multipart/form-data body lines (before resolution).
--- raw_lines: body lines from the .http file (unresolved)
local function build_multipart_flags(raw_lines, boundary, buf_dir, var_map)
  local flags = {}
  local boundary_delim = "--" .. boundary
  local closing_boundary = boundary_delim .. "--"
  local current_name
  local current_value = {}
  local in_headers = true
  local file_path

  local function flush_part()
    if not current_name then return end
    if file_path then
      local resolved = resolve_file_path(file_path, buf_dir)
      if resolved then
        table.insert(flags, "-F " .. util.shell_escape(current_name .. "=@" .. resolved))
      end
    else
      local value = substitute_vars(table.concat(current_value), var_map)
      value = value:gsub("{{%$timestamp}}", tostring(os.time()))
      value = value:gsub("{{%$uuid}}", function()
        local t = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
        return t:gsub("[xy]", function(c)
          local r = math.random(0, 15)
          return string.format("%x", c == "x" and r or (r % 4) + 8)
        end)
      end)
      value = value:gsub("{{%$date}}", os.date("%Y-%m-%d"))
      value = value:gsub("{{%$randomInt}}", tostring(math.random(0, 9999999)))
      table.insert(flags, "-F " .. util.shell_escape(current_name .. "=" .. value))
    end
  end

  for _, line in ipairs(raw_lines) do
    local trimmed = vim.trim(line)
    if trimmed == closing_boundary then
      flush_part()
      current_name = nil
      break
    elseif trimmed == boundary_delim then
      flush_part()
      current_name = nil
      current_value = {}
      in_headers = true
      file_path = nil
    elseif in_headers then
      if not line:match("%S") then
        in_headers = false
      else
        local name = line:match('Content%-Disposition:.-name="([^"]+)"')
        if name then current_name = name end
      end
    else
      local ref = line:match("^%s*<%s+(.+)$")
      if ref then
        file_path = vim.trim(ref)
      else
        table.insert(current_value, line)
      end
    end
  end
  flush_part()
  return flags
end

--- Extract current request block and convert to curl command.
--- Returns curl command string or nil, error_msg.
function M.copy_as_curl()
  local cache = require("poste-http.http.cache")

  local buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.fn.line(".")

  -- Find request block boundaries
  local start_line, end_line = cache.find_request_block_bounds(buf, cursor_line)
  if not start_line then
    return nil, "No request block found at cursor"
  end

  -- Build VarResolver with all variable layers
  local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local buf_path = vim.api.nvim_buf_get_name(buf)
  local resolver = vars.build_resolver_from_state({
    buf = buf,
    lines = buf_lines,
    file_path = buf_path,
    block_start = start_line,
    block_end = end_line,
    env_name = state.current_env,
  })

  -- Resolve variables in the raw block content
  local raw_lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local resolved_content = vars.substitute_vars(table.concat(raw_lines, "\n"), resolver)

  -- Resolve cross-request {{Name.response.body.X}} / {{Name.request.body.X}}
  -- references from cached responses. This does not trigger new requests;
  -- unresolved refs are left as-is, matching `gi` behavior.
  resolved_content = resolved_content:gsub("{{(.-)}}", function(var_name)
    var_name = vim.trim(var_name)
    if var_name:gsub("%.res%.", ".response."):match("%.response%.") or var_name:match("%.request%.") then
      local resolved = request_deps.resolve_single_ref(var_name)
      if resolved ~= nil then
        return request_deps.value_to_http_string(resolved)
      end
    end
    return "{{" .. var_name .. "}}"
  end)

  local resolved_lines = vim.split(resolved_content, "\n", { plain = true })
  local request_lines = {}
  local in_script = false

  for _, line in ipairs(resolved_lines) do
    if line:match("^%s*%%}") then
      in_script = false
    elseif line:match("^%s*[<>]%s*{%%") then
      in_script = true
    elseif not in_script and not (line:match("^%s*###") or line:match("^%s*#") or line:match("^%s*@%S+")) then
      -- skips: separators, comments, @var definitions, script bodies
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
  table.insert(parts, util.shell_escape(url))

  -- Detect multipart/form-data (extract boundary from raw header)
  local is_multipart = false
  local boundary
  for _, h in ipairs(headers) do
    if h[1]:lower() == "content-type" then
      local b = h[2]:match("boundary=([^;]+)")
      if h[2]:find("multipart/form%-data") and b then
        is_multipart = true
        boundary = vim.trim(b)
      end
    end
  end

  -- Parse raw body lines (before resolution) for multipart -F conversion
  local raw_body_lines = {}
  if is_multipart then
    local in_raw_headers = true
    for i = 2, #raw_lines do
      local line = raw_lines[i]
      if in_raw_headers then
        if not line:match("%S") then
          in_raw_headers = false
        end
      else
        table.insert(raw_body_lines, line)
      end
    end
  end

  local buf_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":h")
  if buf_dir == "" then buf_dir = vim.fn.getcwd() end

  -- Headers (skip Content-Type for multipart — curl sets it for -F)
  for _, h in ipairs(headers) do
    if not (is_multipart and h[1]:lower() == "content-type") then
      table.insert(parts, "-H " .. util.shell_escape(h[1] .. ": " .. h[2]))
    end
  end

  -- Body
  if #body_lines > 0 then
    if is_multipart and #raw_body_lines > 0 then
      -- Magic-var generation below draws math.random without going through
      -- the resolver's seeding path: arm it explicitly or the first copied
      -- {{$uuid}}/{{$randomInt}} repeats the session's fixed LuaJIT sequence.
      util.seed_random()
      local var_map = collect_vars(buf, start_line, raw_lines)
      local f_flags = build_multipart_flags(raw_body_lines, boundary, buf_dir, var_map)
      for _, flag in ipairs(f_flags) do
        table.insert(parts, flag)
      end
    else
      local body = table.concat(body_lines, "\n")
      table.insert(parts, "--data-binary " .. util.shell_escape(body))
    end
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

-- Test hook: collect_vars is internal; exposed for specs only.
M._collect_vars = collect_vars

return M
