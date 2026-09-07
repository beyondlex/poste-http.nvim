local variable_inspector = require("poste-http.http.variable_inspector")
local request_deps = require("poste-http.http.request_deps")
local state = require("poste-http.state")

local function setup_buffer(lines, filename)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, filename or os.tmpname() .. ".http")
  vim.bo[buf].filetype = "poste_http"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

local function write_lua_file(path, content)
  local f = io.open(path, "w")
  f:write(content)
  f:close()
end

describe("variable_inspector collect_entries", function()
  local buf
  local lua_file

  before_each(function()
    state.global_vars = {}
    state.script_variables = {}
    state.current_env = ""
  end)

  after_each(function()
    state.global_vars = {}
    state.script_variables = {}
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
    if lua_file then
      os.remove(lua_file)
      lua_file = nil
    end
  end)

  it("displays a table-valued request ref as JSON, not 'table: 0x...'", function()
    request_deps.cache_response("request1", {
      body = vim.json.encode({ obj = { name = "doge" } }),
    })

    buf = setup_buffer({
      "### request1",
      "GET /request1",
      "",
      "### request2",
      "@obj = {{request1.response.body.obj}}",
      "POST /request2",
      "Content-Type: application/json",
      "",
      '{"obj": {{request1.response.body.obj}}}',
    })

    local entries, _ = variable_inspector.collect_entries(buf, 5)
    assert.truthy(entries)
    assert.truthy(entries.obj)
    assert.equals('{"name":"doge"}', entries.obj[1].value)
    assert.is_falsy(entries.obj[1].value:match("^table:"))
  end)

  it("resolves Lua import @var = alias.keypath to the actual value", function()
    lua_file = os.tmpname() .. ".lua"
    write_lua_file(lua_file, [[
return {
  a_string = "hello from lua",
  an_int = 100,
  a_float = 3.14,
  person = { name = "Lex", age = 23, role = "admin" },
}
]])

    buf = setup_buffer({
      "import " .. lua_file .. " as m",
      "",
      "@my_name = m.a_string",
      "@my_number = m.an_int",
      "@my_person = m.person",
      "@my_pi = m.a_float",
      "",
      "### 01",
      "GET /test",
    }, os.tmpname() .. ".http")

    local entries, _ = variable_inspector.collect_entries(buf, 9)
    assert.truthy(entries)
    assert.equals("hello from lua", entries.my_name[1].value)
    assert.equals("100", entries.my_number[1].value)
    assert.truthy(entries.my_person[1].value:match('"name"%s*:%s*"Lex"'))
    assert.truthy(entries.my_person[1].value:match('"age"%s*:%s*23'))
    assert.truthy(entries.my_person[1].value:match('"role"%s*:%s*"admin"'))
    assert.equals("3.14", entries.my_pi[1].value)
  end)

  it("shows the raw alias token when Lua import resolution fails", function()
    buf = setup_buffer({
      "import ./nonexistent.lua as m",
      "",
      "@my_name = m.a_string",
      "",
      "### 01",
      "GET /test",
    })

    local entries, _ = variable_inspector.collect_entries(buf, 6)
    assert.truthy(entries)
    assert.truthy(entries.my_name)
    -- When the Lua file doesn't exist, resolve_lua_imports leaves the line
    -- unchanged (import line becomes blank, @var value stays as raw token).
    assert.equals("m.a_string", entries.my_name[1].value)
  end)
end)

describe("variable_inspector rendering", function()
  local buf

  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "bwipeout!")
  end)

  local function float_lines()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == "poste-variable-inspector" then
        return vim.api.nvim_buf_get_lines(b, 0, -1, false)
      end
    end
    return nil
  end

  it("aligns CJK variable names by display width", function()
    buf = setup_buffer({
      "@用户 = 张三",
      "@en = John",
      "### Test",
      "GET /api",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    variable_inspector.show_inspector()

    local lines = float_lines()
    assert.truthy(lines, "inspector float buffer was created")
    assert.equals(2, #lines, "one rendered row per variable")

    -- Value column must start at the same display column for CJK and ASCII
    -- names. string.format pads by bytes, which would misalign CJK names.
    local function value_display_col(line, value_text)
      local pos = line:find(value_text, 1, true)
      assert.truthy(pos, "value text present in rendered line")
      return vim.fn.strdisplaywidth(line:sub(1, pos - 1))
    end
    local function line_with(lines_, text)
      for _, line in ipairs(lines_) do
        if line:find(text, 1, true) then return line end
      end
      return nil
    end
    local cjk_line = line_with(lines, "张三")
    local ascii_line = line_with(lines, "John")
    assert.truthy(cjk_line, "CJK value row rendered")
    assert.truthy(ascii_line, "ASCII value row rendered")
assert.equals(
      value_display_col(cjk_line, "张三"),
      value_display_col(ascii_line, "John")
    )
  end)
end)