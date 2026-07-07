local state = require("poste.state")
require("poste.util")
require("poste.http.highlights")
require("poste.indicators")
require("poste.http.format")
require("poste.http.buffer")
require("poste.http.assertions")
require("poste.http.scripts")
require("poste.http.request_vars")
pcall(require, "blink.cmp")
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

  if vim.g.poste_setup_done then
    return
  end
  vim.g.poste_setup_done = true

  -- Auto-clean old response cache on startup (deferred)
  vim.defer_fn(function()
    local format = require("poste.http.format")
    local cleaned = format.clean_response_cache(120)  -- 2 hour default
    if cleaned > 0 then
      vim.notify(string.format("[Poste] Cleaned %d stale response file(s)", cleaned), vim.log.levels.DEBUG)
    end
  end, 2000)

  completion.register()
  require("poste.http.lua_docs").setup()
  require("poste.http.script_snippet").setup()

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

  vim.api.nvim_create_user_command("PosteImportOpenAPI", function()
    require("poste.http.import_openapi").run()
  end, { desc = "Import OpenAPI 3.x spec as .http files" })

  vim.api.nvim_create_user_command("PosteImportSwagger", function()
    require("poste.http.import_swagger").run()
  end, { desc = "Import Swagger 2.0 spec as .http files" })

  vim.api.nvim_create_user_command("PosteImportPostman", function()
    require("poste.http.import_postman").run()
  end, { desc = "Import Postman collection as .http files" })

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
    symbols.show_symbols()
  end, { desc = "Show symbol picker (all HTTP requests)" })

  vim.api.nvim_create_user_command("PosteFormatHttp", function()
    local binary = state.find_poste_binary()
    if not binary then
      vim.notify("poste binary not found. Run :PosteUpdate or set vim.g.poste_binary", vim.log.levels.ERROR)
      return
    end
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local result = vim.fn.systemlist({ binary, "fmt", "--stdin" }, lines)
    if vim.v.shell_error == 0 then
      vim.api.nvim_buf_set_lines(0, 0, -1, false, result)
      vim.notify("poste fmt: formatted", vim.log.levels.INFO)
    else
      vim.notify("poste fmt failed: " .. table.concat(result, " "), vim.log.levels.ERROR)
    end
  end, { desc = "Format .http buffer using poste fmt" })

  vim.api.nvim_create_user_command("PosteHttpHistory", function()
    require("poste.http.history").show()
  end, { desc = "Show HTTP request history" })

  vim.api.nvim_create_user_command("PosteUpdate", function()
    local install = require("poste.install")
    local ok = install.update()
    if ok then
      local v = install.installed_version()
      vim.notify("[Poste] Updated to " .. (v or "latest"), vim.log.levels.INFO)
    end
   end, { desc = "Update poste-cli binary to latest release" })

  vim.api.nvim_create_user_command("PosteClearCache", function()
    local format = require("poste.http.format")
    local cleaned = format.clean_response_cache()
    vim.notify(string.format("[Poste] Cleared %d old response file(s)", cleaned), vim.log.levels.INFO)
  end, { desc = "Remove old cached response files from stdpath(cache)/poste_res/" })

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
      local buf = vim.api.nvim_get_current_buf()
      vim.wo.winbar = env_mod.build_http_winbar()
      if vim.bo.filetype == "poste_http" then
        require("poste.http.boundary_indicator").refresh(buf, vim.fn.line("."))
      end
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