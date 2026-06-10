-- Tests for poste.util shared utility functions.
--
-- These functions are extracted from init.lua and sql/init.lua to
-- eliminate code duplication between HTTP and SQL subsystems.

local util = require("poste.util")

---------------------------------------------------------------------------
-- clean_nil
---------------------------------------------------------------------------

describe("clean_nil", function()
  it("returns nil for nil input", function()
    assert.is_nil(util.clean_nil(nil))
  end)

  it("returns non-table values as-is", function()
    assert.equals(42, util.clean_nil(42))
    assert.equals("hello", util.clean_nil("hello"))
    assert.is_true(util.clean_nil(true))
  end)

  it("removes top-level vim.NIL values", function()
    local t = { a = 1, b = vim.NIL, c = "keep" }
    local result = util.clean_nil(t)
    assert.equals(1, result.a)
    assert.is_nil(result.b)
    assert.equals("keep", result.c)
  end)

  it("removes nested vim.NIL values recursively", function()
    local t = {
      name = "test",
      meta = {
        ok = true,
        error = vim.NIL,
        extra = vim.NIL,
      },
      items = { 1, 2, vim.NIL },
    }
    local result = util.clean_nil(t)
    assert.equals("test", result.name)
    assert.is_true(result.meta.ok)
    assert.is_nil(result.meta.error)
    assert.is_nil(result.meta.extra)
    assert.equals(1, result.items[1])
    assert.equals(2, result.items[2])
    assert.is_nil(result.items[3])
  end)

  it("handles empty tables", function()
    local result = util.clean_nil({})
    assert.is_table(result)
    assert.equals(0, vim.tbl_count(result))
  end)

  it("handles tables with no vim.NIL values unchanged", function()
    local t = { a = 1, b = { c = 2 } }
    local result = util.clean_nil(t)
    assert.equals(1, result.a)
    assert.equals(2, result.b.c)
  end)

  it("handles deeply nested mixed structures", function()
    local t = {
      x = vim.NIL,
      y = {
        z = vim.NIL,
        w = {
          v = vim.NIL,
          u = "deep",
        },
      },
    }
    local result = util.clean_nil(t)
    assert.is_nil(result.x)
    assert.is_nil(result.y.z)
    assert.is_nil(result.y.w.v)
    assert.equals("deep", result.y.w.u)
  end)
end)

---------------------------------------------------------------------------
-- find_file_upwards
---------------------------------------------------------------------------

describe("find_file_upwards", function()
  it("returns nil for empty filename", function()
    assert.is_nil(util.find_file_upwards("", "/tmp"))
  end)

  it("returns nil when file does not exist", function()
    assert.is_nil(util.find_file_upwards("nonexistent-file-12345.json", "/tmp"))
  end)

  it("finds a file in the starting directory", function()
    -- Write a temp file, search for it, then clean up
    local tmpdir = os.tmpname():gsub("tmp.*", "") or "/tmp"
    -- Use a unique name
    local search_file = "/tmp/poste_test_file_" .. tostring(math.random(10000, 99999)) .. ".tmp"
    local f = io.open(search_file, "w")
    assert.is_not_nil(f)
    f:write("test")
    f:close()

    local result = util.find_file_upwards(search_file:match("/([^/]+)$"), "/tmp")
    if not result then
      -- Try with the full expected path
      result = util.find_file_upwards(search_file:match("/([^/]+)$"), "/private/tmp")
    end

    -- On macOS, /tmp is a symlink to /private/tmp
    if not result then
      result = util.find_file_upwards(search_file:match("/([^/]+)$"), "/private/tmp")
    end

    assert.is_not_nil(result)

    os.remove(search_file)
  end)

  it("returns nil for non-existent directory", function()
    assert.is_nil(util.find_file_upwards("env.json", "/nonexistent_dir_xyz_12345"))
  end)
end)

---------------------------------------------------------------------------
-- ensure_job_data
---------------------------------------------------------------------------

describe("ensure_job_data", function()
  it("returns empty table for nil input", function()
    local result = util.ensure_job_data(nil)
    assert.is_table(result)
    assert.equals(0, #result)
  end)

  it("returns empty table for non-table input", function()
    local result = util.ensure_job_data("hello")
    assert.is_table(result)
    assert.equals(0, #result)
  end)

  it("preserves data without trailing empty strings", function()
    local data = { "line1", "line2", "line3" }
    local result = util.ensure_job_data(data)
    assert.equals(3, #result)
    assert.equals("line1", result[1])
    assert.equals("line2", result[2])
    assert.equals("line3", result[3])
  end)

  it("removes trailing empty strings", function()
    local data = { "line1", "line2", "" }
    local result = util.ensure_job_data(data)
    assert.equals(2, #result)
    assert.equals("line1", result[1])
    assert.equals("line2", result[2])
  end)

  it("removes multiple trailing empty strings", function()
    local data = { "line1", "", "", "" }
    local result = util.ensure_job_data(data)
    assert.equals(1, #result)
    assert.equals("line1", result[1])
  end)

  it("returns empty table for all-empty input", function()
    local data = { "", "", "" }
    local result = util.ensure_job_data(data)
    assert.is_table(result)
    assert.equals(0, #result)
  end)

  it("preserves empty strings in the middle", function()
    local data = { "line1", "", "line2" }
    local result = util.ensure_job_data(data)
    assert.equals(3, #result)
    assert.equals("line1", result[1])
    assert.equals("", result[2])
    assert.equals("line2", result[3])
  end)

  it("mutates the input array in place (backward compatible)", function()
    local data = { "a", "b", "", "" }
    local result = util.ensure_job_data(data)
    -- Both the input and result should reflect the change
    assert.equals(2, #data)
    assert.equals(2, #result)
    assert.equals(data, result)
  end)
end)