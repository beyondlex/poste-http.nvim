-- Tests for poste-http.ai.mentions — @req/<Name> match + resolve (pure seams).

local mentions = require("poste-http.ai.mentions")

local CONTENT = [[
### Get users
GET {{api_base}}/users

### Login
POST {{api_base}}/login
Authorization: Bearer {{api_token}}
]]

describe("ai.mentions.match", function()
  it("matches req/<Name> tokens", function()
    assert.same({ request = "Login" }, mentions.match("req/Login"))
    assert.same({ request = "Get-users" }, mentions.match("req/Get-users"))
  end)

  it("rejects other shapes", function()
    assert.is_nil(mentions.match("Login"))
    assert.is_nil(mentions.match("req/"))
    assert.is_nil(mentions.match("conn/db/table"))
    assert.is_nil(mentions.match(""))
  end)
end)

describe("ai.mentions.resolve_from_content", function()
  it("renders the raw block with placeholders intact", function()
    local md, err = mentions.resolve_from_content("Login", CONTENT, "requests/api.http")
    assert.is_nil(err)
    assert.truthy(md:match("requests/api%.http:4"))
    assert.truthy(md:match("```http\n### Login\nPOST {{api_base}}/login\nAuthorization: Bearer {{api_token}}\n```"))
  end)

  it("errors for unknown names", function()
    local md, err = mentions.resolve_from_content("Nope", CONTENT, "api.http")
    assert.is_nil(md)
    assert.truthy(err:match("not found"))
  end)
end)

describe("ai.mentions.sources", function()
  it("returns at least the focus source when a poste_http buffer is present", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(CONTENT, "\n", { plain = true }))
    vim.bo[buf].filetype = "poste_http"
    -- nvim_buf_set_name expands relative names to absolute paths
    local expected = vim.fn.fnamemodify("mentions-fixture.http", ":p")
    vim.api.nvim_buf_set_name(buf, expected)

    local srcs = mentions.sources(nil)
    assert.truthy(#srcs >= 1)
    local found = false
    for _, src in ipairs(srcs) do
      if src.file == expected then
        found = true
        assert.truthy(src.content:match("### Login"))
      end
    end
    assert.is_true(found)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  it("a non-string token is a non-match, not a crash", function()
    assert.is_nil(mentions.match(42))
    assert.is_nil(mentions.match(nil))
    assert.is_nil(mentions.match(""))
  end)
end)
