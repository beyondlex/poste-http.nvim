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
local state = require("poste.state")

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
  if not trimmed:match("^run ") then return nil end

  local rest = trimmed:match("^run%s+(.+)")
  if not rest then return nil end

  -- Extract optional inline variables: (@key=val, ...)
  local target, vars_str = rest:match("^(.+)%s*%((.+)%)%s*$")
  if not target then
    target = rest
    vars_str = nil
  end

  local vars = {}
  if vars_str then
    for pair in vars_str:gmatch("[^,]+") do
      pair = vim.trim(pair)
      local key, value = pair:match("^@?(%w[%w_]*)%s*=%s*(.+)%s*$")
      if key then
        vars[key] = value
      end
    end
  end

  target = vim.trim(target)

  -- run #alias.Name
  local alias_name, req_name = target:match("^#([^%.]+)%.(.+)$")
  if alias_name and req_name then
    return { type = "by_alias", alias = alias_name, name = vim.trim(req_name), vars = vars }
  end

  -- run #Name
  local name = target:match("^#(.+)$")
  if name then
    return { type = "by_name", name = vim.trim(name), vars = vars }
  end

  -- run ./path
  return { type = "by_path", path = target, vars = vars }
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

--- Collect all imports and run directives from a buffer's content.
--- Parses file-level imports (before first ###) and block-level run directives.
--- @param buf_content string  Full buffer content
--- @return { imports = table[], runs = table[] }
function M.collect_directives(buf_content)
  local imports = {}
  local runs = {}
  local past_first_block = false

  for line in buf_content:gmatch("[^\n]+") do
    local imp = parse_import_line(line)
    if imp then
      if not past_first_block then
        table.insert(imports, imp)
      end
    else
      local run = parse_run_line(line)
      if run then
        table.insert(runs, run)
      end
    end

    if line:match("^%s*###") then
      past_first_block = true
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
    if entry then
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
    for _, req in ipairs(entry.requests) do
      if req.name == reference then
        return { path = entry.path, line = req.line, request = req }
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

--- Inject global vars as @var lines after block_start.
--- Mirrors run.lua:inject_global_vars logic.
--- @param buf_content string
--- @param block_start number  ### marker line (1-indexed)
--- @param global_vars table  { name = value, ... }
--- @return string, number  Modified content, lines injected
local function inject_global_vars(buf_content, block_start, global_vars)
  if not block_start or not global_vars or not next(global_vars) then
    return buf_content, 0
  end
  local glines = vim.split(buf_content, "\n", { plain = true })
  local result = {}
  local gcount = 0
  for _ in pairs(global_vars) do gcount = gcount + 1 end
  for i, line_text in ipairs(glines) do
    table.insert(result, line_text)
    if i == block_start then
      for name, value in pairs(global_vars) do
        table.insert(result, string.format("@%s = %s", name, value))
      end
    end
  end
  return table.concat(result, "\n"), gcount
end

--- Process target block's pre-script: extract, run in sandbox, inject vars into content.
--- Handles both request.variables.set() and client.global.set() from pre-scripts.
--- @param content string  Target file content
--- @param block_start number  ### marker line (1-indexed)
--- @param block_end number  End line of target block
--- @return string  Modified content with pre-script vars + global vars injected
--- @return number  Total number of lines injected
local function process_target_pre_script(content, block_start, block_end)
  local scripts = require("poste.http.scripts")

  local modified_content, pre_code = scripts.extract_pre_script_blocks(content, block_start, block_end)
  if not pre_code then
    -- No pre-script, but still inject any existing global vars
    return inject_global_vars(content, block_start, state.global_vars)
  end

  local script_vars = scripts.collect_script_variables(modified_content, block_start, block_end)
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
    modified_content, gcount = inject_global_vars(modified_content, block_start, state.global_vars)
    total_injected = total_injected + gcount or 0
  end

  return modified_content, total_injected
end

--- Process target block's post-script: extract and run assertion code.
--- This enables client.global.set() calls from the target block to persist
--- (e.g., setting a token) for subsequent requests in the calling file.
--- @param response table  Parsed response from Rust CLI
--- @param content string  Target file content (original, before pre-script injection)
--- @param block_start number  ### marker line (1-indexed)
--- @param block_end number  End line
local function process_target_post_script(response, content, block_start, block_end)
  local assertions = require("poste.http.assertions")
  local scripts = require("poste.http.scripts")

  local _, assertion_code = assertions.extract_assertion_blocks(content, block_start, block_end)
  if not assertion_code then return end

  local script_vars = scripts.collect_script_variables(content, block_start, block_end)
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

  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found", vim.log.levels.ERROR)
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
    local orig_block_end = block_end  -- original bounds for post-script on original content

    -- Process pre-script from target block
    local modified_content, injected_count = process_target_pre_script(content, opts.line, block_end)
    block_end = block_end + injected_count

    -- Apply variable overrides if specified
    if opts.vars and next(opts.vars) then
      opts.line = opts.line + injected_count
      modified_content = M.apply_variable_overrides(modified_content, opts.line, opts.vars)
    end

    local cmd = string.format("%s run %s --line %d --env %s --json --stdin",
      vim.fn.shellescape(binary),
      vim.fn.shellescape(opts.path),
      opts.line,
      vim.fn.shellescape(state.current_env)
    )

    state.log("INFO", string.format("import run: %s", cmd))

    local stdout_buf = {}
    local stderr_buf = {}

    local job_id = vim.fn.jobstart(cmd, {
      stdin = "pipe",
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        if not data then return end
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(stdout_buf, line) end
        end
      end,
      on_stderr = function(_, data)
        if not data then return end
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(stderr_buf, line) end
        end
      end,
      on_exit = function(_, code)
        if code ~= 0 then
          vim.schedule(function()
            vim.notify(string.format("run directive failed (exit %d): %s", code,
              table.concat(stderr_buf, "\n")), vim.log.levels.ERROR, { title = "Poste" })
            if callback then callback(false, {
              status = 0,
              status_text = "Failed (exit " .. code .. ")",
              body = table.concat(stderr_buf, "\n"),
            }) end
          end)
          return
        end

        local stdout_text = table.concat(stdout_buf, "\n")
        local ok, parsed = pcall(vim.json.decode, stdout_text)
        if ok and type(parsed) == "table" then
          -- Run target block's post-script (so client.global.set() persists)
          process_target_post_script(parsed, content, opts.line, orig_block_end)
          if callback then callback(true, parsed) end
        else
          if callback then callback(false, {
            status = 0,
            status_text = "JSON parse failed",
            body = stdout_text,
          }) end
        end
      end,
    })

    if job_id > 0 then
      vim.fn.chansend(job_id, modified_content)
      vim.fn.chanclose(job_id, "stdin")
    else
      vim.notify("Failed to start poste job for run directive", vim.log.levels.ERROR, { title = "Poste" })
      if callback then callback(false, nil) end
    end

  elseif opts.action == "execute_all" then
    -- Execute all requests in the target file
    M.execute_all_requests(opts.path, opts.content, opts.vars, callback)
  end
end

--- Execute all named requests in a file sequentially.
--- @param file_path string
--- @param content string  File content (already read)
--- @param vars table|nil  Variable overrides to apply to all requests
--- @param callback function
function M.execute_all_requests(file_path, content, vars, callback)
  local requests = extract_request_names(content)
  if #requests == 0 then
    vim.notify("No named requests found in " .. file_path, vim.log.levels.WARN, { title = "Poste" })
    if callback then callback(false, nil) end
    return
  end

  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found", vim.log.levels.ERROR)
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

    -- Find block bounds and process pre-script from target block
    local block_end = find_block_end(content, req.line)
    local modified_content, _ = process_target_pre_script(content, req.line, block_end)

    if vars and next(vars) then
      modified_content = M.apply_variable_overrides(modified_content, req.line, vars)
    end

    local cmd = string.format("%s run %s --line %d --env %s --json --stdin",
      vim.fn.shellescape(binary),
      vim.fn.shellescape(file_path),
      req.line,
      vim.fn.shellescape(state.current_env)
    )

    local stdout_buf = {}
    local stderr_buf = {}

    local job_id = vim.fn.jobstart(cmd, {
      stdin = "pipe",
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        if not data then return end
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(stdout_buf, line) end
        end
      end,
      on_stderr = function(_, data)
        if not data then return end
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(stderr_buf, line) end
        end
      end,
      on_exit = function(_, code)
        local stdout_text = table.concat(stdout_buf, "\n")
        local ok, parsed = pcall(vim.json.decode, stdout_text)
        if ok and type(parsed) == "table" then
          -- Run target block's post-script so client.global.set() persists
          process_target_post_script(parsed, content, req.line, block_end)
          table.insert(results, { name = req.name, response = parsed })
        else
          table.insert(results, { name = req.name, response = {
            status = code,
            status_text = "Failed",
            body = stdout_text,
            stderr = table.concat(stderr_buf, "\n"),
          }})
        end
        vim.schedule(function()
          vim.notify(string.format("[%d/%d] %s — %s", idx - 1, #requests, req.name,
            parsed and (parsed.status .. " " .. (parsed.status_text or "")) or "failed"),
            vim.log.levels.INFO, { title = "Poste" })
        end)
        execute_next()
      end,
    })

    if job_id > 0 then
      vim.fn.chansend(job_id, modified_content)
      vim.fn.chanclose(job_id, "stdin")
    else
      table.insert(results, { name = req.name, response = {
        status = 0, status_text = "Job start failed", body = "",
      }})
      execute_next()
    end
  end

  execute_next()
end

--- Inject variable overrides into a request block.
--- Scans forward past existing @var defs, blanks, and entire < {% %} script blocks,
--- then inserts @var lines right before the HTTP request line. This ensures overrides
--- are processed LAST (HashMap.insert wins for same key) → highest priority.
--- @param content string  Full file content
--- @param block_line number  Line number of the ### marker (1-indexed)
--- @param vars table  { var_name = value, ... }
--- @return string  Modified content
function M.apply_variable_overrides(content, block_line, vars)
  if not vars or not next(vars) then return content end

  local lines = vim.split(content, "\n", { plain = true })

  -- Find injection point: past all @var defs, blanks, and < {% %} blocks
  local inject_at = block_line
  local i = block_line + 1
  while i <= #lines do
    local trimmed = vim.trim(lines[i])
    if trimmed:match("^@") or trimmed == "" then
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
  for _, line in ipairs(lines) do
    table.insert(result, line)
    if i == inject_at then
      for name, value in pairs(vars) do
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
    table.insert(out, string.format("  %s (%d requests)", entry.path, #entry.requests))
    for _, req in ipairs(entry.requests) do
      table.insert(out, string.format("    #%s  (line %d)", req.name, req.line))
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
    table.insert(out, string.format("  %s → %s (%d requests)", alias, entry.path, #entry.requests))
    for _, req in ipairs(entry.requests) do
      table.insert(out, string.format("    #%s.%s  (line %d)", alias, req.name, req.line))
    end
  end

  return out
end

-- Test interface
M._test = {
  parse_import_line = parse_import_line,
  parse_run_line = parse_run_line,
  resolve_path = resolve_path,
  extract_request_names = extract_request_names,
  resolve_reference = resolve_reference,
}

return M
