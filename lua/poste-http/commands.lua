local state = require("poste-http.state")
local completion = require("poste-http.http.completion")
local symbols = require("poste-http.http.symbols")
local notify = require("poste-http.ui.notify").notify

local M = {}

local commands = {
  {
    name = "PosteHttpRun",
    handler = function()
      require("poste-http.http.run").run_request()
    end,
    opts = { desc = "Run request at cursor" },
  },
  {
    name = "PosteHttpEnv",
    handler = function(args)
      local env_mod = require("poste-http.http.env")
      if args.args == "" then
        notify("Current environment: " .. state.current_env, vim.log.levels.INFO)
      else
        env_mod.set_env(args.args)
      end
    end,
    opts = { nargs = "?", desc = "Switch environment or show current" },
  },
  {
    name = "PosteHttpPasteCurl",
    handler = function()
      require("poste-http.http.curl").paste_curl("+")
    end,
    opts = { desc = "Paste curl command from clipboard as HTTP request" },
  },
  {
    name = "PosteHttpImportOpenAPI",
    handler = function()
      require("poste-http.http.import_openapi").run()
    end,
    opts = { desc = "Import OpenAPI 3.x spec as .http files" },
  },
  {
    name = "PosteHttpImportSwagger",
    handler = function()
      require("poste-http.http.import_swagger").run()
    end,
    opts = { desc = "Import Swagger 2.0 spec as .http files" },
  },
  {
    name = "PosteHttpImportPostman",
    handler = function()
      require("poste-http.http.import_postman").run()
    end,
    opts = { desc = "Import Postman collection as .http files" },
  },
  {
    name = "PosteHttpCopyAsCurl",
    handler = function()
      require("poste-http.http.copy").copy_to_clipboard("+")
    end,
    opts = { desc = "Copy current request as curl command to clipboard" },
  },
  {
    name = "PosteHttpChat",
    handler = function()
      require("poste-http.ai").open_chat()
    end,
    opts = { desc = "Open the AI chat scoped to the current .http file (needs poste-ai.nvim)" },
  },
  {
    name = "PosteHttpHelp",
    handler = function()
      require("poste-http.help").open()
    end,
    opts = { desc = "Show Poste keymap help" },
  },
  {
    name = "PosteHttpImportResolve",
    handler = function()
      local import = require("poste-http.http.import")
      local lines = import.status()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "poste://import-status")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "poste"
      vim.bo[buf].modifiable = false
      vim.bo[buf].bufhidden = "wipe"
      local width = 80
      local height = math.min(#lines + 2, 20)
      local _, win = require("poste-http.ui.float").open({
        buf = buf,
        width = width,
        height = height,
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        border = "single",
        title = " Import Resolution Status ",
      })
      if not win then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        return
      end
      vim.api.nvim_buf_attach(buf, false, { on_detach = function() pcall(vim.api.nvim_win_close, win, true) end })
    end,
    opts = { desc = "Show import resolution status" },
  },
  {
    name = "PosteHttpCmpStatus",
    handler = function()
      notify(completion.status(), vim.log.levels.INFO)
    end,
    opts = { desc = "Check poste completion status" },
  },
  {
    name = "PosteHttpCmpProfile",
    handler = function()
      completion.profile()
    end,
    opts = { desc = "Profile poste completion performance" },
  },
  {
    name = "PosteHttpSymbols",
    handler = function()
      symbols.show_symbols()
    end,
    opts = { desc = "Show symbol outline (all HTTP requests)" },
  },
  {
    name = "PosteHttpOutline",
    handler = function()
      symbols.show_symbols()
    end,
    opts = { desc = "Show symbol picker (all HTTP requests)" },
  },
  {
    name = "PosteHttpFormat",
    handler = function()
      local format_file = require("poste-http.http.format_file")
      local changed = format_file.format_buffer()
      if changed then
        notify("formatted", vim.log.levels.INFO)
      else
        notify("already formatted", vim.log.levels.INFO)
      end
    end,
    opts = { desc = "Format .http buffer" },
  },
  {
    name = "PosteHttpHistory",
    handler = function()
      require("poste-http.http.history").show()
    end,
    opts = { desc = "Show HTTP request history" },
  },
  {
    name = "PosteHttpHistoryClear",
    handler = function()
      require("poste-http.http.history").clear()
      notify("HTTP history cleared", vim.log.levels.INFO)
    end,
    -- Scriptable wipe-all (the browser's double-D guard is the interactive
    -- route); mirrors :PosteMqHistoryClear in the family.
    opts = { desc = "Clear HTTP request history (in-memory ring + persisted file)" },
  },
  {
    name = "PosteHttpClearCache",
    handler = function()
      local format = require("poste-http.http.format")
      local cleaned = format.clean_response_cache()
      notify(string.format("Cleared %d old response file(s)", cleaned), vim.log.levels.INFO)
    end,
    opts = { desc = "Remove old cached response files from stdpath(cache)/poste_res/" },
  },
  {
    name = "PosteHttpTSInspect",
    handler = function()
      require("poste-http.http.treesitter").inspect()
    end,
    opts = { desc = "Inspect tree-sitter parse tree for current buffer" },
  },
  {
    -- health.lua / install.lua direct users here when a parser is missing or
    -- stale; the command registration used to be missing, so the guidance
    -- named a command that did not exist.
    name = "PosteHttpBuildParsers",
    handler = function()
      require("poste-http.install").force_build()
    end,
    opts = { desc = "(Re)compile poste tree-sitter parsers" },
  },
}

function M.setup()
  for _, cmd in ipairs(commands) do
    vim.api.nvim_create_user_command(cmd.name, cmd.handler, cmd.opts)
  end
end

function M.status()
  return string.format("[env: %s]", state.current_env)
end

return M