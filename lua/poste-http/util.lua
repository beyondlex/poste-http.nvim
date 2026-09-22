local M = {}
local hover_tracker = nil

-- LuaJIT seeds math.random deterministically at process start: without an
-- explicit seed every nvim session produced the SAME sequence, so the first
-- {{$uuid}}/{{$randomInt}}/{{$timestamp}} repeated across runs — idempotency
-- keys colliding run over run. Seed once, on first use, from the wall clock
-- + the monotonic clock + the pid: two processes started in the same second
-- still differ.
M._random_seeded = false

--- Seed the global PRNG exactly once per session (a no-op afterwards).
function M.seed_random()
  if M._random_seeded then return end
  M._random_seeded = true
  local uv = vim.uv or vim.loop
  local mono_ms = uv and math.floor((uv.hrtime() / 1000000) % 1000000) or 0
  math.randomseed(os.time() * 31 + vim.fn.getpid() * 1000003 + mono_ms)
end

--- Recursively convert decoded JSON to pure Lua tables, avoiding userdata/cdata.
--- `vim.json.decode` may return `vim.NIL` or cdata wrappers depending on
--- the Neovim build; this normalizes to plain `nil` and plain Lua tables.
--- @param v any
--- @return any
function M.json_to_table(v)
  if v == vim.NIL then return nil end
  local t = type(v)
  if t == "table" then
    local r = {}
    for k, v2 in pairs(v) do
      r[k] = M.json_to_table(v2)
    end
    return r
  end
  return v
end

function M.clean_nil(t)
  if not t or type(t) ~= "table" then return t end
  for k, v in pairs(t) do
    if v == vim.NIL then
      t[k] = nil
    elseif type(v) == "table" then
      M.clean_nil(v)
    end
  end
  return t
end

function M.find_file_upwards(filename, start_dir)
  if not filename or filename == "" then return nil end
  local dir = start_dir or vim.fn.getcwd()
  while true do
    local candidate = dir .. "/" .. filename
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      return nil
    end
    dir = parent
  end
end

function M.ensure_job_data(data)
  if not data or type(data) ~= "table" then return {} end
  while #data > 0 and data[#data] == "" do
    data[#data] = nil
  end
  return data
end

--- Stateful re-assembler for unbuffered job stdout (`stdout_buffered = false`).
--- nvim delivers each callback's `data` as a list whose last element is a
--- fragment when the chunk ended without a newline; treating every element
--- as a line splits any frame that arrives across multiple reads. Feed each
--- callback's data to `feed` and call `flush` once the job exits.
function M.line_splitter()
  local carry = ""
  local self = {}
  function self.feed(data, on_line)
    if not data or type(data) ~= "table" then return end
    for i = 1, #data do
      local piece = data[i]
      if i < #data then
        on_line(carry .. piece)
        carry = ""
      elseif piece ~= "" then
        carry = carry .. piece
      end
    end
  end
  function self.flush(on_line)
    if carry ~= "" then
      on_line(carry)
      carry = ""
    end
  end
  return self
end

--- Current wall-clock timestamp with milliseconds: "YYYY-MM-DD HH:MM:SS.mmm".
--- Falls back to second precision when gettimeofday is unavailable.
function M.timestamp()
  local uv = vim.uv or vim.loop
  if uv and uv.gettimeofday then
    local sec, usec = uv.gettimeofday()
    if sec then
      local ms = math.floor((usec or 0) / 1000)
      return os.date("%Y-%m-%d %H:%M:%S", sec) .. string.format(".%03d", ms)
    end
  end
  return os.date("%Y-%m-%d %H:%M:%S")
end

--- Redact query-string parameter values from a URL for safe logging.
--- Preserves the path; masks every `key=` value as `key=[REDACTED]`.
--- Leaves URLs without a query unchanged.
function M.redact_url_query(url)
  if not url or url == "" then return url end
  local base, query = url:match("^([^?]+)%?(.*)$")
  if not base then return url end
  local parts = {}
  for kv in query:gmatch("[^&]+") do
    local k = kv:match("^([^=]*)=")
    if k then
      table.insert(parts, k .. "=[REDACTED]")
    else
      table.insert(parts, kv)
    end
  end
  return base .. "?" .. table.concat(parts, "&")
end

--- Header names whose values must not appear in command logs.
--- Shared by every protocol executor (curl, grpcurl, websocat): metadata
--- and headers carry credentials just like HTTP headers do.
M.SENSITIVE_HEADERS = {
  ["authorization"] = true,
  ["proxy-authorization"] = true,
  ["cookie"] = true,
  ["set-cookie"] = true,
  ["x-api-key"] = true,
  ["api-key"] = true,
}

--- Redact user:pass@ in a URL's authority (poste-mq util.redact_url rule:
--- split at the LAST @ so a bare @ inside a password leaks nothing, scoped
--- to the authority so path @s stay untouched). URLs without userinfo are
--- returned unchanged.
function M.redact_url_userinfo(url)
  if type(url) ~= "string" then return url end
  local scheme, rest = url:match("^(%w+)://(.*)$")
  if not scheme then return url end
  local authority, tail = rest:match("^([^/?]*)(.*)$")
  local userinfo, hostport = authority:match("^(.*)@(.+)$")
  if userinfo and userinfo:find(":", 1, true) then
    local user = userinfo:match("^[^:]*")
    authority = user .. ":***@" .. hostport
  end
  return scheme .. "://" .. authority .. (tail or "")
end

--- Shell-escape a single argument. Safe characters pass through unquoted.
function M.shell_escape(s)
  if not s or s == "" then return "''" end
  if s:match("^[a-zA-Z0-9_./:=-]+$") then
    return s
  end
  local escaped = s:gsub("'", "'\\''")
  return "'" .. escaped .. "'"
end

--- Render an argv list as a log-safe command string.
--- Values of sensitive headers (see M.SENSITIVE_HEADERS) are replaced with
--- [REDACTED]; -u/--user values are credentials outright; URL-shaped
--- arguments get their userinfo masked; every argument is shell-escaped.
function M.redacted_cmd(args)
  if not args then return "" end
  local parts = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if (a == "-H" or a == "--header") and args[i + 1] then
      local raw = args[i + 1]
      local k = raw:match("^([^:]+):%s*")
      if k and M.SENSITIVE_HEADERS[k:lower()] then
        table.insert(parts, M.shell_escape(a))
        table.insert(parts, M.shell_escape(k .. ": [REDACTED]"))
        i = i + 1
      else
        table.insert(parts, M.shell_escape(a))
        table.insert(parts, M.shell_escape(raw))
        i = i + 1
      end
    elseif (a == "-u" or a == "--user") and args[i + 1] then
      table.insert(parts, M.shell_escape(a))
      table.insert(parts, M.shell_escape("***"))
      i = i + 1
    else
      local shown = a
      if type(a) == "string" and a:match("^%w+://") then
        shown = M.redact_url_userinfo(a)
      end
      table.insert(parts, M.shell_escape(shown))
    end
    i = i + 1
  end
  return table.concat(parts, " ")
end

--- Open a markdown doc preview in a floating window.
--- Returns float_buf, win, reused (boolean — true if an existing tracked window was re-focused).
--- opts:
---   title     - window title (optional)
---   track_key - unique key for hover re-focus (optional)
---   on_close  - callback invoked when the window is closed via q/<Esc>
function M.open_doc_preview(lines, opts)
  opts = opts or {}

  if opts.track_key then
    if hover_tracker and vim.api.nvim_win_is_valid(hover_tracker.win) then
      if hover_tracker.key == opts.track_key then
        vim.api.nvim_set_current_win(hover_tracker.win)
        return hover_tracker.buf, hover_tracker.win, true
      end
      pcall(vim.api.nvim_win_close, hover_tracker.win, true)
      hover_tracker = nil
    end
  end

  local float_buf, win
  local ok
  ok, float_buf, win = pcall(vim.lsp.util.open_floating_preview, lines, "markdown", {
    border = "single",
    title = opts.title,
    title_pos = "left",
    focusable = false,
  })
  if not ok or not float_buf then
    ok, float_buf, win = pcall(vim.lsp.util.open_floating_preview, lines, "markdown", {
      border = "single",
      focusable = false,
    })
    if not ok or not float_buf then
      return nil, nil, false
    end
  end

  if opts.track_key then
    hover_tracker = { win = win, buf = float_buf, key = opts.track_key }
    local hover_group = vim.api.nvim_create_augroup("PosteHoverWin_" .. win, { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
      group = hover_group,
      pattern = tostring(win),
      callback = function() hover_tracker = nil end,
    })
  end

  local function close()
    pcall(vim.api.nvim_win_close, win, true)
    if opts.track_key then hover_tracker = nil end
    if opts.on_close then opts.on_close() end
  end

  vim.keymap.set("n", "q", close, { buffer = float_buf, noremap = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = float_buf, noremap = true, silent = true })

  return float_buf, win, false
end

return M