-- Smoke specs for modules that previously had zero test coverage (F28).
--
-- Covers the pure/testable exports of:
--   nested_access, import_parser, import_openapi, import_swagger,
--   import_postman, format/multipart, md5, file_include, prompt_vars,
--   var_collector, format_file, constants
-- GUI-coupled modules now covered by dedicated harness specs:
--   highlights → tests/http/highlights_spec.lua
--   commands  → tests/http/commands_spec.lua
--   help      → tests/http/help_spec.lua
--   script_snippet → tests/http/script_snippet_spec.lua
-- Remaining GUI-coupled modules (buffer_setup, outline, install, textobj,
-- lua_docs, curl, copy, folding) are exercised via integration specs and
-- existing dedicated tests (folding_spec, copy_spec, curl_exec_spec,
-- buffer_setup_spec).

local M = {}

local nested_access = require("poste-http.http.nested_access")
local import_parser = require("poste-http.http.import_parser")
local import_openapi = require("poste-http.http.import_openapi")
local import_swagger = require("poste-http.http.import_swagger")
local import_postman = require("poste-http.http.import_postman")
local multipart = require("poste-http.http.format.multipart")
local md5 = require("poste-http.http.md5")
local file_include = require("poste-http.http.file_include")
local prompt_vars = require("poste-http.http.prompt_vars")
local var_collector = require("poste-http.http.var_collector")
local format_file = require("poste-http.http.format_file")
local constants = require("poste-http.constants")

local tmp_dir = "/private/tmp/poste-zero-coverage"
local spec_file = tmp_dir .. "/spec.json"
local out_dir = tmp_dir .. "/out"

local function write_tmp_file(path, content)
  os.execute("mkdir -p " .. vim.fn.fnamemodify(path, ":h"))
  local fd = io.open(path, "w")
  fd:write(content)
  fd:close()
end

describe("zero-coverage smoke specs", function()
  ---------------------------------------------------------------------------
  -- nested_access
  ---------------------------------------------------------------------------
  describe("nested_access", function()
    it("resolves a nested object path", function()
      local obj = { user = { name = "alice", tags = { "a", "b" } } }
      assert.equals("alice", nested_access.get_nested_value(obj, "user.name"))
    end)

    it("resolves array-indexed paths", function()
      local obj = { items = { { id = 1 }, { id = 2 } } }
      assert.equals(2, nested_access.get_nested_value(obj, "items[1].id"))
    end)

    it("parses bracket segments", function()
      local segs = nested_access.parse_path_segments("user.tags[0]")
      assert.same({ "user", "tags[0]" }, segs)
    end)

    it("returns nil for missing paths", function()
      assert.is_nil(nested_access.get_nested_value({ a = 1 }, "b.c"))
    end)
  end)

  ---------------------------------------------------------------------------
  -- import_parser
  ---------------------------------------------------------------------------
  describe("import_parser", function()
    it("resolve_ref follows JSON pointer", function()
      local spec = { components = { schemas = { Pet = { type = "object" } } } }
      local resolved = import_parser.resolve_ref("#/components/schemas/Pet", spec)
      assert.equals("object", resolved.type)
    end)

    it("schema_to_example builds objects from properties", function()
      local schema = { type = "object", properties = { name = { type = "string" }, n = { type = "integer" } } }
      local ex = import_parser.schema_to_example(schema, {})
      assert.equals("string", ex.name)
      assert.equals(0, ex.n)
    end)

    it("schema_to_example handles $ref", function()
      local spec = { components = { schemas = { Pet = { type = "string", default = "Rex" } } } }
      local ex = import_parser.schema_to_example({ ["$ref"] = "#/components/schemas/Pet" }, spec)
      assert.equals("Rex", ex)
    end)

    it("generate_http_block emits method line and adds Content-Type for JSON body", function()
      local block = import_parser.generate_http_block("Get", "GET", "/pets", {}, '{"a":1}')
      assert.matches("### Get", block)
      assert.matches("GET /pets", block)
      assert.matches("Content%-Type: application/json", block)
    end)

    it("extract_auth_header recognizes bearer security", function()
      local spec = {
        security = { { bearerAuth = {} } },
        components = { securitySchemes = { bearerAuth = { type = "http", scheme = "bearer" } } },
      }
      local auth = import_parser.extract_auth_header(spec)
      assert.equals("Authorization", auth.key)
      assert.equals("Bearer {{token}}", auth.value)
    end)

    it("make_filename sanitizes a title", function()
      assert.equals("pet_store_api.http", import_parser.make_filename("Pet Store API!"))
    end)

    it("collect_parameters emits an enum header param as a {{var}} header", function()
      -- A header parameter with enum values used to emit only the prompt
      -- line — the header itself was missing from the generated request.
      local headers, qs, _, prompts = import_parser.collect_parameters({
        {
          name = "X-Region",
          ["in"] = "header",
          required = true,
          schema = { type = "string", enum = { "us", "eu" } },
        },
        {
          name = "sort",
          ["in"] = "query",
          schema = { type = "string", enum = { "asc", "desc" } },
        },
      }, {}, {})
      assert.equals(1, #headers)
      assert.equals("X-Region", headers[1].key)
      assert.equals("{{X-Region}}", headers[1].value)
      assert.equals(1, #qs)
      assert.equals("sort={{sort}}", qs[1])
      assert.equals(2, #prompts)
    end)
  end)

  ---------------------------------------------------------------------------
  -- import_openapi (F07 crash source)
  ---------------------------------------------------------------------------
  describe("import_openapi.import_spec", function()
    before_each(function()
      write_tmp_file(spec_file, [[
{
  "openapi": "3.0.0",
  "info": { "title": "Pets" },
  "servers": [ { "url": "http://localhost:8000" } ],
  "paths": {
    "/pets": {
      "get": { "operationId": "listPets" },
      "post": {
        "operationId": "createPet",
        "requestBody": {
          "content": {
            "application/json": {
              "schema": { "type": "object", "properties": { "name": { "type": "string" } } }
            }
          }
        }
      }
    }
  }
}
]])
      os.execute("rm -rf " .. out_dir)
    end)

    it("imports a spec and returns block count", function()
      local result, err = import_openapi.import_spec(spec_file, out_dir)
      assert.is_not_nil(result, tostring(err))
      assert.equals(2, result.block_count)
      assert.matches("pets.http", result.filename)
      assert.equals(1, vim.fn.filereadable(out_dir .. "/pets.http"))
    end)

    it("rejects non-OpenAPI files", function()
      write_tmp_file(spec_file, [[{"swagger": "2.0"}]])
      local result, err = import_openapi.import_spec(spec_file, out_dir)
      assert.is_nil(result)
      assert.matches("Not an OpenAPI", err)
    end)

    it("does not crash when an example is a scalar (F07 regression)", function()
      write_tmp_file(spec_file, [[
{
  "openapi": "3.0.0",
  "info": { "title": "Scalar" },
  "paths": {
    "/pets": {
      "post": {
        "requestBody": {
          "content": {
            "application/json": { "schema": { "type": "array", "items": { "type": "string", "example": "abc" } } }
          }
        }
      }
    }
  }
}
]])
      local result, err = import_openapi.import_spec(spec_file, out_dir)
      assert.is_not_nil(result, tostring(err))
    end)
  end)

  ---------------------------------------------------------------------------
  -- import_swagger
  ---------------------------------------------------------------------------
  describe("import_swagger.import_spec", function()
    before_each(function()
      write_tmp_file(spec_file, [[
{
  "swagger": "2.0",
  "info": { "title": "Legacy" },
  "host": "example.com",
  "paths": {
    "/users": {
      "get": { "operationId": "listUsers", "responses": { "200": { "description": "ok" } } }
    }
  }
}
]])
      os.execute("rm -rf " .. out_dir)
    end)

    it("imports a swagger 2.0 spec", function()
      local result, err = import_swagger.import_spec(spec_file, out_dir)
      assert.is_not_nil(result, tostring(err))
      assert.equals(1, result.block_count)
    end)

    it("rejects specs without swagger field", function()
      write_tmp_file(spec_file, [[{"info": {"title": "Nope"}}]])
      local result, err = import_swagger.import_spec(spec_file, out_dir)
      assert.is_nil(result)
      assert.matches("Not a Swagger", err)
    end)

    it("does not crash when example is a table (F07 regression)", function()
      write_tmp_file(spec_file, [[
{
  "swagger": "2.0",
  "info": { "title": "TableExample" },
  "paths": {
    "/pets": {
      "post": {
        "operationId": "createPet",
        "parameters": [
          {
            "name": "body",
            "in": "body",
            "schema": { "type": "object", "example": { "name": "Rex" } }
          }
        ],
        "responses": { "200": { "description": "ok" } }
      }
    }
  }
}
]])
      local result, err = import_swagger.import_spec(spec_file, out_dir)
      assert.is_not_nil(result, tostring(err))
    end)
  end)

  ---------------------------------------------------------------------------
  -- import_postman
  ---------------------------------------------------------------------------
  describe("import_postman.import_spec", function()
    before_each(function()
      write_tmp_file(spec_file, [[
{
  "info": { "name": "Collection" },
  "item": [
    {
      "name": "Get user",
      "request": {
        "method": "GET",
        "url": "http://example.com/users?page=1"
      }
    }
  ]
}
]])
      os.execute("rm -rf " .. out_dir)
    end)

    it("imports a collection", function()
      local result, err = import_postman.import_spec(spec_file, out_dir)
      assert.is_not_nil(result, tostring(err))
      assert.equals(1, result.block_count)
    end)

    it("does not duplicate the ? when a query is already in the URL (F07 regression)", function()
      local result, err = import_postman.import_spec(spec_file, out_dir)
      assert.is_not_nil(result, tostring(err))
      local fd = io.open(out_dir .. "/collection.http", "r")
      local content = fd:read("*a")
      fd:close()
      assert.is_false(content:find("??", 1, true) ~= nil, "URL should not contain double ??")
      assert.matches("GET http://example.com/users%?page=1", content)
    end)
  end)

  ---------------------------------------------------------------------------
  -- format/multipart
  ---------------------------------------------------------------------------
  describe("format/multipart", function()
    it("extracts a quoted boundary", function()
      assert.equals("abc123", multipart.extract_boundary('multipart/form-data; boundary="abc123"'))
    end)

    it("parses multipart parts", function()
      local body = "--BOUND\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nvalue1\r\n--BOUND--\r\n"
      local parts = multipart.parse_multipart_parts(body, "BOUND")
      assert.is_not_nil(parts)
      assert.equals(1, #parts)
      assert.equals("value1", parts[1].body)
    end)

    it("condenses file parts to a placeholder", function()
      local body = '--B\r\nContent-Disposition: form-data; name="f"; filename="x.txt"\r\nContent-Type: text/plain\r\n\r\n' .. string.rep("data", 200) .. "\r\n--B--\r\n"
      local condensed = multipart.condense_multipart_body(body, 'multipart/form-data; boundary="B"')
      assert.matches("%[file: x.txt, %d+ bytes%]", condensed)
    end)

    it("strip_request_preamble removes request line and headers", function()
      local raw = "POST /x HTTP/1.1\nHost: e\n\n{\"a\":1}"
      assert.equals('{"a":1}', multipart.strip_request_preamble(raw))
    end)
  end)

  ---------------------------------------------------------------------------
  -- md5
  ---------------------------------------------------------------------------
  describe("md5", function()
    it("computes a known MD5 digest", function()
      assert.equals("900150983cd24fb0d6963f7d28e17f72", md5.md5("abc"))
    end)

    it("computes the empty-string digest", function()
      assert.equals("d41d8cd98f00b204e9800998ecf8427e", md5.md5(""))
    end)
  end)

  ---------------------------------------------------------------------------
  -- file_include
  ---------------------------------------------------------------------------
  describe("file_include", function()
    it("returns content unchanged when no includes", function()
      local content = "a\nb"
      local out, err = file_include.expand_file_includes(content, "/tmp")
      assert.equals(content, out)
      assert.is_nil(err)
    end)

    it("expands a file include line", function()
      write_tmp_file(tmp_dir .. "/body.txt", "included-content")
      local out = file_include.expand_file_includes("prefix\n< " .. tmp_dir .. "/body.txt", tmp_dir)
      assert.matches("included%-content", out)
    end)

    it("errors when the included file is missing", function()
      local out, err = file_include.expand_file_includes("< /no/such/file", "/tmp")
      assert.is_nil(out)
      assert.matches("File not found", err)
    end)

    it("does not treat < {% script lines as file includes", function()
      local content = "< {% print('hello') %}\n"
      local out, err = file_include.expand_file_includes(content, "/tmp")
      assert.is_nil(err)
      assert.equals(content, out)
    end)
  end)

  ---------------------------------------------------------------------------
  -- prompt_vars
  ---------------------------------------------------------------------------
  describe("prompt_vars.strip_prompt_lines", function()
    it("removes prompt option lines", function()
      local out = prompt_vars.strip_prompt_lines("GET /x\n<<var [a, b]\n")
      assert.equals("GET /x\n", out)
    end)

    it("keeps non-prompt lines", function()
      local out = prompt_vars.strip_prompt_lines("GET /x\n")
      assert.equals("GET /x\n", out)
    end)
  end)

  ---------------------------------------------------------------------------
  -- var_collector
  ---------------------------------------------------------------------------
  describe("var_collector.collect_magic_vars", function()
    it("returns magic var definitions", function()
      local defs = var_collector.collect_magic_vars()
      assert.is_table(defs)
      assert.equals("timestamp", defs[1].name)
      assert.is_not_nil(defs[1].desc)
    end)
  end)

  ---------------------------------------------------------------------------
  -- format_file
  ---------------------------------------------------------------------------
  describe("format_file.format", function()
    it("normalizes header spacing", function()
      local out = format_file.format("### Test\nGET /api\nContent-Type:application/json\n")
      assert.matches("Content%-Type: application/json", out)
    end)

    it("adds blank line before ### blocks", function()
      local out = format_file.format("### One\nGET /a\n### Two\nGET /b")
      assert.matches("GET /a\n\n### Two", out)
    end)

    it("handles empty input", function()
      assert.equals("", format_file.format(""))
    end)

    it("restores {{var}} markers containing %-sequences verbatim", function()
      local out = format_file.format(
        "### T\nPOST /x\nContent-Type: application/json\n\n{\"key\": {{a%1b}}}\n")
      assert.matches("%{{a%%1b}}", out)
      assert.is_false(out:find("POSTE_VAR", 1, true) ~= nil,
        "placeholder must be fully restored")
    end)
  end)

  ---------------------------------------------------------------------------
  -- constants
  ---------------------------------------------------------------------------
  describe("constants", function()
    it("defines spinner frames and intervals", function()
      assert.is_table(constants.SPINNER_FRAMES)
      assert.equals(10, #constants.SPINNER_FRAMES)
      assert.is_number(constants.SPINNER_INTERVAL_MS)
    end)
  end)
end)

return M
