--- Test assertions (> {% ... %} syntax): extraction, sandboxed execution, formatting.
local state = require("poste.state")

local M = {}

---------------------------------------------------------------------------
-- Pure Lua MD5 implementation (LuaJIT compatible)
---------------------------------------------------------------------------

local bit = require("bit")

-- MD5 constants
local function md5_init()
  return { 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 }
end

-- Bit manipulation helpers (LuaJIT bit library)
local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local bnot = bit.bnot
local lshift = bit.lshift
local rshift = bit.rshift
local rol = bit.rol

local function rotate_left(x, n)
  return rol(x, n)
end

-- MD5 auxiliary functions
local function F(x, y, z) return bor(band(x, y), band(bnot(x), z)) end
local function G(x, y, z) return bor(band(x, z), band(y, bnot(z))) end
local function H(x, y, z) return bxor(x, bxor(y, z)) end
local function I(x, y, z) return bxor(y, bor(x, bnot(z))) end

-- MD5 round constants
local T = {
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

local function md5_transform(state, block)
  local a, b, c, d = state[1], state[2], state[3], state[4]
  local x = {}

  -- Convert block to 16 32-bit words (little-endian)
  for i = 0, 15 do
    local offset = i * 4
    x[i] = block:byte(offset + 1) +
           lshift(block:byte(offset + 2), 8) +
           lshift(block:byte(offset + 3), 16) +
           lshift(block:byte(offset + 4), 24)
  end

  -- Round 1
  local function round1(a, b, c, d, k, s, i)
    a = a + F(b, c, d) + x[k] + T[i]
    a = rotate_left(a, s)
    return band(a + b, 0xffffffff)
  end

  -- Round 2
  local function round2(a, b, c, d, k, s, i)
    a = a + G(b, c, d) + x[k] + T[i]
    a = rotate_left(a, s)
    return band(a + b, 0xffffffff)
  end

  -- Round 3
  local function round3(a, b, c, d, k, s, i)
    a = a + H(b, c, d) + x[k] + T[i]
    a = rotate_left(a, s)
    return band(a + b, 0xffffffff)
  end

  -- Round 4
  local function round4(a, b, c, d, k, s, i)
    a = a + I(b, c, d) + x[k] + T[i]
    a = rotate_left(a, s)
    return band(a + b, 0xffffffff)
  end

  -- Round 1
  a = round1(a, b, c, d, 0, 7, 1)
  d = round1(d, a, b, c, 1, 12, 2)
  c = round1(c, d, a, b, 2, 17, 3)
  b = round1(b, c, d, a, 3, 22, 4)
  a = round1(a, b, c, d, 4, 7, 5)
  d = round1(d, a, b, c, 5, 12, 6)
  c = round1(c, d, a, b, 6, 17, 7)
  b = round1(b, c, d, a, 7, 22, 8)
  a = round1(a, b, c, d, 8, 7, 9)
  d = round1(d, a, b, c, 9, 12, 10)
  c = round1(c, d, a, b, 10, 17, 11)
  b = round1(b, c, d, a, 11, 22, 12)
  a = round1(a, b, c, d, 12, 7, 13)
  d = round1(d, a, b, c, 13, 12, 14)
  c = round1(c, d, a, b, 14, 17, 15)
  b = round1(b, c, d, a, 15, 22, 16)

  -- Round 2
  a = round2(a, b, c, d, 1, 5, 17)
  d = round2(d, a, b, c, 6, 9, 18)
  c = round2(c, d, a, b, 11, 14, 19)
  b = round2(b, c, d, a, 0, 20, 20)
  a = round2(a, b, c, d, 5, 5, 21)
  d = round2(d, a, b, c, 10, 9, 22)
  c = round2(c, d, a, b, 15, 14, 23)
  b = round2(b, c, d, a, 4, 20, 24)
  a = round2(a, b, c, d, 9, 5, 25)
  d = round2(d, a, b, c, 14, 9, 26)
  c = round2(c, d, a, b, 3, 14, 27)
  b = round2(b, c, d, a, 8, 20, 28)
  a = round2(a, b, c, d, 13, 5, 29)
  d = round2(d, a, b, c, 2, 9, 30)
  c = round2(c, d, a, b, 7, 14, 31)
  b = round2(b, c, d, a, 12, 20, 32)

  -- Round 3
  a = round3(a, b, c, d, 5, 4, 33)
  d = round3(d, a, b, c, 8, 11, 34)
  c = round3(c, d, a, b, 11, 16, 35)
  b = round3(b, c, d, a, 14, 23, 36)
  a = round3(a, b, c, d, 1, 4, 37)
  d = round3(d, a, b, c, 4, 11, 38)
  c = round3(c, d, a, b, 7, 16, 39)
  b = round3(b, c, d, a, 10, 23, 40)
  a = round3(a, b, c, d, 13, 4, 41)
  d = round3(d, a, b, c, 0, 11, 42)
  c = round3(c, d, a, b, 3, 16, 43)
  b = round3(b, c, d, a, 6, 23, 44)
  a = round3(a, b, c, d, 9, 4, 45)
  d = round3(d, a, b, c, 12, 11, 46)
  c = round3(c, d, a, b, 15, 16, 47)
  b = round3(b, c, d, a, 2, 23, 48)

  -- Round 4
  a = round4(a, b, c, d, 0, 6, 49)
  d = round4(d, a, b, c, 7, 10, 50)
  c = round4(c, d, a, b, 14, 15, 51)
  b = round4(b, c, d, a, 5, 21, 52)
  a = round4(a, b, c, d, 12, 6, 53)
  d = round4(d, a, b, c, 3, 10, 54)
  c = round4(c, d, a, b, 10, 15, 55)
  b = round4(b, c, d, a, 1, 21, 56)
  a = round4(a, b, c, d, 8, 6, 57)
  d = round4(d, a, b, c, 15, 10, 58)
  c = round4(c, d, a, b, 6, 15, 59)
  b = round4(b, c, d, a, 13, 21, 60)
  a = round4(a, b, c, d, 4, 6, 61)
  d = round4(d, a, b, c, 11, 10, 62)
  c = round4(c, d, a, b, 2, 15, 63)
  b = round4(b, c, d, a, 9, 21, 64)

  state[1] = band(state[1] + a, 0xffffffff)
  state[2] = band(state[2] + b, 0xffffffff)
  state[3] = band(state[3] + c, 0xffffffff)
  state[4] = band(state[4] + d, 0xffffffff)
end

--- Compute MD5 hash of a string
local function md5(input)
  local state = md5_init()
  local len = #input
  local bit_len = len * 8

  -- Padding
  local pad_len = (56 - (len + 1) % 64) % 64
  input = input .. string.char(0x80) .. string.rep(string.char(0), pad_len)

  -- Append length in bits (little-endian)
  input = input .. string.char(
    band(bit_len, 0xff),
    band(rshift(bit_len, 8), 0xff),
    band(rshift(bit_len, 16), 0xff),
    band(rshift(bit_len, 24), 0xff),
    0, 0, 0, 0
  )

  -- Process blocks
  for i = 1, #input, 64 do
    local block = input:sub(i, i + 63)
    md5_transform(state, block)
  end

  -- Convert to hex string (little-endian)
  local result = ""
  for i = 1, 4 do
    result = result .. string.format("%02x%02x%02x%02x",
      band(state[i], 0xff),
      band(rshift(state[i], 8), 0xff),
      band(rshift(state[i], 16), 0xff),
      band(rshift(state[i], 24), 0xff)
    )
  end

  return result
end

---------------------------------------------------------------------------
-- Extract assertion blocks from request content
---------------------------------------------------------------------------

--- Extract `> {% ... %}` assertion blocks from request content.
--- Always strips ALL assertion blocks (replacing with empty lines to preserve line count).
--- Only collects assertion code within the optional start_line/end_line range (1-indexed).
--- When start_line/end_line are nil, collects from all blocks.
--- Returns (stripped_content, assertion_code_or_nil).
function M.extract_assertion_blocks(content, start_line, end_line)
  local lines = vim.split(content, "\n", { plain = true })
  local result = {}
  local code_parts = {}
  local in_block = false
  local block_lines = {}
  local block_start_line = 0

  for i, line in ipairs(lines) do
    local trimmed = vim.trim(line)

    -- Single-line: > {% code %}
    if not in_block then
      local code = trimmed:match("^>%s*{%%(.-)%%}$")
      if code then
        -- Only collect code if within range (or no range specified)
        if not start_line or (i >= start_line and i <= end_line) then
          table.insert(code_parts, code)
        end
        table.insert(result, "")  -- preserve line count

      -- External assertion script: > ./path.lua or > ../path.lua
      elseif trimmed:match("^>%s*%.?%.") and trimmed:match("%.lua%s*$") then
        local path = trimmed:match("^>%s*(%S+)%s*$")
        if path and (not start_line or (i >= start_line and i <= end_line)) then
          -- Resolve relative path against .http file directory
          local file_dir = vim.fn.expand("%:p:h")
          if path:sub(1, 1) == "." then
            path = file_dir .. "/" .. path
          end
          -- Read external script file
          local f = io.open(path, "r")
          if f then
            local script_content = f:read("*a")
            f:close()
            table.insert(code_parts, "-- external: " .. path .. "\n" .. script_content)
            state.log("INFO", "Loaded external assertion script: " .. path)
          else
            state.log("ERROR", "Cannot open assertion script file: " .. path)
            table.insert(code_parts, 'error("Cannot open assertion script file: ' .. path .. '")')
          end
        end
        table.insert(result, "")  -- preserve line count

      elseif trimmed:match("^>%s*{%%") then
        -- Multi-line start: > {%
        in_block = true
        block_lines = {}
        block_start_line = i
        table.insert(result, "")  -- preserve line count
      else
        table.insert(result, line)
      end
    else
      -- Inside multi-line block
      if trimmed == "%}" then
        -- End of block
        if not start_line or (block_start_line >= start_line and i <= end_line) then
          table.insert(code_parts, table.concat(block_lines, "\n"))
        end
        in_block = false
        block_lines = {}
      else
        table.insert(block_lines, line)
      end
      table.insert(result, "")  -- preserve line count
    end
  end

  if #code_parts == 0 then
    return table.concat(result, "\n"), nil
  end

  return table.concat(result, "\n"), table.concat(code_parts, "\n")
end

---------------------------------------------------------------------------
-- Run assertions in a sandboxed environment
---------------------------------------------------------------------------

--- Run assertion code in a sandboxed environment.
--- @param response_data table  Parsed response from Rust CLI
--- @param code string  Assertion code to execute
--- @param script_vars table|nil  { variables = { name = value }, env = { key = value } }
--- Returns: { tests = [...], logs = [...], total = N, passed = N, failed = N }
function M.run_assertions(response_data, code, script_vars)
  local tests = {}
  local logs = {}
  local current_test = nil
  script_vars = script_vars or { variables = {}, env = {} }

  -- Build case-insensitive headers table
  local headers = {}
  if response_data.headers then
    for _, pair in ipairs(response_data.headers) do
      if pair[1] then
        headers[pair[1]:lower()] = pair[2]
      end
    end
  end

  -- Build response object with lazy JSON body decoding
  local raw_body = response_data.body
  local decoded_body = nil
  local response = setmetatable({
    status = response_data.status,
    headers = setmetatable(headers, {
      __index = function(t, k)
        return rawget(t, k:lower())
      end,
    }),
    latency_ms = response_data.latency_ms,
    content_type = response_data.content_type,
    url = response_data.url,
  }, {
    __index = function(t, k)
      if k == "body" then
        if decoded_body == nil then
          local ok, parsed = pcall(vim.json.decode, raw_body)
          if ok and parsed then
            decoded_body = parsed
          else
            decoded_body = raw_body
          end
        end
        return decoded_body
      end
      return rawget(t, k)
    end,
  })

  -- Build request object (for post-request scripting within assertion blocks)
  local request = {
    variables = {
      set = function(name, value)
        state.script_variables[name] = tostring(value)
        state.log("INFO", string.format("Post-script: request.variables.set('%s', '%s')", name, tostring(value)))
      end,
      get = function(name)
        return state.script_variables[name]
      end,
    },
  }

  -- Build client object
  local client = {
    global = {
      set = function(name, value)
        state.global_vars[name] = tostring(value)
        state.log("INFO", string.format("Post-script: client.global.set('%s', '%s')", name, tostring(value)))
      end,
      get = function(name)
        return state.global_vars[name]
      end,
    },
    test = function(name, fn)
      current_test = { name = name, passed = 0, failed = 0, errors = {} }
      table.insert(tests, current_test)
      local ok, err = pcall(fn)
      if not ok then
        table.insert(current_test.errors, tostring(err))
        current_test.failed = current_test.failed + 1
      end
      current_test = nil
    end,
    assert = function(cond, msg)
      if not cond then
        local err_msg = msg or "Assertion failed"
        if current_test then
          table.insert(current_test.errors, err_msg)
          current_test.failed = current_test.failed + 1
        end
        error(err_msg, 2)
      else
        if current_test then
          current_test.passed = current_test.passed + 1
        end
      end
    end,
    log = function(msg)
      table.insert(logs, tostring(msg))
    end,
  }

  -- Top-level assert shorthand (outside client.test)
  local assert_fn = function(cond, msg)
    if not cond then
      local err_msg = msg or "Assertion failed"
      error(err_msg, 2)
    end
  end

  -- Build sandbox environment
  local sandbox_env = {
    response = response,
    request = request,
    client = client,
    assert = assert_fn,
    variables = script_vars.variables,
    env = script_vars.env,
    error = error,
    pcall = pcall,
    tostring = tostring,
    tonumber = tonumber,
    next = next,
    type = type,
    string = string,
    table = table,
    math = math,
    os = os,
    io = io,
    ipairs = ipairs,
    pairs = pairs,
    md5 = md5,
  }

  -- Execute code in sandbox
  local fn, load_err = load(code, "assertions", "t", sandbox_env)
  if not fn then
    return {
      tests = {},
      logs = {},
      total = 1,
      passed = 0,
      failed = 1,
      error = "Syntax error: " .. tostring(load_err),
    }
  end

  local ok, run_err = pcall(fn)
  if not ok then
    return {
      tests = tests,
      logs = logs,
      total = #tests,
      passed = 0,
      failed = #tests,
      error = "Runtime error: " .. tostring(run_err),
    }
  end

  -- Count totals
  local total_passed = 0
  local total_failed = 0
  for _, test in ipairs(tests) do
    if test.failed == 0 and #test.errors == 0 then
      total_passed = total_passed + 1
    else
      total_failed = total_failed + 1
    end
  end

  return {
    tests = tests,
    logs = logs,
    total = #tests,
    passed = total_passed,
    failed = total_failed,
  }
end

---------------------------------------------------------------------------
-- Format assertion results for display
---------------------------------------------------------------------------

function M.format_assertions(results)
  if not results then
    return { "No assertions defined" }
  end

  local lines = {
    string.format("## Test Results: %d passed, %d failed", results.passed, results.failed),
    "",
  }

  if results.error then
    table.insert(lines, "**Error**: " .. results.error)
    table.insert(lines, "")
  end

  for _, test in ipairs(results.tests) do
    local icon = (test.failed == 0 and #test.errors == 0) and "✓" or "✘"
    table.insert(lines, string.format("### %s %s", icon, test.name))

    if #test.errors > 0 then
      for _, err in ipairs(test.errors) do
        table.insert(lines, string.format("  ✘ %s", err))
      end
    end
  end

  if #results.logs > 0 then
    table.insert(lines, "")
    table.insert(lines, "## Logs")
    table.insert(lines, "")
    for _, msg in ipairs(results.logs) do
      for line in msg:gmatch("[^\r\n]+") do
        table.insert(lines, line)
      end
    end
  end

  return lines
end

return M
