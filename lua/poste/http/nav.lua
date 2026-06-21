local state = require("poste.state")
local util = require("poste.util")
local request_vars = require("poste.http.request_vars")

local M = {}

function M.jump_next()
  local line = vim.fn.line(".")
  local total = vim.fn.line("$")
  for i = line + 1, total do
    local text = vim.fn.getline(i)
    if text:match("^###") then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  vim.notify("No more requests", vim.log.levels.INFO)
end

function M.jump_prev()
  local line = vim.fn.line(".")
  for i = line - 1, 1, -1 do
    local text = vim.fn.getline(i)
    if text:match("^###") then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  vim.notify("No previous requests", vim.log.levels.INFO)
end

function M.show_var_value()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col = cursor[2] + 1
  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""

  local var_name = nil
  local s, e = line_text:find("{{[^}]+}}")
  while s do
    if col >= s and col <= e then
      var_name = line_text:sub(s + 2, e - 2):gsub("^%s+", ""):gsub("%s+$", "")
      break
    end
    s, e = line_text:find("{{[^}]+}}", e + 1)
  end

  if not var_name then
    vim.notify("Not on a {{variable}} reference", vim.log.levels.WARN, { title = "Poste" })
    return
  end

  local resolved = nil
  local source = nil

  local magic_vars = {
    timestamp = function() return tostring(os.time()) .. math.random(100000, 999999) end,
    uuid = function()
      local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
      return template:gsub("[xy]", function(c)
        local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
        return string.format("%x", v)
      end)
    end,
    date = function() return os.date("%Y-%m-%d") end,
    randomInt = function() return tostring(math.random(0, 9999999)) end,
  }
  if var_name:match("^%$") then
    local magic_name = var_name:sub(2)
    if magic_vars[magic_name] then
      resolved = magic_vars[magic_name]()
      source = "magic var"
    end
  end

  if not resolved then
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for _, l in ipairs(all_lines) do
      if l:match("^###") then break end
      local def_name, def_op, def_val = l:match("^%s*@(%w+)%s*(=?)(.*)")
      if def_name and def_name == var_name then
        resolved = vim.trim(def_val)
        source = "file variable"
        break
      end
    end
  end

  if not resolved then
    local buf_path = vim.api.nvim_buf_get_name(buf)
    if buf_path ~= "" then
      local search_dir = vim.fn.fnamemodify(buf_path, ":h")
      local env_file = util.find_file_upwards("env.json", search_dir)
      if env_file then
        local env_lines = vim.fn.readfile(env_file)
        if env_lines and #env_lines > 0 then
          local ok, env_data = pcall(vim.json.decode, table.concat(env_lines, "\n"))
          if ok and type(env_data) == "table" then
            local env_vars = env_data[state.current_env]
            if env_vars and type(env_vars) == "table" and env_vars[var_name] then
              resolved = env_vars[var_name]
              source = "env.json (" .. state.current_env .. ")"
            end
          end
        end
      end
    end
  end

  if not resolved then
    resolved = "(unresolved)"
    source = "unknown"
  end

  local title = "{{" .. var_name .. "}}"
  local lines = { resolved }
  if source then
    table.insert(lines, "")
    table.insert(lines, "— " .. source)
  end

  local max_width = math.min(math.floor(vim.o.columns * 0.7), 80)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 4, max_width)

  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.4))
  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].modifiable = false

  local win_opts = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height, style = "minimal",
    border = "rounded", title = title, title_pos = "left",
  }
  local ok, win = pcall(vim.api.nvim_open_win, float_buf, true, win_opts)
  if not ok then
    win_opts.title = nil; win_opts.title_pos = nil
    win = vim.api.nvim_open_win(float_buf, true, win_opts)
  end

  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end,
    { buffer = float_buf, noremap = true, silent = true })
  vim.keymap.set("n", "<Esc>", function() pcall(vim.api.nvim_win_close, win, true) end,
    { buffer = float_buf, noremap = true, silent = true })
end

function M.goto_definition()
  local ft = vim.bo.filetype
  if ft == "poste_sql" or ft == "poste_sqlite" then
    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_num = cursor[1]
    local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""
    local conn_match = line_text:match("^%s*--%s*@connection%s+(.+)")
    if conn_match then
      local conn_name = vim.trim(conn_match)
      local connections = require("poste.sql.connections")
      local search_dir = vim.api.nvim_buf_get_name(buf)
      if search_dir ~= "" then
        search_dir = vim.fn.fnamemodify(search_dir, ":h")
      else
        search_dir = vim.fn.getcwd()
      end
      local config_path = connections.find_connections_json(search_dir)
      if not config_path then
        vim.notify("connections.json not found", vim.log.levels.WARN)
        return
      end
      local config_lines = vim.fn.readfile(config_path)
      if not config_lines then
        vim.notify("Cannot read connections.json", vim.log.levels.WARN)
        return
      end
      local target_line = nil
      local pattern = '^%s*"' .. vim.pesc(conn_name) .. '"%s*:'
      for i, l in ipairs(config_lines) do
        if l:match(pattern) then
          target_line = i
          break
        end
      end
      if not target_line then
        vim.notify("Connection '" .. conn_name .. "' not found in connections.json", vim.log.levels.WARN)
        return
      end
      vim.cmd("normal! m'")
      vim.cmd("edit " .. vim.fn.fnameescape(config_path))
      vim.api.nvim_win_set_cursor(0, { target_line, 0 })
      return
    end
    local db_match = line_text:match("^%s*--%s*@database%s+(.+)")
    if db_match then
      local db_name = vim.trim(db_match)
      local ctx = require("poste.sql.context")
      local full_ctx = ctx.resolve_full_context(buf, line_num)
      local conn = full_ctx.connection
      if not conn then
        vim.notify("No connection context for database '" .. db_name .. "'. Add -- @connection <name> to the file.", vim.log.levels.WARN)
        return
      end
      vim.cmd("normal! m'")
      require("poste.sql.db_browser").navigate_to(conn, db_name)
      return
    end
    local table_name = vim.fn.expand("<cword>")
    if table_name and table_name ~= "" then
      local ctx = require("poste.sql.context")
      local full_ctx = ctx.resolve_full_context(buf, line_num)
      if full_ctx.connection then
        local data = require("poste.sql.completion_data")
        local bin = data.find_binary()
        local column_name = nil

        if bin then
          local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          local line_text = all_lines[line_num] or ""
          local col = cursor[2]
          local line_len = #line_text

          local end_col = col
          while end_col < line_len do
            local ch = line_text:sub(end_col + 1, end_col + 1)
            if ch:match("[%w_]") then end_col = end_col + 1 else break end
          end

          local block_start = 1
          if line_num > 1 then
            for i = line_num - 1, 1, -1 do
              if all_lines[i] and all_lines[i]:match("^###") then block_start = i + 1; break end
            end
          end
          local block_end = #all_lines
          for i = line_num + 1, #all_lines do
            if all_lines[i] and all_lines[i]:match("^###") then block_end = i - 1; break end
          end

          if block_start <= line_num and line_num <= block_end then
            local before_parts = {}
            for i = block_start, line_num - 1 do
              table.insert(before_parts, all_lines[i] or "")
            end
            table.insert(before_parts, line_text:sub(1, end_col))
            local offset = #table.concat(before_parts, "\n")

            local block_parts = {}
            for i = block_start, block_end do table.insert(block_parts, all_lines[i] or "") end
            local sql_text = table.concat(block_parts, "\n")

            local dialect_flag = ""
            local conn_config = require("poste.sql.connections").get_connection_config(full_ctx.connection)
            if conn_config and conn_config.dialect then
              dialect_flag = " --dialect " .. conn_config.dialect
            end

            local cmd = string.format("%s context detect %d%s",
              vim.fn.shellescape(bin), offset, dialect_flag)
            local output = vim.fn.system(cmd, sql_text)
            if vim.v.shell_error == 0 then
              local ok, parsed = pcall(vim.json.decode, output)
              if ok and parsed then
                util.clean_nil(parsed)

                local ct = parsed.ctx_type
                if ct == "dot_column" and parsed.ctx_data then
                  local resolved = nil
                  local prefix = parsed.ctx_data or ""
                  if parsed.tables then
                    for _, t in ipairs(parsed.tables) do
                      if t.alias and t.alias:lower() == prefix:lower() then
                        resolved = t.name
                        break
                      end
                    end
                  end
                  local ad = line_text:sub(end_col + 2)
                  local cm = ad:match("^([%w_]+)")
                  table_name = resolved or prefix
                  column_name = cm or vim.fn.expand("<cword>")
                elseif ct == "insert_column" and parsed.ctx_data then
                  local resolved = nil
                  local prefix = parsed.ctx_data or ""
                  if parsed.tables then
                    for _, t in ipairs(parsed.tables) do
                      if t.alias and t.alias:lower() == prefix:lower() then
                        resolved = t.name
                        break
                      end
                    end
                  end
                  local ad = line_text:sub(end_col + 2)
                  local cm = ad:match("^([%w_]+)")
                  table_name = resolved or prefix
                  column_name = cm or vim.fn.expand("<cword>")
                elseif (ct == "column" or ct == "keyword") and parsed.tables and #parsed.tables > 0 then
                  local cword = vim.fn.expand("<cword>")
                  local cword_lower = cword:lower()

                  local after_dot_col = nil
                  local nxt = line_text:sub(end_col + 1, end_col + 1)
                  if nxt == "." then
                    local cm = line_text:match("^([%w_]+)", end_col + 2)
                    if cm then after_dot_col = cm end
                  end

                  if after_dot_col then
                    local matched = nil
                    for _, t in ipairs(parsed.tables) do
                      local tn = (t.name or ""):lower()
                      local ta = (t.alias or ""):lower()
                      if tn == cword_lower or ta == cword_lower then matched = t; break end
                    end
                    local resolved = matched and (matched.name or matched.alias) or parsed.ctx_data
                    if resolved then
                      table_name = resolved
                      column_name = after_dot_col
                    end
                  else
                    local matched = nil
                    for _, t in ipairs(parsed.tables) do
                      local tn = (t.name or ""):lower()
                      local ta = (t.alias or ""):lower()
                      if tn == cword_lower or ta == cword_lower then matched = t; break end
                    end
                    if matched then
                      table_name = matched.name or matched.alias
                      column_name = nil
                    else
                      local alias = nil
                      local ws = col
                      while ws > 0 do
                        if not line_text:sub(ws + 1, ws + 1):match("[%w_]") then break end
                        ws = ws - 1
                      end
                      if ws >= 0 and line_text:sub(ws + 1, ws + 1) == "." then
                        local ae = ws - 1
                        local ap = ae
                        while ap >= 0 do
                          if not line_text:sub(ap + 1, ap + 1):match("[%w_]") then break end
                          ap = ap - 1
                        end
                        if ap + 1 <= ae then alias = line_text:sub(ap + 2, ae + 1) end
                      end
                      local resolved = nil
                      if alias then
                        for _, t in ipairs(parsed.tables) do
                          if t.alias and t.alias:lower() == alias:lower() then
                            resolved = t.name or t.alias; break
                          end
                        end
                      end
                      if resolved then
                        table_name = resolved
                        column_name = cword
                      else
                        local target = parsed.tables[1].name or parsed.tables[1].alias
                        if target then
                          table_name = target
                          column_name = cword
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end

        vim.cmd("normal! m'")
        require("poste.sql.db_browser").navigate_to_table(full_ctx.connection, full_ctx.database, table_name, column_name)
        return
      end
    end
    vim.notify("No connection context. Add -- @connection <name> to the file header.", vim.log.levels.WARN)
  end

  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col = cursor[2]

  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""

  local req_name = nil
  local start_pos = 1
  while true do
    local s, e = line_text:find("{{[^}]+}}", start_pos)
    if not s then break end
    if col + 1 >= s and col + 1 <= e then
      local ref_text = line_text:sub(s + 2, e - 2)
      req_name = vim.trim(ref_text:match("^([^%.]+)%.") or ref_text)
      break
    end
    start_pos = e + 1
  end

  if not req_name then
    vim.notify("No named request reference under cursor", vim.log.levels.INFO)
    return
  end

  local requests = request_vars.collect_requests(buf)
  for _, req in ipairs(requests) do
    if req.name == req_name then
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { req.start_line, 0 })
      return
    end
  end

  local total = vim.api.nvim_buf_line_count(buf)

  local current_req = nil
  for _, req in ipairs(requests) do
    if line_num >= req.start_line and line_num <= req.end_line then
      current_req = req
      break
    end
  end

  local var_pattern = "^%s*@" .. vim.pesc(req_name) .. "[%s=]"
  local found_line = nil

  if current_req then
    for i = current_req.start_line, current_req.end_line do
      local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
      if text:match(var_pattern) then
        found_line = i
        break
      end
    end
  end

  if not found_line then
    local end_line = #requests > 0 and requests[1].start_line - 1 or total
    for i = 1, end_line do
      local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
      if text:match(var_pattern) then
        found_line = i
        break
      end
    end
  end

  if found_line then
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { found_line, 0 })
    return
  end

  local buf_path = vim.api.nvim_buf_get_name(buf)
  if buf_path == "" then
    vim.notify("Definition not found: " .. req_name, vim.log.levels.WARN)
    return
  end

  local search_dir = vim.fn.fnamemodify(buf_path, ":h")
  local env_file = util.find_file_upwards("env.json", search_dir)

  if not env_file then
    vim.notify("Definition not found: " .. req_name, vim.log.levels.WARN)
    return
  end

  local env_lines = vim.fn.readfile(env_file)
  if not env_lines or #env_lines == 0 then
    vim.notify("Cannot read env.json", vim.log.levels.WARN)
    return
  end

  local env_content = table.concat(env_lines, "\n")
  local ok, env_data = pcall(vim.json.decode, env_content)
  if not ok or type(env_data) ~= "table" then
    vim.notify("Cannot parse env.json", vim.log.levels.WARN)
    return
  end

  local current_env = state.current_env
  local env_vars = env_data[current_env]
  if not env_vars or type(env_vars) ~= "table" then
    vim.notify(string.format("Environment '%s' not found in env.json", current_env), vim.log.levels.WARN)
    return
  end

  if env_vars[req_name] then
    local env_section_start = nil
    local env_pattern = '^%s*"' .. vim.pesc(current_env) .. '"%s*:'
    for i, l in ipairs(env_lines) do
      if l:match(env_pattern) then
        env_section_start = i
        break
      end
    end

    local env_section_end = #env_lines
    if env_section_start then
      local depth = 0
      local started = false
      for i = env_section_start, #env_lines do
        local l = env_lines[i]
        local opens = (l:match("{") and 1 or 0) - (l:match("}") and 1 or 0)
        if i == env_section_start then
          depth = depth + opens
          started = true
        elseif started then
          depth = depth + opens
          if depth <= 0 then
            env_section_end = i
            break
          end
        end
      end
    end

    local target_line = nil
    local start_search = (env_section_start or 0) + 1
    for i = start_search, env_section_end do
      local l = env_lines[i]
      if l:match('^%s*"' .. vim.pesc(req_name) .. '"%s*:') then
        target_line = i
        break
      end
    end

    if target_line then
      vim.cmd("normal! m'")
      vim.cmd("edit " .. vim.fn.fnameescape(env_file))
      vim.api.nvim_win_set_cursor(0, { target_line, 0 })
      return
    end
  end

  vim.notify("Definition not found: " .. req_name, vim.log.levels.WARN)
end

function M.goto_references()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col = cursor[2]

  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""
  local total = vim.api.nvim_buf_line_count(buf)

  local symbol_name = nil
  local is_request = false

  local start_pos = 1
  while true do
    local s, e = line_text:find("{{[^}]+}}", start_pos)
    if not s then break end
    if col + 1 >= s and col + 1 <= e then
      local ref_text = line_text:sub(s + 2, e - 2)
      symbol_name = vim.trim(ref_text:match("^([^%.]+)%.") or ref_text)
      if ref_text:match("%.response%.") or ref_text:match("%.request%.") then
        is_request = true
      end
      break
    end
    start_pos = e + 1
  end

  if not symbol_name then
    local var_name = line_text:match("^%s*@(.-)[%s=]")
    if var_name then
      symbol_name = vim.trim(var_name)
    end
  end

  if not symbol_name then
    local req_name = line_text:match("^%s*###%s*(.+)")
    if req_name then
      symbol_name = vim.trim(req_name)
      is_request = true
    end
  end

  if not symbol_name then
    vim.notify("No variable or request reference under cursor", vim.log.levels.INFO)
    return
  end

  local results = {}
  local seen = {}

  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local function add(line_i, text, ref_col)
    if not seen[line_i] and line_i ~= line_num then
      seen[line_i] = true
      table.insert(results, { line = line_i, text = text, col = ref_col })
    end
  end

  local esc = vim.pesc(symbol_name)

  local comment_pat = "^%s*[#%-]"

  if is_request then
    local def_pat = "^%s*###%s*" .. esc .. "%s*$"
    local ref_pat = "{{" .. esc .. "[%}%.]"
    for i = 1, total do
      local text = all_lines[i] or ""
      if text:match(def_pat) then
        add(i, vim.trim(text), 0)
      elseif not text:match(comment_pat) then
        local ref_col = text:find(ref_pat)
        if ref_col then
          add(i, vim.trim(text), ref_col - 1)
        end
      end
    end
  else
    local def_pat = "^%s*@" .. esc .. "[%s=]"
    local ref_pat = "{{" .. esc .. "[%}%.]"
    for i = 1, total do
      local text = all_lines[i] or ""
      if text:match(def_pat) then
        add(i, vim.trim(text), 0)
      elseif not text:match(comment_pat) then
        local ref_col = text:find(ref_pat)
        if ref_col then
          add(i, vim.trim(text), ref_col - 1)
        end
      end
    end
  end

  local filtered_results = {}
  for _, r in ipairs(results) do
    if r.line ~= line_num then
      table.insert(filtered_results, r)
    end
  end
  results = filtered_results

  if #results == 0 then
    vim.notify("No other references found for: " .. symbol_name, vim.log.levels.INFO)
    return
  end

  table.sort(results, function(a, b) return a.line < b.line end)

  if #results == 1 then
    local r = results[1]
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { r.line, r.col })
    return
  end

  local items = {}
  local filetype = vim.api.nvim_get_option_value("filetype", {buf = buf})

  for idx, r in ipairs(results) do
    table.insert(items, string.format("L%d:%d: %s", r.line, r.col, r.text))
  end

  local preview_data = setmetatable({}, {
    __index = function(_, idx)
      local r = results[idx]
      if not r then return nil end

      local ctx = 5
      local start_l = math.max(1, r.line - ctx)
      local end_l = math.min(total, r.line + ctx)
      local preview_lines = {}
      for i = start_l, end_l do
        local ltext = all_lines[i] or ""
        local prefix = (i == r.line) and "▶ " .. i .. " " or "  " .. i .. " "
        preview_lines[i - start_l + 1] = prefix .. ltext
      end

      return {
        lines = preview_lines,
        filetype = filetype,
        highlight_line = r.line - start_l + 1,
      }
    end
  })

  local function jump_to(item)
    xpcall(function()
      local target_line, target_col = item:match("^L(%d+):(%d+):")
      if not target_line then return end

      local line = tonumber(target_line)
      local col = tonumber(target_col)
      if not line or not col then return end

      line = math.floor(line)
      col = math.floor(col)

      local line_count = vim.fn.line("$")
      if line < 1 or line > line_count then return end

      local lines = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)
      local line_text = (lines and lines[1]) or ""
      if col < 0 or col > #line_text then col = 0 end

      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { line, col })
    end, function(err)
    end)
  end

  local select = require("poste.select")
  select.select(items, "References to '" .. symbol_name .. "'", function(selected)
    if selected then
      jump_to(selected)
    end
  end, preview_data)
end

return M
