--- Context detection for Poste HTTP completion.
--- Extracted from completion.lua for reuse across modules.
local M = {}
local data = require("poste-http.http.data")
local cache = require("poste-http.http.cache")
local ts_query = require("poste-http.http.ts_query")
local grpc_proto = require("poste-http.http.grpc_proto")

--- Whether tree-sitter should be used for context detection for this buffer.
--- Falls back to regex-based detection when the parser is unavailable.
local function use_ts_effective(buf)
  return ts_query.enabled_for(buf, "context_detector")
end

--- Detect completion context for client.run("#target", ...) inside SCRIPT
--- blocks. Mirrors the run-directive contexts so the existing request-name
--- providers are reused.
--- @param line_before_cursor string
--- @return string|nil, table|nil
local function detect_client_run_target(line_before_cursor)
  local after_open = line_before_cursor:match('client%.run%s*%(%s*["\'](.*)$')
  if not after_open then return nil end

  local partial = after_open:match('^([^"\']*)')
  if partial == "" then
    -- Right after the opening quote: offer "#" / "./" prefixes
    return "run_target", nil
  end
  if partial:sub(1, 1) == "#" then
    local rest = partial:sub(2)
    if rest:find("%.") then
      local alias, p = rest:match("^([^%.]+)%.(.*)$")
      return "run_target_alias", { alias = alias, partial = p or "" }
    end
    return "run_target_hash", rest or ""
  end
  return nil
end

--- GRPC request line: `GRPC host:port/pkg.Service/Method` — complete the
--- method-path segment once the host slash is typed. While the host is
--- still being typed (no slash) there is nothing to complete.
--- @param line_before_cursor string
--- @return string|nil, table|nil
local function detect_grpc_request_target(line_before_cursor)
  local target = line_before_cursor:match("^%s*GRPC%s+(.+)$")
  if not target then return nil end
  local slash = target:find("/", 1, true)
  if not slash then return nil end
  local host = target:sub(1, slash - 1)
  local rest = target:sub(slash + 1)
  -- greedy backtrack puts the capture on the LAST slash in rest
  local last_slash = rest:match("^.*()/")
  local service_prefix, partial
  if last_slash then
    service_prefix = rest:sub(1, last_slash - 1)
    partial = rest:sub(last_slash + 1)
  else
    service_prefix = ""
    partial = rest
  end
  return "grpc_method_path",
    { host = host, service_prefix = service_prefix, partial = partial }
end

--- `# @grpc-proto <path>` / `# @grpc-proto-set <path>` comment operators:
--- complete the proto file path argument.
--- @param trimmed string
--- @return string|nil, string|nil
local function detect_grpc_comment_operator(trimmed)
  local partial = trimmed:match("^#%s*@grpc%-proto%-set%s+(.+)$")
      or trimmed:match("^#%s*@grpc%-proto%s+(.+)$")
  if partial then return "grpc_proto_path", partial end
  return nil
end

--- GRPC request body: complete message fields from the proto index.
--- @param buf number|nil
--- @param cursor_line number|nil
--- @return string|nil, table|nil
local function detect_grpc_body(buf, cursor_line)
  if buf and cursor_line and grpc_proto.is_grpc_body(buf, cursor_line) then
    return "grpc_body", nil
  end
  return nil
end

--- Detect if cursor is inside a pre/post script block via tree-sitter.
--- cursor_line is 1-based, cursor_col is 0-based (nvim_win_get_cursor).
local function ts_detect_script_context(buf, cursor_line, cursor_col)
  local row = cursor_line - 1
  local col = cursor_col
  local node = ts_query.node_at_point(buf, row, col)
  if not node then return nil end

  local parent = ts_query.parent_of_type(node, "pre_script", "post_script")
  if parent then
    if parent:type() == "pre_script" then return "pre_script" end
    if parent:type() == "post_script" then return "post_script" end
  end
  return nil
end

local function ts_detect_context(line_before_cursor, buf, cursor_line, cursor_col)
  if buf and cursor_line and cursor_col then
    local script_ctx = ts_detect_script_context(buf, cursor_line, cursor_col)
    if script_ctx then
      -- client.run("#alias.Name", ...) request-target completion
      local run_ctx, run_extra = detect_client_run_target(line_before_cursor)
      if run_ctx then
        return run_ctx, run_extra
      end
      if script_ctx == "post_script" then
        local status_pat = "response%.status%s*[=!~<>]=?%s*"
        if line_before_cursor:match(status_pat) then
          return "status_code", line_before_cursor
        end
      end
      return script_ctx, line_before_cursor
    end
  end

  if not buf then return nil end
  local row = cursor_line and (cursor_line - 1) or 0
  local col = cursor_col or 0

  local node = ts_query.node_at_point(buf, row, col)
  if not node then
    local trimmed = vim.trim(line_before_cursor)
    if trimmed == "" then
      return "method", nil
    end
    return nil
  end

  local node_type = node:type()
  local parent = ts_query.parent_of_type(node,
    "request_line", "header", "variable", "variable_definition",
    "prompt_variable", "import_directive", "run_directive",
    "json_body", "request_block", "multipart_boundary",
    "multipart_form_data", "form_body", "file_upload", "file_ref"
  )

  local parent_type = parent and parent:type() or node_type

  if parent_type == "request_line" then
    local grpc_ctx, grpc_extra = detect_grpc_request_target(line_before_cursor)
    if grpc_ctx then return grpc_ctx, grpc_extra end
    if node_type == "url" or node_type == "url_path" or node_type == "query_string" then
      return nil
    end
    if node_type == "method" or node_type == "method_get" or node_type == "method_post"
      or node_type == "method_put" or node_type == "method_delete"
      or node_type == "method_patch" or node_type == "method_head"
      or node_type == "method_options" then
      return nil
    end
    -- Any other node on an existing request line (e.g. cursor past the URL)
    -- is not a method position, so no completion.
    return nil
  end

  if parent_type == "header" then
    local header_key = ts_query.find_child_by_type(parent, "header_key")
    local key_text = header_key and ts_query.node_text(header_key, buf) or ""
    if node_type == "header_value" then
      return "header_value", key_text
    end
    if not line_before_cursor:find(":", 1, true) then
      return "method_or_header", nil
    end
    if key_text ~= "" then
      return "header_value", key_text
    end
    return "method_or_header", nil
  end

  if parent_type == "variable" then
    local after
    if node:type() == "identifier" then
      after = ts_query.node_text(node, buf)
    else
      local identifier_node = node:named_child(0)
      after = identifier_node and ts_query.node_text(identifier_node, buf) or ""
    end
    local dot_pos = after:find("%.")
    if dot_pos then
      local prefix = after:sub(1, dot_pos - 1)
      local partial = after:sub(dot_pos + 1)
      if prefix:match("^[%w_%.]+$") then
        return "variable_namespace", { prefix = prefix, partial = partial or "" }
      end
    end
    return "variable", after
  end

  if parent_type == "variable_definition" then
    if node_type == "var_name" then
      return nil
    end
    -- Lua import alias keypath: @var = alias. → suggest keys from the module
    if node_type == "import_var_ref" or node_type == "var_value" then
      local text = ts_query.node_text(node, buf)
      local alias, partial = text:match("^(%w+)%.(.*)$")
      if alias then
        local index = cache.collect_import_index(buf)
        if (index.aliased or {})[alias] then
          return "import_var_ref", { alias = alias, partial = partial or "" }
        end
      end
    end
    return nil
  end

  if parent_type == "prompt_variable" then
    local trimmed = vim.trim(line_before_cursor)
    local rev = line_before_cursor:reverse()
    local last_open = rev:find("{{", 1, true)
    local last_close = rev:find("}}", 1, true)
    if last_open and (not last_close or last_close > last_open) then
      local after_open = line_before_cursor:sub(#line_before_cursor - last_open + 2)
      return "variable", after_open
    end
    return nil
  end

  if parent_type == "import_directive" then
    if node_type == "import_path" then
      return "import_path", nil
    end
    local node_text = ts_query.node_text(node, buf)
    if node_text == "as" or node_text:match("^as%s+") then
      return "import_alias", nil
    end
    if node_text:match("^import") then
      return "import_path", nil
    end
    return nil
  end

  if parent_type == "run_directive" then
    local trimmed = vim.trim(line_before_cursor)
    if trimmed:lower():match("^run%s+#") then
      local rest = trimmed:match("^[Rr][Uu][Nn]%s+#(.*)$")
      if rest and rest:find("%.") then
        local alias, partial = rest:match("^([^%.]+)%.(.*)$")
        return "run_target_alias", { alias = alias, partial = partial or "" }
      end
      return "run_target_hash", rest or ""
    end
    if trimmed:lower():match("^run%s+") then
      local target = trimmed:match("^[Rr][Uu][Nn]%s+(.*)$")
      return "run_target", target or ""
    end
    return "run_target", nil
  end

  if parent_type == "json_body" or parent_type == "multipart_boundary"
    or parent_type == "multipart_form_data" or parent_type == "form_body" then
    local rev = line_before_cursor:reverse()
    local last_open = rev:find("{{", 1, true)
    local last_close = rev:find("}}", 1, true)
    if last_open and (not last_close or last_close > last_open) then
      local after_open = line_before_cursor:sub(#line_before_cursor - last_open + 2)
      return "variable", after_open
    end
    local grpc_body_ctx = detect_grpc_body(buf, cursor_line)
    if grpc_body_ctx then return grpc_body_ctx, nil end
    return nil
  end

  if parent_type == "file_upload" or parent_type == "file_ref" then
    return nil
  end

  local trimmed = vim.trim(line_before_cursor)

  -- comment operators: # @grpc-proto[-set] <path> (comment lines fall through
  -- the parent branches above when tree-sitter is active)
  local grpc_op_ctx, grpc_op_extra = detect_grpc_comment_operator(trimmed)
  if grpc_op_ctx then return grpc_op_ctx, grpc_op_extra end

  if trimmed == "" then
    return "method", nil
  end

  if not line_before_cursor:find(" ", 1, true) then
    return "method_or_header", nil
  end

  local colon_pos = line_before_cursor:find(":", 1, true)
  if colon_pos then
    local header_part = line_before_cursor:sub(1, colon_pos - 1)
    local header_name = header_part:match("^%s*([A-Za-z][A-Za-z0-9%-]*)$")
    if header_name then
      return "header_value", header_name
    end
  end

  return nil
end

--- Detect if cursor is inside a pre-request or post-request script block.
--- Uses cache.lua O(1) line_type lookup instead of buffer scanning.
--- Returns: "pre_script", "post_script", or nil
local function detect_script_context(buf, cursor_line, cursor_col)
  if use_ts_effective(buf) then
    return ts_detect_script_context(buf, cursor_line, cursor_col)
  end
  local t = require("poste-http.http.cache").get_line_type(buf, cursor_line)
  if t == "pre_script" then
    return "pre_script"
  elseif t == "post_script" then
    return "post_script"
  end
  return nil
end

--- Check if cursor is in file-level area (before first ### block).
local function is_file_level(buf, line)
  if not buf or not line then return true end
  local t = cache.get_line_type(buf, line)
  return t == "file"
end

--- Detect the completion context from the line up to cursor.
--- Optimized with direct string ops instead of pattern matching where possible.
--- Returns: context_type, extra_data
--- Context types:
---   "method"           - empty line, expecting HTTP method
---   "method_or_header" - single word, could be method or header name
---   "header_value"     - after "Header:" (extra_data = header name)
---   "variable"         - inside {{...}} (extra_data = text after {{)
---   "pre_script"       - inside < {% ... %} block
---   "post_script"      - inside > {% ... %} block
---   nil                - no completion
local function detect_context(line_before_cursor, buf, cursor_line, cursor_col)
  if use_ts_effective(buf) then
    return ts_detect_context(line_before_cursor, buf, cursor_line, cursor_col)
  end

  -- Check if we're inside a script block (takes precedence over all other contexts)
  if buf and cursor_line and cursor_col then
    local script_ctx = detect_script_context(buf, cursor_line, cursor_col)
    if script_ctx then
      -- client.run("#alias.Name", ...) request-target completion
      local run_ctx, run_extra = detect_client_run_target(line_before_cursor)
      if run_ctx then
        return run_ctx, run_extra
      end
      -- Inside a script block: check for status code comparison pattern
      if script_ctx == "post_script" then
        local status_pat = "response%.status%s*[=!~<>]=?%s*"
        if line_before_cursor:match(status_pat) then
          return "status_code", line_before_cursor
        end
      end
      return script_ctx, line_before_cursor
    end
  end

  local trimmed = vim.trim(line_before_cursor)

  -- import/run directive detection (before empty-line check so "import" on blank line still triggers)
  if trimmed:match("^import") then
    if trimmed:match("^import%s+%S+%s+as?$") or trimmed:match("^import%s+%S+%s+a$") then
      return "import_alias", nil
    end
    if trimmed:match("^import%s+%S+") then
      return nil, nil  -- already has path + optional alias name
    end
    return "import_path", nil
  end
  if trimmed:lower():match("^run") then
    -- run #Name or run #alias.Name
    if trimmed:lower():match("^run%s+#") then
      local rest = trimmed:match("^[Rr][Uu][Nn]%s+#(.*)$")
      if rest and rest:find("%.") then
        local alias, partial = rest:match("^([^%.]+)%.(.*)$")
        return "run_target_alias", { alias = alias, partial = partial or "" }
      end
      return "run_target_hash", rest or ""
    end
    if trimmed:lower():match("^run%s+") then
      local target = trimmed:match("^[Rr][Uu][Nn]%s+(.*)$")
      return "run_target", target or ""
    end
    return "run_target", nil
  end

  -- Fast-path: empty or whitespace-only → method completion
  if trimmed == "" then
    if is_file_level(buf, cursor_line) then
      return "file_directive", nil
    end
    return "method", nil
  end

  -- Direct string prefix checks (faster than :match)
  local first_char = trimmed:sub(1, 1)
  if first_char == "#" then
    -- After ### (request name line) → no completion
    if trimmed:sub(2, 2) == "#" then return nil, nil end
    -- Commented prompt line (# <<var ...): allow {{ completion
    if trimmed:match("^#%s*<<") then
      -- Fall through for {{variable}} completion
    else
      -- Comment operators: # @grpc-proto[-set] <path>
      local grpc_op_ctx, grpc_op_extra = detect_grpc_comment_operator(trimmed)
      if grpc_op_ctx then return grpc_op_ctx, grpc_op_extra end
      -- Regular comment lines → no completion
      return nil, nil
    end
  end

  -- Comment: -- (direct check instead of pattern)
  if first_char == "-" and trimmed:sub(2, 2) == "-" then
    return nil, nil
  end

  -- Variable reference: check for unclosed {{ before cursor
  -- Must be before @var check so @base_url = {{ works (after other early-returns
  -- like #, -- which don't need {{ support).
  local rev = line_before_cursor:reverse()
  local last_open = rev:find("{{", 1, true)   -- plain string find
  local last_close = rev:find("}}", 1, true)  -- plain string find
  if last_open and (not last_close or last_close > last_open) then
    -- Cursor is inside an unclosed {{...}}
    local after_open = line_before_cursor:sub(#line_before_cursor - last_open + 2)
    -- Check if this is a prompt mapping context (contains | {)
    if after_open:match("|%s*{%s*$") or after_open:match("|%s*{%s*%w*$") then
      return "prompt_mapping", after_open
    end
    local last_dot_start, last_dot_end = after_open:find("%.[^.]*$")
    if last_dot_start then
      local prefix = after_open:sub(1, last_dot_start - 1)
      if prefix:match("^[%w_%.]+$") then
        local partial = after_open:sub(last_dot_start + 1)
        return "variable_namespace", { prefix = prefix, partial = partial or "" }
      end
    end
    return "variable", after_open
  end

  -- GRPC request body: complete message fields from the proto index
  local grpc_body_ctx = detect_grpc_body(buf, cursor_line)
  if grpc_body_ctx then return grpc_body_ctx, nil end

  -- @var definition: detect Lua import alias keypath @var = alias.
  if first_char == "@" then
    local var_name, alias, partial = line_before_cursor:match("^%s*@(%w[%w_]*)%s*=%s*(%w+)%s*%.(.*)$")
    if var_name and alias then
      local index = cache.collect_import_index(buf)
      if (index.aliased or {})[alias] then
        return "import_var_ref", { alias = alias, partial = partial or "" }
      end
    end
    return nil, nil
  end

  -- GRPC request line: complete pkg.Service/Method from proto/reflection index
  local grpc_ctx, grpc_extra = detect_grpc_request_target(line_before_cursor)
  if grpc_ctx then return grpc_ctx, grpc_extra end

  -- URL check (direct string find instead of pattern)
  if line_before_cursor:find("://", 1, true) then
    return nil, nil
  end

  -- Check if line already has a complete HTTP method followed by space
  local method_match = trimmed:match("^(%u+)%s")
  if method_match then
    for _, method in ipairs(data.http_methods) do
      if method_match == method then
        return nil, nil  -- already have method, rest is URL
      end
    end
  end

  -- Header value context: extract header name before colon
  -- Manual parsing is faster than pattern for short lines
  local colon_pos = line_before_cursor:find(":", 1, true)
  if colon_pos then
    -- Extract header name (letters, digits, hyphens) before colon
    local header_part = line_before_cursor:sub(1, colon_pos - 1)
    local header_name = header_part:match("^%s*([A-Za-z][A-Za-z0-9%-]*)$")
    if header_name then
      return "header_value", header_name
    end
  end

  -- No colon, no space → single word being typed (method or header name)
  if not line_before_cursor:find(" ", 1, true) then
    if is_file_level(buf, cursor_line) then
      return "file_directive", nil
    end
    return "method_or_header", nil
  end

  -- Has space but no colon and no method → no completion
  return nil, nil
end

M.detect_script_context = detect_script_context
M.detect_context = detect_context

return M
