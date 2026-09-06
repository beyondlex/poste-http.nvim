--- gRPC completion index: pkg.Service/Method names for GRPC request lines,
--- resolved either offline from the block's `# @grpc-proto` /
--- `# @grpc-proto-set` / `# @grpc-import-path` operators via
--- `grpcurl ... list|describe` (no server needed), or from server reflection
--- via `grpcurl <host> list|describe` when no proto is pinned.
---
--- Cache-first: completion is synchronous, so items are always served from
--- the in-memory index (`M._cache`); `prewarm` spawns the grpcurl jobs in the
--- background and the index is finalized when every describe job exits. The
--- cache key folds in proto file mtimes, so editing a proto invalidates it.
---
--- Also provides file-path completion for `# @grpc-proto` arguments.

local M = {}

local cache = require("poste-http.http.cache")
local block_operators = require("poste-http.http.block_operators")

local uv = vim.uv or vim.loop

--- proto scalar field types (never describe-referenced for completion)
local SCALARS = {
  string = true, bytes = true, bool = true, float = true, ["double"] = true,
  int32 = true, int64 = true, uint32 = true, uint64 = true,
  sint32 = true, sint64 = true, fixed32 = true, fixed64 = true,
  sfixed32 = true, sfixed64 = true,
}

--- vim.fn indirection so tests can stub jobstart/executable.
M.fn = vim.fn

--- Per-buffer index cache: buf -> { key, pending, index = { services = { [fq] = { methods } } } }
M._cache = {}

--- Overridable stat hook used by index_key (tests).
M.fs_stat = function(path) return uv.fs_stat(path) end

local function add_flag_args(args, info)
  if info.plaintext then table.insert(args, "-plaintext") end
  if info.tls then table.insert(args, "-tls") end
  for _, v in ipairs(info.import_paths or {}) do
    table.insert(args, "-import-path")
    table.insert(args, v)
  end
  for _, v in ipairs(info.protos or {}) do
    table.insert(args, "-proto")
    table.insert(args, v)
  end
  for _, v in ipairs(info.proto_sets or {}) do
    table.insert(args, "-proto-set")
    table.insert(args, v)
  end
end

local function has_protos(info)
  return #(info.protos or {}) > 0 or #(info.proto_sets or {}) > 0
end

--- grpcurl argv for `list` — offline when protos are pinned, else reflection.
function M.build_list_args(info)
  local args = { "grpcurl" }
  add_flag_args(args, info)
  if has_protos(info) then
    table.insert(args, "list")
  else
    table.insert(args, info.host or "")
    table.insert(args, "list")
  end
  return args
end

--- grpcurl argv for `describe <service>` of one service.
function M.build_describe_args(info, service)
  local args = { "grpcurl" }
  add_flag_args(args, info)
  if not has_protos(info) then
    table.insert(args, info.host or "")
  end
  table.insert(args, "describe")
  table.insert(args, service)
  return args
end

--- Parse `grpcurl list` output into a sorted list of service names.
function M.parse_list_output(text)
  local services = {}
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local name = vim.trim(line)
    if name ~= "" and name:match("^[%w_.]+$") then
      table.insert(services, name)
    end
  end
  table.sort(services)
  return services
end

--- Parse `grpcurl describe <service>` output into method entries:
--- { name, request_type, client_stream } — request_type is the
--- fully-qualified message name with the leading dot stripped.
function M.parse_describe_output(text)
  local methods = {}
  for method, req_type in (text or ""):gmatch(
    "rpc%s+([%w_]+)%s*%(%s*(.-)%s*%)%s*returns%s*%(") do
    local client_stream = req_type:match("^stream%s+") ~= nil
    local fq = req_type:gsub("^stream%s+", ""):gsub("^%.", "")
    table.insert(methods, {
      name = method,
      request_type = fq,
      client_stream = client_stream,
    })
  end
  return methods
end

local function strip_dot(t)
  return (t:gsub("^%.", ""))
end

--- Parse `grpcurl describe <type>` output (message or enum):
---   { kind = "message", fields = { { name, type, repeated, is_map }, ... } }
---   { kind = "enum", values = { ... } }
---   { kind = "unknown" }
--- grpcurl prints field types fully qualified (".demo.v1.Address"); the
--- leading dot is stripped. Nested message/enum definitions inside the block
--- are skipped (their defining lines push a block kind), oneof members are
--- collected as ordinary fields.
function M.parse_type_describe(text)
  if not text or text == "" then return { kind = "unknown" } end
  if text:match("is an enum:") then
    local values = {}
    for name in text:gmatch("([%w_]+)%s*=%s*%-?%d+%s*;") do
      table.insert(values, name)
    end
    return { kind = "enum", values = values }
  end
  if not text:match("is a message:") then return { kind = "unknown" } end

  local fields = {}
  local stack = {}
  local function outer_message_depth()
    local depth = 0
    for _, kind in ipairs(stack) do
      if kind == "message" then depth = depth + 1 end
    end
    return depth
  end
  for line in text:gmatch("[^\n]+") do
    local t = vim.trim(line)
    local open_kind = t:match("^(message)%s+[%w_.]+%s*{$")
        or t:match("^(oneof)%s+[%w_]+%s*{$")
        or t:match("^(enum)%s+[%w_]+%s*{$")
    if open_kind then
      stack[#stack + 1] = open_kind
    elseif t == "}" then
      stack[#stack] = nil
    elseif outer_message_depth() == 1 then
      -- directly inside the described message (its oneof members included)
      local map_value, map_name = t:match("^map%s*<.-%s*,%s*(.-)%s*>%s+([%w_]+)%s*=%s*%d+;$")
      if map_value then
        table.insert(fields, { name = map_name, type = strip_dot(map_value), is_map = true })
      else
        local repeated, ftype, fname = t:match("^(repeated%s+)(.-)%s+([%w_]+)%s*=%s*%d+;$")
        if repeated then
          table.insert(fields, { name = fname, type = strip_dot(ftype), repeated = true })
        else
          ftype, fname = t:match("^(.-)%s+([%w_]+)%s*=%s*%d+;$")
          if ftype then
            table.insert(fields, { name = fname, type = strip_dot(ftype) })
          end
        end
      end
    end
  end
  return { kind = "message", fields = fields }
end

--- Scan the body text up to the cursor and report where completion should
--- happen: { path = { "user", "address" }, position = "key"|"value",
--- partial = "ci" }. `{{var}}` placeholders are skipped atomically so their
--- braces don't disturb the object depth; strings respect backslash escapes.
function M.body_context(text)
  local frames = {} -- { kind = "object"|"array", key = string|nil }
  local position = "key"
  local pending_key = nil
  local last_string = nil
  local in_string = false
  local string_start = nil
  local escaped = false
  local bare_start = nil
  local partial = ""
  local i, n = 1, #text

  local function frame() return frames[#frames] end
  local function new_frame_key()
    local f = frame()
    if not f then return nil end
    if f.kind == "object" then return pending_key end
    return f.key
  end

  while i <= n do
    local c = text:sub(i, i)
    if in_string then
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        in_string = false
        last_string = text:sub(string_start, i - 1)
      end
      i = i + 1
    elseif c == "{" then
      if text:sub(i + 1, i + 1) == "{" then
        local close = text:find("}}", i + 2, true)
        i = close and (close + 2) or (n + 1)
      else
        frames[#frames + 1] = { kind = "object", key = new_frame_key() }
        pending_key = nil
        position = "key"
        partial = ""
        bare_start = nil
        i = i + 1
      end
    elseif c == "[" then
      frames[#frames + 1] = { kind = "array", key = new_frame_key() }
      pending_key = nil
      position = "value"
      partial = ""
      bare_start = nil
      i = i + 1
    elseif c == "}" or c == "]" then
      frames[#frames] = nil
      pending_key = nil
      position = (frame() and frame().kind == "object") and "key" or "value"
      partial = ""
      bare_start = nil
      i = i + 1
    elseif c == '"' then
      in_string = true
      string_start = i + 1
      partial = ""
      bare_start = nil
      i = i + 1
    elseif c == ":" then
      if last_string then
        pending_key = last_string
        last_string = nil
      end
      position = "value"
      partial = ""
      bare_start = nil
      i = i + 1
    elseif c == "," then
      last_string = nil
      position = (frame() and frame().kind == "object") and "key" or "value"
      partial = ""
      bare_start = nil
      i = i + 1
    elseif c == " " or c == "\t" or c == "\n" or c == "\r" then
      bare_start = nil
      partial = ""
      i = i + 1
    else
      if position == "value" then
        if not bare_start then bare_start = i end
        partial = text:sub(bare_start, i)
      end
      i = i + 1
    end
  end
  if in_string then
    partial = text:sub(string_start, n)
  end

  local path = {}
  for _, f in ipairs(frames) do
    if f.kind == "object" and f.key then
      table.insert(path, f.key)
    end
  end
  -- at a value position the pending key locates the field being filled in
  if position == "value" and pending_key then
    table.insert(path, pending_key)
  end
  return { path = path, position = position, partial = partial }
end

--- Collect the GRPC request-line target and `# @grpc-*` operators of the
--- block containing cursor_line. Returns nil outside a request block.
function M.get_block_info(buf, cursor_line)
  local start_line, end_line = cache.find_request_block_bounds(buf, cursor_line)
  if not start_line then return nil end

  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local operators = block_operators.extract(lines)

  local host = nil
  for _, line in ipairs(lines) do
    local target = line:match("^%s*GRPC%s+(%S+)")
    if target then
      host = target:match("^([^/]*)")
      break
    end
  end

  return {
    host = host,
    protos = operators["grpc-proto"] or {},
    proto_sets = operators["grpc-proto-set"] or {},
    import_paths = operators["grpc-import-path"] or {},
    plaintext = #(operators["grpc-plaintext"] or {}) > 0,
    tls = #(operators["grpc-tls"] or {}) > 0,
  }
end

--- Cache key folding in every input that can change the index: host,
--- operator values, and proto file mtimes.
function M.index_key(info)
  local parts = { "v1", info.host or "" }
  local groups = { info.import_paths, info.protos, info.proto_sets }
  for _, group in ipairs(groups) do
    local sorted = vim.deepcopy(group or {})
    table.sort(sorted)
    for _, path in ipairs(sorted) do
      local mtime = "missing"
      local st = M.fs_stat(path)
      -- uv.fs_stat returns the stat table FLAT (st.mtime = {sec, nsec});
      -- accept a .stat-wrapped shape too so test stubs can use either
      local mt = st and (st.stat and st.stat.mtime or st.mtime) or nil
      if mt and mt.sec then
        mtime = mt.sec .. "." .. mt.nsec
      end
      table.insert(parts, path .. "@" .. mtime)
    end
    table.insert(parts, "#")
  end
  return table.concat(parts, "|")
end

--- Spawn a grpcurl describe job for one type and merge the parsed
--- message/enum into `index` when it lands. Non-scalar field types of a
--- newly indexed message chain into their own describe jobs, so nested
--- messages and enums used by the body are all indexed after prewarm
--- (index.pending_messages guards against reference cycles).
local function describe_type_into(buf, info, fq, index, remaining)
  local ok = M.fn.jobstart(M.build_describe_args(info, fq), {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      data = data or {}
      local desc = M.parse_type_describe(table.concat(data, "\n"))
      vim.schedule(function()
        if desc.kind == "message" then
          index.messages[fq] = desc
          index.enums[fq] = nil
          for _, f in ipairs(desc.fields or {}) do
            local ft = f.type
            if ft and not SCALARS[ft]
              and not index.messages[ft] and not index.enums[ft]
              and not index.pending_messages[ft] then
              index.pending_messages[ft] = true
              remaining.n = remaining.n + 1
              describe_type_into(buf, info, ft, index, remaining)
            end
          end
        elseif desc.kind == "enum" then
          index.enums[fq] = desc
          index.messages[fq] = nil
        end
        index.pending_messages[fq] = nil
      end)
    end,
    on_exit = function()
      vim.schedule(function()
        remaining.n = remaining.n - 1
        if remaining.n <= 0 then
          M._cache[buf] = { key = M.index_key(info), index = index }
        end
      end)
    end,
  })
  if not ok or ok <= 0 then
    index.pending_messages[fq] = nil
    remaining.n = remaining.n - 1
  end
end

--- Spawn the background grpcurl jobs that fill the index for this block.
--- Service describes run first; each method's request message type is
--- described too so body field completion is ready without a first miss.
--- A failed or empty listing is cached as an empty index so completion
--- doesn't respawn jobs on every keystroke; it retries once the key
--- (proto mtimes / host / operators) changes.
function M.prewarm(buf, info)
  if not info then return end
  local key = M.index_key(info)
  local entry = M._cache[buf]
  if entry and entry.key == key then
    return
  end
  if M.fn.executable("grpcurl") ~= 1 then return end
  if not has_protos(info) and not (info.host and info.host ~= "") then return end

  M._cache[buf] = {
    key = key,
    pending = true,
    index = { services = {}, messages = {}, enums = {}, pending_messages = {} },
  }

  local remaining = { n = 0 }
  local index = { services = {}, messages = {}, enums = {}, pending_messages = {} }

  local seen_request_types = {}
  M.fn.jobstart(M.build_list_args(info), {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      data = data or {}
      for _, svc in ipairs(M.parse_list_output(table.concat(data, "\n"))) do
        index.services[svc] = { methods = {} }
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code ~= 0 then
          M._cache[buf] = { key = key, index = { services = {} } }
          return
        end
        local services = {}
        for svc in pairs(index.services) do
          table.insert(services, svc)
        end
        if #services == 0 then
          M._cache[buf] = { key = key, index = index }
          return
        end
        -- One describe job per service; each service's request message
        -- types chain in when the service describe lands. The index is
        -- published once every job has returned.
        for _, svc in ipairs(services) do
          remaining.n = remaining.n + 1
          local ok = M.fn.jobstart(M.build_describe_args(info, svc), {
            stdout_buffered = true,
            stderr_buffered = true,
            on_stdout = function(_, data)
              data = data or {}
              index.services[svc].methods =
                M.parse_describe_output(table.concat(data, "\n"))
            end,
            on_exit = function()
              vim.schedule(function()
                for _, m in ipairs(index.services[svc].methods or {}) do
                  local rt = m.request_type
                  if rt and not seen_request_types[rt] then
                    seen_request_types[rt] = true
                    index.pending_messages[rt] = true
                    remaining.n = remaining.n + 1
                    describe_type_into(buf, info, rt, index, remaining)
                  end
                end
                remaining.n = remaining.n - 1
                if remaining.n <= 0 then
                  M._cache[buf] = { key = key, index = index }
                end
              end)
            end,
          })
          if not ok or ok <= 0 then
            remaining.n = remaining.n - 1
          end
        end
        if remaining.n <= 0 then
          M._cache[buf] = { key = key, index = index }
        end
      end)
    end,
  })
end

--- Describe one message type on demand (nested types referenced from the
--- body path). No-op when it is already indexed or in flight.
function M.ensure_message(buf, info, fq)
  local entry = M._cache[buf]
  local index = entry and entry.index
  if not index or fq == "" then return end
  if index.messages[fq] or index.enums[fq] or index.pending_messages[fq] then return end
  if M.fn.executable("grpcurl") ~= 1 then return end
  index.pending_messages[fq] = true
  describe_type_into(buf, info, fq, index, { n = 1 })
end

--- Completion items for the `grpc_method_path` context.
--- extra = { host, service_prefix, partial } (from context_detector).
--- Serves from cache only; triggers prewarm when the index is missing.
function M.get_method_items(buf, cursor_line, extra)
  extra = extra or {}
  local items = {}
  local info = M.get_block_info(buf, cursor_line)
  if not info then return items end

  local entry = M._cache[buf]
  local index = nil
  if entry and not vim.tbl_isempty(entry.index or {}) then
    index = entry.index
  else
    M.prewarm(buf, info)
  end
  if not index then return items end

  if (extra.service_prefix or "") == "" then
    local partial = (extra.partial or "")
    for svc in pairs(index.services or {}) do
      if partial == "" or svc:sub(1, #partial) == partial then
        table.insert(items, {
          label = svc,
          kind = 9, -- LSP: Module
          insertText = svc .. "/",
          filterText = svc,
          sortText = "0" .. svc,
          detail = "gRPC service",
        })
      end
    end
    table.sort(items, function(a, b) return a.sortText < b.sortText end)
  else
    local svc = index.services[extra.service_prefix]
    if svc then
      local partial = (extra.partial or "")
      for _, m in ipairs(svc.methods or {}) do
        if partial == "" or m.name:sub(1, #partial) == partial then
          table.insert(items, {
            label = m.name,
            kind = 3, -- LSP: Function
            insertText = m.name,
            filterText = m.name,
            sortText = "0" .. m.name,
            detail = m.request_type or "gRPC method",
          })
        end
      end
      table.sort(items, function(a, b) return a.sortText < b.sortText end)
    end
  end
  return items
end

--- Locate the request line target and body start of the GRPC block
--- containing cursor_line. Returns target = { service, method } (method nil
--- for bare-host list blocks), body_start line (first `{`/`[` line after the
--- headers), or nils when the block is not a GRPC request with a method path.
function M.find_block_target_and_body(buf, cursor_line)
  local start_line, end_line = cache.find_request_block_bounds(buf, cursor_line)
  if not start_line then return nil, nil end
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)

  local target = nil
  local body_start = nil
  for idx, line in ipairs(lines) do
    local t = vim.trim(line)
    if not target then
      local host, method = t:match("^GRPC%s+([^/]+)/(.+)$")
      if host and host ~= "" then
        local service, m = method:match("^(.+)/([^/]+)$")
        if service then target = { service = service, method = m } end
      end
    else
      if t ~= "" and not t:match("^#") and not t:match("^[%a][%w%-]*%s*:") then
        if t:sub(1, 1) == "{" or t:sub(1, 1) == "[" then
          body_start = start_line + idx - 1
        end
        break
      end
    end
  end
  return target, body_start
end

--- True when cursor_line sits in the body region of a GRPC block that has a
--- method path (the region body completion applies to).
function M.is_grpc_body(buf, cursor_line)
  local target, body_start = M.find_block_target_and_body(buf, cursor_line)
  return target ~= nil and body_start ~= nil and cursor_line >= body_start
end

--- Completion items for the `grpc_body` context: field names at a key
--- position, enum values in a string value position. The message type at
--- the cursor's object path is resolved through the cached index; missing
--- (nested) types trigger a background describe and this round returns
--- nothing.
function M.get_body_items(buf, cursor_line, cursor_col)
  local items = {}

  local info = M.get_block_info(buf, cursor_line)
  if not info then return items end
  local target, body_start = M.find_block_target_and_body(buf, cursor_line)
  if not target or not body_start or cursor_line < body_start then return items end

  local entry = M._cache[buf]
  local index = entry and entry.index
  if not index or vim.tbl_isempty(index.services or {}) then
    M.prewarm(buf, info)
    return items
  end

  local svc = index.services[target.service]
  local method = nil
  if svc then
    for _, m in ipairs(svc.methods or {}) do
      if m.name == target.method then method = m break end
    end
  end
  if not method or not method.request_type then return items end

  local body_lines = vim.api.nvim_buf_get_lines(buf, body_start - 1, cursor_line, false)
  body_lines[#body_lines] = body_lines[#body_lines]:sub(1, cursor_col)
  local bc = M.body_context(table.concat(body_lines, "\n"))

  -- Walk the object path from the request message type down. Missing types
  -- (nested messages not described yet) start a background fetch.
  local fq = method.request_type
  for _, key in ipairs(bc.path) do
    local msg = index.messages[fq]
    if not msg then
      M.ensure_message(buf, info, fq)
      return items
    end
    local field = nil
    for _, f in ipairs(msg.fields or {}) do
      if f.name == key then field = f break end
    end
    if not field then return items end
    fq = field.type
  end

  if bc.position == "value" then
    local en = index.enums[fq]
    if not en then
      M.ensure_message(buf, info, fq)
      return items
    end
    for _, v in ipairs(en.values or {}) do
      if bc.partial == "" or v:sub(1, #bc.partial) == bc.partial then
        table.insert(items, {
          label = v,
          kind = 12, -- LSP: Value
          insertText = v,
          filterText = v,
          sortText = "0" .. v,
          detail = "enum value",
        })
      end
    end
    return items
  end

  local msg = index.messages[fq]
  if not msg then
    M.ensure_message(buf, info, fq)
    return items
  end
  for _, f in ipairs(msg.fields or {}) do
    if bc.partial == "" or f.name:sub(1, #bc.partial) == bc.partial then
      table.insert(items, {
        label = f.name,
        kind = 10, -- LSP: Property
        insertText = f.name,
        filterText = f.name,
        sortText = "0" .. f.name,
        detail = (f.repeated and "repeated " or "") .. f.type .. (f.is_map and " (map value type)" or ""),
      })
    end
  end
  return items
end

--- BufEnter hook: proactively warm the index when the cursor sits in a GRPC
--- block (a cheap no-op otherwise — one cached block-bounds lookup).
function M.prewarm_for_cursor(buf, cursor_line)
  local info = M.get_block_info(buf, cursor_line)
  if info then M.prewarm(buf, info) end
end

--- Completion items for the `grpc_proto_path` context: directories (with a
--- trailing slash) and *.proto files under the directory part of `partial`.
--- Items carry only the final path segment — completion engines replace the
--- trailing keyword token, so multi-segment insertText would duplicate the
--- directory part the user already typed.
function M.get_proto_path_items(partial)
  partial = partial or ""
  local dir = partial:match("^(.*/)") or ""
  local name_prefix = partial:match("([^/]*)$") or ""
  local scan_dir = dir == "" and "." or dir

  local items = {}
  local fd = uv.fs_scandir(scan_dir)
  if not fd then return items end

  while true do
    local name, kind = uv.fs_scandir_next(fd)
    if not name then break end
    if name:sub(1, #name_prefix) == name_prefix then
      if kind == "directory" then
        table.insert(items, {
          label = name .. "/",
          kind = 19, -- LSP: Folder
          insertText = name .. "/",
          filterText = name .. "/",
          sortText = "0" .. name,
          detail = "directory",
        })
      elseif name:match("%.proto$") then
        table.insert(items, {
          label = name,
          kind = 17, -- LSP: File
          insertText = name,
          filterText = name,
          sortText = "1" .. name,
          detail = dir .. name,
        })
      end
    end
  end
  table.sort(items, function(a, b) return a.sortText < b.sortText end)
  return items
end

return M
