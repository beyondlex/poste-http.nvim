--- Request orchestration for SCRIPT blocks.
---
--- A SCRIPT block's `> {% ... %}` body runs as a Lua orchestration script in a
--- sandbox where `client.run(target, args)` executes an imported request
--- ("#Name" or "#alias.Name") and returns a typed response object. The body
--- runs inside a coroutine: `client.run` yields and is resumed when the
--- request completes, so scripts read as sequential code.
local import = require("poste-http.http.import")
local state = require("poste-http.state")
local util = require("poste-http.util")
local script_sandbox = require("poste-http.http.script_sandbox")

local M = {}

--- Wrap a raw curl response into the typed response object used by scripts:
--- case-insensitive header access and a lazily JSON-decoded body.
--- @param raw table  Raw response from the curl pipeline
--- @return table
function M.build_response(raw)
  local headers = {}
  if raw.headers then
    for _, pair in ipairs(raw.headers) do
      if pair[1] then
        headers[pair[1]:lower()] = pair[2]
      end
    end
  end

  local raw_body = raw.body
  local decoded = nil

  return setmetatable({
    status = raw.status,
    status_text = raw.status_text,
    headers = setmetatable(headers, {
      __index = function(t, k)
        return rawget(t, tostring(k):lower())
      end,
    }),
    latency_ms = raw.latency_ms,
    content_type = raw.content_type,
    url = raw.url,
    cookies = raw.cookies,
    protocol = raw.protocol,
    ok = raw.ok,
    metadata = raw.metadata,
  }, {
    __index = function(t, k)
      if k == "body" then
        if decoded == nil then
          local ok, parsed = pcall(vim.json.decode, raw_body)
          decoded = (ok and parsed) and util.json_to_table(parsed) or raw_body
        end
        return decoded
      end
      return rawget(t, k)
    end,
  })
end

--- Run orchestration script code with client.run support.
--- @param code string  Lua source
--- @param opts table  { buf = number|nil, variables = table|nil, env = table|nil,
---                     response = table|nil }
--- @param on_complete function  (result) result = { logs = string[],
---                     calls = {{name, response}}, error = string|nil }
function M.run_script(code, opts, on_complete)
  opts = opts or {}
  local logs = {}
  local calls = {}
  local test_failures = {}

  local function collect_log(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    table.insert(logs, table.concat(parts, "\t"))
  end

  local client_api = {
    log = collect_log,
    global = {
      set = function(name, value)
        state.set_global_var(name, tostring(value))
        state.log("INFO", string.format("Orchestration: client.global.set('%s', '%s')", name, tostring(value)))
      end,
      get = function(name)
        return state.global_vars[name]
      end,
      header = {
        set = function(name, value)
          state.set_global_header(name, tostring(value))
          state.log("INFO", string.format("Orchestration: client.global.header.set('%s', '%s')", name, tostring(value)))
        end,
        get = function(name)
          return state.global_headers[name]
        end,
        remove = function(name)
          state.remove_global_header(name)
          state.log("INFO", string.format("Orchestration: client.global.header.remove('%s')", name))
        end,
        clear = function()
          state.clear_global_headers()
          state.log("INFO", "Orchestration: client.global.header.clear()")
        end,
      },
    },
    assert = function(cond, msg)
      if not cond then
        error(msg or "Assertion failed", 2)
      end
    end,
    test = function(name, fn)
      local ok, err = pcall(fn)
      if not ok then
        table.insert(test_failures, { name = name, error = tostring(err) })
      end
    end,
    run = function(target, args)
      local req = coroutine.yield({ kind = "run", target = target, args = args })
      if not req or req.error then
        error(("client.run(%s) failed: %s"):format(tostring(target),
          req and req.error or "unknown error"), 2)
      end
      table.insert(calls, { name = req.name, response = req.response })
      return M.build_response(req.response)
    end,
  }

  -- Stdlib whitelist comes from the shared builder (orchestration used to
  -- hand-roll the list and had already drifted: no md5). Orchestration-only
  -- bits — collect_log as print, the level-2 assert — are layered on top.
  local sandbox = script_sandbox.build_sandbox_env({
    client = client_api,
    variables = opts.variables or {},
    env = opts.env or {},
    response = opts.response,
    assert = function(cond, msg)
      if not cond then error(msg or "Assertion failed", 2) end
    end,
  })
  sandbox.print = collect_log

  local co
  local finished = false

  local function finish(err)
    if finished then return end
    finished = true
    if not err and #test_failures > 0 then
      local t = test_failures[1]
      err = ("Test '%s' failed: %s"):format(t.name, t.error)
    end
    if on_complete then
      on_complete({ logs = logs, calls = calls, error = err })
    end
  end

  local function drive(resume_arg)
    local ok, yielded = coroutine.resume(co, resume_arg)
    if not ok then
      finish(tostring(yielded))
      return
    end
    if coroutine.status(co) == "dead" then
      finish(nil)
      return
    end
    if yielded and yielded.kind == "run" then
      import.execute_request_reference(yielded.target, yielded.args, { buf = opts.buf }, function(ok2, response, name)
        if ok2 and response then
          drive({ name = name, response = response })
        else
          drive({ error = response and response.error or ("Request '%s' failed"):format(tostring(yielded.target)) })
        end
      end)
    else
      finish("Unknown yield from orchestration script")
    end
  end

  local fn, load_err = load(code, "orchestration_script", "t", sandbox)
  if not fn then
    finish("Syntax error: " .. tostring(load_err))
    return
  end
  co = coroutine.create(function()
    fn()
  end)
  drive()
end

return M
