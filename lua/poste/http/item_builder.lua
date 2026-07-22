--- Item building utilities for HTTP completion.
--- Extracted from completion.lua for better modularity.

local M = {}

local cache = require("poste.http.cache")
local data = require("poste.http.data")
local context_detector = require("poste.http.context_detector")

local KIND_KEYWORD = 14
local KIND_PROPERTY = 10
local KIND_VALUE = 12
local KIND_VARIABLE = 6
local KIND_REFERENCE = 18
local KIND_FUNCTION = 3

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
    local buf_cache = cache.get_buffer_cache(buf)
    for name in pairs(buf_cache.file_vars) do
      all_vars[name] = true
    end
    local req_vars = cache.collect_request_vars(buf, cursor_line or vim.api.nvim_win_get_cursor(0)[1])
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
    local env_vars = cache.collect_env_vars()
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

local function build_namespace_tree(req_names)
  local tree = { _type = "ns", _children = {} }
  for _, name in ipairs(req_names) do
    local entry = { _type = "ns", _children = {} }
    local resp = { _type = "ns", _children = {} }
    resp._children["body"] = { _type = "leaf", _detail = "response body" }
    resp._children["headers"] = { _type = "leaf", _detail = "response headers" }
    resp._children["status"] = { _type = "leaf", _detail = "response status code" }
    entry._children["response"] = resp
    local req = { _type = "ns", _children = {} }
    req._children["body"] = { _type = "leaf", _detail = "request body" }
    req._children["headers"] = { _type = "leaf", _detail = "request headers" }
    entry._children["request"] = req
    tree._children[name] = entry
  end
  return tree
end

local function navigate_namespace(tree, prefix)
  if not prefix or prefix == "" then return tree end
  local parts = vim.split(prefix, ".", true)
  local node = tree
  for _, part in ipairs(parts) do
    if node._type == "ns" and node._children then
      node = node._children[part]
      if not node then return nil end
    else
      return nil
    end
  end
  return node
end

--- Get namespace-aware completion items for a given prefix path.
--- @param prefix string  Namespace path (e.g. "GetUser" or "GetUser.response")
--- @param partial string  Partial query for filtering children
--- @param req_names table  List of request names
--- @return table|nil  Completion items or nil if prefix not found
function M.get_namespace_items(prefix, partial, req_names)
  local tree = build_namespace_tree(req_names)
  local node = navigate_namespace(tree, prefix)
  if not node or node._type ~= "ns" then return nil end

  local items = {}
  local partial_lower = partial:lower()
  local KIND_MODULE = 9
  local KIND_VARIABLE = 6

  for child_name, child_node in pairs(node._children) do
    if partial_lower == "" or child_name:lower():find(partial_lower, 1, true) then
      if child_node._type == "ns" then
        table.insert(items, {
          label = child_name .. ".",
          kind = KIND_MODULE,
          insertText = child_name .. ".",
          filterText = child_name,
          sortText = "00" .. child_name,
          detail = "namespace",
        })
      else
        table.insert(items, {
          label = child_name,
          kind = KIND_VARIABLE,
          insertText = child_name,
          filterText = child_name,
          sortText = "01" .. child_name,
          detail = child_node._detail,
        })
      end
    end
  end

  table.sort(items, function(a, b) return a.sortText < b.sortText end)
  return items
end

--- Get variable completion items for {{ }} context.
--- Extracted for reuse with variable_namespace fallback.
--- @param after_open string  Text after {{ (e.g. "base_", "$ti", "Name.response.body")
--- @param buf number|nil  Buffer number
--- @param cursor_line number|nil  Cursor line number
--- @return table  Completion items
function M._get_variable_items(after_open, buf, cursor_line)
  local items = {}
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
        sortText = "3" .. mv.name,
      })
    end
    return items
  end

  local all_vars = {}
  local buf_cache = cache.get_buffer_cache(buf)

  for name in pairs(buf_cache.file_vars) do
    all_vars[name] = "file"
  end

  local req_vars = cache.collect_request_vars(buf, cursor_line)
  for name in pairs(req_vars) do
    all_vars[name] = "request"
  end

  local env_vars = cache.collect_env_vars()
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

  for _, name in ipairs(buf_cache.req_names) do
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
end

--- Get completion items for a given line context.
--- @param line_before_cursor string Text before cursor
--- @param buf number Buffer number
--- @param cursor_line number Cursor line number
--- @param cursor_col number Cursor column
--- @return table Completion items
function M.get_items_for_context(line_before_cursor, buf, cursor_line, cursor_col)
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
    local import_index = cache.collect_import_index(buf)

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
    local import_index = cache.collect_import_index(buf)

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
    items = M._get_variable_items(extra or "", buf, cursor_line)
    return items
  elseif ctx == "variable_namespace" then
    buf = buf or vim.api.nvim_get_current_buf()
    local buf_cache = cache.get_buffer_cache(buf)
    local ns_items = M.get_namespace_items(extra.prefix, extra.partial, buf_cache.req_names)
    if ns_items and #ns_items > 0 then
      return ns_items
    end
    local after_open = extra.prefix .. "." .. extra.partial
    items = M._get_variable_items(after_open, buf, cursor_line)
    return items
  elseif ctx == "file_directive" then
    items = M.build_items({ "import", "run" }, KIND_REFERENCE)
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
  elseif ctx == "prompt_mapping" then
    items = M.build_keyword_items(data.prompt_mapping_fields, KIND_PROPERTY)
    return items
  end

  return items
end

return M
