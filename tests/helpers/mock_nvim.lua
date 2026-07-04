-- Mock nvim API for isolated testing of poste modules.
--
-- Usage:
--   local mock = require("helpers.mock_nvim")
--   mock.setup()  -- patches vim.api.*, vim.fn.*, etc.
--   -- ... run tests that use vim.api ...
--   mock.teardown()  -- restores originals
--
-- Only the functions used by the module under test are mocked.
-- Add more mocks as needed for additional modules.

local M = {}

-- Store originals for teardown
local _originals = {}

-- Track calls for assertions
M.calls = {}

function M.reset_calls()
  M.calls = {}
end

--- Setup mock environment.
-- @param opts table  Optional overrides for mock behavior
  --   .buf_is_valid: function(buf) -> boolean (default: always true)
  --   .buf_line_count: function(buf) -> integer (default: 100)
  --   .buf_get_lines: function(buf, start, end) -> string[] (default: {""})
  --   .systemlist: function(cmd) -> string[] (default: nil)
  function M.setup(opts)
  opts = opts or {}
  M.reset_calls()

  -- Store originals
  _originals.vim_api = vim.api
  _originals.vim_fn = vim.fn
  _originals.vim_uv = vim.uv
  _originals.vim_loop = vim.loop
  _originals.vim_cmd = vim.cmd
  _originals.vim_schedule = vim.schedule
  _originals.vim_keymap_set = vim.keymap and vim.keymap.set or nil

  -- Mock nvim_buf_is_valid
  vim.api.nvim_buf_is_valid = function(buf)
    table.insert(M.calls, "nvim_buf_is_valid")
    if opts.buf_is_valid then return opts.buf_is_valid(buf) end
    return true
  end

  -- Mock nvim_buf_line_count
  vim.api.nvim_buf_line_count = function(buf)
    table.insert(M.calls, "nvim_buf_line_count")
    return opts.buf_line_count or 100
  end

  -- Mock nvim_buf_get_lines
  vim.api.nvim_buf_get_lines = function(buf, start, end_, strict)
    table.insert(M.calls, "nvim_buf_get_lines")
    if opts.buf_get_lines then return opts.buf_get_lines(buf, start, end_, strict) end
    return { "" }
  end

  -- Mock nvim_buf_set_lines
  vim.api.nvim_buf_set_lines = function(buf, start, end_, strict, lines)
    table.insert(M.calls, "nvim_buf_set_lines")
    table.insert(M.calls, { buf = buf, start = start, end_ = end_, strict = strict, lines = lines })
  end

  -- Mock nvim_buf_set_name
  vim.api.nvim_buf_set_name = function(buf, name)
    table.insert(M.calls, "nvim_buf_set_name")
    table.insert(M.calls, { buf = buf, name = name })
  end

  -- Mock nvim_buf_delete
  vim.api.nvim_buf_delete = function(buf, opts2)
    table.insert(M.calls, "nvim_buf_delete")
    table.insert(M.calls, { buf = buf, opts = opts2 })
  end

  -- Mock nvim_create_buf
  vim.api.nvim_create_buf = function(listed, scratch)
    table.insert(M.calls, "nvim_create_buf")
    return 1001
  end

  -- Mock nvim_open_win
  vim.api.nvim_open_win = function(buf, enter, config)
    table.insert(M.calls, "nvim_open_win")
    table.insert(M.calls, { buf = buf, enter = enter, config = config })
    return 2001
  end

  -- Mock nvim_win_set_buf
  vim.api.nvim_win_set_buf = function(win, buf)
    table.insert(M.calls, "nvim_win_set_buf")
    table.insert(M.calls, { win = win, buf = buf })
  end

  -- Mock nvim_win_set_width
  vim.api.nvim_win_set_width = function(win, width)
    table.insert(M.calls, "nvim_win_set_width")
    table.insert(M.calls, { win = win, width = width })
  end

  -- Mock nvim_win_set_height
  vim.api.nvim_win_set_height = function(win, height)
    table.insert(M.calls, "nvim_win_set_height")
    table.insert(M.calls, { win = win, height = height })
  end

  -- Mock nvim_win_is_valid
  vim.api.nvim_win_is_valid = function(win)
    table.insert(M.calls, "nvim_win_is_valid")
    if opts.win_is_valid then return opts.win_is_valid(win) end
    return true
  end

  -- Mock nvim_win_get_width
  vim.api.nvim_win_get_width = function(win)
    table.insert(M.calls, "nvim_win_get_width")
    return opts.win_width or 80
  end

  -- Mock nvim_win_get_height
  vim.api.nvim_win_get_height = function(win)
    table.insert(M.calls, "nvim_win_get_height")
    return opts.win_height or 24
  end

  -- Mock nvim_get_current_win
  vim.api.nvim_get_current_win = function()
    table.insert(M.calls, "nvim_get_current_win")
    return opts.current_win or 1
  end

  -- Mock nvim_set_current_win
  vim.api.nvim_set_current_win = function(win)
    table.insert(M.calls, "nvim_set_current_win")
    table.insert(M.calls, win)
  end

  -- Mock nvim_win_set_cursor
  vim.api.nvim_win_set_cursor = function(win, pos)
    table.insert(M.calls, "nvim_win_set_cursor")
    table.insert(M.calls, { win = win, pos = pos })
  end

  -- Mock nvim_win_get_cursor
  vim.api.nvim_win_get_cursor = function(win)
    table.insert(M.calls, "nvim_win_get_cursor")
    return opts.current_cursor or { 1, 0 }
  end

  -- Mock nvim_win_close
  vim.api.nvim_win_close = function(win, force)
    table.insert(M.calls, "nvim_win_close")
    table.insert(M.calls, { win = win, force = force })
  end

  -- Mock nvim_open_term
  vim.api.nvim_open_term = function(buf, opts2)
    table.insert(M.calls, "nvim_open_term")
    table.insert(M.calls, { buf = buf, opts = opts2 })
    return 3001
  end

  -- Mock nvim_chan_send
  vim.api.nvim_chan_send = function(chan, data)
    table.insert(M.calls, "nvim_chan_send")
    table.insert(M.calls, { chan = chan, data = data })
    return true
  end

  -- Mock nvim_buf_set_extmark
  vim.api.nvim_buf_set_extmark = function(buf, ns, line_0, col_0, opts2)
    table.insert(M.calls, "nvim_buf_set_extmark")
    table.insert(M.calls, { buf = buf, ns = ns, line = line_0, col = col_0, opts = opts2 })
    return 1  -- extmark id
  end

  -- Mock nvim_get_hl
  vim.api.nvim_get_hl = function(ns_id, opts2)
    table.insert(M.calls, "nvim_get_hl")
    if opts.get_hl then return opts.get_hl(ns_id, opts2) end
    return { bg = 0x000000 }
  end

  -- Mock nvim_set_hl
  vim.api.nvim_set_hl = function(ns_id, name, val)
    table.insert(M.calls, "nvim_set_hl")
    table.insert(M.calls, { ns_id = ns_id, name = name, val = val })
  end

  -- Mock nvim_buf_clear_namespace
  vim.api.nvim_buf_clear_namespace = function(buf, ns, line_start, line_end)
    table.insert(M.calls, "nvim_buf_clear_namespace")
  end

  -- Mock nvim_create_namespace
  vim.api.nvim_create_namespace = function(name)
    table.insert(M.calls, "nvim_create_namespace")
    return 42  -- arbitrary ns id
  end

  -- Mock nvim_create_augroup
  vim.api.nvim_create_augroup = function(name, opts2)
    table.insert(M.calls, "nvim_create_augroup")
    table.insert(M.calls, { name = name, opts = opts2 })
    return 77
  end

  -- Mock nvim_create_autocmd
  vim.api.nvim_create_autocmd = function(events, opts2)
    table.insert(M.calls, "nvim_create_autocmd")
    table.insert(M.calls, { events = events, opts = opts2 })
    return 88
  end

  -- Mock nvim_del_augroup_by_id
  vim.api.nvim_del_augroup_by_id = function(id)
    table.insert(M.calls, "nvim_del_augroup_by_id")
    table.insert(M.calls, id)
  end

  -- Mock nvim_buf_set_option (used by minimal_init)
  vim.api.nvim_buf_set_option = function(buf, opt, val)
    table.insert(M.calls, "nvim_buf_set_option")
  end

  -- Mock nvim_set_option_value
  vim.api.nvim_set_option_value = function(name, value, opts2)
    table.insert(M.calls, "nvim_set_option_value")
    table.insert(M.calls, { name = name, value = value, opts = opts2 })
  end

  -- Mock sign_define
  vim.fn.sign_define = function(name, config)
    table.insert(M.calls, "sign_define")
  end

  -- Mock bufwinid
  vim.fn.bufwinid = function(buf)
    table.insert(M.calls, "bufwinid")
    return opts.bufwinid or 1
  end

  -- Mock sign_place
  vim.fn.sign_place = function(id, group, name, buf, opts2)
    table.insert(M.calls, "sign_place")
    return 1  -- sign id
  end

  -- Mock sign_unplace
  vim.fn.sign_unplace = function(group, opts2)
    table.insert(M.calls, "sign_unplace")
  end

  -- Mock jobstart
  vim.fn.jobstart = function(cmd, opts2)
    table.insert(M.calls, "jobstart")
    table.insert(M.calls, { cmd = cmd, opts = opts2 })
    return 1
  end

  -- Mock systemlist for external command execution
  vim.fn.systemlist = function(cmd)
    table.insert(M.calls, "systemlist")
    table.insert(M.calls, { cmd = cmd })
    if opts.systemlist then return opts.systemlist(cmd) end
    return {}
  end

  -- Mock executable
  vim.fn.executable = function(name)
    table.insert(M.calls, "executable")
    if opts.executable then return opts.executable(name) end
    return 1
  end

  -- Mock vim.uv.new_timer
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
  end

  -- Mock vim.schedule to execute immediately (synchronous tests)
  vim.schedule = function(fn)
    table.insert(M.calls, "vim_schedule")
    fn()
  end

  -- Mock vim.cmd
  vim.cmd = function(cmd)
    table.insert(M.calls, "vim_cmd")
    table.insert(M.calls, cmd)
  end

  -- Mock keymaps
  vim.keymap = vim.keymap or {}
  vim.keymap.set = function(mode, lhs, rhs, opts2)
    table.insert(M.calls, "keymap_set")
    table.insert(M.calls, { mode = mode, lhs = lhs, opts = opts2 })
  end

  -- Mock vim.base64.encode
  _originals.vim_base64 = vim.base64
  vim.base64 = vim.base64 or {}
  vim.base64.encode = vim.base64.encode or function(data)
    return ((data:gsub(".", function(c)
      return string.format("%02x", string.byte(c))
    end)))
  end
end

--- Teardown mock environment, restoring originals.
function M.teardown()
  if _originals.vim_api then vim.api = _originals.vim_api end
  if _originals.vim_fn then vim.fn = _originals.vim_fn end
  if _originals.vim_uv then vim.uv = _originals.vim_uv end
  if _originals.vim_loop then vim.loop = _originals.vim_loop end
  if _originals.vim_cmd then vim.cmd = _originals.vim_cmd end
  if _originals.vim_schedule then vim.schedule = _originals.vim_schedule end
  if _originals.vim_keymap_set and vim.keymap then vim.keymap.set = _originals.vim_keymap_set end
  if _originals.vim_base64 then vim.base64 = _originals.vim_base64 end
  M.reset_calls()
end

return M
