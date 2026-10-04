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

  -- The old pattern required one char after `=`, so the space-separator
  -- fallback picked the line up instead and captured the `=` itself as the
  -- value: `@token =` substituted as literal "=".
  it("treats @var = with no value as the empty string", function()
    local r = collect({ "@token =" }, 1, 1)
    assert.equals("", r.token)
  end)

  it("treats @var= (no spaces, no value) as the empty string", function()
    local r = collect({ "@token=" }, 1, 1)
    assert.equals("", r.token)
  end)

  -- Regression: the greedy `%S+` name let the LAST `=` on the line win, so
  -- the compact form `@url=http://a?b=c` parsed as name "url=http://a?b",
  -- value "c" — a JWT or query-string value was unreachable as {{name}}.
  it("splits the compact @var=value form at the FIRST equals sign", function()
    local r = collect({ "@url=http://a?b=c" }, 1, 1)
    assert.equals("http://a?b=c", r.url)
  end)

  it("keeps = signs in compact values (base64 padding, JWT shape)", function()
    local r = collect({ "@tok=eyJ9.eyJ.abc==", "@b64=dGVzdA==" }, 1, 2)
    assert.equals("eyJ9.eyJ.abc==", r.tok)
    assert.equals("dGVzdA==", r.b64)
  end)

  it("does not register an empty-name @=value line", function()
    local r = collect({ "@=value" }, 1, 1)
    assert.is_nil(r[""])
    local count = 0
    for _ in pairs(r) do count = count + 1 end
    assert.equals(0, count)
  end)

  it("collect_var_defs_with_lines splits compact values at the first =", function()
    local r = vars.collect_var_defs_with_lines({ "@url=http://a?b=c" }, 1, 1)
    assert.equals("http://a?b=c", r.url.value)
    assert.equals(1, r.url.line)
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

  it("passes non-string input through untouched (family contract)", function()
    -- substitute(nil) used to crash on `result:gsub`; every current caller
    -- hands a string, but the resolver is public API (poste-mq's
    -- vars.expand passes non-strings through).
    local resolver = vars.new()
    assert.equals(nil, resolver:substitute(nil))
    assert.equals(5, resolver:substitute(5))
    assert.equals("", resolver:substitute(""))
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
    local env = require("poste-http.http.vars").load_env_vars_with_lines(env_path, "dev")
    assert.equals("https://dev.example.com", env.host.value)
    assert.equals("{", env.open.value)
    assert.equals("}", env.close.value)
    -- the leak signature: prod.host would have overwritten dev.host
    assert.equals("https://dev.example.com", env.host.value)
  end)
end)

describe("value_to_string at inspect/display boundaries", function()
  -- K (show_var_value) fed the resolver's RAW env values into `:find` — an
  -- env.json object crashed ("attempt to call a nil value") and a JSON null
  -- crashed on the vim.NIL userdata. The stringifier is the contract.
  it("JSON-encodes table values", function()
    assert.equals('{"a":1}', vars.value_to_string({ a = 1 }))
    assert.equals('[1,2]', vars.value_to_string({ 1, 2 }))
  end)

  it("maps vim.NIL to an empty string (not the userdata, not a crash)", function()
    assert.equals("", vars.value_to_string(vim.NIL))
  end)

  it("keeps strings and scalar reprs verbatim", function()
    assert.equals("plain", vars.value_to_string("plain"))
    assert.equals("42", vars.value_to_string(42))
    assert.equals("true", vars.value_to_string(true))
    assert.equals("", vars.value_to_string(nil))
  end)
end)

describe("resolver resolve() returns raw env shapes (display must stringify)", function()
  it("an object-valued env key resolves to a table", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local env_path = dir .. "/env.json"
    local f = io.open(env_path, "w")
    f:write('{"dev": {"cfg": {"a": 1}, "null_v": null, "host": "h"}}')
    f:close()

    local resolver = vars.build_resolver_from_state({
      lines = { "GET {{host}}" },
      file_path = env_path .. ".http",
      env_name = "dev",
    })
    assert.equals("h", resolver:resolve("host"))
    assert.are_same({ a = 1 }, resolver:resolve("cfg"))
    assert.truthy(vim.NIL == resolver:resolve("null_v") or resolver:resolve("null_v") ~= nil,
      "null env value resolves to the vim.NIL shape, not nil")

    pcall(vim.fn.delete, dir, "rf")
  end)
end)
