--- End-to-end tests for the OpenAPI 3.x and Swagger 2.0 spec importers.
--- The generated .http file is meant to be committed and reviewed, so the
--- block order must be a pure function of the spec (sorted path order) —
--- pairs() hash order changed between runs and between nvim sessions.
local openapi = require("poste-http.http.import_openapi")
local swagger = require("poste-http.http.import_swagger")

local function write_json(path, tbl)
  local fd = io.open(path, "w")
  fd:write(vim.json.encode(tbl))
  fd:close()
end

local function read_file(path)
  local fd = io.open(path, "r")
  local content = fd and fd:read("*a") or nil
  if fd then fd:close() end
  return content
end

describe("OpenAPI import ordering", function()
  it("emits blocks in sorted path order and is deterministic across runs", function()
    -- 30 paths: pairs() hash order is certainly not sorted order here.
    local paths = {}
    for i = 1, 30 do
      paths[string.format("/p%02d", i)] = {
        get = { summary = "Get p" .. i, responses = { ["200"] = { description = "ok" } } },
      }
    end
    paths["/users"] = {
      get = { summary = "List users", responses = { ["200"] = { description = "ok" } } },
    }
    local spec_path = os.tmpname() .. ".json"
    write_json(spec_path, {
      openapi = "3.0.0",
      info = { title = "Ordering Test" },
      servers = { { url = "http://localhost:8080" } },
      paths = paths,
    })
    local out_dir = os.tmpname() .. "-out"
    os.remove(out_dir)

    local result = openapi.import_spec(spec_path, out_dir)
    assert.is_truthy(result, "import must succeed")

    local content = read_file(out_dir .. "/" .. result.filename)
    assert.is_truthy(content)

    -- Collect the request-line order and compare against the sorted paths.
    local order = {}
    for line in content:gmatch("[^\n]+") do
      if line:match("^GET ") then table.insert(order, line) end
    end
    assert.are_equal(31, #order)
    local sorted = {}
    for i = 1, 30 do table.insert(sorted, "GET {{base_url}}/p" .. string.format("%02d", i)) end
    table.insert(sorted, "GET {{base_url}}/users")
    for i, expected in ipairs(sorted) do
      assert.are_equal(expected, order[i], "block " .. i .. " must follow sorted path order")
    end

    -- Re-import into a second dir: byte-identical output.
    local out_dir2 = os.tmpname() .. "-out2"
    os.remove(out_dir2)
    local result2 = openapi.import_spec(spec_path, out_dir2)
    assert.are_equal(content, read_file(out_dir2 .. "/" .. result2.filename))

    os.remove(spec_path)
    os.remove(out_dir .. "/" .. result.filename)
    os.remove(out_dir .. "/env.json")
    os.remove(out_dir2 .. "/" .. result2.filename)
    os.remove(out_dir2 .. "/env.json")
  end)

  it("skips malformed (non-table) path items instead of erroring", function()
    local spec_path = os.tmpname() .. ".json"
    write_json(spec_path, {
      openapi = "3.0.0",
      info = { title = "Malformed" },
      paths = {
        ["/ok"] = { get = { summary = "Fine", responses = {} } },
        ["/bad-num"] = 42,
        ["/bad-null"] = vim.NIL,
      },
    })
    local out_dir = os.tmpname() .. "-out"
    os.remove(out_dir)

    local result, err = openapi.import_spec(spec_path, out_dir)
    assert.is_truthy(result, "malformed path items must be skipped, not fatal: " .. tostring(err))
    assert.are_equal(1, result.block_count)

    os.remove(spec_path)
    os.remove(out_dir .. "/" .. result.filename)
    os.remove(out_dir .. "/env.json")
  end)

  it("swagger: survives scalar/null security, parameters, and defs sections", function()
    -- JSON null decodes to vim.NIL (which `or {}` does NOT catch) and
    -- hand-edited files carry scalar lists: security/parameters used to
    -- raise ipairs-on-a-string or pairs-on-userdata mid-import.
    local spec_path = os.tmpname() .. ".json"
    write_json(spec_path, {
      swagger = "2.0",
      info = { title = "Drifted" },
      securityDefinitions = "not-a-table",
      paths = {
        ["/a"] = {
          get = {
            summary = "G",
            security = "not-a-table",
            parameters = "not-a-table",
            responses = {},
          },
          post = {
            summary = "P",
            security = { "not-a-table", { drift = {} } },
            parameters = { "scalar", { name = "q", ["in"] = "query", type = "string" } },
            responses = {},
          },
        },
      },
    })
    local out_dir = os.tmpname() .. "-out"
    os.remove(out_dir)

    local result, err = swagger.import_spec(spec_path, out_dir)
    assert.is_truthy(result, "drifted sections must degrade, not crash: " .. tostring(err))
    assert.are_equal(2, result.block_count)

    os.remove(spec_path)
    os.remove(out_dir .. "/" .. result.filename)
    os.remove(out_dir .. "/env.json")
  end)

  it("read_spec strips vim.NIL: JSON null anywhere imports as plain nil", function()
    -- The boundary contract every importer relies on: {"info":null} reads
    -- back as info == nil (not userdata), so `spec.info == nil` guards hold.
    local parser = require("poste-http.http.import_parser")
    local spec_path = os.tmpname() .. ".json"
    local fd = io.open(spec_path, "w")
    fd:write('{"info":null,"item":null,"paths":{"a":null}}')
    fd:close()
    local spec, err = parser.read_spec(spec_path)
    assert.is_truthy(spec, err)
    assert.is_nil(spec.info)
    assert.is_nil(spec.item)
    assert.is_nil(spec.paths.a)
    os.remove(spec_path)
  end)
end)

describe("Swagger import ordering", function()
  it("emits blocks in sorted path order and is deterministic across runs", function()
    local paths = {}
    for i = 1, 30 do
      paths[string.format("/p%02d", i)] = {
        get = { summary = "Get p" .. i, responses = { ["200"] = { description = "ok" } } },
      }
    end
    paths["/users"] = {
      get = { summary = "List users", responses = { ["200"] = { description = "ok" } } },
    }
    local spec_path = os.tmpname() .. ".json"
    write_json(spec_path, {
      swagger = "2.0",
      info = { title = "Ordering Test" },
      host = "localhost",
      basePath = "/api",
      paths = paths,
    })
    local out_dir = os.tmpname() .. "-out"
    os.remove(out_dir)

    local result = swagger.import_spec(spec_path, out_dir)
    assert.is_truthy(result, "import must succeed")

    local content = read_file(out_dir .. "/" .. result.filename)
    local order = {}
    for line in content:gmatch("[^\n]+") do
      if line:match("^GET ") then table.insert(order, line) end
    end
    assert.are_equal(31, #order)
    assert.matches("^GET {{base_url}}/api/p01$", order[1])
    assert.matches("^GET {{base_url}}/api/users$", order[31])

    local out_dir2 = os.tmpname() .. "-out2"
    os.remove(out_dir2)
    local result2 = swagger.import_spec(spec_path, out_dir2)
    assert.are_equal(content, read_file(out_dir2 .. "/" .. result2.filename))

    os.remove(spec_path)
    os.remove(out_dir .. "/" .. result.filename)
    os.remove(out_dir .. "/env.json")
    os.remove(out_dir2 .. "/" .. result2.filename)
    os.remove(out_dir2 .. "/env.json")
  end)

  it("skips malformed (non-table) path items instead of erroring", function()
    local spec_path = os.tmpname() .. ".json"
    write_json(spec_path, {
      swagger = "2.0",
      info = { title = "Malformed" },
      paths = {
        ["/ok"] = { get = { summary = "Fine", responses = {} } },
        ["/bad-num"] = 42,
      },
    })
    local out_dir = os.tmpname() .. "-out"
    os.remove(out_dir)

    local result, err = swagger.import_spec(spec_path, out_dir)
    assert.is_truthy(result, "malformed path items must be skipped, not fatal: " .. tostring(err))
    assert.are_equal(1, result.block_count)

    os.remove(spec_path)
    os.remove(out_dir .. "/" .. result.filename)
    os.remove(out_dir .. "/env.json")
  end)

  it("swagger: survives scalar/null security, parameters, and defs sections", function()
    -- JSON null decodes to vim.NIL (which `or {}` does NOT catch) and
    -- hand-edited files carry scalar lists: security/parameters used to
    -- raise ipairs-on-a-string or pairs-on-userdata mid-import.
    local spec_path = os.tmpname() .. ".json"
    write_json(spec_path, {
      swagger = "2.0",
      info = { title = "Drifted" },
      securityDefinitions = "not-a-table",
      paths = {
        ["/a"] = {
          get = {
            summary = "G",
            security = "not-a-table",
            parameters = "not-a-table",
            responses = {},
          },
          post = {
            summary = "P",
            security = { "not-a-table", { drift = {} } },
            parameters = { "scalar", { name = "q", ["in"] = "query", type = "string" } },
            responses = {},
          },
        },
      },
    })
    local out_dir = os.tmpname() .. "-out"
    os.remove(out_dir)

    local result, err = swagger.import_spec(spec_path, out_dir)
    assert.is_truthy(result, "drifted sections must degrade, not crash: " .. tostring(err))
    assert.are_equal(2, result.block_count)

    os.remove(spec_path)
    os.remove(out_dir .. "/" .. result.filename)
    os.remove(out_dir .. "/env.json")
  end)

  it("read_spec strips vim.NIL: JSON null anywhere imports as plain nil", function()
    -- The boundary contract every importer relies on: {"info":null} reads
    -- back as info == nil (not userdata), so `spec.info == nil` guards hold.
    local parser = require("poste-http.http.import_parser")
    local spec_path = os.tmpname() .. ".json"
    local fd = io.open(spec_path, "w")
    fd:write('{"info":null,"item":null,"paths":{"a":null}}')
    fd:close()
    local spec, err = parser.read_spec(spec_path)
    assert.is_truthy(spec, err)
    assert.is_nil(spec.info)
    assert.is_nil(spec.item)
    assert.is_nil(spec.paths.a)
    os.remove(spec_path)
  end)
end)
