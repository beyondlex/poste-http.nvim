local state = require("poste.state")
local blink_ok, blink = pcall(require, "blink.cmp")
if not blink_ok then blink = nil end
local util = require("poste.util")
local highlights = require("poste.http.highlights")
local indicators = require("poste.indicators")
local format = require("poste.http.format")
local buffer = require("poste.http.buffer")
local assertions = require("poste.http.assertions")
local scripts = require("poste.http.scripts")
local request_vars = require("poste.http.request_vars")
local completion = require("poste.http.completion")
local symbols = require("poste.http.symbols")

local view = require("poste.http.view")
local env_mod = require("poste.http.env")
local nav = require("poste.http.nav")
local run = require("poste.http.run")
local buffer_setup = require("poste.buffer_setup")

local M = {}

M.show_view = view.show_view
M.set_env = env_mod.set_env
M.get_env = env_mod.get_env
M.pick_env = env_mod.pick_env
M.jump_next = nav.jump_next
M.jump_prev = nav.jump_prev
M.show_var_value = nav.show_var_value
M.goto_definition = nav.goto_definition
M.goto_references = nav.goto_references
M.run_request = run.run_request

function M.setup(opts)
  opts = opts or {}
  state.config = vim.tbl_deep_extend("force", state.config, opts)

  completion.register()
  require("poste.http.lua_docs").setup()

  require("poste.sql.init").setup(opts)

  vim.api.nvim_create_user_command("PosteRun", function()
    M.run_request()
  end, { desc = "Run request at cursor" })

  vim.api.nvim_create_user_command("PosteEnv", function(args)
    if args.args == "" then
      vim.notify("Current environment: " .. state.current_env, vim.log.levels.INFO)
    else
      M.set_env(args.args)
    end
  end, {
    nargs = "?",
    desc = "Switch environment or show current",
  })

  vim.api.nvim_create_user_command("PostePasteCurl", function()
    local curl = require("poste.http.curl")
    curl.paste_curl("+")
  end, { desc = "Paste curl command from clipboard as HTTP request" })

  vim.api.nvim_create_user_command("PosteCopyAsCurl", function()
    local copy = require("poste.http.copy")
    copy.copy_to_clipboard("+")
  end, { desc = "Copy current request as curl command to clipboard" })

  vim.api.nvim_create_user_command("PosteHelp", function()
    require("poste.help").open()
  end, { desc = "Show Poste keymap help" })

  vim.api.nvim_create_user_command("PosteImportResolve", function()
    local import = require("poste.http.import")
    local lines = import.status()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "poste://import-status")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "poste"
    vim.bo[buf].modifiable = false
    local width = 80
    local height = math.min(#lines + 2, 20)
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.max(0, (vim.o.lines - height) / 2 - 1),
      col = math.max(0, (vim.o.columns - width) / 2),
      style = "minimal",
      border = "single",
      title = " Import Resolution Status ",
      title_pos = "center",
    })
    vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end,
      { buffer = buf, noremap = true, silent = true })
    vim.api.nvim_buf_attach(buf, false, { on_detach = function() pcall(vim.api.nvim_win_close, win, true) end })
  end, { desc = "Show import resolution status" })

  vim.api.nvim_create_user_command("PosteCmpStatus", function()
    vim.notify(completion.status(), vim.log.levels.INFO)
  end, { desc = "Check poste completion status" })

  vim.api.nvim_create_user_command("PosteCmpProfile", function()
    completion.profile()
  end, { desc = "Profile poste completion performance" })

  vim.api.nvim_create_user_command("PosteSymbols", function()
    symbols.show_symbols()
  end, { desc = "Show symbol outline (all HTTP requests)" })

  vim.api.nvim_create_user_command("PosteOutline", function()
    require("poste.http.outline").toggle()
  end, { desc = "Toggle outline sidebar for .http file" })

  vim.api.nvim_create_user_command("PosteFormatHttp", function()
    local binary = state.find_poste_binary()
    if not binary then
      vim.notify("poste binary not found. Run :PosteInstall or set vim.g.poste_binary", vim.log.levels.ERROR)
      return
    end
    vim.cmd(string.format("%%!%s fmt --stdin", vim.fn.shellescape(binary)))
  end, { desc = "Format .http buffer using poste fmt" })

  vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    pattern = { "*.http", "*.rest", "*.redis" },
    callback = function()
      local name = vim.api.nvim_buf_get_name(0)
      if name:match("%.redis$") then
        vim.bo.filetype = "poste_redis"
        buffer_setup.setup_buffer_keymaps(0)
      else
        vim.bo.filetype = "poste_http"
        buffer_setup.setup_buffer_keymaps(0)
        local bg = vim.api.nvim_create_augroup("PosteHttpBoundary_" .. vim.api.nvim_get_current_buf(), { clear = true })
        vim.api.nvim_create_autocmd("CursorMoved", {
          group = bg,
          buffer = 0,
          callback = function()
            require("poste.http.boundary_indicator").refresh(0, vim.fn.line("."))
          end,
        })
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    pattern = { "*.http", "*.rest" },
    callback = function()
      vim.wo.winbar = env_mod.build_http_winbar()
    end,
  })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("%.http$") or name:match("%.rest$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_http")
      buffer_setup.setup_buffer_keymaps(buf)
      local bg = vim.api.nvim_create_augroup("PosteHttpBoundary_" .. buf, { clear = true })
      vim.api.nvim_create_autocmd("CursorMoved", {
        group = bg,
        buffer = buf,
        callback = function()
          require("poste.http.boundary_indicator").refresh(buf, vim.fn.line("."))
        end,
      })
    elseif name:match("%.redis$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_redis")
      buffer_setup.setup_buffer_keymaps(buf)
    end
  end

  _G.poste_status = function()
    local parts = { string.format("[env: %s]", state.current_env) }
    local ft = vim.bo.filetype
    if ft == "poste_sql" or ft == "poste_sqlite" then
      local ok, ctx_mod = pcall(require, "poste.sql.context")
      if ok and ctx_mod.get_status_text then
        local text = ctx_mod.get_status_text()
        if text ~= "" then
          parts[#parts + 1] = text
        end
      end
    end
    return table.concat(parts, " ")
  end
end

return M