local vars = require("poste-http.http.vars")
local cache = require("poste-http.http.cache")
local state = require("poste-http.state")
local request_deps = require("poste-http.http.request_deps")
local columns = require("poste-http.ui.columns")
local text = require("poste-http.ui.text")
local float = require("poste-http.ui.float")

local M = {}

local PRIORITY_ORDER = {
  import_params = 1,
  request_vars = 2,
  file_vars = 3,
  session_vars = 4,
  script_vars = 5,
  env = 6,
}

local PRIORITY_LABELS = {
  import_params = "import param",
  request_vars = "@var (block)",
  file_vars = "@var (file)",
  session_vars = "client.global.set",
  script_vars = "request.variables.set",
  env = "env file",
}

local function find_env_json_path(file_path)
  if not file_path or file_path == "" then return nil end
  local dir = vim.fn.fnamemodify(file_path, ":h")
  local seen = {}
  while true do
    local candidate = vim.fs.joinpath(dir, "env.json")
    if not seen[dir] and vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return nil
end

local function find_first_block_line(lines)
  for i, line in ipairs(lines) do
    if line:match("^%s*###") then return i end
  end
  return nil
end

local function collect_entries(buf, cursor_line)
  local buf_path = vim.api.nvim_buf_get_name(buf)
  local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local block_start, block_end = cache.find_request_block_bounds(buf, cursor_line)
  local first_block = find_first_block_line(buf_lines)

  -- Resolve Lua import references (@var = alias.keypath → @var = value) so the
  -- inspector shows the actual Lua value, not the raw alias token. Line count is
  -- preserved (import lines become blank), so block/file ranges still align.
  local buf_dir = buf_path ~= "" and vim.fn.fnamemodify(buf_path, ":h") or vim.fn.getcwd()
  local import = require("poste-http.http.import")
  local resolved_lines = vim.split(import.resolve_lua_imports(table.concat(buf_lines, "\n"), buf_dir), "\n", { plain = true })

  local entries = {}

  local function add_entry(var_name, value, source, opts)
    opts = opts or {}
    if not entries[var_name] then
      entries[var_name] = {}
    end
    table.insert(entries[var_name], {
      value = value,
      source = source,
      source_label = PRIORITY_LABELS[source] or source,
      order = PRIORITY_ORDER[source] or 99,
      file = opts.file,
      line = opts.line,
      timestamp = opts.timestamp,
    })
  end

  local block_vars = {}
  if block_start and block_end then
    block_vars = vars.collect_var_defs_with_lines(resolved_lines, block_start, block_end)
    for name, info in pairs(block_vars) do
      add_entry(name, info.value, "request_vars", { file = buf_path, line = info.line })
    end
  end

  local file_vars = vars.collect_var_defs_with_lines(resolved_lines, 1, first_block and first_block - 1 or #resolved_lines)
  for name, info in pairs(file_vars) do
    add_entry(name, info.value, "file_vars", { file = buf_path, line = info.line })
  end

  for name, value in pairs(state.global_vars) do
    local src = state.global_vars_sources[name]
    add_entry(name, value, "session_vars", { file = src and src.file, line = src and src.line })
  end

  for name, value in pairs(state.script_variables) do
    local src = state.script_variables_sources[name]
    add_entry(name, value, "script_vars", { file = src and src.file, line = src and src.line })
  end

  local env_name = state.current_env
  if buf_path and buf_path ~= "" and env_name and env_name ~= "" then
    local env_vars = vars.load_env_vars_with_lines(buf_path, env_name)
    local env_json_path = find_env_json_path(buf_path)
    for name, info in pairs(env_vars) do
      add_entry(name, info.value, "env", { file = env_json_path, line = info.line })
    end
  end

  local resolver = vars.new()
  for name, info in pairs(file_vars) do
    resolver.file_vars[name] = info.value
  end
  for name, _ in pairs(resolver.file_vars) do
    resolver.file_vars[name] = resolver:substitute(resolver.file_vars[name])
  end
  for name, info in pairs(block_vars) do
    resolver.request_vars[name] = info.value
  end
  for name, _ in pairs(resolver.request_vars) do
    resolver.request_vars[name] = resolver:substitute(resolver.request_vars[name])
  end
  resolver.session_vars = vim.deepcopy(state.global_vars)
  resolver.script_vars = vim.deepcopy(state.script_variables)
  if buf_path and buf_path ~= "" and env_name and env_name ~= "" then
    resolver.env = vars.load_env_vars(buf_path, env_name)
  end
  for _, varents in pairs(entries) do
    for _, entry in ipairs(varents) do
      entry.value = resolver:substitute(entry.value)
    end
  end

  for _, varents in pairs(entries) do
    for _, entry in ipairs(varents) do
      entry.value = entry.value:gsub("{{([^}]+)}}", function(var_name)
        if var_name:gsub("%.res%.", ".response."):match("%.response%.") or var_name:match("%.request%.") then
          local resolved = request_deps.resolve_single_ref(var_name)
          if resolved ~= nil then
            return request_deps.value_to_http_string(resolved)
          end
        end
        return "{{" .. var_name .. "}}"
      end)
    end
  end

  for _, varents in pairs(entries) do
    table.sort(varents, function(a, b)
      if a.order ~= b.order then return a.order < b.order end
      return (a.line or 0) < (b.line or 0)
    end)
    local active = true
    for i = #varents, 1, -1 do
      if active then
        varents[i].active = true
        active = false
      else
        varents[i].active = false
      end
    end
  end

  local sorted_names = {}
  for name in pairs(entries) do
    table.insert(sorted_names, name)
  end
  table.sort(sorted_names, function(a, b)
    local ao = entries[a][1].order
    local bo = entries[b][1].order
    if ao ~= bo then return ao < bo end
    return a < b
  end)

  return entries, sorted_names
end

local function middle_ellipsis(s, max_len)
  return text.middle(s, max_len)
end

local function format_value(val)
  if val == nil then return "" end
  local s = tostring(val)
  s = s:gsub("\n", "\\n")
  return s
end

local function relative_path(from_dir, to_path)
  if not from_dir or from_dir == "" or not to_path or to_path == "" then
    return to_path or ""
  end
  local from_parts = vim.split(from_dir, "/", { plain = true })
  local to_parts = vim.split(to_path, "/", { plain = true })
  local common = 0
  for i = 1, math.min(#from_parts, #to_parts) do
    if from_parts[i] == to_parts[i] then
      common = i
    else
      break
    end
  end
  local result = {}
  for _ = common + 1, #from_parts do
    table.insert(result, "..")
  end
  for i = common + 1, #to_parts do
    table.insert(result, to_parts[i])
  end
  if #result == 0 then return "." end
  return table.concat(result, "/")
end

local function format_location(entry, buf_dir)
  local path = entry.file
  if not path or path == "" then return "" end
  path = relative_path(buf_dir or "", path)
  if entry.line then
    return path .. ":" .. entry.line
  end
  return path
end

function M.show_inspector()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]

  local entries, sorted_names = collect_entries(buf, cursor_line)

  if vim.tbl_isempty(entries) then
    vim.notify("No variables found", vim.log.levels.INFO, { title = "Poste" })
    return
  end

  local buf_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":h")
  local rows = {}
  for _, name in ipairs(sorted_names) do
    local ve = entries[name][1]
    table.insert(rows, {
      name = name,
      value = format_value(ve.value),
      type = ve.source_label,
      source = ve.source,
      location = format_location(ve, buf_dir),
      entry = ve,
    })
  end

  local target_width = math.floor(vim.o.columns * 0.85)
  local content_width = target_width - 6

  local col_name_w = 2
  local col_type_w = 2
  local col_loc_w = 2
  for _, r in ipairs(rows) do
    col_name_w = math.max(col_name_w, vim.fn.strdisplaywidth(r.name))
    col_type_w = math.max(col_type_w, vim.fn.strdisplaywidth(r.type))
    col_loc_w = math.max(col_loc_w, vim.fn.strdisplaywidth(r.location))
  end
  col_name_w = math.min(col_name_w, 22)
  col_type_w = math.min(col_type_w, 20)
  local col_loc_max = 40
  col_loc_w = math.min(col_loc_w, col_loc_max)
  local col_value_w = math.max(20, content_width - col_name_w - col_type_w - col_loc_w - 6)
  col_loc_w = math.min(col_loc_w, math.max(10, content_width - col_name_w - col_type_w - col_value_w - 6))

  -- Render through the columns component: padding is display-width aware
  -- (string.format pads by bytes, which misaligns wide characters).
  local render_rows = { { "Variable", "Value", "Type", "Location" } }
  for _, r in ipairs(rows) do
    table.insert(render_rows, {
      r.name,
      middle_ellipsis(r.value, col_value_w),
      r.type,
      middle_ellipsis(r.location, col_loc_w),
    })
  end
  local lines, cells = columns.render(render_rows, {
    { max = col_name_w },
    { width = col_value_w, ellipsis = false },
    { max = col_type_w },
    { width = col_loc_w, ellipsis = false },
  }, { width = target_width, gap = 2 })

  local float_buf = vim.api.nvim_create_buf(false, true)
  local jump_map = {}
  vim.b[float_buf].poste_var_jump_map = jump_map
  for i, r in ipairs(rows) do
    jump_map[i] = r.entry
  end

  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, vim.list_slice(lines, 2))
  vim.bo[float_buf].modifiable = false
  vim.bo[float_buf].bufhidden = "wipe"
  vim.bo[float_buf].filetype = "poste-variable-inspector"

  local height = math.min(#rows + 2, math.floor(vim.o.lines * 0.7))

  -- close_keys = {}: "q"/"<Esc>" close via the `close()` closure below, which
  -- jump_to_def also uses; float's generic close would bypass nothing here but
  -- keeping one close path avoids double bookkeeping.
  local _, win = float.open({
    buf = float_buf,
    width = target_width,
    height = height,
    title = " Variable Inspector ",
    cursorline = true,
    close_keys = {},
  })
  if not win then
    pcall(vim.api.nvim_buf_delete, float_buf, { force = true })
    return
  end

  vim.wo[win].winbar = lines[1]

  for i, r in ipairs(rows) do
    local c = cells[i + 1]
    local line_idx = i - 1
    vim.api.nvim_buf_add_highlight(float_buf, -1, "PosteVarDef", line_idx, c[1].col, c[1].end_col)
    vim.api.nvim_buf_add_highlight(float_buf, -1, "PosteVarValue", line_idx, c[2].col, c[2].end_col)
    local type_hl = r.source == "env" and "Comment" or "Normal"
    vim.api.nvim_buf_add_highlight(float_buf, -1, type_hl, line_idx, c[3].col, c[3].end_col)
    vim.api.nvim_buf_add_highlight(float_buf, -1, "Comment", line_idx, c[4].col, -1)
  end

  local function close()
    pcall(vim.api.nvim_win_close, win, true)
  end

  local function jump_to_def()
    local cur = vim.api.nvim_win_get_cursor(win)
    local entry = jump_map[cur[1]]
    if entry and entry.file then
      close()
      local target_buf = vim.fn.bufadd(entry.file)
      vim.fn.bufload(target_buf)
      vim.api.nvim_set_current_buf(target_buf)
      if entry.line then
        vim.api.nvim_win_set_cursor(0, { entry.line, 0 })
        vim.cmd("normal! zz")
      end
    end
  end

  vim.keymap.set("n", "q", close, { buffer = float_buf, noremap = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = float_buf, noremap = true, silent = true })
  vim.keymap.set("n", "<CR>", jump_to_def, { buffer = float_buf, noremap = true, silent = true })
end

--- Collect variable entries for a buffer at the given cursor line.
--- @param buf number
--- @param cursor_line number
--- @return table, table  entries map (name → array of entries, last = active),
---   sorted_names (rows in display order, priority then name)
function M.collect_entries(buf, cursor_line)
  return collect_entries(buf, cursor_line)
end

return M