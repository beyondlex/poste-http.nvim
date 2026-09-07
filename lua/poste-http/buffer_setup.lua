local state = require("poste-http.state")
local _ = require("poste-http.indicators")
local M = {}

local fileref_ns = vim.api.nvim_create_namespace("poste_fileref")

function M.setup_buffer_keymaps(buf)
  -- 0 = current-buffer sentinel (plugin/poste.lua passes it from BufRead).
  -- Resolve now: closures below pass `buf` to nvim_buf_*/sign_* APIs that
  -- reject 0 (sign_unplace(buffer=0) raises E158).
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  local nav_ok, nav = pcall(require, "poste-http.http.nav")
  local run_ok, run = pcall(require, "poste-http.http.run")

  local specs = {
    { action = "quickfix_next", default = "]q", handler = function() vim.cmd("cnext") end },
    { action = "quickfix_prev", default = "[q", handler = function() vim.cmd("cprev") end },
    { action = "paste_curl", default = "<leader>rp", handler = function()
      require("poste-http.http.curl").paste_curl("+")
    end },
    { action = "copy_as_curl", default = "<leader>rc", handler = function()
      require("poste-http.http.copy").copy_to_clipboard("+")
    end },
    { action = "toggle_outline", default = "gs", handler = function()
      require("poste-http.http.symbols").show_symbols()
    end },
    { action = "pick_env", default = "<leader>vv", handler = require("poste-http.http.env").pick_env },
    { action = "show_history", default = "<leader>l", handler = function()
      require("poste-http.http.history").show()
    end },
    { action = "help", default = "g?", handler = function() require("poste-http.help").open() end },
    { action = "ask_ai", default = "ga", opts = { modes = { "n", "x" } }, handler = function()
      require("poste-http.ai").ask_request()
    end },
  }

  if run_ok and run.run_request then
    table.insert(specs, 1, {
      action = "run_hsplit", default = "<M-CR>", handler = function()
        state._split_override = "horizontal"
        run.run_request()
      end,
    })
    table.insert(specs, 1, { action = "run", default = "<CR>", handler = run.run_request })
  end

  if nav_ok then
    local nav_specs = {
      { action = "jump_next", default = "]]", handler = nav.jump_next },
      { action = "jump_prev", default = "[[", handler = nav.jump_prev },
      { action = "goto_definition", default = "gd", handler = function() nav.goto_definition() end },
      { action = "goto_references", default = "grr", handler = nav.goto_references },
      { action = "show_var_value", default = "K", handler = nav.show_var_value },
      { action = "show_variable_inspector", default = "gi", handler = function()
        require("poste-http.http.variable_inspector").show_inspector()
      end },
    }
    for i = #nav_specs, 1, -1 do
      table.insert(specs, 1, nav_specs[i])
    end
  end

  require("poste-http.ui.keymaps").register_all(buf, "http_source", specs)

  local group = vim.api.nvim_create_augroup("PosteClearIndicators_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group, buffer = buf,
    callback = function()
      -- clear signs + spinner timers too (the namespace wipe alone left
      -- stale timer bookkeeping behind)
      require("poste-http.indicators").clear_all(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group, buffer = buf,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_name, "PosteClearIndicators_" .. buf)
    end,
  })

  local function refresh_fileref_marks()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, fileref_ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:match("^%s*[<>]%s+%S") and not line:find("{%", 1, true) then
        local path_start = line:match("^%s*[<>]%s+()")
        if path_start then
          vim.api.nvim_buf_set_extmark(buf, fileref_ns, i - 1, path_start - 1, {
            end_col = #line, hl_group = "PosteFileRef",
          })
        end
      end
    end
  end
  refresh_fileref_marks()
  local frg = vim.api.nvim_create_augroup("PosteFileref_" .. buf, { clear = true })
  local fileref_debounce
  vim.api.nvim_create_autocmd("TextChanged", {
    group = frg, buffer = buf,
    callback = function()
      if fileref_debounce then fileref_debounce:stop() end
      fileref_debounce = vim.defer_fn(refresh_fileref_marks, 150)
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = frg, buffer = buf,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_name, "PosteFileref_" .. buf)
    end,
  })
end

--- Attach the boundary-indicator autocmds for an .http/.rest buffer:
--- CursorMoved refreshes the request-block highlight, BufDelete removes the
--- per-buffer augroup. Extracted from plugin/poste.lua, which needed the
--- same pair for both its BufRead hook and its already-loaded-buffers loop.
function M.attach_boundary(buf)
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  local bg = vim.api.nvim_create_augroup("PosteHttpBoundary_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = bg, buffer = buf,
    callback = function()
      require("poste-http.http.boundary_indicator").refresh(buf, vim.fn.line("."))
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = bg, buffer = buf,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_name, "PosteHttpBoundary_" .. buf)
    end,
  })
end

return M