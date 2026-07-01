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

  -- Mock nvim_buf_set_extmark
  vim.api.nvim_buf_set_extmark = function(buf, ns, line_0, col_0, opts2)
    table.insert(M.calls, "nvim_buf_set_extmark")
    table.insert(M.calls, { buf = buf, ns = ns, line = line_0, col = col_0, opts = opts2 })
    return 1  -- extmark id
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

  -- Mock nvim_buf_set_option (used by minimal_init)
  vim.api.nvim_buf_set_option = function(buf, opt, val)
    table.insert(M.calls, "nvim_buf_set_option")
  end

  -- Mock sign_define
  vim.fn.sign_define = function(name, config)
    table.insert(M.calls, "sign_define")
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
end

--- Teardown mock environment, restoring originals.
function M.teardown()
  if _originals.vim_api then vim.api = _originals.vim_api end
  if _originals.vim_fn then vim.fn = _originals.vim_fn end
  if _originals.vim_uv then vim.uv = _originals.vim_uv end
  if _originals.vim_loop then vim.loop = _originals.vim_loop end
  if _originals.vim_cmd then vim.cmd = _originals.vim_cmd end
  if _originals.vim_schedule then vim.schedule = _originals.vim_schedule end
  M.reset_calls()
end

return M
