local cache = require("poste-http.http.cache")
local context_detector = require("poste-http.http.context_detector")
local request_vars = require("poste-http.http.request_vars")
local nav_util = require("poste-http.http.nav.util")
local notify = require("poste-http.ui.notify").notify

local M = {}

function M.goto_definition()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col = cursor[2]

  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""

  local trimmed = vim.trim(line_text)
  -- client.run("#alias.Name", ...) inside SCRIPT blocks
  if nav_util.goto_client_run_definition(buf, line_num, col) then
    return
  end
  if trimmed:lower():match("^run%s+#") then
    local cword = vim.fn.expand("<cword>")
    local ref = trimmed:match("^[Rr][Uu][Nn]%s+#(.+)$")
    if ref then
      local name_only = ref:match("^(%S+)") or ref
      local dot_pos = name_only:find("%.")
      if dot_pos then
        local alias = name_only:sub(1, dot_pos - 1)
        local name = name_only:sub(dot_pos + 1)
        if cword == alias then
          local esc_alias = vim.pesc(alias)
          local total = vim.api.nvim_buf_line_count(buf)
          for i = 1, total do
            local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
            if text:match("^%s*import%s+%S+%s+as%s+" .. esc_alias .. "%s*$") then
              local as_find = text:find(" as " .. esc_alias .. "%s*$")
              local target_col = (as_find and as_find + 3) or 0
              vim.cmd("normal! m'")
              vim.api.nvim_win_set_cursor(0, { i, target_col })
              return
            end
          end
          notify("Alias '" .. alias .. "' not found in import directives", vim.log.levels.WARN)
          return
        elseif cword == name then
          local import_mod = require("poste-http.http.import")
          local resolved = import_mod.resolve_run_at_cursor(buf, line_num)
          if resolved.action == "execute" and resolved.path then
            vim.cmd("normal! m'")
            vim.cmd("edit " .. vim.fn.fnameescape(resolved.path))
            local target_text = (vim.api.nvim_buf_get_lines(0, resolved.line - 1, resolved.line, false) or {})[1] or ""
            local name_col = (target_text:find(vim.pesc(name)) or 2) - 1
            vim.api.nvim_win_set_cursor(0, { resolved.line, name_col })
          else
            notify(resolved.error or "Cannot resolve reference", vim.log.levels.WARN)
          end
          return
        end
      else
        local name = name_only
        if cword == name then
          local import_mod = require("poste-http.http.import")
          local resolved = import_mod.resolve_run_at_cursor(buf, line_num)
          if resolved.action == "execute" and resolved.path then
            vim.cmd("normal! m'")
            vim.cmd("edit " .. vim.fn.fnameescape(resolved.path))
            local target_text = (vim.api.nvim_buf_get_lines(0, resolved.line - 1, resolved.line, false) or {})[1] or ""
            local name_col = (target_text:find(vim.pesc(name)) or 2) - 1
            vim.api.nvim_win_set_cursor(0, { resolved.line, name_col })
          else
            notify(resolved.error or "Cannot resolve reference", vim.log.levels.WARN)
          end
          return
        end
      end
    end
  elseif trimmed:lower():match("^run%s+%.") then
    local path = trimmed:match("^[Rr][Uu][Nn]%s+(%S+)")
    if path then
      local path_pos = line_text:find(vim.pesc(path))
      if path_pos and col >= path_pos - 1 and col <= path_pos - 1 + #path then
        nav_util.open_relative_file(path, buf)
        return
      end
    end
  elseif trimmed:match("^>%s+") then
    local path = trimmed:match("^>%s+(%S+)")
    if path then
      local path_pos = line_text:find(vim.pesc(path))
      if path_pos and col >= path_pos - 1 and col <= path_pos - 1 + #path then
        nav_util.open_relative_file(path, buf)
        return
      end
    end
  elseif trimmed:match("^<%s+") then
    local path = trimmed:match("^<%s+(%S+)")
    if path then
      local path_pos = line_text:find(vim.pesc(path))
      if path_pos and col >= path_pos - 1 and col <= path_pos - 1 + #path then
        nav_util.open_relative_file(path, buf)
        return
      end
    end
  elseif trimmed:match("^import%s+") then
    local path = trimmed:match("^import%s+(%S+)")
    if path then
      local path_start = line_text:find(vim.pesc(path))
      if path_start and col >= path_start - 1 and col <= path_start - 1 + #path then
        nav_util.open_relative_file(path, buf)
        return
      end
    end
    local alias = trimmed:match("^import%s+%S+%s+as%s+(%S+)")
    if alias then
      local as_pos = line_text:find("%s+as%s+" .. vim.pesc(alias) .. "%s*$")
      if as_pos then
        local alias_start = as_pos + 4
        if col >= alias_start - 1 and col <= alias_start - 1 + #alias then
          notify("Alias '" .. alias .. "' defined here", vim.log.levels.INFO)
          return
        end
      end
    end
  end

  local req_name = nil
  local start_pos = 1
  while true do
    local s, e = line_text:find("{{(.-)}}", start_pos)
    if not s then break end
    if col + 1 >= s and col + 1 <= e then
      local ref_text = line_text:sub(s + 2, e - 2)
      req_name = vim.trim(ref_text:match("^([^%.]+)%.") or ref_text)
      break
    end
    start_pos = e + 1
  end

  -- Lua import alias.keypath reference: @var = m.a_string
  if not req_name then
    local var_name, suffix = line_text:match("^%s*@(%w[%w_]*)%s*=%s*(.+)%s*$")
    if var_name and suffix then
      local alias, keypath = suffix:match("^(%w+)%.(.+)$")
      if alias and keypath then
        local escaped_alias = vim.pesc(alias)
        local eq_pos = line_text:find("= ", 1, true)
        local suffix_start = eq_pos and (eq_pos + 1) or 1
        local alias_col = line_text:find(escaped_alias, suffix_start, true)
        if alias_col then
          local on_alias_half = col + 1 >= alias_col and col + 1 < alias_col + #alias
          if nav_util.goto_import_keypath(buf, alias, keypath,
              { alias_half = on_alias_half }) then
            return
          end
          notify("Import not found for alias '" .. alias .. "'", vim.log.levels.WARN)
          return
        end
      end
    end
  end

  if not req_name then
    local cword = vim.fn.expand("<cword>")
    if cword and cword ~= "" then
      local before_cursor = line_text:sub(1, col + 1)
      local dot_pos = before_cursor:find("%.[%w_]*$")
      if dot_pos then
        local pre_dot = before_cursor:sub(1, dot_pos - 1)
        local prefix = pre_dot:match("(%w+)$")
        if prefix == "variables" or prefix == "env" then
          req_name = cword
        end
      end
    end
  end

  if not req_name then
    local sc = context_detector.detect_script_context(buf, line_num, col + 1)
    if sc then
      local cword = vim.fn.expand("<cword>")
      if cword and cword ~= "" then
        local requests = request_vars.collect_requests(buf)
        local current_req = nil
        for _, req in ipairs(requests) do
          if line_num >= req.start_line and line_num <= req.end_line then
            current_req = req
            break
          end
        end
        if current_req then
          local local_pat = "^%s*local%s+" .. vim.pesc(cword) .. "%s*[=%n]"
          local assign_pat = "^%s*" .. vim.pesc(cword) .. "%s*="
          for i = current_req.start_line, current_req.end_line do
            local t = cache.get_line_type(buf, i)
            if t == "pre_script" or t == "post_script" then
              local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
              if text:match(local_pat) or text:match(assign_pat) then
                local pos = text:find(cword, 1, true)
                vim.cmd("normal! m'")
                vim.api.nvim_win_set_cursor(0, { i, pos and (pos - 1) or 0 })
                return
              end
            end
          end
        end
      end
    end
    notify("No named request reference under cursor", vim.log.levels.INFO)
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
  local prompt_pattern = "^%s*<<" .. vim.pesc(req_name) .. "%s"
  local prompt_comment_pattern = "^%s*#%s*<<" .. vim.pesc(req_name) .. "%s"
  local found_line = nil
  local found_col = nil

  if current_req then
    for i = current_req.start_line, current_req.end_line do
      local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
      if text:match(var_pattern) or text:match(prompt_pattern) or text:match(prompt_comment_pattern) then
        found_line = i
        break
      end
    end
  end

  if not found_line then
    local end_line = #requests > 0 and requests[1].start_line - 1 or total
    for i = 1, end_line do
      local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
      if text:match(var_pattern) or text:match(prompt_pattern) or text:match(prompt_comment_pattern) then
        found_line = i
        break
      end
    end
  end

  if not found_line then
    local pre_line, pre_col = nav_util.find_var_in_pre_script(buf, req_name, line_num)
    if pre_line then
      found_line = pre_line
      found_col = pre_col
    end
  end

  if found_line then
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { found_line, found_col or 0 })
    return
  end

  if nav_util.goto_env_var(buf, req_name) then return end

  notify("Definition not found: " .. req_name, vim.log.levels.WARN)
end

function M.goto_references()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col = cursor[2]

  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""

  local symbol_name = nil
  local is_request = false

  local start_pos = 1
  while true do
    local s, e = line_text:find("{{(.-)}}", start_pos)
    if not s then break end
    if col + 1 >= s and col + 1 <= e then
      local ref_text = line_text:sub(s + 2, e - 2)
      symbol_name = vim.trim(ref_text:match("^([^%.]+)%.") or ref_text)
      if ref_text:gsub("%.res%.", ".response."):match("%.response%.") or ref_text:match("%.request%.") then
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
    local cword = vim.fn.expand("<cword>")
    if cword and cword ~= "" then
      local before_cursor = line_text:sub(1, col + 1)
      local dot_pos = before_cursor:find("%.[%w_]*$")
      if dot_pos then
        local pre_dot = before_cursor:sub(1, dot_pos - 1)
        local prefix = pre_dot:match("(%w+)$")
        if prefix == "variables" or prefix == "env" then
          symbol_name = cword
        end
      end
    end
  end

  if not symbol_name then
    local req_name = line_text:match("^%s*###%s*(.+)")
    if req_name then
      symbol_name = vim.trim(req_name)
      is_request = true
    end
  end

  local is_import_ref = false
  if not symbol_name then
    local trimmed_l = vim.trim(line_text)
    if trimmed_l:match("^import%s+") then
      local alias = trimmed_l:match("^import%s+%S+%s+as%s+(%S+)")
      if alias then
        local as_pos = line_text:find("%s+as%s+" .. vim.pesc(alias) .. "%s*$")
        if as_pos then
          local alias_start = as_pos + 4
          if col >= alias_start - 1 and col <= alias_start - 1 + #alias then
            symbol_name = alias
            is_import_ref = true
          end
        end
      end
    elseif trimmed_l:lower():match("^run%s+#") then
      local ref = trimmed_l:match("^[Rr][Uu][Nn]%s+#(.+)$")
      if ref then
        local dot_pos = ref:find("%.")
        if dot_pos then
          local alias = ref:sub(1, dot_pos - 1)
          local cword = vim.fn.expand("<cword>")
          if cword == alias then
            symbol_name = alias
            is_import_ref = true
          end
        end
      end
    end
  end

  if not symbol_name then
    local sc = context_detector.detect_script_context(buf, line_num, col + 1)
    if sc then
      local cword = vim.fn.expand("<cword>")
      if cword and cword ~= "" then
        symbol_name = cword
      end
    end
  end

  if not symbol_name then
    notify("No variable or request reference under cursor", vim.log.levels.INFO)
    return
  end

  local results = nav_util.collect_references(buf, symbol_name, is_request, line_num)

  if is_import_ref and symbol_name then
    local total = vim.api.nvim_buf_line_count(buf)
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local esc_alias = vim.pesc(symbol_name)
    local as_marker = " as " .. esc_alias .. "%s*$"
    local hash_marker = "#" .. esc_alias .. "%."
    for i = 1, total do
      local text = all_lines[i] or ""
      local def_raw = text:find("^%s*import%s+%S+%s+as%s+" .. esc_alias .. "%s*$")
      if def_raw then
        local as_pos = text:find(as_marker)
        if as_pos then
          table.insert(results, { line = i, col = as_pos + 3, text = vim.trim(text) })
        end
      end
      local ref_raw = text:find("^%s*run%s+#" .. esc_alias .. "%.")
      if ref_raw then
        local hash_pos = text:find(hash_marker)
        if hash_pos then
          table.insert(results, { line = i, col = hash_pos, text = vim.trim(text) })
        end
      end
    end
  end

  nav_util.show_references(buf, results, symbol_name)
end

return M
