--- md5 spec — RFC 1321 vectors plus block-boundary cases. The pure-Lua
--- implementation feeds sandbox scripts (signatures/auth), so a length-
--- padding regression here would silently corrupt generated credentials.
local md5 = require("poste-http.http.md5").md5

describe("md5 (RFC 1321 vectors)", function()
  local cases = {
    { "", "d41d8cd98f00b204e9800998ecf8427e" },
    { "a", "0cc175b9c0f1b6a831c399e269772661" },
    { "abc", "900150983cd24fb0d6963f7d28e17f72" },
    { "message digest", "f96b697d7cb7938d525a2f31aaf161d0" },
    { "abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b" },
    {
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
      "d174ab98d277d9f5a5611c2c9f419d9f",
    },
    {
      "12345678901234567890123456789012345678901234567890123456789012345678901234567890",
      "57edf4a22be3c955ac49da2e2107b67a",
    },
  }

  for _, c in ipairs(cases) do
    local label = (#c[1] > 0 and c[1]:sub(1, 24) or "<empty>") .. " → " .. c[2]
    it("digests " .. label, function()
      assert.equals(c[2], md5(c[1]))
    end)
  end

  it("handles the 56/57-byte padding boundary and multi-block inputs", function()
    -- length ≡ 56 mod 64 is where the pad length hits 0x80 exactly
    assert.equals("3b0c8ac703f828b04c6c197006d17218", md5(string.rep("a", 56)))
    assert.equals("652b906d60af96844ebd21b674f35e93", md5(string.rep("a", 57)))
    assert.equals("014842d480b571495a4a0363793f7367", md5(string.rep("a", 64)))
    assert.equals("9146ef3527c7cfcc66dc615c3986e391", md5(string.rep("a", 112)))
  end)
end)
