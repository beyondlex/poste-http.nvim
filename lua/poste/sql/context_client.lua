--- Persistent context client — manages a `poste context serve` subprocess.
--- Designed for non-critical background I/O (introspection, data pre-fetching).
--- NOT used on the completion hot path — that uses `vim.fn.system()`.
local state = require("poste.state")

local M = {}

local _job_id = nil
local _next_id = 1
local _callbacks = {}
local _buf = ""
local _stopped = false
local _restart_attempts = 0
local _restart_timer = nil

local MAX_RESTART_DELAY_MS = 5000
local RESTART_BASE_DELAY_MS = 200

local function find_binary()
  if state.config and state.config.poste_binary ~= ""
      and vim.fn.filereadable(state.config.poste_binary) == 1 then
    return vim.fn.fnamemodify(state.config.poste_binary, ":p")
  end
  local paths = {}
  -- CWD-relative: highest priority (works when nvim is launched from repo root)
  local cwd = vim.fn.getcwd()
  if cwd ~= "" then
    table.insert(paths, cwd .. "/target/debug/poste")
    table.insert(paths, cwd .. "/target/release/poste")
  end
  -- Resolve relative to this file's dir (plugin install or repo)
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

local function schedule_restart()
  if _stopped or _restart_timer then return end
  _restart_attempts = _restart_attempts + 1
  local delay = math.min(
    RESTART_BASE_DELAY_MS * (2 ^ (_restart_attempts - 1)),
    MAX_RESTART_DELAY_MS
  )
  _restart_timer = vim.defer_fn(function()
    _restart_timer = nil
    start()  -- luacheck: ignore 113
  end, delay)
end

local function start()
  if _stopped then return false end

  if _job_id then
    local running = vim.fn.jobwait({ _job_id }, 0) == -1
    if running then return true end
    _job_id = nil
  end

  local binary = find_binary()
  if not binary or binary == "" then return false end

  local ok, new_id = pcall(vim.fn.jobstart, { binary, "context", "serve" }, {
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
          local ok_p, parsed = pcall(vim.json.decode, line)
          if ok_p and parsed and type(parsed) == "table" and parsed.id then
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
      _restart_attempts = _restart_attempts + 1
      _job_id = nil
      local pending = _callbacks
      _callbacks = {}
      vim.schedule(function()
        for _, cb in pairs(pending) do
          cb(nil)
        end
      end)
      if not _stopped then
        schedule_restart()
      end
    end,
  })

  if not ok or new_id <= 0 then return false end

  _job_id = new_id
  _restart_attempts = 0
  return true
end

function M.stop()
  _stopped = true
  _callbacks = {}
  if _restart_timer then
    vim.fn.timer_stop(_restart_timer)
    _restart_timer = nil
  end
  if _job_id then
    local jid = _job_id
    _job_id = nil
    pcall(vim.fn.jobstop, jid)
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
