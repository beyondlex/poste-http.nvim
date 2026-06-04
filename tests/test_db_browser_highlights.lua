-- Test DB browser icon highlighting byte offset calculation
-- Run with: nvim --headless -c "luafile tests/test_db_browser_highlights.lua" -c "qa!"

-- Use byte escapes (same as db_browser.lua) to avoid UTF-8 stripping
local MARKER_COLLAPSED = "\239\132\133"  -- nf-fa-angle_right (3 bytes)
local MARKER_EXPANDED  = "\239\132\135"  -- nf-fa-angle_down (3 bytes)
local MARKER_LOADING   = "\226\128\166"  -- U+2026 (3 bytes)

local ICON_TABLE  = "\239\131\142"  -- nf-fa-table (3 bytes)
local ICON_COLUMN = "\226\151\143"  -- U+25CF ● (3 bytes)
local ICON_INDEX  = "#"             -- 1 byte
local ICON_DB     = "\239\135\128"  -- nf-fa-database (3 bytes)

--- Reproduce the icon position calculation from apply_highlights.
--- Strategy: find the first non-space byte, then check if it's a marker
--- character (3-byte UTF-8 starting with 0xEF or 0xE2). If so, skip
--- 3 bytes (marker) + 1 byte (space). Otherwise, it IS the icon.
local function calc_icon_position(text)
  -- Find first non-space byte (1-indexed)
  local first_content = 0
  for ci = 1, #text do
    if text:byte(ci) ~= 0x20 then
      first_content = ci
      break
    end
  end

  if first_content == 0 then return -1 end

  -- Check if first 3 bytes match a MARKER character
  local first_3 = text:sub(first_content, first_content + 2)
  if first_3 == MARKER_EXPANDED
    or first_3 == MARKER_COLLAPSED
    or first_3 == MARKER_LOADING then
    -- Skip marker (3 bytes) + space (1 byte), result is 0-indexed
    return first_content + 3
  else
    -- First non-space IS the icon, convert to 0-indexed
    return first_content - 1
  end
end

local function test_icon_position()
  -- Line format from flatten_tree: indent + marker + " " + icon + " " + name + count
  local test_cases = {
    {
      name = "expanded table (depth 1)",
      line = "  " .. MARKER_EXPANDED .. " " .. ICON_TABLE .. " users (5)",
      --          2(indent) + 3(marker) + 1(space) = 6
      expected_icon_byte = 6,
    },
    {
      name = "leaf column (depth 2)",
      line = "    " .. "  " .. ICON_COLUMN .. " id int PK",
      --          4(indent) + 2(leaf marker, no space) = 6
      expected_icon_byte = 6,
    },
    {
      name = "leaf index (depth 2)",
      line = "    " .. "  " .. ICON_INDEX .. " PRIMARY",
      --          4(indent) + 2(leaf marker, no space) = 6
      expected_icon_byte = 6,
    },
    {
      name = "collapsed database (depth 0)",
      line = MARKER_COLLAPSED .. " " .. ICON_DB .. " mydb",
      --          0(indent) + 3(marker) + 1(space) = 4
      expected_icon_byte = 4,
    },
    {
      name = "collapsed table (depth 2)",
      line = "    " .. MARKER_COLLAPSED .. " " .. ICON_TABLE .. " orders",
      --          4(indent) + 3(marker) + 1(space) = 8
      expected_icon_byte = 8,
    },
    {
      name = "loading schema (depth 1)",
      line = "  " .. MARKER_LOADING .. " " .. "\239\129\187" .. " public",
      --          2(indent) + 3(marker) + 1(space) = 6
      expected_icon_byte = 6,
    },
  }

  print("Testing icon byte position calculation...\n")

  local all_passed = true
  for _, tc in ipairs(test_cases) do
    local icon_byte_start = calc_icon_position(tc.line)
    local passed = (icon_byte_start == tc.expected_icon_byte)

    if passed then
      print(string.format("  [PASS] %s — icon at byte %d", tc.name, icon_byte_start))
    else
      all_passed = false
      local char_at = tc.line:sub(icon_byte_start + 1, icon_byte_start + 1)
      local char_expected = tc.line:sub(tc.expected_icon_byte + 1, tc.expected_icon_byte + 1)
      print(string.format("  [FAIL] %s", tc.name))
      print(string.format("         Expected byte %d (char %q), got %d (char %q)",
        tc.expected_icon_byte, char_expected, icon_byte_start, char_at))
    end
  end

  print()
  if all_passed then
    print("All icon position tests passed")
    return true
  else
    print("Some icon position tests FAILED")
    return false
  end
end

local success = test_icon_position()
if not success then
  vim.cmd("cquit 1")
end
