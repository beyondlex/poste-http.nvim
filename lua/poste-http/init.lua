local state = require("poste-http.state")
require("poste-http.http.highlights")
require("poste-http.http.format")
require("poste-http.http.buffer")
require("poste-http.http.assertions")
require("poste-http.http.scripts")
require("poste-http.http.request_vars")
pcall(require, "blink.cmp")
local completion = require("poste-http.http.completion")
require("poste-http.http.symbols")
local commands = require("poste-http.commands")

local view = require("poste-http.http.view")
local env_mod = require("poste-http.http.env")
local nav = require("poste-http.http.nav")
local run = require("poste-http.http.run")

local M = {}

M.show_view = view.show_view
M.set_env = env_mod.set_env
M.get_env = env_mod.get_env
M.pick_env = env_mod.pick_env
M.jump_next = nav.jump_next
M.jump_prev = nav.jump_prev
M.show_var_value = nav.show_var_value
M.show_variable_inspector = require("poste-http.http.variable_inspector").show_inspector
M.goto_definition = nav.goto_definition
M.goto_references = nav.goto_references
M.run_request = run.run_request

function M.setup(opts)
  opts = opts or {}
  state.config = vim.tbl_deep_extend("force", state.config, opts)
  if opts.default_env then
    state.current_env = opts.default_env
  end

  state.config.use_treesitter = vim.tbl_deep_extend("force", {
    nav = false,
    context_detector = false,
    outline = false,
    folding = false,
    diagnostics = false,
  }, state.config.use_treesitter or {})

  if vim.g.poste_setup_done then
    return
  end
  vim.g.poste_setup_done = true

  -- Ensure tree-sitter parsers are compiled (fast, one-time)
  pcall(require("poste-http.install").ensure_parsers)

  -- Auto-clean old response cache on startup (deferred)
  vim.defer_fn(function()
    local format = require("poste-http.http.format")
    format.clean_response_cache(120)
  end, 2000)

  completion.register()
  require("poste-http.http.lua_docs").setup()
  require("poste-http.http.script_snippet").setup()
  commands.setup()

  -- Optional AI chat integration (poste-ai.nvim); retried on :PosteHttpChat
  pcall(function() require("poste-http.ai").register() end)

  pcall(function()
    require("poste-http.http.history").load()
  end)

  _G.poste_status = commands.status
end

return M
