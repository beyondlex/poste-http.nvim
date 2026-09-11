local state = require("poste-http.state")
local util = require("poste-http.util")
local curl_exec = require("poste-http.http.curl_exec")
local describe = require("poste-http.http.describe")
local assertions = require("poste-http.http.assertions")
local scripts = require("poste-http.http.scripts")
local vars = require("poste-http.http.vars")
local nested_access = require("poste-http.http.nested_access")
local global_headers = require("poste-http.http.global_headers")
local _import_mod = nil
local _cache_mod = nil
local function get_import_mod()
  if not _import_mod then
    _import_mod = require("poste-http.http.import")
  end
  return _import_mod
end
local function get_cache_mod()
  if not _cache_mod then
    _cache_mod = require("poste-http.http.cache")
  end
  return _cache_mod
end

local M = {}

local get_nested_value = nested_access.get_nested_value

local request_response_cache = {}

--- Convert a resolved request-variable value into the text to inject into content.
--- Strings → as-is, numbers/booleans → tostring, tables → JSON, other → ""
--- A Lua table (JSON object/array) must be encoded as JSON so it becomes part
--- of a JSON body instead of a "table: 0x..." string.
local function value_to_http_string(val)
  local t = type(val)
  if t == "string" then
    return val
  elseif t == "number" or t == "boolean" then
    return tostring(val)
  elseif t == "table" and val ~= vim.NIL then
    local ok, encoded = pcall(vim.json.encode, val)
    if ok then return encoded end
    return tostring(val)
  end
  return ""
end
local _chain_dep_set = {}
local _chain_dep_order = {}

local handle_prompt_fn = nil

--- Run a dependency's post-script/assertion blocks against its response so
--- side effects like `client.global.set(...)` populate globals the same way a
--- manual run of the dependency would.
--- @param response table
--- @param dep_block_text string  The dependency block's content
--- @param file_dir string|nil    Directory of the .http file
local function run_dep_post_scripts(response, dep_block_text, file_dir)
  local _, assertion_code = assertions.extract_assertion_blocks(dep_block_text, nil, nil, file_dir)
  if assertion_code then
    local dep_lines = vim.split(dep_block_text, "\n", { plain = true })
    local script_vars = scripts.collect_script_variables(dep_block_text, 1, #dep_lines, file_dir)
    assertions.run_assertions(response, assertion_code, script_vars)
  end
end

function M.set_prompt_handler(fn)
  handle_prompt_fn = fn
end

--- Split a request variable reference of the form
--- <req_name>.<source>.<target>[.<path>] where source ∈ {response, request} and
--- target ∈ {body, headers}. The request name may itself contain dots; the
--- last .response./.request. marker splits name from the source.
--- @param pattern string
--- @return string req_name
--- @return string|nil source
--- @return string|nil target
--- @return string path
local function split_request_ref(pattern)
  local rpos = pattern:find(".response.", 1, true)
  local qpos = pattern:find(".request.", 1, true)
  local pos = math.max(rpos or 0, qpos or 0)
  if pos == 0 then
    return pattern, nil, nil, ""
  end

  local req_name = pattern:sub(1, pos - 1)
  local rest = pattern:sub(pos + 1)
  local source = rest:match("^([^%.]+)")
  local target, path
  if source then
    local after_source = rest:sub(#source + 2)
    target = after_source:match("^([^%.]+)")
    if target then
      path = after_source:sub(#target + 2)
    end
  end
  return req_name, source, target, path or ""
end

--- Normalize the `.res.` shorthand to `.response.` so lookups go through the
--- single split path. Returns the input unchanged when it has no shorthand.
local function normalize_ref(inner)
  return (inner:gsub("%.res%.", ".response."))
end

--- Build one ref record from the raw `{{...}}` text as written in the buffer.
--- `full` keeps the raw spelling (substitution must match what the user wrote,
--- e.g. `{{Login.res.body.token}}`), `norm` is the `.response.`-normalized
--- inner ref used for the cache lookup. `norm` is nil when identical to raw.
local function make_ref(raw_inner)
  local norm = normalize_ref(raw_inner)
  local req_name, source = split_request_ref(norm)
  if not source then
    return nil
  end
  return {
    full = "{{" .. raw_inner .. "}}",
    norm = (norm ~= raw_inner) and norm or nil,
    request_name = req_name,
  }
end

local function resolve_request_variable(pattern, cached_responses)
  -- Parse as <req_name>.<source>.<target>.<path> where source/target come from a
  -- fixed vocabulary, so request names may themselves contain dots.
  local req_name, source, target, path = split_request_ref(pattern)
  if not req_name or not source or not target then
    return nil
  end

  local response = cached_responses[req_name]
  if not response then
    state.log("WARN", string.format("Request variable: '%s' not found in cache", req_name))
    return nil
  end

  if source == "response" then
    if target == "body" then
      local body = response.body
      if not body or body == "" then return nil end
      if path == "" then return body end
      local ok, parsed = pcall(vim.json.decode, body)
      if not ok then
        state.log("WARN", string.format("Cannot parse response body as JSON for '%s'", req_name))
        return nil
      end
      return get_nested_value(util.json_to_table(parsed), path)
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
      if ok then return get_nested_value(util.json_to_table(parsed), path) end
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

local function find_request_variable_refs(block_text)
  local refs = {}
  -- Scan the raw text so `full` preserves the user's `.res.` spelling; the
  -- normalized form is derived per-ref in make_ref for the cache lookup.
  for raw_inner in block_text:gmatch("{{(.-)}}") do
    local ref = make_ref(raw_inner)
    if ref then
      table.insert(refs, ref)
    end
  end
  return refs
end

local function find_dynamic_prompt_refs(block_text)
  local refs = {}
  for line in block_text:gmatch("[^\n]+") do
    local options_str = line:match("^%s*<<[%a_][%w_]*%s*%[(.+)%]")
    if options_str then
      -- Greedy: a jq mapping inside the prompt options may itself end with
      -- `}}`, so the ref span runs to the LAST closing braces.
      local raw_inner = options_str:match("{{(.+)}}")
      if raw_inner then
        local ref = make_ref(raw_inner)
        if ref then
          table.insert(refs, ref)
        end
      end
    end
  end
  return refs
end

local function execute_dependent_request_async(buf, file, env_name, dep_req, dep_block_text, on_complete)
  if request_response_cache[dep_req.name] then
    state.log("INFO", string.format("Using cached response for '%s'", dep_req.name))
    vim.schedule(function() on_complete(request_response_cache[dep_req.name]) end)
    return
  end

  state.log("INFO", string.format("Executing dependency '%s' via curl", dep_req.name))

  local blocks = describe.describe_content(dep_block_text, file)
  if not blocks or #blocks == 0 then
    state.log("WARN", string.format("Failed to parse dependency '%s' block", dep_req.name))
    vim.schedule(function() on_complete(nil) end)
    return
  end
  local meta = blocks[1]
  local method = meta.method or "GET"
  local url = meta.path or ""
  local headers = meta.headers or {}
  local body = meta.body or ""

  if not url or url == "" then
    state.log("WARN", string.format("Dependency '%s' has no URL", dep_req.name))
    vim.schedule(function() on_complete(nil) end)
    return
  end

  local dep_lines = vim.split(dep_block_text, "\n", { plain = true })
  local resolver = vars.build_resolver_from_state({
    lines = dep_lines,
    file_path = file,
    block_start = 1,
    block_end = #dep_lines,
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

  local buf_dir = file ~= "" and vim.fn.fnamemodify(file, ":h") or vim.fn.getcwd()

  curl_exec.execute({
    method = method,
    url = url,
    headers = global_headers.merge(resolved_headers, resolver),
    body = body,
    buf_dir = buf_dir,
    timeout = state.config.timeout,
  }, function(response)
    if response.error then
      state.log("WARN", string.format("Dependency '%s' failed: %s", dep_req.name, response.error))
      on_complete(nil)
      return
    end
    response.metadata = response.metadata or {}
    if not response.metadata.timestamp then
      response.metadata.timestamp = os.date("%Y-%m-%d %H:%M:%S")
    end
    request_response_cache[dep_req.name] = response
    response.request_name = dep_req.name
    run_dep_post_scripts(response, dep_block_text, buf_dir)
    state.log("INFO", string.format("Cached response for '%s'", dep_req.name))
    on_complete(response)
  end)
end

function M.cache_response(req_name, response)
  if req_name then
    request_response_cache[req_name] = response
  end
end

function M.is_response_cached(name)
  return request_response_cache[name] ~= nil
end

function M.resolve_single_ref(pattern)
  return resolve_request_variable(pattern, request_response_cache)
end

function M.collect_requests_from_content(content)
  local requests = {}
  local lines = vim.split(content, "\n", { plain = true })
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^%s*###%s+(%S.*)$")
    if name then
      name = vim.trim(name)
      local start_line = i
      local end_line = #lines
      for j = i + 1, #lines do
        if lines[j]:match("^%s*###") then
          end_line = j - 1
          break
        end
      end
      table.insert(requests, { name = name, start_line = start_line, end_line = end_line })
    end
    i = i + 1
  end
  return requests
end

local resolve_content_dependencies_impl

local function execute_deps_for_block(opts)
  local buf = opts.buf
  local file = opts.file
  local env_name = opts.env_name
  local content = opts.content
  local block_text = opts.block_text
  local all_lines = opts.all_lines
  local block_start = opts.block_start
  local block_end = opts.block_end
  local requests = opts.requests
  local depth = opts.depth
  local on_complete = opts.on_complete
  local handle_prompt = opts.handle_prompt

  -- File-level @var lines (before the first `###`) may reference request
  -- responses too. Include their refs so referenced deps execute and the refs
  -- are substituted inline, making the @var value resolvable by the resolver.
  local file_var_end = 0
  for i, l in ipairs(all_lines) do
    if l:match("^%s*###") then
      file_var_end = i - 1
      break
    end
  end

  local refs = find_request_variable_refs(block_text)
  local dyn_refs = find_dynamic_prompt_refs(block_text)
  for _, dr in ipairs(dyn_refs) do
    local found = false
    for _, r in ipairs(refs) do
      if r.request_name == dr.request_name then
        found = true
        break
      end
    end
    if not found then
      table.insert(refs, dr)
    end
  end
  if file_var_end > 0 then
    local file_var_text = table.concat(all_lines, "\n", 1, file_var_end)
    for _, fr in ipairs(find_request_variable_refs(file_var_text)) do
      local found = false
      for _, r in ipairs(refs) do
        if r.full == fr.full then
          found = true
          break
        end
      end
      if not found then
        table.insert(refs, fr)
      end
    end
  end
  if #refs == 0 then
    on_complete(content)
    return
  end

  state.log("INFO", string.format("Found %d request variable reference(s) in target block (depth %d)", #refs, depth))

  local pending_deps = {}
  for _, ref in ipairs(refs) do
    if not request_response_cache[ref.request_name] then
      local already_pending = false
      for _, req in ipairs(pending_deps) do
        if req.name == ref.request_name then
          already_pending = true
          break
        end
      end
      if not already_pending then
        for _, req in ipairs(requests) do
          if req.name == ref.request_name then
            table.insert(pending_deps, req)
            already_pending = true
            break
          end
        end
      end
      if not already_pending then
        local resolved = get_import_mod().resolve_reference(ref.request_name, get_cache_mod().collect_import_index(opts.buf))
        if resolved then
          local file_content = vim.fn.readfile(resolved.path)
          if file_content and #file_content > 0 then
            -- Bounds inside the IMPORTED file (distinct from the target
            -- block's block_start/block_end in the source buffer).
            local import_start = resolved.line
            local import_end = #file_content
            for j = import_start + 1, #file_content do
              if file_content[j]:match("^%s*###") then
                import_end = j - 1
                break
              end
            end
            local block_lines = {}
            for i = import_start, import_end do
              table.insert(block_lines, file_content[i] or "")
            end
            table.insert(pending_deps, {
              name = ref.request_name,
              start_line = import_start,
              end_line = import_end,
              block_text = table.concat(block_lines, "\n"),
              file = resolved.path,
            })
          end
        end
      end
    end
  end

  local function substitute_and_finish()
    local resolved_block = block_text
    for _, ref in ipairs(refs) do
      -- Lookup uses the normalized form; the gsub pattern stays the raw
      -- `{{...}}` spelling so `.res.` shorthand refs are replaced too.
      local value = resolve_request_variable(ref.norm or ref.full:sub(3, -3), request_response_cache)
      if value ~= nil then
        -- replacement via function: response values may contain `%`
        -- (URL-encoding, base64), which a string replacement would treat
        -- as a capture reference
        resolved_block = resolved_block:gsub(vim.pesc(ref.full),
          function() return value_to_http_string(value) end)
      else
        state.log("WARN", string.format("Could not resolve variable: %s", ref.full))
      end
    end
    local result_lines = {}
    local resolved_split = vim.split(resolved_block, "\n", { plain = true })
    for i, l in ipairs(all_lines) do
      if i >= block_start and i <= block_end then
        table.insert(result_lines, resolved_split[i - block_start + 1] or l)
      elseif i <= file_var_end then
        local line = l
        for _, ref in ipairs(refs) do
          local value = resolve_request_variable(ref.norm or ref.full:sub(3, -3), request_response_cache)
          if value ~= nil then
            line = line:gsub(vim.pesc(ref.full),
              function() return value_to_http_string(value) end)
          end
        end
        table.insert(result_lines, line)
      else
        table.insert(result_lines, l)
      end
    end
    return table.concat(result_lines, "\n")
  end

  if #pending_deps == 0 then
    on_complete(substitute_and_finish())
    return
  end

  local dep_idx = 1
  local function execute_next_dep()
    if dep_idx > #pending_deps then
      table.sort(_chain_dep_order, function(a, b) return a.depth > b.depth end)
      M._dep_chain = {}
      for _, entry in ipairs(_chain_dep_order) do
        local resp = request_response_cache[entry.name]
        if resp then
          table.insert(M._dep_chain, {name = entry.name, response = resp})
        end
      end
      on_complete(substitute_and_finish())
      return
    end

    local dep_req = pending_deps[dep_idx]
    dep_idx = dep_idx + 1

    if not _chain_dep_set[dep_req.name] then
      _chain_dep_set[dep_req.name] = true
      table.insert(_chain_dep_order, { name = dep_req.name, depth = depth })
    end

    state.log("INFO", string.format("Resolving dependency '%s' (depth %d)", dep_req.name, depth))

    local function do_execute(resolved_content)
      local dep_block_text
      if dep_req.block_text then
        dep_block_text = dep_req.block_text
      else
        if not resolved_content then resolved_content = content end
        local resolved_lines = vim.split(resolved_content, "\n", { plain = true })
        local dep_lines = {}
        for i = dep_req.start_line, dep_req.end_line do
          table.insert(dep_lines, resolved_lines[i] or "")
        end
        dep_block_text = table.concat(dep_lines, "\n")
      end
      local dep_file = dep_req.file or file
      local has_prompts = dep_block_text:match("<<[%a_][%w_]")

      if has_prompts and handle_prompt then
        handle_prompt(buf, dep_req.start_line, resolved_content or dep_block_text, dep_file, env_name, function(prompt_resolved)
          if not prompt_resolved then
            state.log("WARN", string.format("Dependency '%s' prompt cancelled, skipping", dep_req.name))
            execute_next_dep()
            return
          end
          local prompt_lines = vim.split(prompt_resolved, "\n", { plain = true })
          local dep_lines2 = {}
          for i = dep_req.start_line, dep_req.end_line do
            table.insert(dep_lines2, prompt_lines[i] or "")
          end
          local dep_block_text2 = table.concat(dep_lines2, "\n")
          execute_dependent_request_async(buf, dep_file, env_name, dep_req, dep_block_text2, function(response)
            if response then
              state.log("INFO", string.format("Dependency '%s' executed and cached", dep_req.name))
            else
              state.log("WARN", string.format("Dependency '%s' failed to execute", dep_req.name))
            end
            execute_next_dep()
          end)
        end)
      else
        execute_dependent_request_async(buf, dep_file, env_name, dep_req, dep_block_text, function(response)
          if response then
            state.log("INFO", string.format("Dependency '%s' executed and cached", dep_req.name))
          else
            state.log("WARN", string.format("Dependency '%s' failed to execute", dep_req.name))
          end
          execute_next_dep()
        end)
      end
    end

    resolve_content_dependencies_impl(buf, file, env_name, content, dep_req.start_line, do_execute, depth + 1, { handle_prompt = handle_prompt })
  end

  execute_next_dep()
end

local function resolve_request_variables_impl(buf, file, env_name, cursor_line, content, on_complete, deps)
  deps = deps or {}
  local collect_requests = deps.collect_requests
  local handle_prompt = deps.handle_prompt or handle_prompt_fn

  _chain_dep_set = {}
  _chain_dep_order = {}

  local requests = collect_requests(buf)

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

  local all_lines = vim.split(content, "\n", { plain = true })
  local block_lines = {}
  for i = current_req.start_line, current_req.end_line do
    table.insert(block_lines, all_lines[i] or "")
  end
  local block_text = table.concat(block_lines, "\n")

  execute_deps_for_block({
    buf = buf,
    file = file,
    env_name = env_name,
    content = content,
    block_text = block_text,
    all_lines = all_lines,
    block_start = current_req.start_line,
    block_end = current_req.end_line,
    requests = requests,
    depth = 0,
    on_complete = on_complete,
    handle_prompt = handle_prompt,
  })
end

resolve_content_dependencies_impl = function(buf, file_path, env_name, content, block_line, on_complete, _depth, deps)
  deps = deps or {}
  local handle_prompt = deps.handle_prompt or handle_prompt_fn

  _depth = _depth or 0
  if _depth > 10 then
    state.log("ERROR", string.format("Max dependency depth (10) reached at block line %d, aborting resolution", block_line))
    on_complete(content)
    return
  end

  local requests = M.collect_requests_from_content(content)

  local lines = vim.split(content, "\n", { plain = true })
  local block_end = #lines
  for i = block_line + 1, #lines do
    if lines[i]:match("^%s*###") then
      block_end = i - 1
      break
    end
  end
  local block_lines = {}
  for i = block_line, block_end do
    table.insert(block_lines, lines[i] or "")
  end
  local block_text = table.concat(block_lines, "\n")

  execute_deps_for_block({
    buf = buf,
    file = file_path,
    env_name = env_name,
    content = content,
    block_text = block_text,
    all_lines = lines,
    block_start = block_line,
    block_end = block_end,
    requests = requests,
    depth = _depth,
    on_complete = on_complete,
    handle_prompt = handle_prompt,
  })
end

M.find_request_variable_refs = find_request_variable_refs
M.find_dynamic_prompt_refs = find_dynamic_prompt_refs
M.execute_dependent_request_async = execute_dependent_request_async
M.run_dep_post_scripts = run_dep_post_scripts

M._dep_chain = nil
M._resolve_request_variable = resolve_request_variable
M.value_to_http_string = value_to_http_string

M._resolve_request_variables_impl = resolve_request_variables_impl
M._resolve_content_dependencies_impl = resolve_content_dependencies_impl

function M.resolve_request_variables(buf, file, env_name, cursor_line, content, on_complete, deps)
  resolve_request_variables_impl(buf, file, env_name, cursor_line, content, on_complete, deps)
end

function M.resolve_content_dependencies(buf, file_path, env_name, content, block_line, on_complete, deps)
  _chain_dep_set = {}
  _chain_dep_order = {}
  request_response_cache = {}
  resolve_content_dependencies_impl(buf, file_path, env_name, content, block_line, on_complete, nil, deps)
end

return M