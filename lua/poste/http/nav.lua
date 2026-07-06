local state = require("poste.state")
local util = require("poste.util")
local request_vars = require("poste.http.request_vars")
local context_detector = require("poste.http.context_detector")
local data = require("poste.http.data")
local lua_docs = require("poste.http.lua_docs")

local M = {}

--- Show documentation for script API keywords (client.*, response.*, request.*, etc.)
--- inside pre/post script blocks (< {% %} / > {% %}).
--- Returns true if doc was shown, false otherwise.
function M.show_script_api_doc()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col_1idx = cursor[2] + 1
  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""

  local ctx = context_detector.detect_script_context(buf, line_num, col_1idx)
  if not ctx then return false end

  local ctx_key = ctx == "pre_script" and "pre" or "post"
  local docs = data.script_api_docs[ctx_key]
  if not docs then return false end

  -- Extract the full dotted identifier under cursor
  local start = col_1idx
  while start > 1 do
    local ch = line_text:sub(start - 1, start - 1)
    if ch:match("[%w_]") or ch == "." then start = start - 1 else break end
  end

  local finish = col_1idx
  while finish < #line_text do
    local ch = line_text:sub(finish + 1, finish + 1)
    if ch:match("[%w_]") or ch == "." then finish = finish + 1 else break end
  end

  local identifier = start <= finish and line_text:sub(start, finish) or nil
  if not identifier then return false end

  -- Lua standard library identifiers (tostring, os.time, string.match, etc.)
  -- go directly to LSP / built-in fallback, skipping Poste custom docs.
  if lua_docs.is_lua_identifier(identifier) then
    lua_docs.show_doc(buf, line_num, col_1idx, identifier)
    return true
  end

  -- Determine which dotted segment the cursor is on, then walk up
  -- e.g. response.body.json: cursor on response → lookup response;
  --      cursor on body → lookup response.body;
  --      cursor on json → lookup response.body.json (walk up to response.body)
  local entry = nil
  local rel = col_1idx - start + 1
  local seg_start = 1
  local prefix_parts = {}

  for segment in identifier:gmatch("[^%.]+") do
    local seg_end = seg_start + #segment - 1
    table.insert(prefix_parts, segment)
    if rel >= seg_start and rel <= seg_end then
      local lookup_path = table.concat(prefix_parts, ".")
      entry = docs[lookup_path]
      while not entry and lookup_path:find("%.") do
        lookup_path = lookup_path:match("^(.+)%.[^%.]+$")
        entry = docs[lookup_path]
      end
      break
    end
    seg_start = seg_end + 2
  end
  -- Fallback: try just the word under cursor (for assert, variables, env)
  if not entry then
    local cword = vim.fn.expand("<cword>")
    if cword and cword ~= "" then entry = docs[cword] end
  end
  if not entry then
    lua_docs.show_doc(buf, line_num, col_1idx, identifier)
    return true
  end

  -- Build floating window content
  local lines = {}
  table.insert(lines, entry.sig)
  table.insert(lines, "")
  table.insert(lines, entry.desc)

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

  local title = ctx == "pre_script" and "Pre-script API" or "Post-script API"
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

  return true
end

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
  -- Try script API documentation first (inside < {% %} / > {% %} blocks)
  if M.show_script_api_doc() then return end

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
    -- Check client.global vars (set via pre/post scripts)
    local state = require("poste.state")
    if state.global_vars and state.global_vars[var_name] then
      resolved = state.global_vars[var_name]
      source = "client.global (session var)"
    end
  end

  if not resolved then
    -- Check script_variables (request.variables.set from post-scripts)
    local state = require("poste.state")
    if state.script_variables and state.script_variables[var_name] then
      resolved = state.script_variables[var_name]
      source = "script variable (session var)"
    end
  end

  if not resolved then
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for _, l in ipairs(all_lines) do
      if l:match("^###") then break end
      local def_name, _, def_val = l:match("^%s*@(%w+)%s*(=?)(.*)")
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
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col = cursor[2]

  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""

  -- Import/run go-to-definition
  local trimmed = vim.trim(line_text)
  if trimmed:match("^run%s+#") then
    local cword = vim.fn.expand("<cword>")
    local ref = trimmed:match("^run%s+#(.+)$")
    if ref then
      local name_only = ref:match("^(%S+)") or ref
      local dot_pos = name_only:find("%.")
      if dot_pos then
        local alias = name_only:sub(1, dot_pos - 1)
        local name = name_only:sub(dot_pos + 1)
        if cword == alias then
          -- Jump to import alias definition in this file
          local esc_alias = vim.pesc(alias)
          local total = vim.api.nvim_buf_line_count(buf)
          local found = false
          for i = 1, total do
            local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
            if text:match("^%s*import%s+%S+%s+as%s+" .. esc_alias .. "%s*$") then
              local as_find = text:find(" as " .. esc_alias .. "%s*$")
              local target_col = (as_find and as_find + 3) or 0
              vim.cmd("normal! m'")
              vim.api.nvim_win_set_cursor(0, { i, target_col })
              found = true
              break
            end
          end
          if not found then
            vim.notify("Alias '" .. alias .. "' not found in import directives", vim.log.levels.WARN)
          end
          return
        elseif cword == name then
          -- Jump to request in imported file
          local import_mod = require("poste.http.import")
          local resolved = import_mod.resolve_run_at_cursor(buf, line_num)
          if resolved.action == "execute" and resolved.path then
            vim.cmd("normal! m'")
            vim.cmd("edit " .. vim.fn.fnameescape(resolved.path))
            local target_text = (vim.api.nvim_buf_get_lines(0, resolved.line - 1, resolved.line, false) or {})[1] or ""
            local name_col = (target_text:find(vim.pesc(name)) or 2) - 1
            vim.api.nvim_win_set_cursor(0, { resolved.line, name_col })
          else
            vim.notify(resolved.error or "Cannot resolve reference", vim.log.levels.WARN)
          end
          return
        end
      else
        local name = name_only
        if cword == name then
          -- Jump to request in bare import
          local import_mod = require("poste.http.import")
          local resolved = import_mod.resolve_run_at_cursor(buf, line_num)
          if resolved.action == "execute" and resolved.path then
            vim.cmd("normal! m'")
            vim.cmd("edit " .. vim.fn.fnameescape(resolved.path))
            local target_text = (vim.api.nvim_buf_get_lines(0, resolved.line - 1, resolved.line, false) or {})[1] or ""
            local name_col = (target_text:find(vim.pesc(name)) or 2) - 1
            vim.api.nvim_win_set_cursor(0, { resolved.line, name_col })
          else
            vim.notify(resolved.error or "Cannot resolve reference", vim.log.levels.WARN)
          end
          return
        end
      end
    end
  elseif trimmed:match("^run%s+%.") then
    -- run ./path — open target file at line 1
    local path = trimmed:match("^run%s+(%S+)")
    if path then
      local path_pos = line_text:find(vim.pesc(path))
      if path_pos and col >= path_pos - 1 and col <= path_pos - 1 + #path then
        local buf_name = vim.api.nvim_buf_get_name(buf)
        local buf_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
        local full_path = vim.fn.simplify(buf_dir .. "/" .. path)
        if vim.fn.filereadable(full_path) == 1 then
          vim.cmd("normal! m'")
          vim.cmd("edit " .. vim.fn.fnameescape(full_path))
        else
          vim.notify("File not found: " .. full_path, vim.log.levels.WARN)
        end
        return
      end
    end
  elseif trimmed:match("^>%s+") then
    -- > ./path — open script/assertion file at line 1
    local path = trimmed:match("^>%s+(%S+)")
    if path then
      local path_pos = line_text:find(vim.pesc(path))
      if path_pos and col >= path_pos - 1 and col <= path_pos - 1 + #path then
        local buf_name = vim.api.nvim_buf_get_name(buf)
        local buf_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
        local full_path = vim.fn.simplify(buf_dir .. "/" .. path)
        if vim.fn.filereadable(full_path) == 1 then
          vim.cmd("normal! m'")
          vim.cmd("edit " .. vim.fn.fnameescape(full_path))
        else
          vim.notify("File not found: " .. full_path, vim.log.levels.WARN)
        end
        return
      end
    end
  elseif trimmed:match("^<%s+") then
    -- < ./path — open file include / file upload target
    local path = trimmed:match("^<%s+(%S+)")
    if path then
      local path_pos = line_text:find(vim.pesc(path))
      if path_pos and col >= path_pos - 1 and col <= path_pos - 1 + #path then
        local buf_name = vim.api.nvim_buf_get_name(buf)
        local buf_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
        local full_path = vim.fn.simplify(buf_dir .. "/" .. path)
        if vim.fn.filereadable(full_path) == 1 then
          vim.cmd("normal! m'")
          vim.cmd("edit " .. vim.fn.fnameescape(full_path))
        else
          vim.notify("File not found: " .. full_path, vim.log.levels.WARN)
        end
        return
      end
    end
  elseif trimmed:match("^import%s+") then
    local path = trimmed:match("^import%s+(%S+)")
    if path then
      local path_start = line_text:find(vim.pesc(path))
      if path_start and col >= path_start - 1 and col <= path_start - 1 + #path then
        local buf_name = vim.api.nvim_buf_get_name(buf)
        local buf_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
        local full_path = vim.fn.simplify(buf_dir .. "/" .. path)
        if vim.fn.filereadable(full_path) == 1 then
          vim.cmd("normal! m'")
          vim.cmd("edit " .. vim.fn.fnameescape(full_path))
        else
          vim.notify("File not found: " .. full_path, vim.log.levels.WARN)
        end
        return
      end
    end
    local alias = trimmed:match("^import%s+%S+%s+as%s+(%S+)")
    if alias then
      local as_pos = line_text:find("%s+as%s+" .. vim.pesc(alias) .. "%s*$")
      if as_pos then
        local alias_start = as_pos + 4 -- skip " as "
        if col >= alias_start - 1 and col <= alias_start - 1 + #alias then
          vim.notify("Alias '" .. alias .. "' defined here", vim.log.levels.INFO)
          return
        end
      end
    end
  end

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

  -- Script block variable reference: variables.xxx / env.xxx
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
  local prompt_pattern = "^%s*<<" .. vim.pesc(req_name) .. "%s"
  local prompt_comment_pattern = "^%s*#%s*<<" .. vim.pesc(req_name) .. "%s"
  local found_line = nil

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

  -- Script block variable reference: variables.xxx / env.xxx
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

  -- Import/run alias detection
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
    elseif trimmed_l:match("^run%s+#") then
      local ref = trimmed_l:match("^run%s+#(.+)$")
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
        add(i, vim.trim(text), 0)
      elseif not text:match(comment_pat) then
        local ref_col = text:find(ref_pat)
        if ref_col then
          add(i, vim.trim(text), ref_col - 1)
        else
          local script_col = find_script_ref(text)
          if script_col then
            add(i, vim.trim(text), script_col)
          end
        end
      end
    end
  end

  -- Import/run reference scanning (aliased imports)
  if is_import_ref and symbol_name then
    local esc_alias = vim.pesc(symbol_name)
    local as_marker = " as " .. esc_alias .. "%s*$"
    local hash_marker = "#" .. esc_alias .. "%."
    for i = 1, total do
      local text = all_lines[i] or ""
      -- Definition: cursor on alias word after " as "
      local def_raw = text:find("^%s*import%s+%S+%s+as%s+" .. esc_alias .. "%s*$")
      if def_raw then
        local as_pos = text:find(as_marker)
        if as_pos then add(i, text, as_pos + 3) end
      end
      -- Reference: cursor on alias word after "#"
      local ref_raw = text:find("^%s*run%s+#" .. esc_alias .. "%.")
      if ref_raw then
        local hash_pos = text:find(hash_marker)
        if hash_pos then add(i, text, hash_pos) end
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
