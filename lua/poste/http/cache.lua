--- Cache management for HTTP completion.
--- Provides buffer-level caching for file variables, request names, and import index.

local M = {}

-- Buffer-level caches (invalidated on text change via changedtick)
local buffer_caches = {}     -- bufnr → { changedtick, file_vars, req_names, import_index }
local env_cache = {}         -- path → { mtime, env_name, vars }
local cache_autocmds = {}    -- bufnr → true

--- Set up text-change autocmd for a buffer to invalidate cache.
function M.ensure_cache_autocmd(buf)
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

--- Get buffer-level cache, rescanning if buffer has changed.
function M.get_buffer_cache(buf)
  local ct = vim.api.nvim_buf_get_changedtick(buf)
  local cached = buffer_caches[buf]
  if cached and cached.changedtick == ct then
    return cached
  end

  -- Rescan entire buffer for file vars and request names in one pass
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
  M.ensure_cache_autocmd(buf)
  return entry
end

--- Get file-level variables from cache.
function M.collect_file_vars(buf)
  return M.get_buffer_cache(buf).file_vars
end

--- Collect request-level variables (current request block only, not cached).
function M.collect_request_vars(buf, cursor_line)
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

--- Get environment variables from env.json (cached by path + mtime + env).
function M.collect_env_vars()
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

  -- Check cache: skip re-read if mtime and env name unchanged
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

  local json_ok, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
  if not json_ok or type(data) ~= "table" then
    env_cache[env_file] = nil
    return {}
  end

  local env_data = data[env_name]
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

--- Get request names from buffer cache.
function M.collect_request_names(buf)
  return M.get_buffer_cache(buf).req_names
end

--- Collect import index for the buffer (cached, invalidated on buffer change).
--- Builds the index by parsing import directives and reading target files.
--- @param buf number|nil  Buffer number
--- @return table  Import index from build_import_index()
function M.collect_import_index(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local cache = M.get_buffer_cache(buf)
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

return M
