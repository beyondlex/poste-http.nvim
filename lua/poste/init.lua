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

  local sql_comp = require("poste.sql.completion")
  local function register_sql_completion()
    local ok_b, blink_mod = pcall(require, "blink.cmp")
    if not ok_b then return end
    blink_mod.add_source_provider("poste_sql", {
      module = "poste.sql.completion",
      name = "PosteSQL",
      async = true,
      score_offset = 1000,
      min_keyword_length = 0,
      should_show_items = true,
    })
    blink_mod.add_filetype_source("poste_sql", "poste_sql")
    blink_mod.add_filetype_source("poste_sqlite", "poste_sql")

    local blink_config = require("blink.cmp.config")
    blink_config.sources.per_filetype["poste_sql"]    = { "poste_sql" }
    blink_config.sources.per_filetype["poste_sqlite"] = { "poste_sql" }

    local orig_blocked = blink_config.completion.trigger.show_on_blocked_trigger_characters
    blink_config.completion.trigger.show_on_blocked_trigger_characters = function()
      local ft = vim.bo.filetype
      if ft == "poste_sql" or ft == "poste_sqlite" then
        local blocked = type(orig_blocked) == "function" and orig_blocked() or orig_blocked
        return vim.tbl_filter(function(c) return c ~= " " end, blocked)
      end
      return type(orig_blocked) == "function" and orig_blocked() or orig_blocked
    end
  end

  local ok, err = pcall(register_sql_completion)
  if not ok then
    local group = vim.api.nvim_create_augroup("PosteSQLCmpRegister", { clear = true })
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = group,
      once = true,
      callback = function()
        pcall(register_sql_completion)
        vim.api.nvim_del_augroup_by_name("PosteSQLCmpRegister")
      end,
    })
  end

  local function setup_buffer_keymaps(buf)
    local keymap_opts = { buffer = buf, noremap = true, silent = true }
    local km = state.get_keymap

    local k = km("source_buffer", "run", "<CR>")
    if k then vim.keymap.set("n", k, M.run_request, keymap_opts) end
    k = km("source_buffer", "jump_next", "]]")
    if k then vim.keymap.set("n", k, M.jump_next, keymap_opts) end
    k = km("source_buffer", "jump_prev", "[[")
    if k then vim.keymap.set("n", k, M.jump_prev, keymap_opts) end
    k = km("source_buffer", "goto_definition", "gd")
    if k then vim.keymap.set("n", k, M.goto_definition, keymap_opts) end
    k = km("source_buffer", "goto_references", "grr")
    if k then vim.keymap.set("n", k, M.goto_references, keymap_opts) end
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
    k = km("source_buffer", "show_symbols", "gs")
    if k then
      vim.keymap.set("n", k, function()
        symbols.show_symbols()
      end, keymap_opts)
    end
    k = km("source_buffer", "pick_env", "<leader>vv")
    if k then vim.keymap.set("n", k, M.pick_env, keymap_opts) end
    k = km("source_buffer", "show_var_value", "K")
    if k then vim.keymap.set("n", k, M.show_var_value, keymap_opts) end
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

    -- File reference markers: underline for < ./path and > ./path
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

  local function setup_db_browser_keymap(buf)
    local k = state.get_keymap("sql_source", "toggle_db_browser", "<leader>db")
    if k then
      vim.keymap.set("n", k, function()
        require("poste.sql.db_browser").toggle()
      end, { buffer = buf, noremap = true, silent = true, desc = "Toggle DB Browser" })
    end
  end

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
    -- Display in a floating scratch buffer
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

  vim.api.nvim_create_user_command("PosteSQLCmpStatus", function()
    local sql_comp = require("poste.sql.completion")
    local ft = vim.bo.filetype
    local buf = vim.api.nvim_get_current_buf()

    local status = {
      "SQL Completion Status:",
      "  Current filetype: " .. ft,
      "  Buffer: " .. buf,
    }

    local instance = sql_comp.new()
    table.insert(status, "  Enabled: " .. tostring(instance:enabled()))

    table.insert(status, "  blink.cmp loaded: true")
    local blink_config = require("blink.cmp.config")
    if blink_config.sources and blink_config.sources.providers then
      local has_sql = blink_config.sources.providers.poste_sql ~= nil
      table.insert(status, "  poste_sql provider registered: " .. tostring(has_sql))
    end

    local ctx_mod = require("poste.sql.context")
    local ctx = ctx_mod.resolve_context(buf)
    table.insert(status, "  Connection: " .. (ctx.connection or "none"))
    table.insert(status, "  Database: " .. (ctx.database or "none"))

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local col = cursor[2]
    local line_before = line:sub(1, col)

    table.insert(status, "\nAt cursor position (col=" .. col .. "):")
    table.insert(status, "  Line: " .. line)
    table.insert(status, "  Before cursor: '" .. line_before .. "'")
    table.insert(status, "  After cursor: '" .. line:sub(col + 1) .. "'")

    if sql_comp._test then
      local ctx_type, ctx_data = sql_comp._test.detect_context_for_completion(line_before)
      table.insert(status, "  Detected context: " .. tostring(ctx_type))
      if ctx_data then
        table.insert(status, "  Context data: " .. tostring(ctx_data))
      end
    end

    vim.notify(table.concat(status, "\n"), vim.log.levels.INFO)
  end, { desc = "Check SQL completion status" })

  vim.api.nvim_create_user_command("PosteSQLAutoTrigger", function()
    local group = vim.api.nvim_create_augroup("PosteSQLAutoComplete", { clear = true })
    vim.api.nvim_create_autocmd("TextChangedI", {
      group = group,
      buffer = 0,
      callback = function()
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(0)[2]

        if col > 0 and line:sub(col, col) == " " then
          local before = line:sub(1, col - 1)
          local last_word = before:match("(%w+)%s*$")

          if last_word then
            local lw = last_word:lower()
            if lw == "from" or lw == "join" or lw == "where" or
               lw == "set" or lw == "on" or lw == "having" or
               lw == "by" or lw == "and" or lw == "or" then
              vim.schedule(function()
                pcall(function() require("blink.cmp").show() end)
              end)
            end
          end
        end
      end
    })
    vim.notify("SQL auto-trigger installed for current buffer", vim.log.levels.INFO)
  end, { desc = "Install SQL auto-trigger for completion" })

vim.api.nvim_create_user_command("PosteSQLCmpReload", function()
    package.loaded["poste.sql.completion"] = nil
    local sql_comp = require("poste.sql.completion")

    local ok_b, blink_mod = pcall(require, "blink.cmp")
    if not ok_b then
      vim.notify("blink.cmp not loaded, cannot re-register", vim.log.levels.WARN)
      return
    end
    blink_mod.add_source_provider("poste_sql", {
      module = "poste.sql.completion",
      name = "PosteSQL",
      score_offset = 1000,
      min_keyword_length = 0,
      should_show_items = true,
    })
    blink_mod.add_filetype_source("poste_sql", "poste_sql")
    blink_mod.add_filetype_source("poste_sqlite", "poste_sql")
    vim.notify("SQL completion reloaded and re-registered with blink.cmp", vim.log.levels.INFO)
  end, { desc = "Reload SQL completion provider" })

  vim.api.nvim_create_user_command("PosteSQLDiag", function()
    local sql_comp = require("poste.sql.completion")
    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local col = cursor[2]
    local line_before = line:sub(1, col)
    local cursor_lnum = cursor[1]

    local ctx_type, ctx_data = sql_comp._test.detect_context_for_completion(line_before)
    local tbls, alias_map = sql_comp._test.extract_from_tables(buf, cursor_lnum)
    local conn = sql_comp._test.conn_key()

    local blink_src = require("blink.cmp.sources.lib")
    local blink_config = require("blink.cmp.config")
    local active_providers = blink_src.get_enabled_provider_ids("insert")
    local per_ft = "(unavailable)"
    if blink_config.sources and blink_config.sources.per_filetype then
      per_ft = vim.inspect(blink_config.sources.per_filetype["poste_sql"])
    end
    local runtime_ft = vim.inspect(blink_src.per_filetype_provider_ids)

    local msg = {
      "line_before: '" .. line_before .. "'",
      "ctx: " .. tostring(ctx_type),
      "conn_key: " .. tostring(conn),
      "cursor_lnum: " .. cursor_lnum,
      "ft: " .. vim.bo.filetype,
      "active blink providers: " .. vim.inspect(active_providers),
      "static per_filetype[poste_sql]: " .. per_ft,
      "runtime per_filetype_provider_ids: " .. runtime_ft,
    }
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, cursor_lnum, false)
    for i, l in ipairs(buf_lines) do
      table.insert(msg, "  " .. i .. ": " .. l)
    end
    table.insert(msg, "tables: " .. vim.inspect(tbls))
    table.insert(msg, "alias_map: " .. vim.inspect(alias_map))

    sql_comp._test.get_items(buf, line_before, cursor_lnum, function(items)
      table.insert(msg, "items(" .. #items .. "): " .. vim.inspect(vim.list_slice(items, 1, 3)))
      vim.notify(table.concat(msg, "\n"), vim.log.levels.WARN)
    end)
  end, { desc = "Diagnose SQL completion at cursor" })

  vim.api.nvim_create_user_command("PosteSQLDebugSpace", function()
    local buf = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)
    local last_word = before:match("(%w+)%s*$")

    local blink_mod = pcall(require, "blink.cmp") and require("blink.cmp") or nil
    local menu_open = false
    local ok_m, menu_mod = pcall(require, "blink.cmp.completion.windows.menu")
    menu_open = ok_m and menu_mod.win:is_open()

    local msg = {
      "PosteSQLDebugSpace:",
      "  line_before cursor: '" .. before .. "'",
      "  last_word: " .. tostring(last_word),
      "  blink loaded: " .. tostring(blink_mod ~= nil),
      "  blink.show exists: " .. tostring(blink_mod and blink_mod.show ~= nil),
      "  menu currently open: " .. tostring(menu_open),
    }

    if blink_mod and blink_mod.show then
      vim.notify(table.concat(msg, "\n") .. "\n  → calling blink.show() now...", vim.log.levels.WARN)
      blink_mod.show()
    else
      vim.notify(table.concat(msg, "\n"), vim.log.levels.ERROR)
    end
  end, { desc = "Debug SQL space completion trigger" })

  vim.api.nvim_create_user_command("PosteSQLCmpTest", function()
    local sql_comp = require("poste.sql.completion")
    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local col = cursor[2]
    local line_before = line:sub(1, col)
    local cursor_line = cursor[1]

    local status = {
      "SQL Completion Test:",
      "  line_before: '" .. line_before .. "'",
      "  cursor_line: " .. cursor_line,
    }

    if sql_comp._test then
      local ctx_type, ctx_data = sql_comp._test.detect_context_for_completion(line_before)
      table.insert(status, "  Context: " .. tostring(ctx_type))

      if ctx_type == "column" and sql_comp._test.extract_from_tables then
        local tbls = sql_comp._test.extract_from_tables(buf, cursor_line)
        table.insert(status, "  Tables found: " .. #tbls .. " - " .. vim.inspect(tbls))
      end

      local conn = sql_comp._test.conn_key and sql_comp._test.conn_key()
      table.insert(status, "  Connection key: " .. tostring(conn))
    end

    if sql_comp._test and sql_comp._test.get_items then
      sql_comp._test.get_items(buf, line_before, cursor_line, function(items)
        table.insert(status, "\nReturned " .. #items .. " items:")
        for i, item in ipairs(items) do
          if i <= 10 then
            table.insert(status, "  " .. item.label .. " (" .. (item.documentation or "") .. ")")
          end
        end
        if #items > 10 then
          table.insert(status, "  ... and " .. (#items - 10) .. " more")
        end
        vim.notify(table.concat(status, "\n"), vim.log.levels.INFO)
      end)
    else
      vim.notify(table.concat(status, "\n"), vim.log.levels.INFO)
    end
  end, { desc = "Test SQL completion at cursor" })

  vim.api.nvim_create_user_command("PosteSQLCmpDebug", function()
    require("poste.sql.completion_debug").toggle()
  end, { desc = "Toggle SQL completion debug floating window" })

  vim.api.nvim_create_user_command("PosteSymbols", function()
    symbols.show_symbols()
  end, { desc = "Show symbol outline (all HTTP requests)" })

  vim.api.nvim_create_user_command("PosteConnection", function()
    require("poste.sql.connections").show_menu()
  end, { desc = "Manage SQL connections" })

  vim.api.nvim_create_user_command("PosteFormat", function()
    local ok, source_format = pcall(require, "poste.sql.source_format")
    if ok then
      source_format.format_buffer()
    else
      vim.notify("Poste source_format module not available", vim.log.levels.ERROR)
    end
  end, { desc = "Format SQL buffer/selection using detected formatter (sqlfluff/sqlfmt/...)" })

  vim.api.nvim_create_user_command("PosteFormatStatus", function()
    local ok, source_format = pcall(require, "poste.sql.source_format")
    if ok then
      source_format.status()
    else
      vim.notify("Poste source_format module not available", vim.log.levels.ERROR)
    end
  end, { desc = "Show formatter status: installed, priority, dialect" })

  vim.api.nvim_create_user_command("PosteFormatHttp", function()
    local binary = state.find_poste_binary()
    if not binary then
      vim.notify("poste binary not found. Run :PosteInstall or set vim.g.poste_binary", vim.log.levels.ERROR)
      return
    end
    vim.cmd(string.format("%%!%s fmt --stdin", vim.fn.shellescape(binary)))
  end, { desc = "Format .http buffer using poste fmt" })

  vim.api.nvim_create_user_command("PosteDBBrowser", function()
    require("poste.sql.db_browser").toggle()
  end, { desc = "Toggle database structure browser sidebar" })

  vim.api.nvim_create_user_command("PosteExport", function(args)
    local parts = {}
    for word in args.args:gmatch("%S+") do
      table.insert(parts, word)
    end
    require("poste.sql.export").run(parts[1], parts[2], parts[3])
  end, {
    nargs = "*",
    complete = function(ArgLead, CmdLine)
      return require("poste.sql.export").complete(ArgLead, CmdLine)
    end,
    desc = "Export dataset — :PosteExport [format] [destination] [path]",
  })

  vim.api.nvim_create_user_command("PosteSqlLog", function()
    require("poste.sql.log_viewer").toggle()
  end, { desc = "Toggle SQL execution log viewer" })

  vim.api.nvim_create_user_command("PosteSQLContext", function(args)
    local context = require("poste.sql.context")
    local parts = {}
    for word in args.args:gmatch("%S+") do
      table.insert(parts, word)
    end
    context.switch_context(parts)
  end, {
    nargs = "*",
    desc = "Switch SQL execution context (connection/database)",
  })

  vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    pattern = { "*.http", "*.rest", "*.redis" },
    callback = function()
      local name = vim.api.nvim_buf_get_name(0)
      if name:match("%.redis$") then
        vim.bo.filetype = "poste_redis"
      else
        vim.bo.filetype = "poste_http"
      end
      setup_buffer_keymaps(0)
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    pattern = { "*.http", "*.rest" },
    callback = function()
      vim.wo.winbar = env_mod.build_http_winbar()
    end,
  })

  vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    pattern = { "*.sql", "*.sqlite" },
    callback = function()
      local name = vim.api.nvim_buf_get_name(0)
      if name:match("%.sqlite$") then
        vim.bo.filetype = "poste_sqlite"
      else
        vim.bo.filetype = "poste_sql"
      end
      setup_buffer_keymaps(0)
      require("poste.sql.init").ensure_sql_keymaps(0)
      setup_db_browser_keymap(0)

      k = state.get_keymap("sql_source", "trigger_completion", "<C-Space>")
      if k then
        vim.keymap.set("i", k, function()
          pcall(function() require("blink.cmp").show() end)
        end, { buffer = 0, noremap = true, silent = true, desc = "Trigger completion" })
      end

      local sql_keywords = { from=true, join=true, where=true, set=true,
                              on=true, having=true, by=true, ["and"]=true, ["or"]=true,
                              use=true }
      local group = vim.api.nvim_create_augroup("PosteSQLTrigger_" .. vim.api.nvim_get_current_buf(), { clear = true })
      vim.api.nvim_create_autocmd("CursorMovedI", {
        group = group,
        buffer = 0,
        callback = function()
          local line = vim.api.nvim_get_current_line()
          local col  = vim.api.nvim_win_get_cursor(0)[2]
          if col < 1 or line:sub(col, col) ~= " " then return end
          local last_word = line:sub(1, col - 1):match("(%w+)%s*$")
          if last_word and sql_keywords[last_word:lower()] then
            local trigger = require("blink.cmp.completion.trigger")
            trigger.show({ force = true, trigger_kind = "manual" })
          end
        end,
      })

      vim.api.nvim_create_autocmd("InsertEnter", {
        group = group,
        buffer = 0,
        callback = function()
          local line = vim.api.nvim_get_current_line()
          local col = vim.api.nvim_win_get_cursor(0)[2]
          local before = line:sub(1, col)
          local prefix = before:match("[%w_]*$") or ""
          if #prefix > 0 then
            vim.schedule(function()
              local trigger = require("blink.cmp.completion.trigger")
              trigger.show({ force = true, trigger_kind = "manual" })
            end)
          end
        end,
      })

      vim.b.blink_cmp_min_keyword_length = 0
    end,
  })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("%.http$") or name:match("%.rest$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_http")
      setup_buffer_keymaps(buf)
    elseif name:match("%.redis$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_redis")
      setup_buffer_keymaps(buf)
    elseif name:match("%.sqlite$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_sqlite")
      setup_buffer_keymaps(buf)
      require("poste.sql.init").ensure_sql_keymaps(buf)
      setup_db_browser_keymap(buf)
    elseif name:match("%.sql$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
      setup_buffer_keymaps(buf)
      require("poste.sql.init").ensure_sql_keymaps(buf)
      setup_db_browser_keymap(buf)
    end
  end

  _G.poste_status = function()
    local parts = { string.format("[env: %s]", state.current_env) }
    local ft = vim.bo.filetype
    if ft == "poste_sql" or ft == "poste_sqlite" then
      local sql_status = require("poste.sql.context").get_status_text()
      if sql_status ~= "" then
        parts[#parts + 1] = sql_status
      end
    end
    return table.concat(parts, " ")
  end
end

return M
