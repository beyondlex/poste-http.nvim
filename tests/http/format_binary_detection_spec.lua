-- Regression coverage for text-vs-binary content-type routing (2026-09-21).
--
-- The legacy test was a bare "mime mentions text/json/xml/html" substring
-- check, which routed textual responses like application/x-www-form-urlencoded
-- and application/javascript to the binary-file path: the body was dumped to
-- a .bin file and the view showed a "Binary File Response" card instead of
-- the content.

local fmt_util = require("poste-http.http.format.util")
local body_mod = require("poste-http.http.format.body")
local state = require("poste-http.state")

local function has_binary_card(lines)
  for _, l in ipairs(lines) do
    if l:match("Binary File Response") then return true end
  end
  return false
end

describe("format.util.is_text_content_type", function()
  it("treats the classic textual markers as text", function()
    assert.is_true(fmt_util.is_text_content_type("text/plain"))
    assert.is_true(fmt_util.is_text_content_type("application/json"))
    assert.is_true(fmt_util.is_text_content_type("application/rss+xml"))
    assert.is_true(fmt_util.is_text_content_type("text/html; charset=utf-8"))
  end)

  it("treats an empty or nil type as text", function()
    assert.is_true(fmt_util.is_text_content_type(""))
    assert.is_true(fmt_util.is_text_content_type(nil))
  end)

  it("treats structured +json/+xml suffixes as text", function()
    assert.is_true(fmt_util.is_text_content_type("application/problem+json"))
    assert.is_true(fmt_util.is_text_content_type("application/graphql-response+json"))
  end)

  it("recognizes textual mimes whose names carry no text/json/xml/html marker", function()
    assert.is_true(fmt_util.is_text_content_type("application/x-www-form-urlencoded"))
    assert.is_true(fmt_util.is_text_content_type("application/javascript"))
    assert.is_true(fmt_util.is_text_content_type("application/x-yaml"))
    assert.is_true(fmt_util.is_text_content_type("application/yaml"))
  end)

  it("still classifies binary payloads as binary", function()
    assert.is_false(fmt_util.is_text_content_type("application/octet-stream"))
    assert.is_false(fmt_util.is_text_content_type("image/png"))
    assert.is_false(fmt_util.is_text_content_type("application/pdf"))
    assert.is_false(fmt_util.is_text_content_type("application/x-protobuf"))
  end)

  it("strips parameters before classification", function()
    assert.is_true(fmt_util.is_text_content_type("application/x-yaml; charset=utf-8"))
    assert.is_false(fmt_util.is_text_content_type("image/png; charset=binary"))
  end)
end)

describe("format_body binary misdetection regression", function()
  local dumped_file
  local saved_cache_dir

  before_each(function()
    saved_cache_dir = state.config.response_cache_dir
    state.config.response_cache_dir = "/tmp/poste-binary-detect-test"
  end)

  after_each(function()
    if dumped_file then os.remove(dumped_file) end
    dumped_file = nil
    state.config.response_cache_dir = saved_cache_dir
  end)

  it("renders a form-urlencoded response as decoded lines, not a binary card", function()
    local r = {
      body = "name=lex%20wei&keep%2Bid=1",
      content_type = "application/x-www-form-urlencoded",
      headers = {},
    }
    local lines = body_mod.format_body(r)
    assert.is_false(has_binary_card(lines), "urlencoded body must not hit the binary path")
    assert.is_nil(r.metadata and r.metadata.file_path, "no file must be written")
    assert.same({ "  name: lex wei", "  keep+id: 1" }, lines)
  end)

  it("renders a javascript response inline, not a binary card", function()
    local r = {
      body = "console.log('hi')",
      content_type = "application/javascript",
      headers = {},
    }
    local lines = body_mod.format_body(r)
    assert.is_false(has_binary_card(lines))
    assert.is_nil(r.metadata and r.metadata.file_path)
    assert.same({ "console.log('hi')" }, lines)
  end)

  it("still dumps a real binary payload to a file", function()
    local r = {
      body = "\x00\x01\x02\x03",
      content_type = "application/octet-stream",
      headers = {},
    }
    local lines = body_mod.format_body(r)
    assert.is_true(has_binary_card(lines))
    assert.is_not_nil(r.metadata and r.metadata.file_path)
    dumped_file = r.metadata.file_path
  end)
end)

describe("verbose Query Parameters decoding", function()
  it("keeps an encoded literal plus (%2B) as a plus", function()
    -- The old inline decode ran %XX before '+', so %2B collapsed into a
    -- space; it now shares format/util.url_decode with the right order.
    local verbose = require("poste-http.http.format.verbose")
    local lines = verbose.format_verbose(nil, {
      method = "GET",
      url = "http://example.com/search?q=a%2Bb&tag=user%20name",
      headers_str = "",
      body = "",
    })
    local joined = table.concat(lines, "\n")
    assert.matches("q: a%+b", joined)
    assert.matches("tag: user name", joined)
  end)
end)
