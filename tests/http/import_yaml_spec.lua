--- The spec importers parse JSON only. These specs pin (1) that the file
--- pickers advertise exactly the extensions the parser can read, and (2)
--- that a YAML spec gets a clear "looks like YAML" error instead of a bare
--- "Invalid JSON".

local import_parser = require("poste-http.http.import_parser")
local import_openapi = require("poste-http.http.import_openapi")
local import_swagger = require("poste-http.http.import_swagger")

describe("spec importer file picker extensions", function()
  -- The finder plugin is optional at runtime; preload a fake before run()
  -- touches it and capture the options each importer hands over.
  local captured = {}
  before_each(function()
    captured = {}
    package.preload["finder"] = function()
      return {
        open = function(opts) table.insert(captured, opts) end,
      }
    end
  end)
  after_each(function()
    package.preload["finder"] = nil
    package.loaded["finder"] = nil
  end)

  it("OpenAPI picker offers only extensions the parser reads (json)", function()
    import_openapi.run()
    assert.equals(1, #captured)
    assert.same({ "json" }, captured[1].extensions)
  end)

  it("Swagger picker offers only extensions the parser reads (json)", function()
    import_swagger.run()
    assert.equals(1, #captured)
    assert.same({ "json" }, captured[1].extensions)
  end)
end)

describe("import_parser.read_spec YAML diagnostics", function()
  local tmpdir = os.tmpname() .. ".d"
  before_each(function()
    vim.fn.mkdir(tmpdir, "p")
  end)
  after_each(function()
    vim.fn.delete(tmpdir, "rf")
  end)

  local function write(name, content)
    local path = tmpdir .. "/" .. name
    local fd = io.open(path, "w")
    fd:write(content)
    fd:close()
    return path
  end

  it("names YAML as the problem for a YAML OpenAPI spec", function()
    local path = write("spec.yaml", table.concat({
      "openapi: 3.0.0",
      "info:",
      "  title: Demo",
      "paths: {}",
    }, "\n"))
    local spec, err = import_parser.read_spec(path)
    assert.is_nil(spec)
    assert.truthy(err:match("YAML"), "expected a YAML hint, got: " .. tostring(err))
  end)

  it("still reports Invalid JSON for JSON that does not parse", function()
    local path = write("spec.json", '{ "openapi": 3.0.0,, }')
    local spec, err = import_parser.read_spec(path)
    assert.is_nil(spec)
    assert.truthy(err:match("Invalid JSON"))
  end)

  it("still parses a real JSON spec", function()
    local path = write("spec.json", '{ "openapi": "3.0.0", "info": { "title": "t" } }')
    local spec, err = import_parser.read_spec(path)
    assert.is_nil(err)
    assert.equals("3.0.0", spec.openapi)
  end)
end)
