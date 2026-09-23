--- JSON request-body normalization.
---
--- `.http` files are annotated JSON: bodies carry `//`, `/* */`, `#` and `--`
--- comments and blank lines that strict server parsers reject. This module
--- turns such a body into text that parses, WITHOUT ever guessing: the cleaned
--- body is only used when it decodes as JSON, otherwise the caller sends the
--- bytes the user wrote. Comment removal is string-aware, so `"https://x"`,
--- `"/* literal */"` and `"#tag"` survive verbatim.

local M = {}

--- True when the body's first non-blank character opens an object or array.
--- Multipart (`---boundary`), form (`k=v`) and GraphQL (`query …`) bodies
--- never match, so they are never rewritten.
--- @param text string|nil
--- @return boolean
function M.looks_like_json(text)
  if type(text) ~= "string" then return false end
  for i = 1, #text do
    local c = text:sub(i, i)
    if c ~= " " and c ~= "\t" and c ~= "\r" and c ~= "\n" then
      return c == "{" or c == "["
    end
  end
  return false
end

local function decodes(text)
  if type(text) ~= "string" or text == "" then return false end
  local ok, value = pcall(vim.json.decode, text)
  return ok and value ~= nil
end

-- One line of strip_comments output. A comment removes its own text; when
-- nothing but whitespace is left, the line itself goes away (that is what
-- makes a commented-out field vanish instead of leaving a hole).
-- `state` carries the block-comment flag across lines; strings never do
-- (JSON forbids a raw newline inside one, so an unterminated quote on this
-- line must not poison every line after it).
local function strip_line(line, state)
  local out = {}
  local had_comment = false
  local in_string, escaped = false, false
  local i, n = 1, #line

  while i <= n do
    local c = line:sub(i, i)

    if state.in_block then
      had_comment = true
      if c == "*" and line:sub(i + 1, i + 1) == "/" then
        state.in_block = false
        i = i + 2
      else
        i = i + 1
      end
    elseif in_string then
      out[#out + 1] = c
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        in_string = false
      end
      i = i + 1
    elseif c == '"' then
      in_string = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "/" and line:sub(i + 1, i + 1) == "/" then
      had_comment = true
      break
    elseif c == "/" and line:sub(i + 1, i + 1) == "*" then
      had_comment = true
      state.in_block = true
      i = i + 2
    elseif (c == "#" or (c == "-" and line:sub(i + 1, i + 1) == "-"))
      -- `#` and `--` are file-level comment markers, so they only count at
      -- the start of a line; a lone `-` is always data.
      and line:sub(1, i - 1):match("^%s*$") ~= nil then
      had_comment = true
      break
    else
      out[#out + 1] = c
      i = i + 1
    end
  end

  local text = table.concat(out)
  if not had_comment then return line end
  if text:match("^%s*$") then return nil end
  return (text:gsub("%s+$", ""))
end

--- Remove comments from a JSON-shaped body (string-aware).
--- @param text string|nil
--- @return string
function M.strip_comments(text)
  if type(text) ~= "string" or text == "" then return text or "" end
  local state = { in_block = false }
  local kept = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local stripped = strip_line(line, state)
    if stripped ~= nil then
      kept[#kept + 1] = stripped
    end
  end
  return table.concat(kept, "\n")
end

--- Drop blank (and whitespace-only) lines, then trim the ends.
--- @param text string|nil
--- @return string
function M.drop_blank_lines(text)
  if type(text) ~= "string" or text == "" then return text or "" end
  local kept = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line:match("%S") then kept[#kept + 1] = line end
  end
  return vim.trim(table.concat(kept, "\n"))
end

--- Delete commas that sit directly before another comma or a closing `}`/`]`
--- (string-aware). A run of commas is what several commented-out fields leave
--- behind, hence the comma-on-comma case. Only reachable as a rescue: a
--- commented-out field usually leaves the previous line's comma dangling.
--- @param text string
--- @return string
function M.repair_trailing_commas(text)
  if type(text) ~= "string" or text == "" then return text or "" end
  local out = {}
  local in_string, escaped = false, false
  local i, n = 1, #text

  while i <= n do
    local c = text:sub(i, i)
    if in_string then
      out[#out + 1] = c
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        in_string = false
      end
      i = i + 1
    elseif c == '"' then
      in_string = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "," then
      local j = i + 1
      while j <= n and text:sub(j, j):match("%s") do j = j + 1 end
      local next_c = text:sub(j, j)
      if next_c ~= "," and next_c ~= "}" and next_c ~= "]" then
        out[#out + 1] = c
      end
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end

  return table.concat(out)
end

--- Normalize a body for the wire.
--- @param text string|nil
--- @return string|nil normalized, info { json, valid, changed }
---   json    — the body is JSON-shaped (`{`/`[` first)
---   valid   — what is being sent parses as JSON
---   changed — normalized differs from `text`
--- When a JSON-shaped body cannot be made to parse, `text` is returned
--- unchanged and `valid` is false — callers warn, they never guess.
function M.normalize(text)
  if type(text) ~= "string" then return nil, { json = false, valid = false, changed = false } end
  if not M.looks_like_json(text) then
    return text, { json = false, valid = false, changed = false }
  end

  local cleaned = M.drop_blank_lines(M.strip_comments(text))
  if decodes(cleaned) then
    return cleaned, { json = true, valid = true, changed = cleaned ~= text }
  end

  -- A removed comma leaves its own whitespace behind, so the blank-line pass
  -- runs again after the repair.
  local repaired = M.drop_blank_lines(M.repair_trailing_commas(cleaned))
  if decodes(repaired) then
    return repaired, { json = true, valid = true, changed = repaired ~= text }
  end

  return text, { json = true, valid = false, changed = false }
end

return M
