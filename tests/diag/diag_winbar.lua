-- Regression tests for winbar highlight marker deduplication.
-- The fix: extract_visible must group consecutive same-hl chars into one segment,
-- so %#Hl# markers = number of hl *transitions*, not number of characters.
-- Without the fix, a wide table causes winbar string overflow → ^@ corruption.

vim.opt.runtimepath:prepend(".")

local out = {}
local function log(s) table.insert(out, s) end
local pass, fail = 0, 0
local function check(label, got, expected)
  if got == expected then log("PASS: " .. label); pass = pass + 1
  else log(string.format("FAIL: %s  got=%s  expected=%s", label, tostring(got), tostring(expected))); fail = fail + 1 end
end
local function check_le(label, got, max)
  if got <= max then log(string.format("PASS: %s (%d <= %d)", label, got, max)); pass = pass + 1
  else log(string.format("FAIL: %s  got=%d  max=%d", label, got, max)); fail = fail + 1 end
end

local buf_mod = require("poste.sql.buffer")
local t = buf_mod._test

log("=== winbar highlight marker deduplication ===")

-- Build a realistic wide header: 10 columns, each 20 chars wide
-- Format: │ col_name           │ col_name           │ ...
local function make_header(ncols, col_width)
  local parts = {}
  for i = 1, ncols do
    parts[i] = " " .. string.rep("x", col_width - 2) .. " "
  end
  return "│" .. table.concat(parts, "│") .. "│"
end

-- 10-column header, each 20 chars → ~210 chars total
local header10 = make_header(10, 20)
t.set_header(header10)

local text = t.build_winbar_text(0, 200)
assert(text ~= nil, "build_winbar_text returned nil")

-- Count %#...# markers in the output
local marker_count = 0
for _ in text:gmatch("%%#[^#]+#") do marker_count = marker_count + 1 end

log("header chars: " .. #header10)
log("winbar text length: " .. #text)
log("highlight markers: " .. marker_count)

-- With 10 columns: separators and cell text alternate → at most 2*(ncols+1) transitions
-- The key assertion: markers = O(columns), not O(characters)
check_le("marker count is O(columns), not O(chars)", marker_count, 30)
-- Markers should be much fewer than characters
check_le("markers << header chars (was 1:1 before fix)", marker_count, math.floor(#header10 / 5))

-- 30-column wide table (stress test for the old bug)
local header30 = make_header(30, 15)
t.set_header(header30)
local text30 = t.build_winbar_text(0, 500)
assert(text30 ~= nil)

local markers30 = 0
for _ in text30:gmatch("%%#[^#]+#") do markers30 = markers30 + 1 end

log("30-col header chars: " .. #header30)
log("30-col winbar text length: " .. #text30)
log("30-col highlight markers: " .. markers30)

check_le("30-col markers << char count", markers30, 70)

-- No non-printable bytes (the ^@ corruption check)
local has_nonprint = false
for i = 1, #text30 do
  local b = text30:byte(i)
  if b < 9 or (b > 13 and b < 32) then  -- allow tab/lf/cr
    has_nonprint = true
    log("  non-printable byte at " .. i .. ": 0x" .. string.format("%02X", b))
  end
end
check("no non-printable bytes in winbar", has_nonprint, false)

-- Content sanity: visible text contains the column content
check("winbar contains cell content", text:find("x") ~= nil, true)

log(string.format("\n=== RESULT: %d passed, %d failed ===", pass, fail))
vim.fn.writefile(out, "/tmp/poste_winbar_diag.txt")
vim.cmd("qa!")
