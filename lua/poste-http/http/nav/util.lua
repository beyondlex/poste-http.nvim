local request_vars = require("poste-http.http.request_vars")
local ts_query = require("poste-http.http.ts_query")
local state = require("poste-http.state")
local util = require("poste-http.util")

local M = {}

function M.find_var_def(buf, var_name, cursor_line)
  local current_req = nil
  local requests = request_vars.collect_requests(buf)
  for _, req in ipairs(requests) do
    if cursor_line >= req.start_line and cursor_line <= req.end_line then
      current_req = req
      break
    end
  end

  local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local first_block_line = nil
  for i, l in ipairs(buf_lines) do
    if l:match("^%s*###") then
      first_block_line = i
      break
    end
  end

  if current_req then
    local prompt_defs = ts_query.find_nodes_of_type(buf, "prompt_variable")
    for _, def in ipairs(prompt_defs) do
      local name_node = def:named_child(0)
      if name_node and ts_query.node_text(name_node) == var_name then
        local sr = def:start()
        local def_line = sr + 1
        if def_line >= current_req.start_line and def_line <= current_req.end_line then
          return name_node
        end
      end
    end
  end

  if current_req then
    local var_defs = ts_query.find_nodes_of_type(buf, "variable_definition")
    for _, def in ipairs(var_defs) do
      local name_node = def:named_child(0)
      if name_node and ts_query.node_text(name_node) == var_name then
        local sr = def:start()
        local def_line = sr + 1
        if def_line >= current_req.start_line and def_line <= current_req.end_line then
          return name_node
        end
      end
    end
  end

  local var_defs = ts_query.find_nodes_of_type(buf, "variable_definition")
  for _, def in ipairs(var_defs) do
    local name_node = def:named_child(0)
    if name_node and ts_query.node_text(name_node) == var_name then
      local sr = def:start()
      local def_line = sr + 1
      if not first_block_line or def_line < first_block_line then
        return name_node
      end
    end
  end

  return nil
end

function M.find_var_in_pre_script(buf, var_name, cursor_line)
  local cache = require("poste-http.http.cache")
  local requests = request_vars.collect_requests(buf)
  local current_req = nil
  for _, req in ipairs(requests) do
    if cursor_line >= req.start_line and cursor_line <= req.end_line then
      current_req = req
      break
    end
  end
  if not current_req then return nil end

  local esc_name = vim.pesc(var_name)
  local set_pattern = 'request%.variables%.set%("' .. esc_name .. '%"'
  local set_pattern_single = "request%.variables%.set%('" .. esc_name .. "%'"

  for i = current_req.start_line, current_req.end_line do
    local t = cache.get_line_type(buf, i)
    if t == "pre_script" then
      local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
      if text:match(set_pattern) then
        local q = text:find('"' .. esc_name .. '"', 1, true)
        return i, (q and q - 1) or 0
      elseif text:match(set_pattern_single) then
        local q = text:find("'" .. esc_name .. "'", 1, true)
        return i, (q and q - 1) or 0
      end
    end
  end
  return nil
end

--- Jump to the definition of a client.run("#target", ...) reference inside a
--- SCRIPT block. Resolves the target through the buffer's imports and opens
--- the imported file at the request block.
--- @param buf number
--- @param line_num number  1-based cursor line
--- @param col number       0-based cursor column
--- @return boolean  true when the line contains a client.run call (handled or
---                  failed); false when this is not a client.run reference
function M.goto_client_run_definition(buf, line_num, col)
  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""
  local pos = col + 1

  local call_s, call_e = line_text:find("client%.run%s*%(")
  if not call_s then return false end

  -- First quoted "#target" after the call: "#alias.Name" or "#Name"
  local qs, qe, target = line_text:find('["\']#([^"\']+)["\']', call_e + 1)
  if not qs then return false end

  -- Only handle when the cursor is on the quoted reference
  if pos < qs or pos > qe then return false end

  local import_mod = require("poste-http.http.import")
  local resolved, err = import_mod.resolve_request_reference(target, buf)
  if not resolved then
    vim.notify(err or ("Cannot resolve request '%s'"):format(target), vim.log.levels.WARN)
    return true
  end

  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(resolved.path))
  local target_text = (vim.api.nvim_buf_get_lines(0, resolved.line - 1, resolved.line, false) or {})[1] or ""
  local name_col = (target_text:find(vim.pesc(resolved.request_name)) or 2) - 1
  vim.api.nvim_win_set_cursor(0, { resolved.line, name_col })
  return true
end

--- Collect references across the buffer for a given symbol name.
--- @param buf number
--- @param symbol_name string
--- @param is_request boolean
--- @param line_num number  current cursor line (1-indexed)
--- @return table[]  { line, col, text }[]
function M.collect_references(buf, symbol_name, is_request, line_num)
  local total = vim.api.nvim_buf_line_count(buf)
  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local results = {}
  local seen = {}
  local esc = vim.pesc(symbol_name)
  local comment_pat = "^%s*[#%-]"

  local function add(line_i, text, ref_col)
    if not seen[line_i] and line_i ~= line_num then
      seen[line_i] = true
      table.insert(results, { line = line_i, col = ref_col, text = vim.trim(text) })
    end
  end

  if is_request then
    local def_pat = "^%s*###%s*" .. esc .. "%s*$"
    local ref_pat = "{{" .. esc .. "[%}%.]"
    for i = 1, total do
      local text = all_lines[i] or ""
      if text:match(def_pat) then
        add(i, text, 0)
      elseif not text:match(comment_pat) then
        local ref_col = text:find(ref_pat)
        if ref_col then
          add(i, text, ref_col - 1)
        end
      end
    end
  else
    local def_pat = "^%s*@" .. esc .. "[%s=]"
    local prompt_def_pat = "^%s*<<" .. esc .. "%s"
    local prompt_def_comment_pat = "^%s*#%s*<<" .. esc .. "%s"
    local ref_pat = "{{" .. esc .. "[%}%.]"

    local function find_script_ref(text)
      for _, prefix in ipairs({ "variables", "env" }) do
        local s = text:find(prefix .. "%." .. esc)
        if s then
          local after = s + #prefix + 1 + #symbol_name
          local next_char = text:sub(after, after)
          if next_char == "" or not next_char:match("[%w_]") then
            return s + #prefix
          end
        end
      end
      return nil
    end

    for i = 1, total do
      local text = all_lines[i] or ""
      if text:match(def_pat) or text:match(prompt_def_pat) or text:match(prompt_def_comment_pat) then
        add(i, text, 0)
      elseif not text:match(comment_pat) then
        local ref_col = text:find(ref_pat)
        if ref_col then
          add(i, text, ref_col - 1)
        else
          local script_col = find_script_ref(text)
          if script_col then
            add(i, text, script_col)
          end
        end
      end
    end

    local local_def_pat = "^%s*local%s+" .. esc .. "%s*[=%n]"
    local assign_def_pat = "^%s*" .. esc .. "%s*="
    for i = 1, total do
      local text = all_lines[i] or ""
      if text:match(local_def_pat) or text:match(assign_def_pat) then
        add(i, text, 0)
      else
        local s = 1
        while s <= #text do
          local pos = text:find(symbol_name, s, true)
          if not pos then break end
          local before = pos > 1 and text:sub(pos - 1, pos - 1) or ""
          local after = text:sub(pos + #symbol_name, pos + #symbol_name)
          if not before:match("[%w_]") and not after:match("[%w_]") then
            add(i, text, pos - 1)
            break
          end
          s = pos + 1
        end
      end
    end
  end

  table.sort(results, function(a, b) return a.line < b.line end)
  return results
end

--- Show reference results in a picker or jump directly.
--- @param buf number
--- @param results table[]  { line, col, text }[]
--- @param symbol_name string
function M.show_references(buf, results, symbol_name)
  local line_num = vim.api.nvim_win_get_cursor(0)[1]
  local filtered = {}
  for _, r in ipairs(results) do
    if r.line ~= line_num then
      table.insert(filtered, r)
    end
  end
  results = filtered

  if #results == 0 then
    vim.notify("No other references found for: " .. symbol_name, vim.log.levels.INFO)
    return
  end

  if #results == 1 then
    local r = results[1]
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { r.line, r.col })
    return
  end

  local items = {}
  for _, r in ipairs(results) do
    table.insert(items, string.format("L%d:%d: %s", r.line, r.col, r.text))
  end

  local function jump_to(item)
    xpcall(function()
      local target_line, target_col = item:match("^L(%d+):(%d+):")
      if not target_line then return end
      local line = tonumber(target_line)
      local target_col_num = tonumber(target_col)
      if not line or not target_col_num then return end
      line = math.floor(line)
      target_col_num = math.floor(target_col_num)
      local line_count = vim.fn.line("$")
      if line < 1 or line > line_count then return end
      local lines2 = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)
      local goto_line_text = (lines2 and lines2[1]) or ""
      if target_col_num < 0 or target_col_num > #goto_line_text then target_col_num = 0 end
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { line, target_col_num })
    end, function(err) end)
  end

  local selector = require("poste-http.select")
  selector.select(items, "References to '" .. symbol_name .. "'", function(selected)
    if selected then
      jump_to(selected)
    end
  end)
end

--- Search for a variable in env.json and open the file at the matching line.
--- @param buf number
--- @param var_name string
--- @return boolean  true if found and jumped
function M.goto_env_var(buf, var_name)
  local buf_path = vim.api.nvim_buf_get_name(buf)
  if buf_path == "" then return false end
  local search_dir = vim.fn.fnamemodify(buf_path, ":h")
  local env_file = util.find_file_upwards("env.json", search_dir)
  if not env_file then return false end

  local env_lines = vim.fn.readfile(env_file)
  if not env_lines or #env_lines == 0 then return false end

  local current_env = state.current_env
  local env_section_start = nil
  local env_pattern = '^%s*"' .. vim.pesc(current_env) .. '"%s*:'
  for i, l in ipairs(env_lines) do
    if l:match(env_pattern) then
      env_section_start = i
      break
    end
  end

  if not env_section_start then return false end

  local depth = 0
  local env_section_end = #env_lines
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

  for i = env_section_start + 1, env_section_end do
    local l = env_lines[i]
    if l:match('^%s*"' .. vim.pesc(var_name) .. '"%s*:') then
      vim.cmd("normal! m'")
      vim.cmd("edit " .. vim.fn.fnameescape(env_file))
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return true
    end
  end
  return false
end

--- Open a file path relative to the current buffer's directory.
--- @param path string
--- @param buf number
--- @return boolean  true if file was opened
function M.open_relative_file(path, buf)
  local buf_name = vim.api.nvim_buf_get_name(buf)
  local buf_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
  local full_path = vim.fn.simplify(buf_dir .. "/" .. path)
  if vim.fn.filereadable(full_path) == 1 then
    vim.cmd("normal! m'")
    vim.cmd("edit " .. vim.fn.fnameescape(full_path))
    return true
  end
  vim.notify("File not found: " .. full_path, vim.log.levels.WARN)
  return false
end

return M
