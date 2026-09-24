--- Postman collection import spec: block generation from collection shapes,
--- including the `disabled` flag contract (disabled params/headers/params
--- are OFF in Postman — importing them would silently send them).
local import_parser = require("poste-http.http.import_parser")
local postman = require("poste-http.http.import_postman")

--- Render blocks without touching the filesystem: import_spec's body minus
--- write_output (that function's contract stays covered by the smoke spec).
local function render(spec)
  local vars = {}
  for _, v in ipairs(spec.variable or {}) do
    vars[v.key or v.name or ""] = v.value or ""
  end
  local blocks = {}
  for _, item in ipairs(spec.item or {}) do
    local result = postman._test_parse_item(item, vars)
    if result then
      for _, b in ipairs(result) do
        blocks[#blocks + 1] = b
      end
    end
  end
  return table.concat(blocks, "\n")
end

describe("postman import", function()
  it("skips disabled query params, headers, and body params", function()
    local spec = {
      info = { name = "Disabled Flag" },
      item = {
        {
          name = "Login",
          request = {
            method = "POST",
            url = {
              raw = "https://api.example.com/login",
              query = {
                { key = "debug", value = "1", disabled = true },
                { key = "locale", value = "en" },
              },
            },
            header = {
              { key = "X-Off", value = "nope", disabled = true },
              { key = "X-On", value = "yes" },
            },
            body = {
              mode = "urlencoded",
              urlencoded = {
                { key = "remember", value = "true", disabled = true },
                { key = "user", value = "bob" },
              },
            },
          },
        },
      },
    }
    local text = render(spec)
    assert.truthy(text:match("locale=en"), "enabled query param kept")
    assert.equals(nil, text:match("debug=1"), "disabled query param must not be sent")
    assert.truthy(text:match("X%-On: yes"), "enabled header kept")
    assert.equals(nil, text:match("X%-Off"), "disabled header must not be sent")
    assert.truthy(text:match("user=bob"), "enabled body param kept")
    assert.equals(nil, text:match("remember=true"), "disabled body param must not be sent")
  end)

  it("renders urlencoded bodies on one line and formdata parts as lines", function()
    local spec = {
      info = { name = "Body Shapes" },
      item = {
        {
          name = "Form",
          request = {
            method = "POST",
            url = "https://api.example.com/f",
            body = {
              mode = "formdata",
              formdata = {
                { key = "a", value = "1" },
                { key = "file", type = "file", src = "upload.bin" },
              },
            },
          },
        },
      },
    }
    local text = render(spec)
    assert.truthy(text:match("a=1"), "plain formdata part")
    assert.truthy(text:match("< upload%.bin"), "file part becomes a < path ref")
  end)

  it("flattens nested folders into blocks", function()
    local spec = {
      info = { name = "Folders" },
      item = {
        { name = "Group", item = {
          { name = "Inner", request = { method = "GET", url = "https://api.example.com/in" } },
        } },
      },
    }
    local text = render(spec)
    assert.truthy(text:match("### Inner"), "nested request becomes a block")
    assert.truthy(text:match("GET https://api%.example%.com/in"), "request line present")
  end)

  it("resolves collection variables in URLs and header values", function()
    local spec = {
      info = { name = "Vars" },
      variable = { { key = "host", value = "api.example.com" } },
      item = {
        { name = "Ping", request = { method = "GET",
          url = "https://{{host}}/ping",
          header = { { key = "X-Origin", value = "{{host}}" },
                     { key = "X-Missing", value = "{{nope}}" } } } },
      },
    }
    local text = render(spec)
    assert.truthy(text:match("https://api%.example%.com/ping"),
      "a known collection variable resolves into the URL")
    assert.truthy(text:match("X%-Origin: api%.example%.com"), "known var resolves in headers")
    assert.truthy(text:match("X%-Missing: {{nope}}"),
      "an unknown variable stays a literal {{ref}}")
  end)

  it("generate_http_block keeps empty-value headers and injects no content-type without a body", function()
    local text = import_parser.generate_http_block("N", "GET", "https://x/y",
      { { key = "X-Empty", value = "" } }, nil, nil)
    assert.truthy(text:match("X%-Empty:%s*\n"), "empty header value kept")
    assert.equals(nil, text:match("Content%-Type"), "no body, no injected content-type")
  end)
end)
