--- Context detection for Poste HTTP completion.
--- Extracted from completion.lua for reuse across modules.
local M = {}
local data = require("poste.http.data")

--- Detect if cursor is inside a pre-request or post-request script block.
--- Returns: "pre_script", "post_script", or nil
local function detect_script_context(buf, cursor_line, cursor_col)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, cursor_line, false)

  -- Track whether we're inside a script block and what type
  local in_script = nil  -- "pre" or "post"
  local script_start = nil

  for i, line in ipairs(lines) do
    if in_script then
      -- Check if this line closes the script block
      if line:find("%%}") then
        -- If we're on the closing line, check if cursor is before %}
        if i == cursor_line then
          local close_pos = line:find("%%}")
          if cursor_col <= close_pos then
            return in_script == "pre" and "pre_script" or "post_script"
          end
        end
        in_script = nil
        script_start = nil
      elseif i == cursor_line then
        -- We're inside the script block on this line
        return in_script == "pre" and "pre_script" or "post_script"
      end
    else
      -- Check for script block start
      local pre_start = line:find("<%s*{%%")
      local post_start = line:find(">%s*{%%")

      if pre_start or post_start then
        local start_pos = pre_start or post_start
        in_script = pre_start and "pre" or "post"
        script_start = i

        -- Check if script closes on same line
        local close_pos = line:find("%%}")
        if close_pos then
          -- Single-line script: < {% ... %} or > {% ... %}
          if i == cursor_line and cursor_col > start_pos and cursor_col <= close_pos then
            return in_script == "pre" and "pre_script" or "post_script"
          end
          in_script = nil
          script_start = nil
        elseif i == cursor_line then
          -- Cursor is on the opening line, after the marker
          if cursor_col > start_pos then
            return in_script == "pre" and "pre_script" or "post_script"
          end
          in_script = nil
          script_start = nil
        end
      end
    end
  end

  -- If we're still in a script at the end, cursor must be inside it
  if in_script then
    return in_script == "pre" and "pre_script" or "post_script"
  end

  return nil
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
    return "method", nil
  end

  -- Direct string prefix checks (faster than :match)
  local first_char = trimmed:sub(1, 1)
  if first_char == "#" then
    -- After ### (request name line) → no completion
    if trimmed:sub(2, 2) == "#" then return nil, nil end
    -- Comment lines → no completion
    return nil, nil
  end

  -- Comment: -- (direct check instead of pattern)
  if first_char == "-" and trimmed:sub(2, 2) == "-" then
    return nil, nil
  end

  -- @var definition → no completion
  if first_char == "@" then
    return nil, nil
  end

  -- Variable reference: check for unclosed {{ before cursor
  local rev = line_before_cursor:reverse()
  local last_open = rev:find("{{", 1, true)   -- plain string find
  local last_close = rev:find("}}", 1, true)  -- plain string find
  if last_open and (not last_close or last_close > last_open) then
    -- Cursor is inside an unclosed {{...}}
    local after_open = line_before_cursor:sub(#line_before_cursor - last_open + 2)
    return "variable", after_open
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
    return "method_or_header", nil
  end

  -- Has space but no colon and no method → no completion
  return nil, nil
end

M.detect_script_context = detect_script_context
M.detect_context = detect_context

return M
