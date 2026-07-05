--- Prompt variables, form data processing, and cross-request variable resolution.
local state = require("poste.state")
local poste_select = require("poste.select")
local assertions = require("poste.http.assertions")

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

--- Process form data magic variables in the request body.
--- - Replaces {{$timestamp}}, {{$uuid}}, {{$date}}, {{$randomInt}}
--- Does NOT expand `< file` directives — that happens in the Rust executor
--- after block parsing (to avoid ### in file content corrupting block boundaries).
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
      table.insert(result, processed)
    else
      table.insert(result, line)
    end
  end

  return table.concat(result, "\n")
end

---------------------------------------------------------------------------
-- Request variable helpers
---------------------------------------------------------------------------

--- Remove resolved prompt directive lines from content (keep @var = value lines)
local function strip_prompt_lines(content)
  local result = {}
  for _, l in ipairs(vim.split(content, "\n", { plain = true })) do
    if not l:match("^%s*<<%S+") then
      table.insert(result, l)
    end
  end
  return table.concat(result, "\n")
end

--- Collect all ### request blocks with their names and line ranges.
--- Delegates to cache.lua block index.
--- Returns list of { name = "Request Name", start_line = 1, end_line = 5 }
--- All line numbers are 1-indexed.
function M.collect_requests(buf)
  local cache = require("poste.http.cache")
  local bc = cache.get_buffer_cache(buf)
  local requests = {}
  for _, block in ipairs(bc.blocks or {}) do
    table.insert(requests, {
      name = block.name or "",
      start_line = block.start_line,
      end_line = block.end_line,
    })
  end
  return requests
end

---------------------------------------------------------------------------
-- Nested value access
---------------------------------------------------------------------------

--- Navigate a nested table using a dot-separated path.
--- Supports: "data.user.name" → data.user.name
---           "items[0].id"    → items[0].id (array indexing)
--- Parse a dot-separated path into segments, treating brackets as grouped
--- delimiters so that "items[].id" becomes {"items[]", "id"}.
local function parse_path_segments(path)
  local segments = {}
  local i = 1
  while i <= #path do
    if path:sub(i, i) == "." then
      i = i + 1
    else
      local start = i
      local depth = 0
      while i <= #path do
        local c = path:sub(i, i)
        if c == "[" then
          depth = depth + 1
        elseif c == "]" then
          depth = depth - 1
        elseif c == "." and depth == 0 then
          break
        end
        i = i + 1
      end
      table.insert(segments, path:sub(start, i - 1))
    end
  end
  return segments
end

--- Resolve path segments recursively, supporting array wildcards.
--- Must be defined before get_nested_value (used recursively).
local function resolve_segments(current, segments, idx)
  if idx > #segments then return current end
  if type(current) == "string" then
    local ok, parsed = pcall(vim.json.decode, current)
    if ok and type(parsed) == "table" then
      current = parsed
    else
      return nil
    end
  end
  if type(current) ~= "table" then return nil end
  local part = segments[idx]
  local array_field = part:match("^(.*)%[%]$")
  if array_field then
    local arr
    if array_field == "" then
      arr = current
    else
      arr = current[array_field]
      if arr == nil then arr = current[array_field .. "[]"] end
    end
    if type(arr) ~= "table" or not vim.tbl_islist(arr) then return nil end
    local results = {}
    for _, elem in ipairs(arr) do
      local r = resolve_segments(elem, segments, idx + 1)
      if r ~= nil then
        table.insert(results, r)
      end
    end
    return results
  end
  local field, idx_str = part:match("^(.*)%[(%d+)%]$")
  if field and idx_str then
    local arr
    if field == "" then
      arr = current
    else
      arr = current[field]
      if arr == nil then arr = current[field .. "[]"] end
    end
    if type(arr) ~= "table" then return nil end
    return resolve_segments(arr[tonumber(idx_str) + 1], segments, idx + 1)
  end
  local value = current[part]
  if value == nil then value = current[part .. "[]"] end
  return resolve_segments(value, segments, idx + 1)
end

--- Walk a dot-separated path into a nested table/JSON structure.
local function get_nested_value(obj, path)
  if not obj or path == "" then return nil end
  local segments = parse_path_segments(path)
  return resolve_segments(obj, segments, 1)
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
-- Dependent request execution (fully async via callback chain)
---------------------------------------------------------------------------

--- Execute a single dependent request asynchronously.
--- Uses cache if available. Calls on_complete(response_or_nil).
--- Non-blocking: uses jobstart on_exit callback chain.
local function execute_dependent_request_async(binary, file, env_name, dep_req, resolved_content, on_complete)
  -- Check cache first
  if request_response_cache[dep_req.name] then
    state.log("INFO", string.format("Using cached response for '%s'", dep_req.name))
    vim.schedule(function() on_complete(request_response_cache[dep_req.name]) end)
    return
  end

  local cmd = string.format("%s run %s --line %d --env %s --json --stdin",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(file),
    dep_req.start_line,
    vim.fn.shellescape(env_name)
  )

  state.log("INFO", string.format("Executing dependent request '%s' at line %d", dep_req.name, dep_req.start_line))

  local stdout_buf = {}
  local stderr_buf = {}
  local completed = false
  local env = { POSTE_CACHE_DIR = state.config.response_cache_dir }

  local job_id = vim.fn.jobstart(cmd, {
    env = env,
    stdin = "pipe",
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(stdout_buf, line) end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(stderr_buf, line) end
        end
      end
    end,
    on_exit = function(_, code)
      if completed then return end
      completed = true
      -- Cancel the timeout timer
      if timeout_timer then timeout_timer:stop() timeout_timer:close() end  -- luacheck: ignore 113

      if code ~= 0 then
        state.log("WARN", string.format("Dependent request '%s' failed with exit code %d", dep_req.name, code))
        on_complete(nil)
        return
      end

      if #stdout_buf == 0 then
        state.log("WARN", "No output from dependent request")
        on_complete(nil)
        return
      end

      local stdout_text = table.concat(stdout_buf, "\n")
      local ok, parsed = pcall(vim.json.decode, stdout_text)
      if not ok then
        state.log("WARN", string.format("Failed to parse dependent request response: %s", stdout_text:sub(1, 100)))
        on_complete(nil)
        return
      end

      request_response_cache[dep_req.name] = parsed
      state.log("INFO", string.format("Cached response for '%s'", dep_req.name))
      on_complete(parsed)
    end,
  })

  if job_id <= 0 then
    state.log("ERROR", "Failed to start job for dependent request")
    on_complete(nil)
    return
  end

  -- 30s timeout via uv timer (non-blocking, doesn't freeze event loop)
  local uv = vim.uv or vim.loop
  local timeout_timer = uv.new_timer()
  timeout_timer:start(30000, 0, vim.schedule_wrap(function()
    if completed then
      timeout_timer:close()
      return
    end
    completed = true
    timeout_timer:close()
    vim.fn.jobstop(job_id)
    state.log("ERROR", string.format("Dependent request '%s' timed out after 30s", dep_req.name))
    vim.notify(string.format("Dependency '%s' timed out", dep_req.name), vim.log.levels.ERROR, { title = "Poste" })
    on_complete(nil)
  end))

  -- Send resolved content via stdin
  local clean_content = strip_prompt_lines(resolved_content)
  clean_content = assertions.extract_assertion_blocks(clean_content)
  vim.fn.chansend(job_id, clean_content)
  vim.fn.chanclose(job_id, "stdin")
end

--- Build a flat execution order for all dependencies (topological via DFS).
--- Dependencies already cached are skipped.
local function build_dep_order(refs, requests, content)
  local order = {}
  local seen = {}

  local function collect(dep_req)
    if seen[dep_req.name] or request_response_cache[dep_req.name] then
      return
    end
    seen[dep_req.name] = true

    -- Extract dep's block text and find its own cross-request refs
    local all_lines = vim.split(content, "\n", { plain = true })
    local dep_lines = {}
    for i = dep_req.start_line, dep_req.end_line do
      table.insert(dep_lines, all_lines[i] or "")
    end
    local dep_block_text = table.concat(dep_lines, "\n")
    local dep_refs = find_request_variable_refs(dep_block_text)

    -- Recursively collect sub-dependencies first (they must execute before us)
    for _, ref in ipairs(dep_refs) do
      if not seen[ref.request_name] and not request_response_cache[ref.request_name] then
        for _, req in ipairs(requests) do
          if req.name == ref.request_name then
            collect(req)
            break
          end
        end
      end
    end

    table.insert(order, dep_req)
  end

  for _, ref in ipairs(refs) do
    if not request_response_cache[ref.request_name] then
      for _, req in ipairs(requests) do
        if req.name == ref.request_name then
          collect(req)
          break
        end
      end
    end
  end

  return order
end

--- Execute all dependencies in order via callback chain.
--- Each dep's on_exit triggers the next dep's execution.
local function execute_deps_sequential(binary, file, env_name, dep_order, content, requests, idx, on_complete)
  idx = idx or 1
  if idx > #dep_order then
    on_complete()
    return
  end

  local dep_req = dep_order[idx]

  -- Resolve this dep's own variable refs using already-cached responses
  local all_lines = vim.split(content, "\n", { plain = true })
  local dep_lines = {}
  for i = dep_req.start_line, dep_req.end_line do
    table.insert(dep_lines, all_lines[i] or "")
  end
  local dep_block_text = table.concat(dep_lines, "\n")
  local dep_refs = find_request_variable_refs(dep_block_text)

  local resolved_dep_block = dep_block_text
  for _, ref in ipairs(dep_refs) do
    local value = resolve_request_variable(ref.full:sub(3, -3), request_response_cache)
    if value then
      resolved_dep_block = resolved_dep_block:gsub(vim.pesc(ref.full), tostring(value))
    end
  end

  -- Rebuild content with resolved dep block
  local resolved_lines = vim.split(resolved_dep_block, "\n", { plain = true })
  for i, line in ipairs(resolved_lines) do
    all_lines[dep_req.start_line + i - 1] = line
  end
  local resolved_content = table.concat(all_lines, "\n")

  execute_dependent_request_async(binary, file, env_name, dep_req, resolved_content, function(_response)
    -- Move to next dep regardless of success/failure
    execute_deps_sequential(binary, file, env_name, dep_order, content, requests, idx + 1, on_complete)
  end)
end

---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Structured options parsing (name|key|description tuples)
---------------------------------------------------------------------------

--- Parse options string into {name, key, description}[].
--- Supports:
---   "opt"              → {name="opt", key="opt", description=""}
---   "name|key"         → {name="name", key="key", description=""}
---   "name|key|desc"    → {name="name", key="key", description="desc"}
--- @param options_str string  Content inside [...] (comma-separated)
--- @return table  Array of {name, key, description}
local function parse_structured_options(options_str)
  local result = {}
  for opt in options_str:gmatch("[^,]+") do
    local trimmed = vim.trim(opt)
    if trimmed ~= "" then
      local parts = vim.split(trimmed, "|", { plain = true })
      if #parts == 1 then
        -- Simple string (backward compatible)
        local name = vim.trim(parts[1])
        table.insert(result, { name = name, key = name, description = "" })
      else
        -- Structured: name|key[|description...]
        local name = vim.trim(parts[1])
        local key = vim.trim(parts[2])
        -- Rest is description (rejoin with | to preserve | in desc)
        local desc_parts = {}
        for i = 3, #parts do
          table.insert(desc_parts, parts[i])
        end
        local description = vim.trim(table.concat(desc_parts, "|"))
        table.insert(result, { name = name, key = key, description = description })
      end
    end
  end
  return result
end

--- Parse dynamic mapping expression from options string.
--- Looks for pattern: "{{<ref> | {name: path, key: path, desc: path} }}"
--- @param options_str string  e.g. "{{Req.body | {name: .x, key: .y} }}"
--- @return string|nil ref, table|nil mapping
local function parse_dynamic_mapping(options_str)
  -- Extract {{...}} ref from options string (greedy to handle nested {})
  local ref = options_str:match("{{(.+)}}")
  if not ref then return nil, nil end
  -- Trim trailing whitespace/braces from the captured inner content
  ref = vim.trim(ref)
  -- Check for pipe + mapping expression
  local response_ref, mapping_expr = ref:match("^(.-)%s*|%s*{(.-)}$")
  if not response_ref then
    return ref, nil
  end
  -- Parse mapping fields from "{name: path, key: path, desc: path}"
  local mapping = {}
  for field_expr in mapping_expr:gmatch("[^,]+") do
    local field, path = field_expr:match("^%s*(%w+)%s*:%s*(.+)$")
    if field and path then
      -- Normalize field name: desc -> description
      field = field == "desc" and "description" or field
      mapping[field] = vim.trim(path)
    end
  end
  return response_ref, mapping
end

--- Apply jq-style path mapping to resolved response data.
--- Paths use ".[]" to indicate array iteration (jq-compatible).
--- Without ".[]", treats value as single object.
--- @param value table  Response data (array or single object)
--- @param mapping table  {name="path", key="path", description="path"}
--- @return table  Array of {name, key, description}
local function apply_jq_mapping(value, mapping)
  if type(value) ~= "table" then return {} end

  -- Check if mapping paths use .[] (array iteration) or direct paths
  local uses_array_iteration = false
  for _, path in pairs(mapping) do
    if type(path) == "string" and path:find("[]", 1, true) then
      uses_array_iteration = true
      break
    end
  end

  local items
  if uses_array_iteration then
    -- Paths contain .[] → extract the root array from value
    -- Strip leading .[] prefix from paths and use value as the array
    -- We assume value is already the array to iterate over
    if vim.tbl_islist(value) then
      items = value
    else
      items = { value }
    end
    -- Strip .[] prefix from mapping paths so paths are relative to each item
    local clean = {}
    for field, path in pairs(mapping) do
      -- Remove leading ".[]" (with optional trailing "."), e.g. ".[].login" → "login"
      local cleaned = path:gsub("^%.[%[%]][%[%]](%.?)", "")
      cleaned = cleaned:gsub("^%.", "")
      clean[field] = cleaned
    end
    mapping = clean
  else
    -- No array iteration: treat value as array, or wrap single object
    if vim.tbl_islist(value) then
      items = value
    else
      items = { value }
    end
    -- Strip leading "." from paths
    local clean = {}
    for field, path in pairs(mapping) do
      clean[field] = path:match("^%.(.+)") or path
    end
    mapping = clean
  end

  local result = {}
  for _, item in ipairs(items) do
    if type(item) == "table" then
      local entry = {}
      local has_field = false
      for _, field in ipairs({ "name", "key", "description" }) do
        if mapping[field] then
          local resolved = get_nested_value(item, mapping[field])
          if resolved ~= nil then
            entry[field] = tostring(resolved)
            has_field = true
          else
            entry[field] = ""
          end
        end
      end
      if has_field then
        table.insert(result, entry)
      end
    end
  end
  return result
end

-- Prompt variables (<<name directives)
---------------------------------------------------------------------------

--- Handle prompt directives in the current request block only.
--- Syntax:
---   <<variable_name                   → text input
---   <<variable_name [opt1, opt2, ...] → selection from list (up/down arrows)
---   <<variable_name [{{Req.response.body.field}}] → dynamic options from request response
--- Only processes prompt lines within the request block containing cursor_line.
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
  local cancelled = false

  local function process_next()
    if idx > #lines then
      if cancelled then
        on_complete(nil)
      else
        on_complete(table.concat(result, "\n"))
      end
      return
    end

    local line = lines[idx]
    local line_num = idx
    idx = idx + 1

    -- Only process prompt directives within the current request block (1-indexed)
    if line_num >= start_line and line_num <= end_line then
      -- Match: <<varname [opt1, opt2, ...]  (selection mode)
      local varname_sel, options_str = line:match("^%s*<<(%S+)%s*%[(.+)%]")

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
              -- Execute the dependent request asynchronously
              local all_lines = vim.split(content, "\n", { plain = true })
              local dep_lines = {}
              for i = dep_req.start_line, dep_req.end_line do
                table.insert(dep_lines, all_lines[i] or "")
              end
              local dep_resolved = table.concat(dep_lines, "\n")

              execute_dependent_request_async(binary, file, env_name, dep_req, dep_resolved, function(response)
                if response then
                  local value = resolve_request_variable(ref_match, { [req_name] = response })
                  if value and type(value) == "table" then
                    -- Check if this is a structured mapping (contains pipe + {name: ..., key: ...})
                    local ref_text, mapping = parse_dynamic_mapping("{{" .. ref_match .. "}}")
                    if mapping then
                      -- Apply structured mapping to build {name,key,desc} items
                      local items = apply_jq_mapping(value, mapping)
                      if #items > 0 then
                        local prompt = string.format("Select value for '%s'", varname_sel)
                        poste_select.select(items, prompt, function(selected)
                          if selected then
                            table.insert(result, string.format("@%s = %s", varname_sel, selected))
                          else
                            cancelled = true
                          end
                          process_next()
                        end)
                        return
                      end
                    else
                      -- Legacy flatten logic (backward compatible)
                      local options = {}
                      local function flatten(item)
                        if type(item) == "table" then
                          for _, sub in ipairs(item) do flatten(sub) end
                        elseif type(item) == "string" then
                          table.insert(options, item)
                        elseif type(item) == "number" then
                          table.insert(options, tostring(item))
                        end
                      end
                      for _, item in ipairs(value) do flatten(item) end

                      if #options > 0 then
                        local prompt = string.format("Select value for '%s'", varname_sel)
                        poste_select.select(options, prompt, function(selected)
                          if selected then
                            table.insert(result, string.format("@%s = %s", varname_sel, selected))
                          else
                            cancelled = true
                          end
                          process_next()
                        end)
                        return
                      end
                    end
                  end
                end
                -- Fallback to static options (structured)
                local options = parse_structured_options(options_str:gsub("{{[^}]+}}", ""))
                if #options > 0 then
                  local prompt = string.format("Select value for '%s'", varname_sel)
                  poste_select.select(options, prompt, function(selected)
                    if selected then
                      table.insert(result, string.format("@%s = %s", varname_sel, selected))
                    else
                      cancelled = true
                    end
                    process_next()
                  end)
                else
                  table.insert(result, line)
                  process_next()
                end
              end)
              return
            end
            -- If we get here, something went wrong with dynamic options
            state.log("WARN", string.format("Could not resolve dynamic options for '%s'", varname_sel))
          end
        end

        -- Static options: parse structured tuples (name|key|description)
        local options = parse_structured_options(options_str)

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
            cancelled = true
          end
          process_next()
        end)
        return
      else
        -- Match: <<varname  (text input mode)
        local varname = line:match("^%s*<<(%S+)")

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
              cancelled = true
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
--- Fully async: executes dependent requests via callback chain, then substitutes variables.
--- Calls on_complete(resolved_content) when all dependencies are resolved.
function M.resolve_request_variables(binary, file, env_name, buf, cursor_line, content, on_complete)
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
    on_complete(content)
    return
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
    on_complete(content)
    return
  end

  state.log("INFO", string.format("Found %d request variable reference(s)", #refs))

  -- Build topological execution order for all dependencies
  local dep_order = build_dep_order(refs, requests, content)

  if #dep_order == 0 then
    -- All dependencies already cached, substitute immediately
    local resolved_block = block_text
    for _, ref in ipairs(refs) do
      local value = resolve_request_variable(ref.full:sub(3, -3), request_response_cache)
      if value then
        resolved_block = resolved_block:gsub(vim.pesc(ref.full), tostring(value))
      else
        state.log("WARN", string.format("Could not resolve variable: %s", ref.full))
      end
    end

    local result_lines = {}
    local resolved_split = vim.split(resolved_block, "\n", { plain = true })
    for i, l in ipairs(all_lines) do
      if i >= current_req.start_line and i <= current_req.end_line then
        table.insert(result_lines, resolved_split[i - current_req.start_line + 1] or l)
      else
        table.insert(result_lines, l)
      end
    end
    on_complete(table.concat(result_lines, "\n"))
    return
  end

  -- Execute dependencies sequentially via callback chain (fully non-blocking)
  execute_deps_sequential(binary, file, env_name, dep_order, content, requests, 1, function()
    -- All deps resolved: substitute variables in current block
    local resolved_block = block_text
    for _, ref in ipairs(refs) do
      local value = resolve_request_variable(ref.full:sub(3, -3), request_response_cache)
      if value then
        resolved_block = resolved_block:gsub(vim.pesc(ref.full), tostring(value))
      else
        state.log("WARN", string.format("Could not resolve variable: %s", ref.full))
      end
    end

    -- Replace block in full content
    local result_lines = {}
    local resolved_split = vim.split(resolved_block, "\n", { plain = true })
    for i, l in ipairs(all_lines) do
      if i >= current_req.start_line and i <= current_req.end_line then
        table.insert(result_lines, resolved_split[i - current_req.start_line + 1] or l)
      else
        table.insert(result_lines, l)
      end
    end

    on_complete(table.concat(result_lines, "\n"))
  end)
end

--- Cache the current request's response for use by subsequent request variables
function M.cache_response(req_name, response)
  if req_name then
    request_response_cache[req_name] = response
  end
end

---------------------------------------------------------------------------
-- Test interface
---------------------------------------------------------------------------

M._test = {
  parse_structured_options = parse_structured_options,
  parse_dynamic_mapping    = parse_dynamic_mapping,
  apply_jq_mapping         = apply_jq_mapping,
}

return M
