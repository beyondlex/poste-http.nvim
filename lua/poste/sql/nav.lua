local util = require("poste.util")

local M = {}

function M.goto_definition()
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
        local nav_line_text = all_lines[line_num] or ""
        local col = cursor[2]
        local line_len = #nav_line_text

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
          -- Adjust offset to point to the last character of the word, not the
          -- character after it (e.g., for "authors;" the offset should be on
          -- "s" not on ";"). This ensures the Rust binary detects the correct
          -- context type (e.g., schema_table for schema-qualified table refs).
          if offset > 0 then
            offset = offset - 1
          end

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
              elseif ct == "schema_table" and parsed.ctx_data then
                -- Schema-qualified table reference: schema.table (e.g., blog.authors)
                -- ctx_data is the schema name (e.g., "blog").
                -- The cursor is on the table name (e.g., "authors").
                local schema = parsed.ctx_data or ""
                if schema ~= "" then
                  full_ctx.database = schema
                end
                table_name = vim.fn.expand("<cword>")
                column_name = nil
              elseif ct == "table" and parsed.tables and #parsed.tables > 0 then
                -- Cursor is on a table reference: could be a table name, alias,
                -- or schema/database qualifier (e.g., "blog" in "blog.authors").
                local cword = vim.fn.expand("<cword>")
                local cword_lower = cword:lower()
                local schema_match = nil
                local alias_match = nil
                for _, t in ipairs(parsed.tables) do
                  local tn = (t.name or ""):lower()
                  local ta = (t.alias or ""):lower()
                  local ts = (t.schema or ""):lower()
                  if tn == cword_lower then
                    alias_match = t
                    if ts ~= "" then
                      full_ctx.database = ts
                    end
                    break
                  end
                  if ta == cword_lower then alias_match = t; break end
                  if ts == cword_lower then schema_match = t end
                end
                if schema_match then
                  -- cword is a schema/database qualifier: navigate to the database
                  vim.cmd("normal! m'")
                  require("poste.sql.db_browser").navigate_to(full_ctx.connection, cword)
                  return
                elseif alias_match then
                  table_name = alias_match.name
                else
                  table_name = cword
                end
                column_name = nil
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
                  local schema_matched = nil
                  for _, t in ipairs(parsed.tables) do
                    local tn = (t.name or ""):lower()
                    local ta = (t.alias or ""):lower()
                    local ts = (t.schema or ""):lower()
                    if tn == cword_lower or ta == cword_lower then matched = t; break end
                    if ts == cword_lower then schema_matched = t end
                  end
                  if matched then
                    table_name = matched.name or matched.alias
                    column_name = after_dot_col
                  elseif schema_matched then
                    -- cword is a schema/database qualifier (e.g., "blog" in "blog.authors")
                    full_ctx.database = cword
                    table_name = schema_matched.name
                    column_name = nil
                  else
                    local resolved = matched and (matched.name or matched.alias) or parsed.ctx_data
                    if resolved then
                      table_name = resolved
                      column_name = after_dot_col
                    end
                  end
                else
                  local matched = nil
                  local schema_matched = nil
                  for _, t in ipairs(parsed.tables) do
                    local tn = (t.name or ""):lower()
                    local ta = (t.alias or ""):lower()
                    local ts = (t.schema or ""):lower()
                    if tn == cword_lower or ta == cword_lower then matched = t; break end
                    if ts == cword_lower then schema_matched = t end
                  end
                  if matched then
                    table_name = matched.name or matched.alias
                    column_name = nil
                  elseif schema_matched then
                    -- cword is a schema/database qualifier; use the table name
                    -- and override the database context.
                    full_ctx.database = cword
                    table_name = schema_matched.name
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

return M
