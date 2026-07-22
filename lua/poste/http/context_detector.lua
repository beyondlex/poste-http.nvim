--- Context detection for Poste HTTP completion.
--- Extracted from completion.lua for reuse across modules.
local M = {}
local data = require("poste.http.data")
local cache = require("poste.http.cache")

--- Detect if cursor is inside a pre-request or post-request script block.
--- Uses cache.lua O(1) line_type lookup instead of buffer scanning.
--- Returns: "pre_script", "post_script", or nil
local function detect_script_context(buf, cursor_line, cursor_col)
  local t = require("poste.http.cache").get_line_type(buf, cursor_line)
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
  -- Check if we're inside a script block (takes precedence over all other contexts)
  if buf and cursor_line and cursor_col then
    local script_ctx = detect_script_context(buf, cursor_line, cursor_col)
    if script_ctx then
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
  if trimmed:match("^run") then
    -- run #Name or run #alias.Name
    if trimmed:match("^run%s+#") then
      local rest = trimmed:match("^run%s+#(.*)$")
      if rest and rest:find("%.") then
        local alias, partial = rest:match("^([^%.]+)%.(.*)$")
        return "run_target_alias", { alias = alias, partial = partial or "" }
      end
      return "run_target_hash", rest or ""
    end
    if trimmed:match("^run%s+") then
      local target = trimmed:match("^run%s+(.*)$")
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

  -- @var definition (no unclosed {{) → no completion
  if first_char == "@" then
    return nil, nil
  end

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
