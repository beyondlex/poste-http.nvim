--- Shared buffer keymap setup (HTTP + SQL).
--- Extracted from init.lua to avoid circular deps.
local state = require("poste.state")
local indicators = require("poste.indicators")

local M = {}

local nav = require("poste.http.nav")

function M.setup_buffer_keymaps(buf)
  local keymap_opts = { buffer = buf, noremap = true, silent = true }
  local km = state.get_keymap

  local run_request = require("poste.http.run").run_request

  local k = km("source_buffer", "run", "<CR>")
  if k then vim.keymap.set("n", k, run_request, keymap_opts) end
  k = km("source_buffer", "jump_next", "]]")
  if k then vim.keymap.set("n", k, nav.jump_next, keymap_opts) end
  k = km("source_buffer", "jump_prev", "[[")
  if k then vim.keymap.set("n", k, nav.jump_prev, keymap_opts) end
  k = km("source_buffer", "goto_definition", "gd")
  if k then vim.keymap.set("n", k, nav.goto_definition, keymap_opts) end
  k = km("source_buffer", "goto_references", "grr")
  if k then vim.keymap.set("n", k, nav.goto_references, keymap_opts) end
  k = km("source_buffer", "quickfix_next", "]q")
  if k then vim.keymap.set("n", k, function() vim.cmd("cnext") end, keymap_opts) end
  k = km("source_buffer", "quickfix_prev", "[q")
  if k then vim.keymap.set("n", k, function() vim.cmd("cprev") end, keymap_opts) end
  k = km("source_buffer", "paste_curl", "<leader>rp")
  if k then
    vim.keymap.set("n", k, function()
      local curl = require("poste.http.curl")
      curl.paste_curl("+")
    end, keymap_opts)
  end
  k = km("source_buffer", "copy_as_curl", "<leader>rc")
  if k then
    vim.keymap.set("n", k, function()
      local copy = require("poste.http.copy")
      copy.copy_to_clipboard("+")
    end, keymap_opts)
  end
  k = km("source_buffer", "toggle_outline", "gs")
  if k then
    vim.keymap.set("n", k, function()
      require("poste.http.outline").toggle()
    end, keymap_opts)
  end
  k = km("source_buffer", "pick_env", "<leader>vv")
  if k then vim.keymap.set("n", k, require("poste.http.env").pick_env, keymap_opts) end
  k = km("source_buffer", "show_var_value", "K")
  if k then vim.keymap.set("n", k, nav.show_var_value, keymap_opts) end
  k = km("source_buffer", "help", "g?")
  if k then
    vim.keymap.set("n", k, function() require("poste.help").open() end, keymap_opts)
  end

  local indicator_ns = vim.api.nvim_create_namespace("poste_indicator")
  local group = vim.api.nvim_create_augroup("PosteClearIndicators_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    buffer = buf,
    callback = function()
      vim.api.nvim_buf_clear_namespace(buf, indicator_ns, 0, -1)
    end,
  })

  local fileref_ns = vim.api.nvim_create_namespace("poste_fileref_" .. buf)
  local function refresh_fileref_marks()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, fileref_ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:match("^%s*[<>]%s+%S") and not line:find("{%", 1, true) then
        local path_start = line:match("^%s*[<>]%s+()")
        if path_start then
          vim.api.nvim_buf_set_extmark(buf, fileref_ns, i - 1, path_start - 1, {
            end_col = #line,
            hl_group = "PosteFileRef",
          })
        end
      end
    end
  end
  refresh_fileref_marks()
  local frg = vim.api.nvim_create_augroup("PosteFileref_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("TextChanged", {
    group = frg,
    buffer = buf,
    callback = refresh_fileref_marks,
  })
end

return M