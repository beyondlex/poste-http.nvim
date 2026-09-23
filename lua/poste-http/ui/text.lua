--- Display-width aware text truncation helpers.
---
--- Single source of truth replacing the byte- or char-based truncation copies
--- that used to live in outline.lua, symbols.lua and variable_inspector.lua.
--- All budgets are measured in display columns (vim.fn.strdisplaywidth), so
--- wide characters (CJK) are never split mid-glyph.
---
--- The ellipsis is the single-width "…" character. columns.lua keeps its own
--- per-cell truncation ("..." suffix, column-spec driven) on purpose: there
--- the ellipsis is part of the column layout contract.

local M = {}

--- A NUL byte turns a Lua string into a Blob the moment it crosses into a
--- vim.fn string function (Vim E976), so one binary-derived character —
--- a literal \u0000 from a JSON variable, a control byte in a response
--- preview — would take down the whole render path (winbar, outline,
--- history list). NUL carries no displayable content: drop it at the door.
local function strip_nul(s)
  if type(s) == "string" and s:find("%z") then
    return (s:gsub("%z", ""))
  end
  return s
end

--- Chars of s (from the start) fitting within max_w display columns.
--- Returns the prefix and the display width actually used.
local function take_prefix(s, max_w)
  local used = 0
  local n = vim.fn.strchars(s)
  for i = 0, n - 1 do
    local w = vim.fn.strdisplaywidth(vim.fn.strcharpart(s, i, 1))
    if used + w > max_w then
      return vim.fn.strcharpart(s, 0, i), used
    end
    used = used + w
  end
  return s, used
end

--- Chars of s (from the end) fitting within max_w display columns.
--- Returns the suffix and the display width actually used.
local function take_suffix(s, max_w)
  local n = vim.fn.strchars(s)
  local start_i = n
  local used = 0
  for i = n - 1, 0, -1 do
    local w = vim.fn.strdisplaywidth(vim.fn.strcharpart(s, i, 1))
    if used + w > max_w then break end
    used = used + w
    start_i = i
  end
  if start_i >= n then return "", 0 end
  return vim.fn.strcharpart(s, start_i, n - start_i), used
end

--- Truncate s to at most max display columns, appending "…" when cut.
--- @param s string|nil
--- @param max number  display column budget
--- @return string
function M.truncate(s, max)
  if not s then return "" end
  s = strip_nul(s)
  max = max or 0
  if max < 1 then return "" end
  if vim.fn.strdisplaywidth(s) <= max then return s end
  local head = take_prefix(s, max - 1)
  return head .. "…"
end

--- Truncate s from both ends to at most max display columns, placing "…"
--- in the middle. Keeps path/file endings recognizable in narrow lists.
--- @param s string|nil
--- @param max number  display column budget
--- @return string
function M.middle(s, max)
  if not s then return "" end
  s = strip_nul(s)
  max = max or 0
  if max < 1 then return "" end
  if vim.fn.strdisplaywidth(s) <= max then return s end
  local half = math.floor((max - 1) / 2)
  local head = take_prefix(s, half)
  local tail = take_suffix(s, half)
  return head .. "…" .. tail
end

return M
