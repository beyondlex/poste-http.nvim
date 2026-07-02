--- Lua documentation provider for script blocks.
--- Tries lua-language-server (LSP) via a hidden Lua buffer first.
--- Falls back to built-in Lua 5.1 standard library docs if LSP unavailable.
local state = require("poste.state")

local M = {}

-- Hidden Lua buffer used for LSP textDocument/hover requests
local lsp_buf = nil

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function M.setup()
  if lsp_buf and vim.api.nvim_buf_is_valid(lsp_buf) then return end
  lsp_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[lsp_buf].swapfile = false
  local buf_name = vim.fn.getcwd() .. "/.poste_lua_docs_tmp.lua"
  pcall(vim.api.nvim_buf_set_name, lsp_buf, buf_name)
  vim.bo[lsp_buf].filetype = "lua"
  state._lsp_doc_buf = lsp_buf
  -- Pre-start lua-language-server so the first K press is responsive
  M._ensure_lua_ls_running()
end

--- Start lua-language-server in background (if not already running).
--- Called during setup for preload; also used by ensure_lsp_attached.
function M._ensure_lua_ls_running()
  if M._start_attempted then return end
  M._start_attempted = true

  -- Reuse existing client
  for _, client in ipairs(vim.lsp.get_clients()) do
    if client.name == "lua_ls" then return end
  end

  if vim.fn.executable("lua-language-server") ~= 1 then return false end

  pcall(vim.lsp.start_client, {
    name = "lua_ls",
    cmd = { "lua-language-server" },
    root_dir = vim.fn.getcwd(),
  })
end

function M.get_buf()
  if not lsp_buf or not vim.api.nvim_buf_is_valid(lsp_buf) then
    M.setup()
  end
  return lsp_buf
end

---------------------------------------------------------------------------
-- Script block extraction from .http buffer
---------------------------------------------------------------------------

--- Extract Lua code lines from the enclosing script block and map cursor
--- position into Lua-buffer coordinates.
--- @return lines string[]|nil  Lua code lines (1 per element)
--- @return lua_line integer|nil  1-based line within Lua code
--- @return lua_col  integer|nil  1-based column within Lua code
function M.extract_script_block(buf, cursor_line, cursor_col)
  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local total = #all_lines

  -- Walk backwards to find opening marker
  local block_start = nil
  local lua_start_col = nil
  for i = math.min(cursor_line, total), 1, -1 do
    local line = all_lines[i] or ""
    local s1, e1 = line:find("<%s*{%%%s*")
    if s1 then
      block_start = i
      lua_start_col = e1 + 1
      break
    end
    local s2, e2 = line:find(">%s*{%%%s*")
    if s2 then
      block_start = i
      lua_start_col = e2 + 1
      break
    end
  end
  if not block_start then return nil end

  -- Walk forwards to find closing marker
  local block_end = nil
  for i = block_start, total do
    local line = all_lines[i] or ""
    if line:find("%%}") then
      block_end = i
      break
    end
  end
  if not block_end then return nil end

  -- Extract Lua lines and map cursor
  local lua_lines = {}
  local cursor_lua_line = nil
  local cursor_lua_col = nil
  for i = block_start, block_end do
    local raw = all_lines[i] or ""
    local col = 1
    if i == block_start then
      col = lua_start_col
    end
    if i == block_end then
      local close_pos = raw:find("%%}")
      local content = close_pos and raw:sub(col, close_pos - 1) or raw:sub(col)
      table.insert(lua_lines, content)
      if i == cursor_line then
        cursor_lua_line = #lua_lines
        cursor_lua_col = math.min(math.max(cursor_col - col + 1, 1), #content + 1)
      end
    else
      local content = raw:sub(col)
      table.insert(lua_lines, content)
      if i == cursor_line then
        cursor_lua_line = #lua_lines
        cursor_lua_col = cursor_col - col + 1
      end
    end
  end

  if not cursor_lua_line then
    cursor_lua_line = 1
    cursor_lua_col = 1
  end
  if cursor_lua_col < 1 then cursor_lua_col = 1 end

  return lua_lines, cursor_lua_line, cursor_lua_col
end

---------------------------------------------------------------------------
-- LSP hover via hidden Lua buffer
---------------------------------------------------------------------------

--- Attach a lua-language-server client to our hidden buffer.
--- The client is pre-started during setup; if it didn't start, tries again.
--- Returns true if a client is attached (or was already attached).
function M.ensure_lsp_attached()
  local buf = M.get_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return false end

  local bufc = vim.lsp.buf_get_clients(buf)
  if bufc and next(bufc) then return true end

  -- Ensure server is (or was attempted to be) running
  M._ensure_lua_ls_running()

  -- Attach existing lua_ls client to our buffer
  for _, client in ipairs(vim.lsp.get_clients()) do
    if client.name == "lua_ls" then
      local ok, _ = pcall(vim.lsp.buf_attach_client, buf, client.id)
      if ok then return true end
    end
  end

  return false
end

--- Try LSP hover and call callback with formatted lines or nil.
--- Does NOT rely on automatic LSP attach; explicitly finds + attaches
--- an existing lua-language-server client.
function M.try_lsp_hover(script_lines, line, col, callback)
  local buf = M.get_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, script_lines)

  if not M.ensure_lsp_attached() then
    callback(nil)
    return
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    position = { line = line - 1, character = math.max(col - 1, 0) },
  }

  vim.lsp.buf_request(buf, "textDocument/hover", params, function(err, result)
    if err or not result or not result.contents then
      callback(nil)
      return
    end
    local lines = {}
    local function add(v)
      if v then
        for _, l in ipairs(vim.split(tostring(v), "\n", { plain = true })) do
          table.insert(lines, l)
        end
      end
    end
    if type(result.contents) == "string" then
      add(result.contents)
    elseif type(result.contents) == "table" then
      if result.contents.kind and result.contents.value then
        add(result.contents.value)
      else
        for _, item in ipairs(result.contents) do
          if type(item) == "string" then
            add(item)
          elseif type(item) == "table" then
            add(item.value)
          end
        end
      end
    end
    callback(#lines > 0 and lines or nil)
  end)
end

--- Render LSP result in a floating window.
function M.show_lsp_result(lines)
  if not lines or #lines == 0 then return end

  local max_width = math.min(math.floor(vim.o.columns * 0.7), 80)
  local width = 2
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 4, max_width)
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.4))

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].modifiable = false
  vim.bo[float_buf].filetype = "markdown"

  local win_opts = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Lua API ",
    title_pos = "left",
  }
  local ok, win = pcall(vim.api.nvim_open_win, float_buf, true, win_opts)
  if not ok then
    win_opts.title = nil
    win_opts.title_pos = nil
    win = vim.api.nvim_open_win(float_buf, true, win_opts)
  end

  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = float_buf, noremap = true, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = float_buf, noremap = true, silent = true })
end

--- Show built-in documentation in a floating window.
function M.show_builtin(sig, desc, title)
  local lines = {}
  table.insert(lines, sig)
  table.insert(lines, "")
  table.insert(lines, desc)

  local max_width = math.min(math.floor(vim.o.columns * 0.7), 80)
  local width = 2
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 4, max_width)
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.4))

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].modifiable = false

  local win_opts = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. (title or "Lua API") .. " ",
    title_pos = "left",
  }
  local ok, win = pcall(vim.api.nvim_open_win, float_buf, true, win_opts)
  if not ok then
    win_opts.title = nil
    win_opts.title_pos = nil
    win = vim.api.nvim_open_win(float_buf, true, win_opts)
  end

  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = float_buf, noremap = true, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = float_buf, noremap = true, silent = true })
end

---------------------------------------------------------------------------
-- Built-in Lua 5.1 standard library documentation (fallback)
---------------------------------------------------------------------------
--- Map bare method names to their module-qualified keys so that
--- `str:match(...)` with cursor on `match` finds "string.match".
local method_module = {
  byte = "string", char = "string", find = "string", format = "string",
  gmatch = "string", gsub = "string", len = "string", lower = "string",
  match = "string", rep = "string", reverse = "string", sub = "string",
  upper = "string",
  concat = "table", insert = "table", maxn = "table", remove = "table",
  sort = "table",
}

--- Look up an identifier in the built-in docs table.
--- Handles dotted paths (os.time), module access (string.match),
--- and bare method names (match → string.match).
function M.lookup_builtin(identifier)
  local docs = M.lua_docs
  if docs[identifier] then return docs[identifier] end
  -- Try bare method name as module.method
  local mod = method_module[identifier]
  if mod then
    local qualified = mod .. "." .. identifier
    if docs[qualified] then return docs[qualified] end
  end
  -- Walk up: os.time → os
  local lookup = identifier
  while lookup and not docs[lookup] do
    local dot = lookup:match("^(.+)%.[^%.]+$")
    if dot then lookup = dot else break end
  end
  return docs[lookup]
end

--- Match root module/global name. Returns true if it's a Lua standard lib.
function M.is_lua_identifier(identifier)
  local root = identifier:match("^([%w_]+)")
  if not root then return false end
  local lua_roots = {
    string = true, table = true, math = true, os = true, io = true,
    tostring = true, tonumber = true, type = true, error = true,
    pcall = true, ipairs = true, pairs = true, assert = true,
  }
  if lua_roots[root] then return true end
  -- Also match bare method names
  return method_module[root] ~= nil
end

M.lua_docs = {
  -- Global functions
  tostring = { sig = "tostring(v)", desc = "Convert value to string." },
  tonumber = { sig = "tonumber(v [, base])", desc = "Convert value to number. Optional base (2-36) for string conversion." },
  type = { sig = "type(v)", desc = "Return type name as string: 'nil', 'number', 'string', 'boolean', 'table', 'function', 'thread', 'userdata'." },
  error = { sig = "error(msg [, level])", desc = "Raise an error. Level 1 (default) reports the caller's location." },
  pcall = { sig = "pcall(f [, ...])", desc = "Protected call. Returns (true, ...) on success or (false, err) on error." },
  ipairs = { sig = "ipairs(t)", desc = "Iterator for array-like tables (indices 1..n)." },
  pairs = { sig = "pairs(t)", desc = "Iterator over all key-value pairs." },
  assert = { sig = "assert(v [, msg])", desc = "Assert value is truthy; raises error with optional message if not." },

  -- string.*
  string = { sig = "string", desc = "String manipulation library." },
  ["string.byte"] = { sig = "string.byte(s [, i [, j]])", desc = "Return internal numeric codes of s[i..j]." },
  ["string.char"] = { sig = "string.char(...)", desc = "Return string from integer codes." },
  ["string.find"] = { sig = "string.find(s, p [, i [, plain]])", desc = "Find first match of pattern p in s starting at i. Returns start,end or nil." },
  ["string.format"] = { sig = "string.format(fmt, ...)", desc = "Format string (printf-style). %s %d %f %x %%. " },
  ["string.gmatch"] = { sig = "string.gmatch(s, p)", desc = "Iterator over pattern p matches." },
  ["string.gsub"] = { sig = "string.gsub(s, p, r [, n])", desc = "Global substitution. Returns result + number of replacements." },
  ["string.len"] = { sig = "string.len(s)", desc = "Length of string (deprecated; use #s)." },
  ["string.lower"] = { sig = "string.lower(s)", desc = "Convert to lowercase." },
  ["string.match"] = { sig = "string.match(s, p [, i])", desc = "Match pattern; returns captures or full match." },
  ["string.rep"] = { sig = "string.rep(s, n)", desc = "Repeat string n times." },
  ["string.reverse"] = { sig = "string.reverse(s)", desc = "Reverse string." },
  ["string.sub"] = { sig = "string.sub(s, i [, j])", desc = "Substring from i to j. Negative indices count from end." },
  ["string.upper"] = { sig = "string.upper(s)", desc = "Convert to uppercase." },

  -- table.*
  table = { sig = "table", desc = "Table manipulation library." },
  ["table.concat"] = { sig = "table.concat(t [, sep [, i [, j]]])", desc = "Join t[i..j] with separator." },
  ["table.insert"] = { sig = "table.insert(t [, pos], v)", desc = "Insert value at position (default: end)." },
  ["table.maxn"] = { sig = "table.maxn(t)", desc = "Largest numeric index (deprecated in 5.2+)." },
  ["table.remove"] = { sig = "table.remove(t [, pos])", desc = "Remove and return element at pos (default: last)." },
  ["table.sort"] = { sig = "table.sort(t [, comp])", desc = "Sort table in-place. Optional comparator(a,b)." },

  -- math.*
  math = { sig = "math", desc = "Mathematical functions." },
  ["math.abs"] = { sig = "math.abs(x)", desc = "Absolute value." },
  ["math.acos"] = { sig = "math.acos(x)", desc = "Arc cosine (radians)." },
  ["math.asin"] = { sig = "math.asin(x)", desc = "Arc sine (radians)." },
  ["math.atan"] = { sig = "math.atan(x)", desc = "Arc tangent (radians)." },
  ["math.atan2"] = { sig = "math.atan2(y, x)", desc = "Arc tangent of y/x (radians)." },
  ["math.ceil"] = { sig = "math.ceil(x)", desc = "Smallest integer >= x." },
  ["math.cos"] = { sig = "math.cos(x)", desc = "Cosine of x (radians)." },
  ["math.cosh"] = { sig = "math.cosh(x)", desc = "Hyperbolic cosine." },
  ["math.deg"] = { sig = "math.deg(x)", desc = "Convert radians to degrees." },
  ["math.exp"] = { sig = "math.exp(x)", desc = "e^x." },
  ["math.floor"] = { sig = "math.floor(x)", desc = "Largest integer <= x." },
  ["math.fmod"] = { sig = "math.fmod(x, y)", desc = "Remainder of x/y." },
  ["math.frexp"] = { sig = "math.frexp(x)", desc = "Returns (m, e) such that x = m*2^e." },
  ["math.huge"] = { sig = "math.huge", desc = "Float value representing infinity." },
  ["math.ldexp"] = { sig = "math.ldexp(m, e)", desc = "Returns m*2^e." },
  ["math.log"] = { sig = "math.log(x)", desc = "Natural logarithm." },
  ["math.log10"] = { sig = "math.log10(x)", desc = "Base-10 logarithm." },
  ["math.max"] = { sig = "math.max(x, ...)", desc = "Maximum value." },
  ["math.min"] = { sig = "math.min(x, ...)", desc = "Minimum value." },
  ["math.modf"] = { sig = "math.modf(x)", desc = "Returns (integer_part, fractional_part)." },
  ["math.pi"] = { sig = "math.pi", desc = "Value of PI." },
  ["math.pow"] = { sig = "math.pow(x, y)", desc = "x^y." },
  ["math.rad"] = { sig = "math.rad(x)", desc = "Convert degrees to radians." },
  ["math.random"] = { sig = "math.random([m [, n]])", desc = "Pseudo-random number. 0-1, 1-n, or m-n." },
  ["math.randomseed"] = { sig = "math.randomseed(x)", desc = "Seed the random generator." },
  ["math.sin"] = { sig = "math.sin(x)", desc = "Sine of x (radians)." },
  ["math.sinh"] = { sig = "math.sinh(x)", desc = "Hyperbolic sine." },
  ["math.sqrt"] = { sig = "math.sqrt(x)", desc = "Square root." },
  ["math.tan"] = { sig = "math.tan(x)", desc = "Tangent of x (radians)." },
  ["math.tanh"] = { sig = "math.tanh(x)", desc = "Hyperbolic tangent." },

  -- os.*
  os = { sig = "os", desc = "Operating system facilities." },
  ["os.clock"] = { sig = "os.clock()", desc = "CPU time in seconds." },
  ["os.date"] = { sig = "os.date([fmt [, t]])", desc = "Format date (default: current). See Lua manual for fmt." },
  ["os.difftime"] = { sig = "os.difftime(t2, t1)", desc = "Difference t2-t1 in seconds." },
  ["os.execute"] = { sig = "os.execute([cmd])", desc = "Execute shell command. Returns status code." },
  ["os.exit"] = { sig = "os.exit([code [, close]])", desc = "Exit the program." },
  ["os.getenv"] = { sig = "os.getenv(varname)", desc = "Get environment variable." },
  ["os.remove"] = { sig = "os.remove(filename)", desc = "Delete file." },
  ["os.rename"] = { sig = "os.rename(old, new)", desc = "Rename file." },
  ["os.setlocale"] = { sig = "os.setlocale(locale [, category])", desc = "Set the current locale." },
  ["os.time"] = { sig = "os.time([t])", desc = "Current time as timestamp. Optional table {year, month, day, ...}." },
  ["os.tmpname"] = { sig = "os.tmpname()", desc = "Return tmp file name." },

  -- io.*
  io = { sig = "io", desc = "I/O library." },
  ["io.close"] = { sig = "io.close([file])", desc = "Close file (default: output)." },
  ["io.flush"] = { sig = "io.flush()", desc = "Flush output buffer." },
  ["io.input"] = { sig = "io.input([file])", desc = "Set/get input file." },
  ["io.lines"] = { sig = "io.lines([filename])", desc = "Iterator over file lines." },
  ["io.open"] = { sig = "io.open(filename [, mode])", desc = "Open file. Modes: 'r', 'w', 'a', 'r+', 'w+', 'a+', 'b' suffix." },
  ["io.output"] = { sig = "io.output([file])", desc = "Set/get output file." },
  ["io.popen"] = { sig = "io.popen([prog [, mode]])", desc = "Run program and return file handle." },
  ["io.read"] = { sig = "io.read(...)", desc = "Read from input. Formats: '*a', '*n', '*l', '*L', or number." },
  ["io.stderr"] = { sig = "io.stderr", desc = "Standard error file handle." },
  ["io.stdin"] = { sig = "io.stdin", desc = "Standard input file handle." },
  ["io.stdout"] = { sig = "io.stdout", desc = "Standard output file handle." },
  ["io.tmpfile"] = { sig = "io.tmpfile()", desc = "Return temp file handle (delete on close)." },
  ["io.type"] = { sig = "io.type(obj)", desc = "Return 'file', 'closed file', or nil." },
  ["io.write"] = { sig = "io.write(...)", desc = "Write values to output." },

  -- file handle methods (returned by io.open)
  ["file:close"] = { sig = "file:close()", desc = "Close file." },
  ["file:flush"] = { sig = "file:flush()", desc = "Flush file output." },
  ["file:lines"] = { sig = "file:lines()", desc = "Iterator over file lines." },
  ["file:read"] = { sig = "file:read(...)", desc = "Read from file. Formats: '*a', '*n', '*l', number." },
  ["file:seek"] = { sig = "file:seek([whence] [, offset])", desc = "Set file position. whence: 'set', 'cur', 'end'." },
  ["file:setvbuf"] = { sig = "file:setvbuf(mode [, size])", desc = "Set buffering. mode: 'no', 'full', 'line'." },
  ["file:write"] = { sig = "file:write(...)", desc = "Write values to file." },
}

---------------------------------------------------------------------------
-- Main entry point
---------------------------------------------------------------------------

--- Show documentation for a Lua identifier inside a script block.
--- Tries LSP first, falls back to built-in docs.
--- @param buf number  .http source buffer
--- @param cursor_line number  1-indexed line in .http buffer
--- @param cursor_col number  1-indexed column in .http buffer
--- @param identifier string  full dotted identifier under cursor
function M.show_doc(buf, cursor_line, cursor_col, identifier)
  -- Bare method names (find, match, gsub, etc.) — query LSP with the
  -- qualified name (string.find) so LSP resolves the rich docs.
  -- Falls back to built-in if LSP unavailable.
  if method_module[identifier] then
    local qualified = method_module[identifier] .. "." .. identifier
    local lsp_col = #method_module[identifier] + 2
    M.try_lsp_hover({ qualified }, 1, lsp_col, function(result)
      if result then
        M.show_lsp_result(result)
      else
        M.show_builtin_fallback(identifier)
      end
    end)
    return
  end
  local lines, lua_line, lua_col = M.extract_script_block(buf, cursor_line, cursor_col)
  if lines then
    M.try_lsp_hover(lines, lua_line, lua_col, function(result)
      if result then
        M.show_lsp_result(result)
      else
        M.show_builtin_fallback(identifier)
      end
    end)
  else
    M.show_builtin_fallback(identifier)
  end
end

function M.show_builtin_fallback(identifier)
  local entry = M.lookup_builtin(identifier)
  if entry then
    M.show_builtin(entry.sig, entry.desc, "Lua API")
  end
end

return M
