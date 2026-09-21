local M = {}

M.config = {
  default_env = "dev",
  split_direction = "vertical",
  result_window_ratio = 0.5,
  log_file = vim.fn.stdpath("cache") .. "/poste.log",
  import_chunk_size = 100,
  response_cache_dir = vim.fn.stdpath("cache") .. "/poste_res",
  image_url_cache_ttl_seconds = 3600,
  history_file = vim.fn.stdpath("data") .. "/poste-http/history.json",
  http_history_max = 100,
  persist_history = true,
  max_body_bytes = 100 * 1024,
  max_body_lines = 500,
  body_preview_lines = 20,
  default_view = "body",
  timeout = 30000,
  keymaps = {
    http_source = {
      run = "<CR>",
      run_hsplit = "<M-CR>",
      jump_next = "]]",
      jump_prev = "[[",
      goto_definition = "gd",
      goto_references = "grr",
      quickfix_next = "]q",
      quickfix_prev = "[q",
      paste_curl = "<leader>rp",
      copy_as_curl = "<leader>rc",
      toggle_outline = "gs",
      pick_env = "<leader>vv",
      show_var_value = "K",
      show_variable_inspector = "gi",
      show_history = "<leader>l",
      ask_ai = "ga",
      help = "g?",
    },
    http_response = {
      close = "q",
      view_body = "B",
      view_request = "R",
      view_verbose = "E",
      view_assertions = "A",
      view_errors = "X",
      view_script_logs = "S",
      next_tab = "<Tab>",
      prev_tab = "<S-Tab>",
      rerun = "r",
      next_response = "]",
      prev_response = "[",
      json_filter = "<leader>j",
      json_restore = "<leader>jc",
      json_toggle_raw = "<leader>jr",
      json_outline = "<leader>jo",
      image_preview = "K",
      ask_ai = "a",
    },
    http_history = {
      close = "q",
      delete_entry = "dd",
      focus_detail = "<CR>",
    },
  },
  highlights = {},
}

M.current_env = M.config.default_env
M.last_response = nil
M.last_responses = nil
M.response_index = nil
M.last_assertion_results = nil
M.last_errors = nil
M.last_script_logs = nil
M.last_request = nil
M.pending_request = nil
M.current_view = "body"
M._split_override = nil
M._busy = false
M._http_session = nil
M.http_history = {}
M.http_history_max = M.config.http_history_max
M.http_history_id_counter = 0
M.global_vars = {}
M.global_headers = {}
M.script_variables = {}
M.global_vars_sources = {}
M.global_headers_sources = {}
M.script_variables_sources = {}
M._exec_context = nil

M._json = {
  original_lines = nil,
  query = nil,
  is_filtered = false,
  pretty_mode = true,
}

function M.get_keymap(section, action, default)
  local km = M.config.keymaps
  if not km then return default end
  local sec = km[section]
  if not sec then return default end
  local key = sec[action]
  if key == nil then return default end
  if key == false then return nil end
  return key
end

local KEY_DISPLAY_NAMES = {
  ["<Tab>"] = "Tab",
  ["<S-Tab>"] = "S-Tab",
  ["<CR>"] = "Enter",
  ["<Esc>"] = "Esc",
  ["<Space>"] = "<Space>",
  ["<Up>"] = "Up",
  ["<Down>"] = "Down",
  ["<Left>"] = "Left",
  ["<Right>"] = "Right",
  ["<C-Space>"] = "C-Space",
  ["<BS>"] = "BS",
}

function M.format_key_string(key)
  if not key or key == "" then return "" end
  if KEY_DISPLAY_NAMES[key] then return KEY_DISPLAY_NAMES[key] end
  if key:sub(1, 8) == "<leader>" then
    local leader = vim.g.mapleader or "\\"
    if leader == " " then leader = "<Space>"
    elseif leader == "\t" then leader = "<Tab>"
    elseif leader == "\r" then leader = "<CR>"
    end
    leader = KEY_DISPLAY_NAMES[leader] or leader
    return leader .. key:sub(9)
  end
  return key
end

function M.format_keymap(section, action)
  local key = M.get_keymap(section, action)
  if not key then return "" end
  return M.format_key_string(key)
end

function M.apply_highlight_overrides(group_names)
  local overrides = M.config.highlights
  if not overrides or vim.tbl_isempty(overrides) then return end
  for _, name in ipairs(group_names) do
    local attr = overrides[name]
    if attr then
      vim.api.nvim_set_hl(0, name, attr)
    end
  end
end

function M.log(level, msg)
  if not M.config.log_file or M.config.log_file == "" then return end
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local line = string.format("[%s] [%s] %s\n", ts, level, msg)
  local f = io.open(M.config.log_file, "a")
  if f then
    f:write(line)
    f:close()
  end
end

---------------------------------------------------------------------------
-- Setters for request-scoped mutable state
---------------------------------------------------------------------------

function M.set_response(resp)
  M.last_response = resp
  M.last_responses = nil
  M.response_index = nil
end

function M.set_responses(chain, idx)
  M.last_responses = chain
  -- `#chain` errors on a nil chain rather than yielding nil, so the old
  -- `idx or (#chain or 1)` crashed instead of falling back; make the
  -- fallback explicit and keep set_responses(nil, nil) total.
  if idx then
    M.response_index = idx
  elseif type(chain) == "table" then
    M.response_index = #chain
  else
    M.response_index = nil
  end
end

function M.set_errors(errors)
  M.last_errors = errors
end

function M.add_error(err)
  M.last_errors = M.last_errors or {}
  table.insert(M.last_errors, err)
end

function M.set_assertion_results(results)
  M.last_assertion_results = results
  if results and results.logs and #results.logs > 0 then
    M.last_script_logs = M.last_script_logs or {}
    for _, msg in ipairs(results.logs) do
      table.insert(M.last_script_logs, msg)
    end
  end
end

function M.set_script_logs(logs)
  M.last_script_logs = logs
end

function M.append_script_logs(logs)
  M.last_script_logs = M.last_script_logs or {}
  for _, msg in ipairs(logs) do
    table.insert(M.last_script_logs, msg)
  end
end

function M.set_request(buf, line)
  M.last_request = { buf = buf, line = line }
end

function M.set_pending_request(info)
  M.pending_request = info
end

function M.set_current_view(view)
  M.current_view = view
end

function M.set_global_var(name, value)
  M.global_vars[name] = value
  if M._exec_context and not M.global_vars_sources[name] then
    M.global_vars_sources[name] = { file = M._exec_context.file, line = M._exec_context.line }
  end
end

function M.set_global_header(name, value)
  M.global_headers[name] = value
  if M._exec_context and not M.global_headers_sources[name] then
    M.global_headers_sources[name] = { file = M._exec_context.file, line = M._exec_context.line }
  end
end

function M.remove_global_header(name)
  M.global_headers[name] = nil
  M.global_headers_sources[name] = nil
end

function M.clear_global_headers()
  M.global_headers = {}
  M.global_headers_sources = {}
end

function M.set_script_variable(name, value)
  M.script_variables[name] = value
  if M._exec_context and not M.script_variables_sources[name] then
    M.script_variables_sources[name] = { file = M._exec_context.file, line = M._exec_context.line }
  end
end

function M.set_json_filter(query)
  M._json.query = query
end

function M.clear_json_state()
  M._json.query = nil
  M._json.original_lines = nil
  M._json.is_filtered = false
end

function M.clear_request_scoped()
  M.last_response = nil
  M.last_responses = nil
  M.response_index = nil
  M.last_assertion_results = nil
  M.last_errors = nil
  M.last_script_logs = nil
  M.last_request = nil
  M.pending_request = nil
  M.current_view = "body"
  M._json.query = nil
  M._json.original_lines = nil
  M._json.is_filtered = false
end

return M