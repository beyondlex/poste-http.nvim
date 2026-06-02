--- Prompt variables, form data processing, and cross-request variable resolution.
local state = require("poste.state")
local poste_select = require("poste.select")
local assertions = require("poste.assertions")

local M = {}

-- Cache for executed request responses: { [request_name] = response_table }
local request_response_cache = {}

---------------------------------------------------------------------------
-- Form data (multipart/form-data, url-encoded, file uploads, magic vars)
---------------------------------------------------------------------------

--- Generate a UUID v4 (random). Safe for LuaJIT (math.random max 2^31-1).
local function generate_uuid()
  -- 32 hex digits in 8-4-4-4-12 groups, with version=4 and variant=10xx
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end)
end

--- Magic variables: {{name}} → generated value
local magic_vars = {
  timestamp = function() return tostring(os.time()) .. math.random(100000, 999999) end,
  uuid      = function() return generate_uuid() end,
  date      = function() return os.date("%Y-%m-%d") end,
  randomInt = function() return tostring(math.random(0, 9999999)) end,
}

--- Process form data magic variables and file inclusions in the request body.
--- - Replaces {{$timestamp}}, {{$uuid}}, {{$date}}, {{$randomInt}}
--- - Replaces lines like `< /path/to/file` with actual file contents
--- Operates on the current request block only.
function M.process_form_data(src_buf, cursor_line, content)
  local start_line, end_line = require("poste.indicators").find_request_block_bounds(src_buf, cursor_line)
  if not start_line then return content end

  -- Generate magic variable values once per request
  local generated = {}
  for name, gen in pairs(magic_vars) do
    generated[name] = gen()
  end

  local lines = vim.split(content, "\n", { plain = true })
  local result = {}

  for i, line in ipairs(lines) do
    if i >= start_line and i <= end_line then
      -- Replace all magic variables
      local processed = line
      for name, value in pairs(generated) do
        processed = processed:gsub("{{%$" .. name .. "}}", value)
      end

      -- Check if this is a file inclusion line: `< /path/to/file`
      local file_path = processed:match("^%s*<%s+(.+)$")
      if file_path then
        file_path = vim.trim(file_path)
        -- Expand ~ to home directory
        if file_path:sub(1, 1) == "~" then
          file_path = vim.fn.expand("~") .. file_path:sub(2)
        end
        -- Read file contents
        local f = io.open(file_path, "rb")
        if f then
          local file_content = f:read("*a")
          f:close()
          table.insert(result, file_content)
          state.log("INFO", string.format("Included file: %s (%d bytes)", file_path, #file_content))
        else
          state.log("ERROR", string.format("Cannot open file: %s", file_path))
          table.insert(result, processed)  -- keep original line on error
        end
      else
        table.insert(result, processed)
      end
    else
      table.insert(result, line)
    end
  end

  return table.concat(result, "\n")
end

---------------------------------------------------------------------------
-- Request variable helpers
---------------------------------------------------------------------------

--- Remove resolved @prompt lines from content (keep @var = value lines)
local function strip_prompt_lines(content)
  local result = {}
  for _, l in ipairs(vim.split(content, "\n", { plain = true })) do
    if not l:match("^%s*#%s*@prompt%s+%S+") then
      table.insert(result, l)
    end
  end
  return table.concat(result, "\n")
end

--- Collect all ### request blocks with their names and line ranges.
--- Returns list of { name = "Request Name", start_line = 1, end_line = 5 }
--- All line numbers are 1-indexed.
function M.collect_requests(buf)
  local requests = {}
  local total = vim.api.nvim_buf_line_count(buf)
  local i = 1

  while i <= total do
    local line_text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if line_text:match("^%s*###") then
      local name = vim.trim(line_text:gsub("^%s*###", ""))
      local start_line = i
      local end_line = total

      -- Find end of this block (next ### or EOF)
      for j = i + 1, total do
        local next_text = vim.api.nvim_buf_get_lines(buf, j - 1, j, false)[1] or ""
        if next_text:match("^%s*###") then
          end_line = j - 1
          break
        end
      end

      table.insert(requests, {
        name = name,
        start_line = start_line,
        end_line = end_line,
      })
      i = end_line + 1
    else
      i = i + 1
    end
  end

  return requests
end

---------------------------------------------------------------------------
-- Nested value access
---------------------------------------------------------------------------

--- Navigate a nested table using a dot-separated path.
--- Supports: "data.user.name" → data.user.name
---           "items[0].id"    → items[0].id (array indexing)
--- Automatically parses JSON strings when navigating deeper
local function get_nested_value(obj, path)
  if not obj or path == "" then return nil end

  local current = obj
  for part in path:gmatch("[^.]+") do
    -- If current is a string, try to parse it as JSON
    if type(current) == "string" then
      local ok, parsed = pcall(vim.json.decode, current)
      if ok and type(parsed) == "table" then
        current = parsed
      else
        return nil  -- Can't navigate into non-JSON string
      end
    end

    if type(current) ~= "table" then return nil end

    -- Handle array indexing: items[0] or items[2]
    local field, idx = part:match("^(.+)%[(%d+)%]$")
    if field and idx then
      -- Try exact field name first, then fallback to field[] suffix
      local arr = current[field]
      if arr == nil and type(current) == "table" then
        arr = current[field .. "[]"]
      end
      if type(arr) == "table" then
        current = arr[tonumber(idx) + 1]  -- Lua is 1-indexed
      else
        return nil
      end
    else
      -- Try exact key first, then fallback to key with [] suffix
      -- This handles cases like httpbin's "items[]" key being accessed as "items"
      local value = current[part]
      if value == nil and type(current) == "table" then
        value = current[part .. "[]"]
      end
      current = value
    end
  end

  return current
end

---------------------------------------------------------------------------
-- Request variable resolution
---------------------------------------------------------------------------

--- Extract a value from a cached request response.
--- pattern format: "RequestName.response.body.field.subfield"
---                 "RequestName.response.headers.Content-Type"
---                 "RequestName.request.headers.Authorization"
local function resolve_request_variable(pattern, cached_responses)
  -- Parse: RequestName.(response|request).(body|headers)[.path]
  local req_name, source, target = pattern:match("^([^%.]+)%.([^%.]+)%.([^%.]+)")
  if not req_name or not source or not target then
    return nil
  end

  -- Extract optional path after target (e.g., "body.user.name" → path = "user.name")
  local full_match = req_name .. "." .. source .. "." .. target
  local path = pattern:sub(#full_match + 2)  -- +2 for the dot separator

  local response = cached_responses[req_name]
  if not response then
    state.log("WARN", string.format("Request variable: '%s' not found in cache", req_name))
    return nil
  end

  if source == "response" then
    if target == "body" then
      local body = response.body
      if not body or body == "" then return nil end

      -- If no path, return the whole body
      if path == "" then return body end

      -- Try to parse as JSON and navigate
      local ok, parsed = pcall(vim.json.decode, body)
      if not ok then
        state.log("WARN", string.format("Cannot parse response body as JSON for '%s'", req_name))
        return nil
      end
      return get_nested_value(parsed, path)

    elseif target == "headers" then
      if not response.headers then return nil end
      for _, h in ipairs(response.headers) do
        if h[1]:lower() == path:lower() then
          return h[2]
        end
      end
    end

  elseif source == "request" then
    if target == "body" then
      local body = response.metadata and response.metadata.request_body
      if not body or body == "" or path == "" then return body end
      local ok, parsed = pcall(vim.json.decode, body)
      if ok then return get_nested_value(parsed, path) end

    elseif target == "headers" then
      local headers_str = response.metadata and response.metadata.request_headers
      if not headers_str then return nil end
      for line in headers_str:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^:]+):%s*(.+)$")
        if key and value and vim.trim(key):lower() == path:lower() then
          return vim.trim(value)
        end
      end
    end
  end

  return nil
end

--- Scan block text for request variable references: {{RequestName.response.body.field}}
--- Returns list of { full = "{{...}}", request_name = "RequestName" }
local function find_request_variable_refs(block_text)
  local refs = {}
  for full_ref in block_text:gmatch("{{([^}]+)}}") do
    -- Request variables contain .response. or .request.
    if full_ref:match("%.response%.") or full_ref:match("%.request%.") then
      local req_name = full_ref:match("^([^%.]+)%.")
      if req_name then
        table.insert(refs, { full = "{{" .. full_ref .. "}}", request_name = req_name })
      end
    end
  end
  return refs
end

---------------------------------------------------------------------------
-- Dependent request execution
---------------------------------------------------------------------------

--- Execute a dependent request and return its response.
--- Uses cache if available.
local function execute_dependent_request(binary, file, env_name, dep_req, buf_content)
  -- Check cache first
  if request_response_cache[dep_req.name] then
    state.log("INFO", string.format("Using cached response for '%s'", dep_req.name))
    return request_response_cache[dep_req.name]
  end

  -- Execute via CLI
  local cmd = string.format("%s run %s --line %d --env %s --json --stdin",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(file),
    dep_req.start_line,  -- 1-indexed, cursor on ### line
    vim.fn.shellescape(env_name)
  )

  state.log("INFO", string.format("Executing dependent request '%s' at line %d", dep_req.name, dep_req.start_line))

  -- Capture stdout/stderr in buffers
  local stdout_buf = {}
  local stderr_buf = {}

  local job_id = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout_buf, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_buf, line)
          end
        end
      end
    end,
  })

  if job_id <= 0 then
    state.log("ERROR", "Failed to start job for dependent request")
    return nil
  end

  -- Send buffer content (with prompts and assertions already resolved)
  local clean_content = strip_prompt_lines(buf_content)
  clean_content = assertions.extract_assertion_blocks(clean_content)
  vim.fn.chansend(job_id, clean_content)
  vim.fn.chanclose(job_id, "stdin")

  -- Wait for completion (blocking)
  local exit_codes = vim.fn.jobwait({ job_id })
  if exit_codes[1] ~= 0 then
    state.log("WARN", string.format("Dependent request '%s' failed with exit code %d", dep_req.name, exit_codes[1]))
    if #stderr_buf > 0 then
      state.log("WARN", "stderr: " .. table.concat(stderr_buf, "\n"))
    end
    return nil
  end

  -- Parse output
  if #stdout_buf == 0 then
    state.log("WARN", "No output from dependent request")
    return nil
  end

  local stdout_text = table.concat(stdout_buf, "\n")
  local ok, parsed = pcall(vim.json.decode, stdout_text)
  if not ok then
    state.log("WARN", string.format("Failed to parse dependent request response: %s", stdout_text:sub(1, 100)))
    return nil
  end

  -- Cache the response
  request_response_cache[dep_req.name] = parsed
  state.log("INFO", string.format("Cached response for '%s'", dep_req.name))

  return parsed
end

---------------------------------------------------------------------------
-- Prompt variables (@prompt directives)
---------------------------------------------------------------------------

--- Handle @prompt directives in the current request block only.
--- Syntax:
---   # @prompt variable_name                   → text input
---   # @prompt variable_name [opt1, opt2, ...] → selection from list (up/down arrows)
---   # @prompt variable_name [{{Req.response.body.field}}] → dynamic options from request response
--- Only processes @prompt lines within the request block containing cursor_line.
--- Always prompts for input (no caching) so users can use different values each time.
--- Processes prompts asynchronously and calls on_complete with modified content.
--- on_complete(modified_content) is called when all prompts are resolved.
function M.handle_prompt_variables(buf, cursor_line, content, binary, file, env_name, on_complete)
  local indicators = require("poste.indicators")
  local start_line, end_line = indicators.find_request_block_bounds(buf, cursor_line)
  if not start_line then
    on_complete(content)
    return
  end

  local lines = vim.split(content, "\n", { plain = true })
  local result = {}
  local idx = 1

  local function process_next()
    if idx > #lines then
      on_complete(table.concat(result, "\n"))
      return
    end

    local line = lines[idx]
    local line_num = idx
    idx = idx + 1

    -- Only process @prompt within the current request block (1-indexed)
    if line_num >= start_line and line_num <= end_line then
      -- Match: # @prompt varname [opt1, opt2, ...]  (selection mode)
      local varname_sel, options_str = line:match("^%s*#%s*@prompt%s+(%S+)%s*%[(.+)%]")

      if varname_sel and options_str then
        -- Check if options contain a request variable reference
        local ref_match = options_str:match("{{([^}]+%.response%.[^}]+)}}")

        if ref_match then
          -- Dynamic options: resolve request variable reference
          local requests = M.collect_requests(buf)
          local req_name = ref_match:match("^([^%.]+)%.")

          if req_name then
            -- Find the referenced request
            local dep_req = nil
            for _, req in ipairs(requests) do
              if req.name == req_name then
                dep_req = req
                break
              end
            end

            if dep_req then
              -- Execute the dependent request
              local response = execute_dependent_request(binary, file, env_name, dep_req, content)
              if response then
                -- Extract the array from response using the path
                local value = resolve_request_variable(ref_match, { [req_name] = response })
                if value and type(value) == "table" then
                  -- Use array values as options
                  local options = {}
                  for _, item in ipairs(value) do
                    if type(item) == "string" then
                      table.insert(options, item)
                    elseif type(item) == "number" then
                      table.insert(options, tostring(item))
                    elseif type(item) == "table" then
                      -- If it's an object, try to stringify it
                      table.insert(options, vim.inspect(item))
                    end
                  end

                  if #options > 0 then
                    -- Use built-in floating window selector (async)
                    local prompt = string.format("Select value for '%s'", varname_sel)
                    poste_select.select(options, prompt, function(selected)
                      if selected then
                        table.insert(result, string.format("@%s = %s", varname_sel, selected))
                      else
                        -- User cancelled
                        table.insert(result, line)
                      end
                      process_next()
                    end)
                    return
                  end
                end
              end
            end
            -- If we get here, something went wrong with dynamic options
            state.log("WARN", string.format("Could not resolve dynamic options for '%s'", varname_sel))
          end
        end

        -- Static options: parse by splitting on comma and trimming
        local options = {}
        for opt in options_str:gmatch("[^,]+") do
          local trimmed = vim.trim(opt)
          if trimmed ~= "" then
            table.insert(options, trimmed)
          end
        end

        if #options == 0 then
          table.insert(result, line)
          process_next()
          return
        end

        -- Use built-in floating window selector (async)
        local prompt = string.format("Select value for '%s'", varname_sel)
        poste_select.select(options, prompt, function(selected)
          if selected then
            table.insert(result, string.format("@%s = %s", varname_sel, selected))
          else
            -- User cancelled
            table.insert(result, line)
          end
          process_next()
        end)
        return
      else
        -- Match: # @prompt varname  (text input mode)
        local varname = line:match("^%s*#%s*@prompt%s+(%S+)")

        if varname then
          -- vim.fn.input is blocking but handles its own event loop
          vim.schedule(function()
            local ok, value = pcall(vim.fn.input, {
              prompt = string.format("Enter value for '%s': ", varname),
              default = "",
            })

            if ok and value and value ~= "" then
              table.insert(result, string.format("@%s = %s", varname, value))
            else
              table.insert(result, line)
            end
            process_next()
          end)
          return
        end
      end
    end

    -- No prompt on this line
    table.insert(result, line)
    process_next()
  end

  process_next()
end

---------------------------------------------------------------------------
-- Request variable resolution (cross-request references)
---------------------------------------------------------------------------

--- Resolve all request variables in the buffer content for the current request block.
--- Executes dependent requests if not already cached.
--- Returns modified buffer content with variables substituted.
function M.resolve_request_variables(binary, file, env_name, buf, cursor_line, content)
  local requests = M.collect_requests(buf)

  -- Find the current request block
  local current_req = nil
  for _, req in ipairs(requests) do
    if cursor_line >= req.start_line and cursor_line <= req.end_line then
      current_req = req
      break
    end
  end

  if not current_req then
    return content
  end

  -- Extract current block text
  local all_lines = vim.split(content, "\n", { plain = true })
  local block_lines = {}
  for i = current_req.start_line, current_req.end_line do
    table.insert(block_lines, all_lines[i] or "")
  end
  local block_text = table.concat(block_lines, "\n")

  -- Find request variable references
  local refs = find_request_variable_refs(block_text)
  if #refs == 0 then
    return content
  end

  state.log("INFO", string.format("Found %d request variable reference(s)", #refs))

  -- Execute dependent requests and build cache
  local cached_responses = {}
  for _, ref in ipairs(refs) do
    if not cached_responses[ref.request_name] then
      -- Find the request block
      local dep_req = nil
      for _, req in ipairs(requests) do
        if req.name == ref.request_name then
          dep_req = req
          break
        end
      end

      if dep_req then
        local response = execute_dependent_request(binary, file, env_name, dep_req, content)
        if response then
          cached_responses[ref.request_name] = response
        end
      else
        state.log("WARN", string.format("Referenced request '%s' not found", ref.request_name))
      end
    end
  end

  -- Substitute variables in block text
  local resolved_block = block_text
  for _, ref in ipairs(refs) do
    local value = resolve_request_variable(ref.full:sub(3, -3), cached_responses)  -- strip {{ }}
    if value then
      resolved_block = resolved_block:gsub(vim.pesc(ref.full), tostring(value))
    else
      state.log("WARN", string.format("Could not resolve variable: %s", ref.full))
    end
  end

  -- Replace block in full content
  local result_lines = {}
  for i, l in ipairs(all_lines) do
    if i >= current_req.start_line and i <= current_req.end_line then
      table.insert(result_lines, vim.split(resolved_block, "\n", { plain = true })[i - current_req.start_line + 1] or l)
    else
      table.insert(result_lines, l)
    end
  end

  return table.concat(result_lines, "\n")
end

--- Cache the current request's response for use by subsequent request variables
function M.cache_response(req_name, response)
  if req_name then
    request_response_cache[req_name] = response
  end
end

return M
