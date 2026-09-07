--- Import/run cross-file reference resolution for HTTP requests.
---
--- Syntax:
---   import ./auth.http                    # bare import, requests merged into global scope
---   import ./orders.http as orders        # aliased import, namespace isolation
---   run #Login                            # execute bare imported request
---   run #orders.ListOrders                # execute aliased request
---   run #Login (@token=xyz)               # execute with variable overrides
---   run ./batch.http                      # execute all requests in file
---
--- Alias rules:
---   - Aliases must be unique (duplicate alias → error)
---   - Aliased requests only accessible via #alias.Name, not bare #Name
---   - Bare import name collisions: later overrides earlier (warning)
local state = require("poste-http.state")
local util = require("poste-http.util")
local request_vars = require("poste-http.http.request_vars")
local resolve = require("poste-http.http.resolve")
local curl_exec = require("poste-http.http.curl_exec")
local describe = require("poste-http.http.describe")
local vars = require("poste-http.http.vars")
local global_headers = require("poste-http.http.global_headers")
local uv = vim.uv or vim.loop

local M = {}

--- Parse a single line for import directive.
--- @param line string
--- @return table|nil  { type = "bare"|"aliased", path = string, alias = string|nil }
local function parse_import_line(line)
  local trimmed = vim.trim(line)
  if not trimmed:match("^import ") then return nil end

  -- import ./path as alias
  local path, alias = trimmed:match("^import%s+(%S+)%s+as%s+(%S+)")
  if path and alias then
    alias = vim.trim(alias)
    return { type = "aliased", path = vim.trim(path), alias = alias }
  end

  -- import ./path
  local bare_path = trimmed:match("^import%s+(%S+)")
  if bare_path then
    return { type = "bare", path = vim.trim(bare_path) }
  end

  return nil
end

--- Parse a single line for run directive.
--- @param line string
--- @return table|nil  { type = "by_name"|"by_alias"|"by_path",
---                      name = string|nil, alias = string|nil, path = string|nil,
---                      vars = { string: string } }
local function parse_run_line(line)
  local trimmed = vim.trim(line)
  if not trimmed:lower():match("^run ") then return nil end

  local rest = trimmed:match("^[Rr][Uu][Nn]%s+(.+)")
  if not rest then return nil end

  -- Extract optional inline variables: (@key=val, ...)
  local target, vars_str = rest:match("^(.+)%s*%((.+)%)%s*$")
  if not target then
    target = rest
    vars_str = nil
  end

  -- `var_map` avoids shadowing the poste-http.http.vars module upvalue.
  local var_map = {}
  if vars_str then
    for pair in vars_str:gmatch("[^,]+") do
      pair = vim.trim(pair)
      local key, value = pair:match("^@?(%w[%w_]*)%s*=%s*(.+)%s*$")
      if key then
        var_map[key] = value
      end
    end
  end

  target = vim.trim(target)

  -- run #alias.Name
  local alias_name, req_name = target:match("^#([^%.]+)%.(.+)$")
  if alias_name and req_name then
    return { type = "by_alias", alias = alias_name, name = vim.trim(req_name), vars = var_map }
  end

  -- run #Name
  local name = target:match("^#(.+)$")
  if name then
    return { type = "by_name", name = vim.trim(name), vars = var_map }
  end

  -- run ./path
  return { type = "by_path", path = target, vars = var_map }
end

--- Resolve a relative or absolute path against the current buffer's directory.
--- @param path string
--- @param buf_dir string|nil  Directory of the current .http file
--- @return string  Resolved absolute path
local function resolve_path(path, buf_dir)
  if path:sub(1, 1) == "/" then
    return path
  end
  if path:sub(1, 1) == "~" then
    return vim.fn.expand(path)
  end
  if buf_dir and buf_dir ~= "" then
    return vim.fn.simplify(buf_dir .. "/" .. path)
  end
  return path
end

--- Extract all named request blocks from file content.
--- Returns list of { name = string, line = number }
--- @param content string
--- @return table[]
local function extract_request_names(content)
  local requests = {}
  local lines = vim.split(content, "\n", { plain = true })
  for i, line in ipairs(lines) do
    local name = line:match("^%s*###%s+(%S.*)$")
    if name then
      name = vim.trim(name)
      if name ~= "" then
        table.insert(requests, { name = name, line = i })
      end
    end
  end
  return requests
end

--- Read a file and return its content.
--- @param path string
--- @return string|nil, string|nil  content, error
local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then
    return nil, err
  end
  local content = f:read("*a")
  f:close()
  return content, nil
end

--- Convert a Lua value to an HTTP string representation.
--- Numbers → tostring, strings → as-is, tables → JSON, booleans → tostring, nil → ""
--- @param val any
--- @return string
local function value_to_http_string(val)
  local t = type(val)
  if t == "string" then
    return val
  elseif t == "number" or t == "boolean" then
    return tostring(val)
  elseif t == "table" then
    local ok, encoded = pcall(vim.json.encode, val)
    if ok then return encoded end
    return ""
  else
    return ""
  end
end

--- Collect all imports and run directives from a buffer's content.
--- Imports are collected from anywhere in the file (top-level or between blocks).
--- @param buf_content string  Full buffer content
--- @return { imports = table[], runs = table[] }
function M.collect_directives(buf_content)
  local imports = {}
  local runs = {}

  for line in buf_content:gmatch("[^\n]+") do
    local imp = parse_import_line(line)
    if imp then
      table.insert(imports, imp)
    else
      local run = parse_run_line(line)
      if run then
        table.insert(runs, run)
      end
    end
  end

  return { imports = imports, runs = runs }
end

--- Build an import index from a list of import directives.
--- Reads each imported file and extracts its request names.
--- @param imports table[]  List of import directives
--- @param buf_dir string   Directory of the current buffer (for resolving relative paths)
--- @return { bare = { path: string, requests: {name: string, line: number}[] }[],
---           aliased = { [alias]: { path: string, requests: table[] } },
---           errors = string[],
---           warnings = string[] }
function M.build_import_index(imports, buf_dir)
  local index = { bare = {}, aliased = {}, errors = {}, warnings = {} }
  local seen_aliases = {}

  for _, imp in ipairs(imports) do
    local file_path = resolve_path(imp.path, buf_dir)
    local content, err = read_file(file_path)
    if not content then
      table.insert(index.errors, string.format("Cannot read import '%s': %s", imp.path, err or "unknown error"))
    elseif file_path:match("%.lua$") then
      -- Lua module import: load and execute the file to get exports
      local fn, load_err = load(content, "@" .. file_path)
      if not fn then
        table.insert(index.errors, string.format("Cannot load Lua import '%s': %s", imp.path, load_err))
      else
        local ok, exports = pcall(fn)
        if not ok then
          table.insert(index.errors, string.format("Cannot execute Lua import '%s': %s", imp.path, exports))
        else
          exports = exports or {}
          local entry = { path = file_path, exports = exports, is_lua = true }
          if imp.type == "aliased" then
            if seen_aliases[imp.alias] then
              table.insert(index.errors, string.format("Duplicate alias '%s': %s and %s",
                imp.alias, seen_aliases[imp.alias], imp.path))
            else
              seen_aliases[imp.alias] = imp.path
              index.aliased[imp.alias] = entry
            end
          else
            table.insert(index.bare, entry)
          end
        end
      end
    else
      local requests = extract_request_names(content)
      if imp.type == "aliased" then
        if seen_aliases[imp.alias] then
          table.insert(index.errors, string.format("Duplicate alias '%s': %s and %s",
            imp.alias, seen_aliases[imp.alias], imp.path))
        else
          seen_aliases[imp.alias] = imp.path
          index.aliased[imp.alias] = { path = file_path, requests = requests, content = content }
        end
      else
        -- Check for name collisions with existing bare imports
        local existing = {}
        for _, entry in ipairs(index.bare) do
          for _, req in ipairs(entry.requests) do
            existing[req.name] = entry.path
          end
        end
        for _, req in ipairs(requests) do
          if existing[req.name] then
            table.insert(index.warnings,
              string.format("Warning: request '%s' in %s overrides same name in %s",
                req.name, imp.path, existing[req.name]))
          end
        end
        table.insert(index.bare, { path = file_path, requests = requests, content = content })
      end
    end
  end

  return index
end

--- Resolve a name or alias.Name reference to a specific request.
--- First checks aliases, then bare imports.
--- @param reference string  "Name" or "alias.Name"
--- @param index table  Import index from build_import_index()
--- @return { path: string, line: number, request: {name: string, line: number} }|nil
local function resolve_reference(reference, index)
  -- Try alias.Name format
  local alias, name = reference:match("^([^%.]+)%.(.+)$")
  if alias and name then
    local entry = index.aliased[alias]
    if entry and not entry.is_lua then
      for _, req in ipairs(entry.requests) do
        if req.name == name then
          return { path = entry.path, line = req.line, request = req }
        end
      end
    end
    return nil
  end

  -- Try bare name lookup
  for _, entry in ipairs(index.bare) do
    -- Lua imports index exports, not requests — nothing to resolve here.
    if not entry.is_lua then
      for _, req in ipairs(entry.requests) do
        if req.name == reference then
          return { path = entry.path, line = req.line, request = req }
        end
      end
    end
  end

  return nil
end

--- Build import index for the current buffer and resolve a run directive.
--- @param buf number|nil  Buffer number (default: current)
--- @param cursor_line number|nil  Line number of the run directive (1-indexed)
--- @return { action: "execute"|"execute_all"|"none",
---           path: string|nil, line: number|nil, vars: table|nil,
---           error: string|nil }
function M.resolve_run_at_cursor(buf, cursor_line)
  buf = buf or vim.api.nvim_get_current_buf()
  cursor_line = cursor_line or vim.fn.line(".")

  local buf_name = vim.api.nvim_buf_get_name(buf)
  local buf_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local total = #lines

  -- Find block start (### marker above cursor), then walk forward to find `run` line
  local block_start = 0
  for i = cursor_line, 1, -1 do
    local text = (lines[i] or "")
    if text:match("^%s*###") then
      block_start = i
      break
    end
  end

  local run = nil
  local run_line = nil
  for i = block_start + 1, total do
    local text = (lines[i] or "")
    if text:match("^%s*###") then
      break
    end
    local maybe_run = parse_run_line(text)
    if maybe_run then
      run = maybe_run
      run_line = i
      break
    end
  end
  if not run then
    return { action = "none" }
  end

  if run.type == "by_path" then
    local file_path = resolve_path(run.path, buf_dir)
    local content, err = read_file(file_path)
    if not content then
      return { action = "none", error = string.format("Cannot open '%s': %s", run.path, err or "unknown") }
    end
    -- Execute all requests in the file
    return { action = "execute_all", path = file_path, content = content, vars = run.vars, run_line = run_line }
  end

  -- by_name or by_alias: need to resolve through imports
  local full_content = table.concat(lines, "\n")
  local directives = M.collect_directives(full_content)
  local index = M.build_import_index(directives.imports, buf_dir)

  if #index.errors > 0 then
    return { action = "none", error = table.concat(index.errors, "\n") }
  end

  local reference = run.type == "by_alias" and (run.alias .. "." .. run.name) or run.name
  local resolved = resolve_reference(reference, index)

  if not resolved then
    if run.type == "by_alias" then
      return { action = "none", error = string.format("Alias '%s' or request '%s' not found", run.alias, run.name) }
    else
      return { action = "none", error = string.format("Request '%s' not found in imports", run.name) }
    end
  end

  return {
    action = "execute",
    path = resolved.path,
    line = resolved.line,
    vars = run.vars,
    request_name = resolved.request.name,
    run_line = run_line,
    warnings = index.warnings,
  }
end

--- Resolve a request reference ("#Name" or "#alias.Name") against the
--- imports declared in a buffer. Used by the client.run() orchestration
--- primitive and by tests.
--- @param target string  "#Name" or "#alias.Name"
--- @param buf number|nil  Buffer whose imports define the reference
--- @return table|nil  { action = "execute", path = string, line = number,
---                      request_name = string, vars = table }
--- @return string|nil  Error message when unresolvable
function M.resolve_request_reference(target, buf)
  buf = buf or vim.api.nvim_get_current_buf()

  local buf_name = vim.api.nvim_buf_get_name(buf)
  local buf_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local full_content = table.concat(lines, "\n")

  local directives = M.collect_directives(full_content)
  local index = M.build_import_index(directives.imports, buf_dir)
  if #index.errors > 0 then
    return nil, table.concat(index.errors, "\n")
  end

  local reference = target:match("^#(.+)$") or target
  local resolved = resolve_reference(reference, index)
  if not resolved then
    return nil, string.format("Request '%s' not found in imports", reference)
  end

  return {
    action = "execute",
    path = resolved.path,
    line = resolved.line,
    vars = {},
    request_name = resolved.request.name,
  }
end

--- Execute a request by reference with typed arguments (client.run primitive).
--- Args are Lua values converted to HTTP strings: strings as-is, numbers and
--- booleans via tostring, tables as JSON, nil as empty string.
--- @param target string  "#Name" or "#alias.Name"
--- @param args table|nil  { name = value, ... }
--- @param opts table|nil  { buf = number } buffer whose imports resolve the reference
--- @param callback function|nil  (ok: boolean, response: table|nil, request_name: string|nil, error: string|nil)
function M.execute_request_reference(target, args, opts, callback)
  opts = opts or {}
  local resolved, err = M.resolve_request_reference(target, opts.buf)
  if not resolved then
    if callback then callback(false, nil, nil, err) end
    return
  end

  local var_map = {}
  if args then
    for name, value in pairs(args) do
      var_map[name] = value_to_http_string(value)
    end
  end
  resolved.vars = var_map

  M.execute_run_directive(resolved, function(ok, response)
    if callback then callback(ok, response, resolved.request_name) end
  end)
end

--- Find the end line of a request block in content.
--- @param content string  Full file content
--- @param block_start number  ### marker line (1-indexed)
--- @return number  End line of the block
local function find_block_end(content, block_start)
  local lines = vim.split(content, "\n", { plain = true })
  for i = block_start + 1, #lines do
    if lines[i]:match("^%s*###") then
      return i - 1
    end
  end
  return #lines
end

--- Resolve imported content through the shared async pipeline.
--- Creates a scratch buffer so prompt handling has a stable buffer context.
local function resolve_import_content(content, block_start, file_path, env_name, mode, on_complete)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_set_option_value, "buftype", "nofile", { buf = buf })
  local lines = vim.split(content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  resolve.resolve(content, {
    mode = mode or "import",
    buf = buf,
    cursor_line = block_start,
    block_line = block_start,
    file = file_path,
    env_name = env_name,
  }, function(resolved_content)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    if resolved_content then
      on_complete(resolved_content)
    else
      state.log("WARN", "Import target prompt cancelled by user")
      on_complete(nil)
    end
  end)
end

--- Execute an import request block via curl (replaces poste CLI binary).
local function execute_import_via_curl(resolved_content, file_path, block_line, env_name, callback)
  local blocks = describe.describe_content(resolved_content, file_path)
  local meta = blocks and describe.block_at_line(blocks, block_line)
  if not meta then
    vim.schedule(function()
      vim.notify("Could not parse request block", vim.log.levels.ERROR, { title = "Poste" })
      if callback then callback(nil) end
    end)
    return
  end

  local method = meta.method or "GET"
  local url = meta.path or ""
  local headers = meta.headers or {}
  local body = meta.body or ""

  if not url or url == "" then
    vim.schedule(function()
      vim.notify("Import request has no URL", vim.log.levels.ERROR, { title = "Poste" })
      if callback then callback(nil) end
    end)
    return
  end

  local resolver = vars.build_resolver_from_state({
    lines = vim.split(resolved_content, "\n", { plain = true }),
    file_path = file_path,
    block_start = block_line,
    block_end = meta.end_line or block_line,
    env_name = env_name,
  })

  url = resolver:substitute(url)
  local resolved_headers = {}
  for _, h in ipairs(headers) do
    table.insert(resolved_headers, { h[1], resolver:substitute(h[2]) })
  end
  if body ~= "" then
    body = resolver:substitute(body)
  end

  local buf_dir = file_path ~= "" and vim.fn.fnamemodify(file_path, ":h") or vim.fn.getcwd()

  local merged_headers = global_headers.merge(resolved_headers, resolver)
  local h_parts = {}
  for _, h in ipairs(merged_headers) do
    table.insert(h_parts, h[1] .. ": " .. h[2])
  end
  local headers_str = #h_parts > 0 and table.concat(h_parts, "\n") or ""
  local timestamp = util.timestamp()
  local req_env = env_name or state.current_env
  state.set_pending_request({
    method = method,
    url = url,
    headers_str = headers_str,
    body = body,
    name = meta.name or "",
    env = req_env,
    timestamp = timestamp,
    start_hires = uv.hrtime(),
  })

  curl_exec.execute({
    method = method,
    url = url,
    headers = merged_headers,
    body = body,
    buf_dir = buf_dir,
    timeout = state.config.timeout,
  }, function(response)
    if response.error then
      vim.schedule(function()
        vim.notify("Import request failed: " .. response.error, vim.log.levels.ERROR, { title = "Poste" })
        if callback then callback(nil) end
      end)
      return
    end
    -- Attach the resolved request details to the response so views render
    -- request name/headers/body even when there is no pending_request context
    -- (multi-response chains, orchestration client.run calls).
    if response then
      response.metadata = response.metadata or {}
      local md = response.metadata
      if not md.method or md.method == "" then md.method = method end
      if not md.request_headers then md.request_headers = headers_str end
      if not md.request_body then md.request_body = body end
      if not md.timestamp then md.timestamp = timestamp end
      if not md.env then md.env = req_env end
      if not response.request_name or response.request_name == "" then
        response.request_name = meta.name or ""
      end
    end
    if callback then callback(response) end
  end)
end

--- Process target block's pre-script: extract, run in sandbox, inject vars into content.
--- Handles both request.variables.set() and client.global.set() from pre-scripts.
--- @param content string  Target file content
--- @param block_start number  ### marker line (1-indexed)
--- @param block_end number  End line of target block
--- @param file_dir string|nil  Directory of the target .http file
--- @return string  Modified content with pre-script vars + global vars injected
--- @return number  Total number of lines injected
local function process_target_pre_script(content, block_start, block_end, file_dir)
  local scripts = require("poste-http.http.scripts")

  local modified_content, pre_code = scripts.extract_pre_script_blocks(content, block_start, block_end, file_dir)
  if not pre_code then
    -- No pre-script, but still inject any existing global vars
    return scripts.inject_global_vars(content, block_start, state.global_vars)
  end

  local script_vars = scripts.collect_script_variables(modified_content, block_start, block_end, file_dir)
  local pre_result = scripts.run_pre_script(pre_code, script_vars)

  if pre_result.error then
    state.log("ERROR", "Import pre-script error: " .. pre_result.error)
    return content, 0
  end

  if pre_result.logs and #pre_result.logs > 0 then
    state.last_script_logs = state.last_script_logs or {}
    for _, msg in ipairs(pre_result.logs) do
      table.insert(state.last_script_logs, msg)
    end
  end

  local total_injected = 0

  -- Inject request.variables.set() vars
  if pre_result.variables and next(pre_result.variables) then
    local count = 0
    for _ in pairs(pre_result.variables) do count = count + 1 end
    modified_content = scripts.inject_pre_script_vars(modified_content, block_start, pre_result.variables)
    total_injected = total_injected + count
    block_start = block_start + count  -- so global vars go after them
  end

  -- Inject client.global.set() vars (set during run_pre_script above)
  if state.global_vars and next(state.global_vars) then
    local gcount
    modified_content, gcount = scripts.inject_global_vars(modified_content, block_start, state.global_vars)
    total_injected = total_injected + gcount or 0
  end

  return modified_content, total_injected
end

--- Process target block's post-script: extract and run assertion code.
--- This enables client.global.set() calls from the target block to persist
--- (e.g., setting a token) for subsequent requests in the calling file.
--- @param response table  Parsed response data
--- @param content string  Target file content (original, before pre-script injection)
--- @param block_start number  ### marker line (1-indexed)
--- @param block_end number  End line
--- @param file_dir string|nil  Directory of the target .http file
local function process_target_post_script(response, content, block_start, block_end, file_dir)
  local assertions = require("poste-http.http.assertions")
  local scripts = require("poste-http.http.scripts")

  local _, assertion_code = assertions.extract_assertion_blocks(content, block_start, block_end, file_dir)
  if not assertion_code then return end

  local script_vars = scripts.collect_script_variables(content, block_start, block_end, file_dir)
  local results = assertions.run_assertions(response, assertion_code, script_vars)

  if results and results.logs and #results.logs > 0 then
    state.last_script_logs = state.last_script_logs or {}
    for _, msg in ipairs(results.logs) do
      table.insert(state.last_script_logs, msg)
    end
  end
end

--- Execute a run directive by constructing and running a poste command.
--- Dispatches to the appropriate execution strategy:
---   - run #Name / run #alias.Name → execute single request
---   - run ./path.http → execute all requests in target file
--- @param opts table  Result from resolve_run_at_cursor()
--- @param callback function  Called with (success: boolean, response: table|nil)
function M.execute_run_directive(opts, callback)
  if opts.action == "none" then
    if callback then callback(false, nil) end
    return
  end

  if opts.action == "execute" then
    -- Read target file content first for pre/post-script processing
    local f = io.open(opts.path, "r")
    if not f then
      vim.notify("Cannot read file: " .. opts.path, vim.log.levels.ERROR, { title = "Poste" })
      if callback then callback(false, nil) end
      return
    end
    local content = f:read("*a")
    f:close()

    -- Find target block bounds
    local block_end = find_block_end(content, opts.line)
    local orig_block_start = opts.line
    local orig_block_end = block_end  -- original bounds for post-script on original content

    resolve_import_content(content, opts.line, opts.path, state.current_env, "import", function(prompt_resolved)
      if not prompt_resolved then
        state.log("WARN", string.format("Import prompt cancelled for '%s', aborting", opts.request_name))
        if callback then callback(false, nil) end
        return
      end

      local file_dir = vim.fn.fnamemodify(opts.path, ":h")

      -- Process pre-script from target block (on prompt-resolved content)
      local modified_content, injected_count = process_target_pre_script(prompt_resolved, opts.line, block_end, file_dir)
      block_end = block_end + injected_count

      -- Apply variable overrides if specified
      if opts.vars and next(opts.vars) then
        opts.line = opts.line + injected_count
        modified_content = M.apply_variable_overrides(modified_content, opts.line, opts.vars)
      end

      execute_import_via_curl(modified_content, opts.path, opts.line, state.current_env, function(response)
        if not response then
          if callback then callback(false, nil) end
          return
        end
        -- Run target block's post-script (so client.global.set() persists)
        -- Post-script scans the ORIGINAL content, so use the original block
        -- start (opts.line may have been shifted by pre-script injection).
        process_target_post_script(response, content, orig_block_start, orig_block_end, file_dir)
        -- Cache the response for cross-request variable resolution
        request_vars.cache_response(opts.request_name, response)
        if callback then callback(true, response) end
      end)
    end)

  elseif opts.action == "execute_all" then
    -- Execute all requests in the target file
    M.execute_all_requests(opts.path, opts.content, opts.vars, callback)
  end
end

--- Execute all named requests in a file sequentially.
--- @param file_path string
--- @param content string  File content (already read)
--- @param var_map table|nil  Variable overrides to apply to all requests
--- @param callback function
function M.execute_all_requests(file_path, content, var_map, callback)
  local requests = extract_request_names(content)
  if #requests == 0 then
    vim.notify("No named requests found in " .. file_path, vim.log.levels.WARN, { title = "Poste" })
    if callback then callback(false, nil) end
    return
  end

  local results = {}
  local idx = 1

  local function execute_next()
    if idx > #requests then
      if callback then callback(true, results) end
      return
    end

    local req = requests[idx]
    idx = idx + 1

    resolve_import_content(content, req.line, file_path, state.current_env, "import", function(dep_resolved_content)
      local block_end = find_block_end(dep_resolved_content, req.line)
      local file_dir = vim.fn.fnamemodify(file_path, ":h")
      local modified_content, _ = process_target_pre_script(dep_resolved_content, req.line, block_end, file_dir)

      if var_map and next(var_map) then
        modified_content = M.apply_variable_overrides(modified_content, req.line, var_map)
      end

      execute_import_via_curl(modified_content, file_path, req.line, state.current_env, function(response)
        if response then
          process_target_post_script(response, content, req.line, block_end, file_dir)
          request_vars.cache_response(req.name, response)
          table.insert(results, { name = req.name, response = response })
        else
          table.insert(results, { name = req.name, response = {
            status = 0, status_text = "Failed", body = "",
          }})
        end
        vim.schedule(function()
          vim.notify(string.format("[%d/%d] %s — %s", idx - 1, #requests, req.name,
            response and (response.status .. " " .. (response.status_text or "")) or "failed"),
            vim.log.levels.INFO, { title = "Poste" })
        end)
        execute_next()
      end)
    end)
  end

  execute_next()
end

--- Inject variable overrides into a request block.
--- Scans forward past existing @var defs, blanks, and entire < {% %} script blocks,
--- then inserts @var lines right before the HTTP request line. This ensures overrides
--- are processed LAST (HashMap.insert wins for same key) → highest priority.
--- @param content string  Full file content
--- @param block_line number  Line number of the ### marker (1-indexed)
--- @param var_map table  { var_name = value, ... }
--- @return string  Modified content
function M.apply_variable_overrides(content, block_line, var_map)
  if not var_map or not next(var_map) then return content end

  local lines = vim.split(content, "\n", { plain = true })

  -- Find injection point: past all @var defs, blanks, comments, and < {% %} blocks
  -- The injection point is set to the LAST line of that preamble, so injected
  -- P1 import-param @var lines come AFTER existing P2 request-level @var lines.
  -- HashMap semantics: later @var insertions overwrite earlier ones → P1 wins.
  local inject_at = block_line
  local i = block_line + 1
  while i <= #lines do
    local trimmed = vim.trim(lines[i])
    if trimmed:match("^@") or trimmed == "" or trimmed:match("^[#%-]") then
      inject_at = i
      i = i + 1
    elseif trimmed:match("^<%s*{%%") then
      -- Skip entire pre-script block: < {% ... %}
      inject_at = i
      i = i + 1
      while i <= #lines do
        if lines[i]:find("%%}") then
          inject_at = i
          i = i + 1
          break
        end
        i = i + 1
      end
    else
      break
    end
  end

  local result = {}
  for idx, line in ipairs(lines) do
    table.insert(result, line)
    if idx == inject_at then
      for name, value in pairs(var_map) do
        table.insert(result, string.format("@%s = %s", name, value))
      end
    end
  end

  return table.concat(result, "\n")
end

--- Build and display import resolution status for the current buffer.
--- Parses import directives, builds the import index, and returns a formatted table.
--- @return string[]  Lines of status output
function M.status()
  local buf = vim.api.nvim_get_current_buf()
  local buf_name = vim.api.nvim_buf_get_name(buf)
  local buf_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local full_content = table.concat(lines, "\n")
  local directives = M.collect_directives(full_content)
  local index = M.build_import_index(directives.imports, buf_dir)

  local out = {}
  table.insert(out, string.format("Import status for: %s", buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":t") or "(unsaved)"))
  table.insert(out, "")

  -- Errors
  if #index.errors > 0 then
    table.insert(out, "Errors:")
    for _, err in ipairs(index.errors) do
      table.insert(out, "  " .. err)
    end
    table.insert(out, "")
  end

  -- Warnings
  if #index.warnings > 0 then
    table.insert(out, "Warnings:")
    for _, w in ipairs(index.warnings) do
      table.insert(out, "  " .. w)
    end
    table.insert(out, "")
  end

  -- Bare imports
  table.insert(out, string.format("Bare imports (%d):", #index.bare))
  for _, entry in ipairs(index.bare) do
    if entry.is_lua then
      table.insert(out, string.format("  %s (Lua module)", entry.path))
      for k, _ in pairs(entry.exports or {}) do
        table.insert(out, string.format("    %s", k))
      end
    else
      table.insert(out, string.format("  %s (%d requests)", entry.path, #entry.requests))
      for _, req in ipairs(entry.requests) do
        table.insert(out, string.format("    #%s  (line %d)", req.name, req.line))
      end
    end
  end
  table.insert(out, "")

  -- Aliased imports
  local alias_keys = {}
  for k in pairs(index.aliased) do table.insert(alias_keys, k) end
  table.sort(alias_keys)
  table.insert(out, string.format("Aliased imports (%d):", #alias_keys))
  for _, alias in ipairs(alias_keys) do
    local entry = index.aliased[alias]
    if entry.is_lua then
      table.insert(out, string.format("  %s → %s (Lua module)", alias, entry.path))
      for k, _ in pairs(entry.exports) do
        table.insert(out, string.format("    %s.%s", alias, k))
      end
    else
      table.insert(out, string.format("  %s → %s (%d requests)", alias, entry.path, #entry.requests))
      for _, req in ipairs(entry.requests) do
        table.insert(out, string.format("    #%s.%s  (line %d)", alias, req.name, req.line))
      end
    end
  end

  return out
end

--- Resolve a dot-separated keypath against an exports table.
--- Supports: "key", "key.subkey", "key[1]", "key[1].subkey"
--- @param exports table  Lua module exports table
--- @param keypath string  Dot-separated path, e.g. "person.name" or "tags[1]"
--- @return any|nil  Resolved value, or nil if not found
local function resolve_path_for_export(exports, keypath)
  if not exports or not keypath then return nil end

  local segments = {}
  local i = 1
  while i <= #keypath do
    if keypath:sub(i, i) == "." then
      i = i + 1
    else
      local start = i
      while i <= #keypath do
        local c = keypath:sub(i, i)
        if c == "." then
          break
        end
        i = i + 1
      end
      table.insert(segments, keypath:sub(start, i - 1))
    end
  end

  local current = exports
  for _, seg in ipairs(segments) do
    if type(current) ~= "table" then return nil end
    -- Handle array index: "key[1]" or "key[2]"
    local name, idx = seg:match("^(%w+)%[(%d+)%]$")
    if name then
      current = current[name]
      if type(current) == "table" then
        current = current[tonumber(idx)]
      else
        return nil
      end
    else
      current = current[seg]
    end
    if current == nil then return nil end
  end

  return current
end

-- Cache for loaded Lua modules: resolved_path → exports table
local lua_module_cache = {}

--- Resolve Lua import references in content.
--- Finds `import ./path.lua as alias` lines, loads the Lua files,
--- and replaces:
---   - {{alias.keypath}}  → resolved value
---   - @var = alias.keypath → @var = <json_value>
--- Also strips import lines for .lua files from the content.
--- @param content string  Full buffer content
--- @param buf_dir string  Directory of the current buffer (for resolving relative paths)
--- @return string  Modified content with Lua imports resolved
function M.resolve_lua_imports(content, buf_dir)
  if not content or not buf_dir then return content end

  -- Collect Lua import directives and build result lines (import lines → blank)
  local lua_imports = {}
  local lines = vim.split(content, "\n", { plain = true })
  local result_lines = {}
  for _, line in ipairs(lines) do
    local imp = parse_import_line(line)
    if imp and imp.path:match("%.lua$") then
      table.insert(lua_imports, imp)
      table.insert(result_lines, "")
    else
      table.insert(result_lines, line)
    end
  end

  if #lua_imports == 0 then return content end

  -- Load Lua modules
  local alias_exports = {}
  for _, imp in ipairs(lua_imports) do
    local file_path = resolve_path(imp.path, buf_dir)
    local cached = lua_module_cache[file_path]
    if not cached then
      local f, err = io.open(file_path, "r")
      if not f then
        state.log("WARN", string.format("Cannot read Lua import '%s': %s", imp.path, err or "unknown"))
        cached = {}
      else
        local src = f:read("*a")
        f:close()
        local fn, load_err = load(src, "@" .. file_path)
        if not fn then
          state.log("WARN", string.format("Cannot load Lua import '%s': %s", imp.path, load_err))
          cached = {}
        else
          local ok, exports = pcall(fn)
          if not ok then
            state.log("WARN", string.format("Cannot execute Lua import '%s': %s", imp.path, exports))
            cached = {}
          else
            cached = exports or {}
          end
        end
      end
      lua_module_cache[file_path] = cached
    end
    if imp.type == "aliased" and imp.alias then
      alias_exports[imp.alias] = cached
    end
  end

  if not next(alias_exports) then
    return table.concat(result_lines, "\n")
  end

  for i, line in ipairs(result_lines) do
    local processed = line

    -- Replace @var = alias.keypath (iterate aliases since Lua patterns lack alternation)
    for alias, exports in pairs(alias_exports) do
      local prefix = alias .. "."
      local var_name, suffix = processed:match("^%s*@(%w[%w_]*)%s*=%s*(.+)%s*$")
      if var_name and suffix and suffix:sub(1, #prefix) == prefix then
        local keypath = suffix:sub(#prefix + 1)
        local resolved = resolve_path_for_export(exports, keypath)
        if resolved ~= nil then
          local line_start = processed:match("^(%s*)")
          processed = (line_start or "") .. "@" .. var_name .. " = " .. value_to_http_string(resolved)
        end
        break
      end
    end

    -- Replace {{alias.keypath}} references
    processed = processed:gsub("{{([^}]+)}}", function(match)
      for alias, exports in pairs(alias_exports) do
        local prefix = alias .. "."
        if match:sub(1, #prefix) == prefix then
          local keypath = match:sub(#prefix + 1)
          local resolved = resolve_path_for_export(exports, keypath)
          if resolved ~= nil then
            return value_to_http_string(resolved)
          end
          break
        end
      end
      return "{{" .. match .. "}}"
    end)

    result_lines[i] = processed
  end

  return table.concat(result_lines, "\n")
end

--- Resolve a single `alias.keypath` reference against Lua imports.
--- Parses import lines from content, loads Lua modules, and resolves the keypath.
--- @param keypath string  e.g. "m.person.age" or "m.tags[1]"
--- @param content string  Full buffer content (to find import directives)
--- @param buf_dir string  Directory of the current buffer
--- @return string|nil  Resolved value as string, or nil if unresolvable
function M.resolve_lua_keypath(keypath, content, buf_dir)
  if not keypath or not content or not buf_dir then return nil end

  local alias = keypath:match("^(%w+)%.")
  if not alias then return nil end

  for line in content:gmatch("[^\n]+") do
    local imp = parse_import_line(line)
    if imp and imp.type == "aliased" and imp.alias == alias then
      local file_path = resolve_path(imp.path, buf_dir)
      local cached = lua_module_cache[file_path]
      if not cached then
        local f, err = io.open(file_path, "r")
        if not f then return nil end
        local src = f:read("*a")
        f:close()
        local fn, load_err = load(src, "@" .. file_path)
        if not fn then return nil end
        local ok, exports = pcall(fn)
        if not ok then return nil end
        cached = exports or {}
        lua_module_cache[file_path] = cached
      end
      local inner_keypath = keypath:match("^%w+%.(.+)$")
      if inner_keypath then
        local resolved = resolve_path_for_export(cached, inner_keypath)
        if resolved ~= nil then
          return value_to_http_string(resolved)
        end
      end
      return nil
    end
  end
  return nil
end

M.parse_import_line = parse_import_line
M.parse_run_line = parse_run_line
M.resolve_path = resolve_path
M.extract_request_names = extract_request_names
M.resolve_reference = resolve_reference
M.resolve_path_for_export = resolve_path_for_export
M.value_to_http_string = value_to_http_string
M.execute_import_via_curl = execute_import_via_curl

return M
