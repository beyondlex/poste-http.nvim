--- Persistent context client — manages a `poste context serve` subprocess.
--- Replaces per-keystroke `vim.fn.system()` with line-delimited JSON over stdin/stdout.
local state = require("poste.state")

local M = {}

local _job_id = nil
local _next_id = 1
local _callbacks = {}
local _buf = ""
local _stopped = false

local function find_binary()
  if state.config and state.config.poste_binary ~= ""
      and vim.fn.filereadable(state.config.poste_binary) == 1 then
    return vim.fn.fnamemodify(state.config.poste_binary, ":p")
  end
  local paths = { "./target/debug/poste", "./target/release/poste" }
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("^(.+/)lua/poste/") or ""
    if dir ~= "" then
      table.insert(paths, dir .. "target/debug/poste")
      table.insert(paths, dir .. "target/release/poste")
      table.insert(paths, dir .. "bin/poste")
    end
  end
  for _, p in ipairs(paths) do
    if vim.fn.filereadable(p) == 1 then return vim.fn.fnamemodify(p, ":p") end
  end
  return vim.fn.exepath("poste")
end

local function start()
  if _stopped then return false end
  if _job_id and vim.fn.jobwait({ _job_id }, 0) == -1 then
    return true
  end

  local binary = find_binary()
  if not binary or binary == "" then return false end

  _job_id = vim.fn.jobstart({ binary, "context", "serve" }, {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data, _event_type)
      if not data then return end
      for _, chunk in ipairs(data) do
        if chunk then
          _buf = _buf .. chunk
        end
      end
      while true do
        local nl = _buf:find("\n")
        if not nl then break end
        local line = _buf:sub(1, nl - 1)
        _buf = _buf:sub(nl + 1)
        if line ~= "" then
          local ok, parsed = pcall(vim.json.decode, line)
          if ok and parsed and type(parsed) == "table" and parsed.id then
            local cb = _callbacks[parsed.id]
            _callbacks[parsed.id] = nil
            if cb then
              vim.schedule(function()
                cb(parsed)
              end)
            end
          end
        end
      end
    end,
    on_stderr = function(_, data, _event_type)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then
          state.log("WARN", "[context_client stderr] " .. l)
        end
      end
    end,
    on_exit = function(_, _code, _event_type)
      _job_id = nil
      -- Flush pending callbacks with nil results (server died)
      local pending = _callbacks
      _callbacks = {}
      vim.schedule(function()
        for _, cb in pairs(pending) do
          cb(nil)
        end
      end)
      -- Auto-restart (unless explicitly stopped)
      if not _stopped then
        vim.defer_fn(function()
          start()
        end, 100)
      end
    end,
  })

  if _job_id <= 0 then
    _job_id = nil
    return false
  end
  return true
end

function M.stop()
  _stopped = true
  _callbacks = {}
  if _job_id then
    vim.fn.jobstop(_job_id)
    _job_id = nil
  end
end

local function send(method, params, cb)
  if _stopped then
    if cb then cb(nil) end
    return
  end

  if not start() then
    if cb then cb(nil) end
    return
  end

  local id = _next_id
  _next_id = _next_id + 1
  _callbacks[id] = cb

  local req = vim.json.encode({
    id = id,
    method = method,
    params = params,
  })

  vim.fn.chansend(_job_id, req .. "\n")
end

--- Detect completion context at cursor position.
---@param sql string Full SQL text of the block
---@param offset number Byte offset of cursor (0-based)
---@param dialect string|nil "generic", "postgres", "mysql", "sqlite"
---@param cb function|nil Callback with parsed response table or nil on failure
function M.detect(sql, offset, dialect, cb)
  if type(dialect) == "function" then
    cb = dialect
    dialect = "generic"
  end
  send("detect", { sql = sql, offset = offset, dialect = dialect or "generic" }, cb)
end

--- Find statement boundaries for a cursor line.
---@param sql string Full SQL text
---@param cursor_line number 0-based cursor line number
---@param cb function|nil Callback with parsed response table or nil on failure
function M.stmt(sql, cursor_line, cb)
  send("stmt", { sql = sql, cursor_line = cursor_line }, cb)
end

--- Get the underlying job ID (for testing).
function M._job_id()
  return _job_id
end

return M
