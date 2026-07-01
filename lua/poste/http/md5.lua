local M = {}

local bit = require("bit")
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

local function F(x, y, z) return bor(band(x, y), band(bnot(x), z)) end
local function G(x, y, z) return bor(band(x, z), band(y, bnot(z))) end
local function H(x, y, z) return bxor(x, bxor(y, z)) end
local function I(x, y, z) return bxor(y, bor(x, bnot(z))) end

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

local function md5_init()
  return { 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 }
end

local function md5_transform(state, block)
  local a, b, c, d = state[1], state[2], state[3], state[4]
  local x = {}

  for i = 0, 15 do
    local offset = i * 4
    x[i] = block:byte(offset + 1) +
           lshift(block:byte(offset + 2), 8) +
           lshift(block:byte(offset + 3), 16) +
           lshift(block:byte(offset + 4), 24)
  end

  local function round1(a, b, c, d, k, s, i)
    a = a + F(b, c, d) + x[k] + T[i]
    a = rotate_left(a, s)
    return band(a + b, 0xffffffff)
  end

  local function round2(a, b, c, d, k, s, i)
    a = a + G(b, c, d) + x[k] + T[i]
    a = rotate_left(a, s)
    return band(a + b, 0xffffffff)
  end

  local function round3(a, b, c, d, k, s, i)
    a = a + H(b, c, d) + x[k] + T[i]
    a = rotate_left(a, s)
    return band(a + b, 0xffffffff)
  end

  local function round4(a, b, c, d, k, s, i)
    a = a + I(b, c, d) + x[k] + T[i]
    a = rotate_left(a, s)
    return band(a + b, 0xffffffff)
  end

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

function M.md5(input)
  local state = md5_init()
  local len = #input
  local bit_len = len * 8

  local pad_len = (56 - (len + 1) % 64) % 64
  input = input .. string.char(0x80) .. string.rep(string.char(0), pad_len)

  input = input .. string.char(
    band(bit_len, 0xff),
    band(rshift(bit_len, 8), 0xff),
    band(rshift(bit_len, 16), 0xff),
    band(rshift(bit_len, 24), 0xff),
    0, 0, 0, 0
  )

  for i = 1, #input, 64 do
    local block = input:sub(i, i + 63)
    md5_transform(state, block)
  end

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

return M
