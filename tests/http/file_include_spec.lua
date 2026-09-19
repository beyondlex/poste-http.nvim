local file_include = require("poste-http.http.file_include")

describe("expand_file_includes", function()
  local tmp = os.tmpname()
  os.remove(tmp)
  tmp = tmp .. "_spec_dir"

  before_each(function()
    vim.fn.mkdir(tmp, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  local function write(name, lines)
    local path = tmp .. "/" .. name
    vim.fn.writefile(lines, path, "b")
    return path
  end

  it("returns content unchanged when no < path line exists", function()
    local content = "POST /api\nContent-Type: application/json\n\n{\"a\":1}"
    local out, err = file_include.expand_file_includes(content, tmp)
    assert.equals(content, out)
    assert.is_nil(err)
  end)

  it("expands an absolute-path include in place", function()
    local path = write("payload.json", { '{"price":', ' 42}' })
    local out, err = file_include.expand_file_includes("body:\n< " .. path, tmp)
    assert.is_nil(err)
    assert.equals("body:\n" .. table.concat({ '{"price":', ' 42}' }, "\n"), out)
  end)

  it("expands a path relative to buf_dir", function()
    write("rel.txt", { "hello from rel" })
    local out, err = file_include.expand_file_includes("< ./rel.txt", tmp)
    assert.is_nil(err)
    assert.equals("hello from rel", out)
  end)

  it("errors on a missing file instead of sending a literal < path line", function()
    local out, err = file_include.expand_file_includes("< " .. tmp .. "/nope.txt", tmp)
    assert.is_nil(out)
    assert.truthy(err:match("File not found"))
  end)

  it("errors on an unreadable include target (directory) instead of silently dropping the line", function()
    -- A directory passes io.open but fd:read("*a") fails; the old code
    -- swallowed the nil and dropped the include line, silently emptying
    -- the body.
    local dir = tmp .. "/as_dir"
    vim.fn.mkdir(dir, "p")
    local out, err = file_include.expand_file_includes("< " .. dir, tmp)
    assert.is_nil(out)
    assert.truthy(err:match("Cannot read file"))
  end)

  it("does not treat script-block opener lines as includes", function()
    local content = "< {% client.log('hi') %}"
    local out, err = file_include.expand_file_includes(content, tmp)
    assert.equals(content, out)
    assert.is_nil(err)
  end)

  it("returns empty content untouched", function()
    local out, err = file_include.expand_file_includes("", tmp)
    assert.equals("", out)
    assert.is_nil(err)
  end)
end)
