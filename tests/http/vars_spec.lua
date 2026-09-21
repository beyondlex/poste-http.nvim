local vars = require("poste-http.http.vars")

describe("collect_var_defs", function()
  local collect = vars.collect_var_defs

  it("collects single-line @var = value", function()
    local lines = { "@host = http://localhost:8888", "@token = abc123" }
    local r = collect(lines, 1, #lines)
    assert.equals("http://localhost:8888", r.host)
    assert.equals("abc123", r.token)
  end)

  it("collects multi-line @var=>>>...<<<", function()
    local lines = {
      '@headers_block=>>>',
      'X-Custom-Auth: Bearer token123',
      'X-Client-Id: poste-test',
      '<<<',
      'GET {{host}}/test',
    }
    local r = collect(lines, 1, 3)
    assert.not_nil(r.headers_block)
    assert.equals("X-Custom-Auth: Bearer token123\nX-Client-Id: poste-test", r.headers_block)
  end)

  it("collects multi-line var across file-level lines", function()
    local lines = {
      '@multi=>>>',
      'line1',
      'line2',
      'line3',
      '<<<',
      '@other = value',
    }
    local r = collect(lines, 1, #lines)
    assert.equals("line1\nline2\nline3", r.multi)
    assert.equals("value", r.other)
  end)

  it("handles multi-line var with blank lines inside", function()
    local lines = {
      '@body=>>>',
      '{"key": "value"}',
      '',
      '{"key2": "value2"}',
      '<<<',
    }
    local r = collect(lines, 1, #lines)
    assert.equals('{"key": "value"}\n\n{"key2": "value2"}', r.body)
  end)

  it("ignores lines after <<<", function()
    local lines = {
      '@x=>>>',
      'content',
      '<<<',
      'not a var',
    }
    local r = collect(lines, 1, #lines)
    assert.equals("content", r.x)
    assert.is_nil(r.not_a_var)
  end)

  it("strips single quotes from value", function()
    local lines = { "@name = 'hello world'" }
    local r = collect(lines, 1, #lines)
    assert.equals("hello world", r.name)
  end)

  it("strips double quotes from value", function()
    local lines = { '@name = "hello world"' }
    local r = collect(lines, 1, #lines)
    assert.equals("hello world", r.name)
  end)

  it("handles @var without = (space separator)", function()
    local lines = { "@host http://localhost:8888" }
    local r = collect(lines, 1, #lines)
    assert.equals("http://localhost:8888", r.host)
  end)
end)

describe("VarResolver:substitute with table values", function()
  it("encodes table as JSON when substituted into content", function()
    local resolver = vars.new()
    resolver.session_vars = { obj = { name = "doge" } }
    local result = resolver:substitute('{"obj": {{obj}}}')
    assert.equals('{"obj": {"name":"doge"}}', result)
  end)

  it("encodes nested table as JSON", function()
    local resolver = vars.new()
    resolver.session_vars = { user = { profile = { name = "Alice", age = 30 } } }
    local result = resolver:substitute('{{user}}')
    assert.truthy(result:match('"name"%s*:%s*"Alice"'))
    assert.truthy(result:match('"age"%s*:%s*30'))
    assert.is_falsy(result:match("^table:"))
  end)

  it("handles string values unchanged", function()
    local resolver = vars.new()
    resolver.session_vars = { name = "hello" }
    local result = resolver:substitute('{{name}}')
    assert.equals("hello", result)
  end)

  it("handles numeric values", function()
    local resolver = vars.new()
    resolver.session_vars = { count = 42 }
    local result = resolver:substitute('{{count}}')
    assert.equals("42", result)
  end)

  it("handles boolean values", function()
    local resolver = vars.new()
    resolver.session_vars = { flag = true }
    local result = resolver:substitute('{{flag}}')
    assert.equals("true", result)
  end)

  it("leaves unresolved {{var}} as-is", function()
    local resolver = vars.new()
    local result = resolver:substitute('{{unknown}}')
    assert.equals("{{unknown}}", result)
  end)
end)
describe("magic vars", function()
  it("draws differ within a session", function()
    local r = vars.new()
    assert.not_equals(r:substitute("{{$uuid}}"), r:substitute("{{$uuid}}"))
    assert.not_equals(r:substitute("{{$randomInt}}"), r:substitute("{{$randomInt}}"))
  end)

  it("{{$uuid}} differs across processes (math.random seeded on first use)", function()
    -- LuaJIT seeds math.random deterministically at process start: without
    -- an explicit seed every nvim session produced the SAME first uuid /
    -- randomInt, so idempotency keys repeated run over run. Probe two real
    -- subprocesses — exactly the cross-process property seeding restores.
    -- util.lua only (no plugin bootstrap): the seed lives there.
    local root = vim.loop.cwd()
    local function triple_from_fresh_process()
      -- -i NONE: the child must not read or write the real ShaDa file —
      -- concurrent runs would corrupt it (E576) and leak tmp files.
      local out = vim.fn.system({
        vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "set rtp+=" .. root,
        "-c",
        "lua local u = require('poste-http.util'); u.seed_random(); print(math.random(0, 255), math.random(0, 255), math.random(0, 255))",
        "-c", "qa!",
      })
      return vim.trim(tostring(out))
    end
    local a = triple_from_fresh_process()
    local b = triple_from_fresh_process()
    assert.matches("^%d+ %d+ %d+$", a)
    assert.not_equals(a, b, "two fresh nvim processes must not share the random sequence")
  end)

  it("substitute wires the seeding (util._random_seeded set after a magic draw)", function()
    local util = require("poste-http.util")
    local r = vars.new()
    r:substitute("{{$uuid}}")
    assert.is_true(util._random_seeded)
  end)
end)

describe("load_env_vars_with_lines section scanning", function()
  local dir, env_path

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    env_path = vim.fs.joinpath(dir, "env.json")
  end)

  after_each(function()
    pcall(vim.fn.delete, dir, "rf")
  end)

  local function write_env(content)
    local f = io.open(env_path, "w")
    f:write(content)
    f:close()
  end

  it("stops at the section boundary even when values contain braces", function()
    -- Regression: bare { / } counting read braces INSIDE string values, so
    -- a value like "{" pushed the boundary out and the next env section's
    -- keys leaked into the lookup.
    write_env([=[
{
  "dev": {
    "open": "{",
    "close": "}",
    "host": "https://dev.example.com"
  },
  "prod": {
    "host": "https://prod.example.com"
  }
}
]=])
    local vars = require("poste-http.http.vars").load_env_vars_with_lines(env_path, "dev")
    assert.equals("https://dev.example.com", vars.host.value)
    assert.equals("{", vars.open.value)
    assert.equals("}", vars.close.value)
    -- the leak signature: prod.host would have overwritten dev.host
    assert.equals("https://dev.example.com", vars.host.value)
  end)
end)
