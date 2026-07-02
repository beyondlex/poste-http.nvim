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

  -- Rescan entire buffer for file vars, request names, line types, blocks, imports in one pass
  local file_vars = {}
  local req_names = {}
  local seen_names = {}
  local past_first_block = false
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local line_type = {}
  local blocks = {}
  local file_imports = {}
  local current_block = nil
  local request_found_in_block = false
  local body_started = false
  local in_pre_block = false
  local in_post_block = false

  for i, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    local t

    if not past_first_block then
      if line:match("^%s*###") then
        past_first_block = true
        request_found_in_block = false
        body_started = false
        in_pre_block = false
        in_post_block = false
          current_block = {
            name = vim.trim(line:match("^%s*###%s*(.*)") or ""),
            start_line = i,
            end_line = nil,
            block_vars = {},
            has_pre = false,
            has_post = false,
            has_run = false,
            last_content_line = nil,
          }
        local name = line:match("^%s*###%s+(.+)")
        if name then
          name = vim.trim(name)
          if name ~= "" and not seen_names[name] then
            seen_names[name] = true
            table.insert(req_names, name)
          end
        end
        t = "head"
      elseif line:match("^%s*@(%w[%w_]*)%s*[= ]") then
        local var_name = line:match("^%s*@(%w[%w_]*)%s*[= ]")
        file_vars[var_name] = true
        t = "var"
      elseif line:match("^import%s+") then
        local path, alias = line:match("^import%s+(%S+)%s+as%s+(%S+)")
        if not path then
          path = line:match("^import%s+(%S+)")
        end
        if alias then
          table.insert(file_imports, { type = "aliased", path = path, alias = alias })
        elseif path then
          table.insert(file_imports, { type = "bare", path = path })
        end
        t = "file"
      else
        if in_pre_block then
          t = "pre_script"
          if trimmed == "%}" then
            in_pre_block = false
          end
        elseif in_post_block then
          t = "post_script"
          if trimmed == "%}" then
            in_post_block = false
          end
        elseif line:match("^%s*<%s+%.%.?") then
          t = "pre_script"
        elseif line:match("^%s*<%s+{%%") then
          t = "pre_script"
          if not line:match("%}") then
            in_pre_block = true
          end
        elseif line:match("^%s*>%s+%.%.?") then
          t = "post_script"
        elseif line:match("^%s*>%s+{%%") then
          t = "post_script"
          if not line:match("%}") then
            in_post_block = true
          end
        else
          t = "file"
        end
      end
    else
      if line:match("^%s*###") then
        if current_block then
          current_block.end_line = i - 1
          if not current_block.last_content_line then
            current_block.last_content_line = current_block.start_line
          end
          table.insert(blocks, current_block)
        end
        request_found_in_block = false
        body_started = false
        in_pre_block = false
        in_post_block = false
          current_block = {
            name = vim.trim(line:match("^%s*###%s*(.*)") or ""),
            start_line = i,
            end_line = nil,
            block_vars = {},
            has_pre = false,
            has_post = false,
            has_run = false,
            last_content_line = nil,
          }
        local name = line:match("^%s*###%s+(.+)")
        if name then
          name = vim.trim(name)
          if name ~= "" and not seen_names[name] then
            seen_names[name] = true
            table.insert(req_names, name)
          end
        end
        t = "head"
      elseif line:match("^%s*@(%w[%w_]*)%s*[= ]") then
        local var_name = line:match("^%s*@(%w[%w_]*)%s*[= ]")
        if current_block then
          current_block.block_vars[var_name] = true
        end
        t = "var"
      elseif in_pre_block then
        t = "pre_script"
        if trimmed == "%}" then
          in_pre_block = false
        end
      elseif line:match("^%s*<%s+%.%.?") then
        t = "pre_script"
        if current_block then current_block.has_pre = true end
      elseif line:match("^%s*<%s+{%%") then
        t = "pre_script"
        if current_block then current_block.has_pre = true end
        if not line:match("%}") then
          in_pre_block = true
        end
      elseif in_post_block then
        t = "post_script"
        if trimmed == "%}" then
          in_post_block = false
        end
      elseif line:match("^%s*>%s+%.%.?") then
        t = "post_script"
        if current_block then current_block.has_post = true end
      elseif line:match("^%s*>%s+{%%") then
        t = "post_script"
        if current_block then current_block.has_post = true end
        if not line:match("%}") then
          in_post_block = true
        end
      elseif line:match("^%s*#%s*@prompt%s") then
        t = "prompt"
      elseif line:match("^[A-Z]+%s+%S") then
        if not request_found_in_block then
          t = "request"
          request_found_in_block = true
        else
          t = "body"
        end
      elseif line:match("^[%w%-]+%s*:") then
        t = "header"
      elseif line:match("^run%s+") then
        t = "run"
        if current_block then current_block.has_run = true end
      elseif trimmed == "" then
        t = "empty"
        if request_found_in_block and not body_started then
          body_started = true
        end
      else
        t = "body"
      end

      if current_block and trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%-%-") then
        current_block.last_content_line = i
      end
    end

    line_type[i] = t
  end

  -- Finalize last block: end_line = last line of buffer (original behavior)
  if current_block then
    current_block.end_line = #lines
    if not current_block.last_content_line then
      current_block.last_content_line = current_block.start_line
    end
    table.insert(blocks, current_block)
  end

  local entry = {
    changedtick = ct,
    file_vars = file_vars,
    req_names = req_names,
    line_type = line_type,
    blocks = blocks,
    file_imports = file_imports,
  }
  buffer_caches[buf] = entry
  M.ensure_cache_autocmd(buf)
  return entry
end

--- Get file-level variables from cache.
function M.collect_file_vars(buf)
  return M.get_buffer_cache(buf).file_vars
end

--- Collect request-level variables (current request block only).
--- Uses block index for O(1) lookup instead of buffer scanning.
function M.collect_request_vars(buf, cursor_line)
  local block = M.get_block_at_line(buf, cursor_line)
  if not block then return {} end
  return vim.deepcopy(block.block_vars)
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

--- Get the line type for a given buffer line.
--- @param buf number
--- @param line number (1-indexed)
--- @return string|nil
function M.get_line_type(buf, line)
  local cache = M.get_buffer_cache(buf)
  return cache.line_type[line]
end

--- Get the block containing a given line.
--- @param buf number
--- @param line number (1-indexed)
--- @return table|nil  block or nil
function M.get_block_at_line(buf, line)
  local cache = M.get_buffer_cache(buf)
  for _, block in ipairs(cache.blocks) do
    if line >= block.start_line and line <= block.end_line then
      -- Check cursor is not on inter-block separator
      -- (past last content line but before next ###)
      if block.last_content_line and line > block.last_content_line then
        return nil
      end
      return block
    end
  end
  return nil
end

--- Get block-level variables for the block containing a given line.
--- @param buf number
--- @param line number (1-indexed)
--- @return table  { name = true, ... }
function M.get_block_vars(buf, line)
  local block = M.get_block_at_line(buf, line)
  if block then return block.block_vars end
  return {}
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
