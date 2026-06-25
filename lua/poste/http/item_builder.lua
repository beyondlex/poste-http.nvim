--- Item building utilities for HTTP completion.
--- Extracted from completion.lua for better modularity.

local M = {}

local data = require("poste.http.data")
local context_detector = require("poste.http.context_detector")

local buffer_caches = {}
local env_cache = {}
local cache_autocmds = {}

local function ensure_cache_autocmd(buf)
  if cache_autocmds[buf] then return end
  cache_autocmds[buf] = true
  local group = vim.api.nvim_create_augroup("PosteCompletionCache_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      buffer_caches[buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    buffer = buf,
    callback = function()
      buffer_caches[buf] = nil
      cache_autocmds[buf] = nil
    end,
  })
end

local function get_buffer_cache(buf)
  local ct = vim.api.nvim_buf_get_changedtick(buf)
  local cached = buffer_caches[buf]
  if cached and cached.changedtick == ct then
    return cached
  end

  local file_vars = {}
  local req_names = {}
  local seen_names = {}
  local past_file_vars = false
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for _, line in ipairs(lines) do
    if line:match("^%s*###") then
      past_file_vars = true
      local name = line:match("^%s*###%s+(.+)")
      if name then
        name = vim.trim(name)
        if name ~= "" and not seen_names[name] then
          seen_names[name] = true
          table.insert(req_names, name)
        end
      end
    elseif not past_file_vars then
      local var_name = line:match("^%s*@(%w[%w_]*)%s*=")
      if var_name then file_vars[var_name] = true end
    end
  end

  local entry = {
    changedtick = ct,
    file_vars = file_vars,
    req_names = req_names,
  }
  buffer_caches[buf] = entry
  ensure_cache_autocmd(buf)
  return entry
end

local function collect_file_vars(buf)
  return get_buffer_cache(buf).file_vars
end

local function collect_request_vars(buf, cursor_line)
  local vars = {}
  local ok, indicators = pcall(require, "poste.indicators")
  if not ok then return vars end
  local start_line, end_line = indicators.find_request_block_bounds(buf, cursor_line)
  if not start_line then return vars end

  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  for _, line in ipairs(lines) do
    if not line:match("^%s*###") then
      local name = line:match("^%s*@(%w[%w_]*)%s*=")
      if name then vars[name] = true end
    end
  end
  return vars
end

local function collect_env_vars()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then return {} end

  local dir = vim.fn.fnamemodify(bufname, ":h")
  local env_file

  while dir and dir ~= "" and dir ~= "/" do
    local candidate = dir .. "/env.json"
    if vim.fn.filereadable(candidate) == 1 then
      env_file = candidate
      break
    end
    dir = vim.fn.fnamemodify(dir, ":h")
  end

  if not env_file then return {} end

  local info = vim.uv.fs_stat(env_file)
  local mtime = info and info.mtime and info.mtime.sec or 0

  local state = require("poste.state")
  local env_name = state.current_env or state.config.default_env

  local cached = env_cache[env_file]
  if cached and cached.mtime == mtime and cached.env_name == env_name then
    return cached.vars
  end

  local ok, content = pcall(vim.fn.readfile, env_file)
  if not ok or not content then return {} end

  local json_ok, json_data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
  if not json_ok or type(json_data) ~= "table" then
    env_cache[env_file] = nil
    return {}
  end

  local env_data = json_data[env_name]
  if type(env_data) ~= "table" then
    env_cache[env_file] = nil
    return {}
  end

  local vars = {}
  for k, _ in pairs(env_data) do
    vars[k] = true
  end

  env_cache[env_file] = { mtime = mtime, env_name = env_name, vars = vars }
  return vars
end

local function collect_request_names(buf)
  return get_buffer_cache(buf).req_names
end

local function collect_import_index(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local cache = get_buffer_cache(buf)
  if cache.import_index then
    return cache.import_index
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local full_content = table.concat(lines, "\n")
  local import_mod = require("poste.http.import")
  local directives = import_mod.collect_directives(full_content)

  local buf_name = vim.api.nvim_buf_get_name(buf)
  local buf_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
  local index = import_mod.build_import_index(directives.imports, buf_dir)

  cache.import_index = index
  return index
end

--- Build completion items from a list of strings.
--- @param words table List of word strings
--- @param kind number LSP CompletionItemKind number
--- @return table Completion items
function M.build_items(words, kind)
  local items = {}
  for _, word in ipairs(words) do
    table.insert(items, {
      label = word,
      kind = kind,
      insertText = word,
      filterText = word,
      sortText = word,
      detail = nil,
    })
  end
  return items
end

--- Build completion items from keyword definitions (name + desc).
--- @param keywords table List of {name, desc} tables
--- @param kind number LSP CompletionItemKind number
--- @return table Completion items
function M.build_keyword_items(keywords, kind)
  local items = {}
  for _, kw in ipairs(keywords) do
    table.insert(items, {
      label = kw.name,
      kind = kind,
      insertText = kw.name,
      filterText = kw.name,
      sortText = kw.name,
      detail = kw.desc,
    })
  end
  return items
end

--- Build completion items for variables.* and env.* in script context.
--- @param line_text string Full line text
--- @param buf number|nil Buffer number
--- @param cursor_line number|nil Cursor line number
--- @return table Completion items
function M.build_script_variable_items(line_text, buf, cursor_line)
  local KIND_VARIABLE = 6
  local items = {}
  buf = buf or vim.api.nvim_get_current_buf()

  local prefix_match = nil
  local pos = 1
  while true do
    local s, e, word = line_text:find("(%w+)%.", pos)
    if not s then break end
    prefix_match = word
    pos = e + 1
  end
  if not prefix_match then
    return items
  end

  if prefix_match == "variables" then
    local all_vars = {}
    local cache = get_buffer_cache(buf)
    for name in pairs(cache.file_vars) do
      all_vars[name] = true
    end
    local req_vars = collect_request_vars(buf, cursor_line or vim.api.nvim_win_get_cursor(0)[1])
    for name in pairs(req_vars) do
      all_vars[name] = true
    end
    for name in pairs(all_vars) do
      table.insert(items, {
        label = "variables." .. name,
        kind = KIND_VARIABLE,
        insertText = "variables." .. name,
        filterText = "variables." .. name,
        sortText = "1" .. name,
        detail = "file/request variable",
      })
    end
  elseif prefix_match == "env" then
    local env_vars = collect_env_vars()
    for name in pairs(env_vars) do
      table.insert(items, {
        label = "env." .. name,
        kind = KIND_VARIABLE,
        insertText = "env." .. name,
        filterText = "env." .. name,
        sortText = "1" .. name,
        detail = "environment variable",
      })
    end
  end

  return items
end

--- Get completion items for a given line context.
--- @param line_before_cursor string Text before cursor
--- @param buf number Buffer number
--- @param cursor_line number Cursor line number
--- @param cursor_col number Cursor column
--- @return table Completion items
function M.get_items_for_context(line_before_cursor, buf, cursor_line, cursor_col)
  local KIND_KEYWORD = 14
  local KIND_PROPERTY = 10
  local KIND_VALUE = 12
  local KIND_VARIABLE = 6
  local KIND_REFERENCE = 18
  local KIND_FUNCTION = 3

  local ctx, extra = context_detector.detect_context(line_before_cursor, buf, cursor_line, cursor_col)
  local items = {}

  if ctx == "pre_script" or ctx == "post_script" then
    local line = extra or ""

    local module_name = line:match("(%w+)%.%w*$")
    if module_name and data.lua_module_members[module_name] then
      local members = data.lua_module_members[module_name]
      for _, member in ipairs(members) do
        table.insert(items, {
          label = member.name,
          kind = KIND_FUNCTION,
          insertText = member.name,
          filterText = member.name,
          sortText = member.name,
          detail = member.desc,
        })
      end
      return items
    end

    local keywords = ctx == "pre_script" and data.pre_script_keywords or data.post_script_keywords
    items = M.build_keyword_items(keywords, KIND_FUNCTION)

    local lua_key_items = M.build_items(data.lua_keywords, KIND_KEYWORD)
    for _, item in ipairs(lua_key_items) do
      table.insert(items, item)
    end

    local func_items = M.build_keyword_items(data.lua_sandbox_functions, KIND_FUNCTION)
    for _, item in ipairs(func_items) do
      table.insert(items, item)
    end

    local module_items = M.build_keyword_items(data.lua_sandbox_modules, KIND_PROPERTY)
    for _, item in ipairs(module_items) do
      table.insert(items, item)
    end

    local var_items = M.build_script_variable_items(extra or "", buf, cursor_line)
    for _, item in ipairs(var_items) do
      table.insert(items, item)
    end

    return items
  elseif ctx == "status_code" then
    for _, sc in ipairs(data.http_status_codes) do
      table.insert(items, {
        label = sc.code,
        kind = KIND_VALUE,
        insertText = sc.code,
        filterText = sc.code .. " " .. sc.desc,
        sortText = sc.code,
        detail = sc.desc,
      })
    end
    return items
  end

  if ctx == "import_path" then
    items = M.build_items({ "./", "../" }, KIND_VALUE)
    return items
  elseif ctx == "import_alias" then
    items = {
      {
        label = "as",
        kind = KIND_KEYWORD,
        insertText = "as ",
        filterText = "as",
        sortText = "as",
        detail = "alias for the imported requests",
      },
    }
    return items
  elseif ctx == "run_target" then
    items = M.build_items({ "#", "./" }, KIND_REFERENCE)
    return items
  elseif ctx == "run_target_hash" then
    local partial = extra or ""
    local import_index = collect_import_index(buf)

    for _, entry in ipairs(import_index.bare or {}) do
      for _, req in ipairs(entry.requests or {}) do
        if req.name:sub(1, #partial) == partial then
          table.insert(items, {
            label = "#" .. req.name,
            kind = KIND_REFERENCE,
            insertText = "#" .. req.name,
            filterText = "#" .. req.name,
            sortText = req.name,
            detail = entry.path,
          })
        end
      end
    end

    for alias, entry in pairs(import_index.aliased or {}) do
      if alias:sub(1, #partial) == partial then
        local label = "#" .. alias
        table.insert(items, {
          label = label,
          kind = KIND_REFERENCE,
          insertText = label,
          filterText = label,
          sortText = "~" .. alias,
          detail = string.format("alias: %s (%d requests)", entry.path, #(entry.requests or {})),
        })
      end
    end

    return items
  elseif ctx == "run_target_alias" then
    local data_extra = extra or {}
    local alias = data_extra.alias or ""
    local partial = data_extra.partial or ""
    local import_index = collect_import_index(buf)

    local entry = (import_index.aliased or {})[alias]
    if entry then
      for _, req in ipairs(entry.requests or {}) do
        if req.name:sub(1, #partial) == partial then
          table.insert(items, {
            label = req.name,
            kind = KIND_REFERENCE,
            insertText = req.name,
            filterText = "#" .. alias .. "." .. req.name,
            sortText = req.name,
            detail = string.format("%s:%d", entry.path, req.line),
          })
        end
      end
    end

    return items
  end

  if ctx == "variable" then
    local after_open = extra or ""
    local is_magic = after_open:sub(1, 1) == "$"
    buf = buf or vim.api.nvim_get_current_buf()
    cursor_line = cursor_line or vim.api.nvim_win_get_cursor(0)[1]

    if is_magic then
      for _, mv in ipairs(data.magic_var_defs) do
        table.insert(items, {
          label = "$" .. mv.name,
          kind = KIND_KEYWORD,
          insertText = "$" .. mv.name,
          detail = mv.desc,
          sortText = "0" .. mv.name,
        })
      end
      return items
    end

    local all_vars = {}
    local cache = get_buffer_cache(buf)

    for name in pairs(cache.file_vars) do
      all_vars[name] = "file"
    end

    local req_vars = collect_request_vars(buf, cursor_line)
    for name in pairs(req_vars) do
      all_vars[name] = "request"
    end

    local env_vars = collect_env_vars()
    for name in pairs(env_vars) do
      if not all_vars[name] then
        all_vars[name] = "env"
      end
    end

    local var_names = {}
    for name in pairs(all_vars) do
      table.insert(var_names, name)
    end
    table.sort(var_names)

    for _, name in ipairs(var_names) do
      table.insert(items, {
        label = name,
        kind = KIND_VARIABLE,
        insertText = name,
        detail = all_vars[name],
        sortText = "1" .. name,
      })
    end

    for _, name in ipairs(cache.req_names) do
      table.insert(items, {
        label = name .. ".response.body",
        kind = KIND_REFERENCE,
        insertText = name .. ".response.body",
        filterText = name,
        detail = "request reference",
        sortText = "2" .. name,
      })
    end

    for _, mv in ipairs(data.magic_var_defs) do
      table.insert(items, {
        label = "$" .. mv.name,
        kind = KIND_KEYWORD,
        insertText = "$" .. mv.name,
        detail = mv.desc .. " (magic)",
        sortText = "3" .. mv.name,
      })
    end

    return items
  elseif ctx == "method" or ctx == "method_or_header" then
    local method_items = M.build_items(data.http_methods, KIND_KEYWORD)
    local header_items = M.build_items(data.header_names, KIND_PROPERTY)
    local directive_items = M.build_items({ "import", "run" }, KIND_REFERENCE)
    for _, item in ipairs(method_items) do
      table.insert(items, item)
    end
    for _, item in ipairs(header_items) do
      table.insert(items, item)
    end
    for _, item in ipairs(directive_items) do
      table.insert(items, item)
    end
  elseif ctx == "header_value" and extra then
    local values = data.header_values[extra:lower()]
    if values then
      items = M.build_items(values, KIND_VALUE)
    end
  end

  return items
end

return M
