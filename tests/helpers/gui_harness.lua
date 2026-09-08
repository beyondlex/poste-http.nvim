--- GUI harness for testing Neovim GUI-coupled modules.
---
--- Provides stateful mocks for buffers, windows, autocmds, keymaps,
--- user commands, and options.  Designed for headless plenary busted tests.
---
--- Usage:
---   local harness = require("helpers.gui_harness")
---   before_each(function() harness.setup() end)
---   after_each(function() harness.teardown() end)

local M = {}

local _originals = {}
local _bufs = {}
local _wins = {}
local _next_buf = 1001
local _next_win = 2001
local _cur_buf = 0
local _cur_win = 0
local _autocmds = {}
local _keymaps = {}
local _user_cmds = {}
local _bo = {}
local _wo = {}
local _o = {}

local function is_buf_valid(buf)
  return _bufs[buf] ~= nil and _bufs[buf].valid ~= false
end

local function is_win_valid(win)
  return _wins[win] ~= nil and _wins[win].valid ~= false
end

local function ensure_buf(buf)
  if not _bo[buf] then _bo[buf] = {} end
  return _bo[buf]
end

local function ensure_win(win)
  if not _wo[win] then _wo[win] = {} end
  return _wo[win]
end

local function as_buf_arg(buf)
  if buf == 0 or buf == nil then return _cur_buf end
  return buf
end

local function as_win_arg(win)
  if win == 0 or win == nil then return _cur_win end
  return win
end

M.calls = {}

function M.reset_calls()
  M.calls = {}
end

function M.get_bufs()
  return _bufs
end

function M.get_wins()
  return _wins
end

function M.get_autocmds()
  return _autocmds
end

function M.get_keymaps(buf)
  if buf then return _keymaps[buf] end
  return _keymaps
end

function M.get_user_commands()
  return _user_cmds
end

function M.fire_autocmd(events, opts)
  opts = opts or {}
  for _, entry in ipairs(_autocmds) do
    local match_events = false
    if type(entry.events) == "string" and entry.events == events then
      match_events = true
    elseif type(entry.events) == "table" then
      for _, e in ipairs(entry.events) do
        if e == events then match_events = true; break end
      end
    end
    if not match_events then goto continue end
    if entry.opts and entry.opts.buffer then
      local target = entry.opts.buffer
      local effective = target == 0 and _cur_buf or target
      if effective ~= opts.buf then goto continue end
    end
    local ok, cb = pcall(function()
      return entry.opts and entry.opts.callback or entry.callback
    end)
    if ok and cb then
      pcall(cb, { buf = opts.buf or _cur_buf, file = opts.file })
    end
    ::continue::
  end
end

local function save_fn(name)
  _originals[name] = vim.api[name]
end

function M.setup(opts)
  opts = opts or {}
  M.reset_calls()

  _bufs = {}
  _wins = {}
  _next_buf = opts.next_buf or 1001
  _next_win = opts.next_win or 2001
  _cur_buf = 0
  _cur_win = 0
  _autocmds = {}
  _keymaps = {}
  _user_cmds = {}
  _bo = {}
  _wo = {}
  _o = {
    lines = 24,
    columns = 80,
  }

  _originals = {}
  _originals.vim_fn = vim.fn
  _originals.vim_uv = vim.uv
  _originals.vim_loop = vim.loop
  _originals.vim_cmd = vim.cmd
  _originals.vim_schedule = vim.schedule
  _originals.vim_keymap = vim.keymap
  _originals.vim_bo = vim.bo
  _originals.vim_wo = vim.wo
  _originals.vim_o = vim.o
  _originals.vim_base64 = vim.base64
  _originals.vim_notify = vim.notify
  _originals.vim_defer_fn = vim.defer_fn

  -- Save vim.fn functions we'll override
  _originals.vim_fn_sign_define = vim.fn.sign_define
  _originals.vim_fn_sign_place = vim.fn.sign_place
  _originals.vim_fn_sign_unplace = vim.fn.sign_unplace
  _originals.vim_fn_bufwinid = vim.fn.bufwinid
  _originals.vim_fn_executable = vim.fn.executable
  _originals.vim_fn_systemlist = vim.fn.systemlist
  _originals.vim_fn_setreg = vim.fn.setreg
  _originals.vim_fn_fnamemodify = vim.fn.fnamemodify
  _originals.vim_fn_stdpath = vim.fn.stdpath
  _originals.vim_fn_line = vim.fn.line
  _originals.vim_fn_strdisplaywidth = vim.fn.strdisplaywidth
  _originals.vim_fn_strcharpart = vim.fn.strcharpart
  _originals.vim_fn_strchars = vim.fn.strchars
  _originals.vim_fn_getcwd = vim.fn.getcwd

  -- Create a default buffer and window
  local default_buf = _next_buf; _next_buf = _next_buf + 1
  _bufs[default_buf] = { lines = { "" }, valid = true, ns_extmarks = {} }
  _cur_buf = default_buf
  _bo[default_buf] = { filetype = "poste_http", modifiable = true, buftype = "" }

  local default_win = _next_win; _next_win = _next_win + 1
  _wins[default_win] = { buf = default_buf, valid = true, width = 80, height = 24, cursor = { 1, 0 } }
  _cur_win = default_win
  _wo[default_win] = { winbar = "", foldmethod = "manual", foldlevel = 99, foldcolumn = "0" }

  save_fn("nvim_buf_is_valid")
  vim.api.nvim_buf_is_valid = function(buf)
    table.insert(M.calls, "nvim_buf_is_valid")
    return is_buf_valid(buf)
  end

  save_fn("nvim_buf_line_count")
  vim.api.nvim_buf_line_count = function(buf)
    table.insert(M.calls, "nvim_buf_line_count")
    buf = as_buf_arg(buf)
    if not is_buf_valid(buf) then return 0 end
    return #_bufs[buf].lines
  end

  save_fn("nvim_buf_get_lines")
  vim.api.nvim_buf_get_lines = function(buf, start, end_, strict)
    table.insert(M.calls, "nvim_buf_get_lines")
    buf = as_buf_arg(buf)
    if not is_buf_valid(buf) then return { "" } end
    local lines = _bufs[buf].lines
    if end_ == -1 then end_ = #lines end
    local result = {}
    for i = start + 1, end_ do
      if i <= #lines then table.insert(result, lines[i]) end
    end
    if #result == 0 then result = { "" } end
    return result
  end

  save_fn("nvim_buf_set_lines")
  vim.api.nvim_buf_set_lines = function(buf, start, end_, strict, lines)
    table.insert(M.calls, "nvim_buf_set_lines")
    buf = as_buf_arg(buf)
    if not is_buf_valid(buf) then return end
    _bufs[buf].lines = vim.deepcopy(lines or { "" })
  end

  save_fn("nvim_buf_set_name")
  vim.api.nvim_buf_set_name = function(buf, name)
    table.insert(M.calls, "nvim_buf_set_name")
    table.insert(M.calls, { buf = buf, name = name })
  end

  save_fn("nvim_buf_delete")
  vim.api.nvim_buf_delete = function(buf, opts2)
    table.insert(M.calls, "nvim_buf_delete")
    table.insert(M.calls, { buf = buf, opts = opts2 })
    if _bufs[buf] then _bufs[buf].valid = false end
  end

  save_fn("nvim_create_buf")
  vim.api.nvim_create_buf = function(listed, scratch)
    table.insert(M.calls, "nvim_create_buf")
    local buf = _next_buf; _next_buf = _next_buf + 1
    _bufs[buf] = { lines = { "" }, valid = true, ns_extmarks = {} }
    _bo[buf] = { filetype = "", modifiable = true, buftype = "" }
    return buf
  end

  save_fn("nvim_open_win")
  vim.api.nvim_open_win = function(buf, enter, config)
    table.insert(M.calls, "nvim_open_win")
    table.insert(M.calls, { buf = buf, enter = enter, config = config })
    local win = _next_win; _next_win = _next_win + 1
    _wins[win] = { buf = buf, valid = true, width = config and config.width or 80,
                   height = config and config.height or 24, cursor = { 1, 0 } }
    _wo[win] = { winbar = "", foldmethod = "manual", foldlevel = 99, foldcolumn = "0" }
    return win
  end

  save_fn("nvim_win_set_buf")
  vim.api.nvim_win_set_buf = function(win, buf)
    table.insert(M.calls, "nvim_win_set_buf")
    table.insert(M.calls, { win = win, buf = buf })
    if _wins[win] then _wins[win].buf = buf end
  end

  save_fn("nvim_win_set_width")
  vim.api.nvim_win_set_width = function(win, width)
    table.insert(M.calls, "nvim_win_set_width")
    if _wins[win] then _wins[win].width = width end
  end

  save_fn("nvim_win_set_height")
  vim.api.nvim_win_set_height = function(win, height)
    table.insert(M.calls, "nvim_win_set_height")
    if _wins[win] then _wins[win].height = height end
  end

  save_fn("nvim_win_is_valid")
  vim.api.nvim_win_is_valid = function(win)
    table.insert(M.calls, "nvim_win_is_valid")
    return is_win_valid(win)
  end

  save_fn("nvim_win_get_width")
  vim.api.nvim_win_get_width = function(win)
    table.insert(M.calls, "nvim_win_get_width")
    win = as_win_arg(win)
    if not is_win_valid(win) then return 80 end
    return _wins[win].width or 80
  end

  save_fn("nvim_win_get_height")
  vim.api.nvim_win_get_height = function(win)
    table.insert(M.calls, "nvim_win_get_height")
    win = as_win_arg(win)
    if not is_win_valid(win) then return 24 end
    return _wins[win].height or 24
  end

  save_fn("nvim_get_current_win")
  vim.api.nvim_get_current_win = function()
    table.insert(M.calls, "nvim_get_current_win")
    return _cur_win
  end

  save_fn("nvim_set_current_win")
  vim.api.nvim_set_current_win = function(win)
    table.insert(M.calls, "nvim_set_current_win")
    _cur_win = win
  end

  save_fn("nvim_get_current_buf")
  vim.api.nvim_get_current_buf = function()
    table.insert(M.calls, "nvim_get_current_buf")
    return _cur_buf
  end

  save_fn("nvim_set_current_buf")
  vim.api.nvim_set_current_buf = function(buf)
    table.insert(M.calls, "nvim_set_current_buf")
    _cur_buf = buf
  end

  save_fn("nvim_win_set_cursor")
  vim.api.nvim_win_set_cursor = function(win, pos)
    table.insert(M.calls, "nvim_win_set_cursor")
    table.insert(M.calls, { win = win, pos = pos })
    win = as_win_arg(win)
    if _wins[win] then _wins[win].cursor = pos end
  end

  save_fn("nvim_win_get_cursor")
  vim.api.nvim_win_get_cursor = function(win)
    table.insert(M.calls, "nvim_win_get_cursor")
    win = as_win_arg(win)
    if not is_win_valid(win) then return { 1, 0 } end
    return _wins[win].cursor or { 1, 0 }
  end

  save_fn("nvim_win_close")
  vim.api.nvim_win_close = function(win, force)
    table.insert(M.calls, "nvim_win_close")
    table.insert(M.calls, { win = win, force = force })
    if _wins[win] then _wins[win].valid = false end
  end

  save_fn("nvim_list_wins")
  vim.api.nvim_list_wins = function()
    table.insert(M.calls, "nvim_list_wins")
    local wins = {}
    for wid, w in pairs(_wins) do
      if w.valid ~= false then table.insert(wins, wid) end
    end
    return wins
  end

  save_fn("nvim_win_get_buf")
  vim.api.nvim_win_get_buf = function(win)
    table.insert(M.calls, "nvim_win_get_buf")
    win = as_win_arg(win)
    if not is_win_valid(win) then return -1 end
    return _wins[win].buf
  end

  save_fn("nvim_open_term")
  vim.api.nvim_open_term = function(buf, opts2)
    table.insert(M.calls, "nvim_open_term")
    table.insert(M.calls, { buf = buf, opts = opts2 })
    return 3001
  end

  save_fn("nvim_buf_add_highlight")
  vim.api.nvim_buf_add_highlight = function(buf, ns, hl_group, line, col_start, col_end)
    table.insert(M.calls, "nvim_buf_add_highlight")
    table.insert(M.calls, { buf = buf, ns = ns, hl_group = hl_group, line = line, col_start = col_start, col_end = col_end })
  end

  save_fn("nvim_buf_get_changedtick")
  vim.api.nvim_buf_get_changedtick = function(buf)
    table.insert(M.calls, "nvim_buf_get_changedtick")
    return 0
  end

  save_fn("nvim_buf_get_name")
  vim.api.nvim_buf_get_name = function(buf)
    table.insert(M.calls, "nvim_buf_get_name")
    return "/tmp/test.http"
  end

  save_fn("nvim_chan_send")
  vim.api.nvim_chan_send = function(chan, data)
    table.insert(M.calls, "nvim_chan_send")
    table.insert(M.calls, { chan = chan, data = data })
    return true
  end

  save_fn("nvim_buf_set_extmark")
  vim.api.nvim_buf_set_extmark = function(buf, ns, line_0, col_0, opts2)
    table.insert(M.calls, "nvim_buf_set_extmark")
    table.insert(M.calls, { buf = buf, ns = ns, line = line_0, col = col_0, opts = opts2 })
    return 1
  end

  save_fn("nvim_buf_clear_namespace")
  vim.api.nvim_buf_clear_namespace = function(buf, ns, line_start, line_end)
    table.insert(M.calls, "nvim_buf_clear_namespace")
  end

  save_fn("nvim_create_namespace")
  vim.api.nvim_create_namespace = function(name)
    table.insert(M.calls, "nvim_create_namespace")
    table.insert(M.calls, name)
    return 42
  end

  save_fn("nvim_create_augroup")
  vim.api.nvim_create_augroup = function(name, opts2)
    table.insert(M.calls, "nvim_create_augroup")
    table.insert(M.calls, { name = name, opts = opts2 })
    return 77
  end

  save_fn("nvim_del_augroup_by_id")
  vim.api.nvim_del_augroup_by_id = function(id)
    table.insert(M.calls, "nvim_del_augroup_by_id")
    table.insert(M.calls, id)
  end

  save_fn("nvim_del_augroup_by_name")
  vim.api.nvim_del_augroup_by_name = function(name)
    table.insert(M.calls, "nvim_del_augroup_by_name")
    table.insert(M.calls, name)
  end

  save_fn("nvim_create_autocmd")
  vim.api.nvim_create_autocmd = function(events, opts2)
    table.insert(M.calls, "nvim_create_autocmd")
    table.insert(M.calls, { events = events, opts = opts2 })
    table.insert(_autocmds, { events = events, opts = opts2 })
  end

  save_fn("nvim_create_user_command")
  vim.api.nvim_create_user_command = function(name, callback, opts2)
    table.insert(M.calls, "nvim_create_user_command")
    table.insert(M.calls, { name = name, cb = callback, opts = opts2 })
    _user_cmds[name] = { callback = callback, opts = opts2 }
  end

  save_fn("nvim_buf_set_option")
  vim.api.nvim_buf_set_option = function(buf, opt, val)
    table.insert(M.calls, "nvim_buf_set_option")
    ensure_buf(buf)[opt] = val
  end

  save_fn("nvim_set_option_value")
  vim.api.nvim_set_option_value = function(name, value, opts2)
    table.insert(M.calls, "nvim_set_option_value")
    table.insert(M.calls, { name = name, value = value, opts = opts2 })
    if opts2 and opts2.buf then
      ensure_buf(opts2.buf)[name] = value
    elseif opts2 and opts2.win then
      ensure_win(opts2.win)[name] = value
    else
      _o[name] = value
    end
  end

  save_fn("nvim_set_hl")
  vim.api.nvim_set_hl = function(ns_id, name, val)
    table.insert(M.calls, "nvim_set_hl")
    table.insert(M.calls, { ns_id = ns_id, name = name, val = val })
  end

  save_fn("nvim_get_hl")
  vim.api.nvim_get_hl = function(ns_id, opts2)
    table.insert(M.calls, "nvim_get_hl")
    return {}
  end

  save_fn("nvim_win_get_position")
  vim.api.nvim_win_get_position = function(win)
    table.insert(M.calls, "nvim_win_get_position")
    return { 0, 0 }
  end

  -- vim.bo
  vim.bo = setmetatable({}, {
    __index = function(_, buf)
      if not _bo[buf] then _bo[buf] = { filetype = "", modifiable = true, buftype = "" } end
      return _bo[buf]
    end,
    __newindex = function(_, buf, val)
      _bo[buf] = val
    end,
  })

  -- vim.wo
  vim.wo = setmetatable({}, {
    __index = function(_, win)
      if not _wo[win] then _wo[win] = {} end
      return _wo[win]
    end,
    __newindex = function(_, win, val)
      _wo[win] = val
    end,
  })

  -- vim.o
  vim.o = setmetatable({}, {
    __index = function(_, key) return _o[key] end,
    __newindex = function(_, key, val) _o[key] = val end,
  })

  vim.cmd = function(cmd)
    table.insert(M.calls, "vim_cmd")
    table.insert(M.calls, cmd)
  end

  vim.schedule = function(fn)
    table.insert(M.calls, "vim_schedule")
    fn()
  end

  vim.keymap = vim.keymap or {}
  vim.keymap.set = function(mode, lhs, rhs, opts2)
    table.insert(M.calls, "keymap_set")
    table.insert(M.calls, { mode = mode, lhs = lhs, opts = opts2 })
    local buf = (opts2 and opts2.buffer) or 0
    if buf == 0 then buf = _cur_buf end
    if not _keymaps[buf] then _keymaps[buf] = {} end
    if not _keymaps[buf][mode] then _keymaps[buf][mode] = {} end
    _keymaps[buf][mode][lhs] = rhs
  end

  vim.fn.sign_define = function(name, config)
    table.insert(M.calls, "sign_define")
  end
  vim.fn.sign_place = function(id, group, name, buf, opts2)
    table.insert(M.calls, "sign_place")
    return 1
  end
  vim.fn.sign_unplace = function(group, opts2)
    table.insert(M.calls, "sign_unplace")
  end
  vim.fn.bufwinid = function(buf)
    table.insert(M.calls, "bufwinid")
    for wid, w in pairs(_wins) do
      if w.buf == buf and w.valid ~= false then return wid end
    end
    return -1
  end
  vim.fn.executable = function(name)
    table.insert(M.calls, "executable")
    if opts.executable then return opts.executable(name) end
    return 1
  end
  vim.fn.systemlist = function(cmd)
    table.insert(M.calls, "systemlist")
    table.insert(M.calls, { cmd = cmd })
    if opts.systemlist then return opts.systemlist(cmd) end
    return {}
  end
  vim.fn.setreg = function(reg, value)
    table.insert(M.calls, "setreg")
    table.insert(M.calls, { reg = reg, value = value })
  end
  vim.fn.fnamemodify = function(path, modifier)
    table.insert(M.calls, "fnamemodify")
    if modifier == ":h" then
      local dir = path:match("^(.*/)")
      return dir or "."
    end
    return path
  end
  vim.fn.stdpath = function(id)
    table.insert(M.calls, "stdpath")
    return "/tmp/poste-http-test"
  end
  vim.fn.line = function(what)
    table.insert(M.calls, "line")
    if what == "." then
      local win = _cur_win
      local cursor = _wins[win] and _wins[win].cursor or { 1, 0 }
      return cursor[1]
    end
    return 1
  end
  vim.fn.strdisplaywidth = function(s)
    return #s
  end
  vim.fn.strcharpart = function(s, idx, len)
    return s:sub(idx + 1, idx + len)
  end
  vim.fn.strchars = function(s)
    return #s
  end
  vim.fn.getcwd = function()
    return "/tmp"
  end

  if vim.uv then
    vim.uv.new_timer = function()
      table.insert(M.calls, "uv_new_timer")
      return {
        start = function(self, delay, interval, cb)
          table.insert(M.calls, "uv_timer_start")
        end,
        stop = function(self)
          table.insert(M.calls, "uv_timer_stop")
        end,
        close = function(self)
          table.insert(M.calls, "uv_timer_close")
        end,
      }
    end
    vim.uv.hrtime = function()
      return os.clock() * 1e9
    end
  end
  if vim.loop then
    vim.loop.new_timer = vim.uv.new_timer
    vim.loop.hrtime = vim.uv.hrtime
  end

  vim.base64 = vim.base64 or {}
  vim.base64.encode = vim.base64.encode or function(data)
    return ((data:gsub(".", function(c)
      return string.format("%02x", string.byte(c))
    end)))
  end

  vim.notify = function(msg, level, opts2)
    table.insert(M.calls, "vim_notify")
    table.insert(M.calls, { msg = msg, level = level, opts = opts2 })
  end

  vim.defer_fn = function(fn, timeout)
    table.insert(M.calls, "vim_defer_fn")
    fn()
  end
end

function M.teardown()
  for name, fn in pairs(_originals) do
    if name:match("^vim_") then
      local key = name:sub(5)
      if key:match("^fn_") then
        local fn_key = key:sub(4)
        vim.fn[fn_key] = fn
      elseif key == "fn" then
        vim.fn = fn
      elseif key == "uv" then
        vim.uv = fn
      elseif key == "loop" then
        vim.loop = fn
      elseif key == "cmd" then
        vim.cmd = fn
      elseif key == "schedule" then
        vim.schedule = fn
      elseif key == "keymap" then
        vim.keymap = fn
      elseif key == "bo" then
        vim.bo = fn
      elseif key == "wo" then
        vim.wo = fn
      elseif key == "o" then
        vim.o = fn
      elseif key == "base64" then
        vim.base64 = fn
      elseif key == "notify" then
        vim.notify = fn
      elseif key == "defer_fn" then
        vim.defer_fn = fn
      end
    else
      vim.api[name] = fn
    end
  end
  _bufs = {}
  _wins = {}
  _autocmds = {}
  _keymaps = {}
  _user_cmds = {}
  _bo = {}
  _wo = {}
  _o = {}
  M.reset_calls()
end

return M