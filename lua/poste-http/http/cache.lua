--- Cache management for HTTP completion.
---
--- UI-level indexing only (line types, block bounds, var names, imports).
--- HTTP semantics (method / path / headers / body) come from the single
--- tree-sitter parse authority via `poste.http.describe`.

local M = {}

local block_boundary = require("poste-http.http.block_boundary")

-- Buffer-level caches (invalidated on text change via changedtick)
local buffer_caches = {}     -- bufnr → { changedtick, file_vars, req_names, import_index }
local semantic_caches = {}   -- bufnr → { changedtick, blocks }  -- from describe
local env_cache = {}         -- path → { mtime, env_name, vars }
local cache_autocmds = {}    -- bufnr → true

--- Set up text-change autocmd for a buffer to invalidate cache.
function M.ensure_cache_autocmd(buf)
  if cache_autocmds[buf] then return end
  cache_autocmds[buf] = true
  local group = vim.api.nvim_create_augroup("PosteCompletionCache_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    buffer = buf,
    callback = function()
      buffer_caches[buf] = nil
      semantic_caches[buf] = nil
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

  local function start_block(line, i)
    local name = vim.trim(line:match("^%s*###%s*(.*)") or "")
    current_block = {
      name = name,
      start_line = i,
      end_line = nil,
      block_vars = {},
      has_pre = false,
      has_post = false,
      has_run = false,
      last_content_line = nil,
    }
    if name ~= "" and not seen_names[name] then
      seen_names[name] = true
      table.insert(req_names, name)
    end
  end

  local function finalize_block()
    if not current_block then return end
    local end_line, last_content = block_boundary.compute_block_range(lines, current_block.start_line)
    current_block.end_line = end_line
    current_block.last_content_line = last_content
    table.insert(blocks, current_block)
    current_block = nil
  end

  for i, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    local t

    if not past_first_block then
      if block_boundary.is_separator(line) then
        past_first_block = true
        request_found_in_block = false
        body_started = false
        in_pre_block = false
        in_post_block = false
        start_block(line, i)
        t = "head"
      elseif line:match("^%s*@([^%s=]+)%s*[= ]") then
        local var_name = line:match("^%s*@([^%s=]+)%s*[= ]")
        file_vars[var_name] = true
        t = "var"
      elseif line:match("^%s*<<(%w[%w_]*)") then
        local var_name = line:match("^%s*<<(%w[%w_]*)")
        file_vars[var_name] = true
        t = "prompt"
      elseif line:match("^%s*#%s*<<") then
        t = "prompt"
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
        elseif vim.trim(line):upper() == "SCRIPT" then
          request_found_in_block = true
          past_first_block = true
          current_block = {
            name = "",
            start_line = i,
            end_line = nil,
            block_vars = {},
            has_pre = false,
            has_post = false,
            has_run = false,
            last_content_line = nil,
          }
          t = "request"
        elseif line:match("^[A-Z]+%s+%S") then
          request_found_in_block = true
          past_first_block = true
          current_block = {
            name = "",
            start_line = i,
            end_line = nil,
            block_vars = {},
            has_pre = false,
            has_post = false,
            has_run = false,
            last_content_line = nil,
          }
          t = "request"
        elseif line:match("^[%w%-]+%s*:") then
          t = "header"
        else
          t = "file"
        end
      end
    else
      if block_boundary.is_separator(line) then
        finalize_block()
        request_found_in_block = false
        body_started = false
        in_pre_block = false
        in_post_block = false
        start_block(line, i)
        t = "head"
      elseif line:match("^%s*@([^%s=]+)%s*[= ]") then
        local var_name = line:match("^%s*@([^%s=]+)%s*[= ]")
        if current_block then
          current_block.block_vars[var_name] = true
        end
        t = "var"
      elseif line:match("^%s*<<(%w[%w_]*)") then
        local var_name = line:match("^%s*<<(%w[%w_]*)")
        if current_block then
          current_block.block_vars[var_name] = true
        end
        t = "prompt"
      elseif line:match("^%s*#%s*<<") then
        t = "prompt"
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
      elseif vim.trim(line):upper() == "SCRIPT" then
        if not request_found_in_block then
          t = "request"
          request_found_in_block = true
        else
          t = "body"
        end
      elseif line:match("^[A-Z]+%s+%S") then
        if not request_found_in_block then
          t = "request"
          request_found_in_block = true
        else
          t = "body"
        end
      elseif line:match("^[%w%-]+%s*:") then
        t = "header"
      elseif line:lower():match("^run%s+") then
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

      end

    line_type[i] = t
  end

  finalize_block()

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

--- Collect local variable names from script blocks in the current request block.
--- Scans pre/post script lines for `local name = ...` declarations.
--- @param buf number  Buffer number
--- @param cursor_line number  Cursor line number (1-indexed)
--- @return table  { name = true, ... }
function M.collect_script_local_vars(buf, cursor_line)
  local block = M.get_block_at_line(buf, cursor_line)
  local start_line, end_line
  if block then
    start_line = block.start_line
    end_line = block.end_line
  else
    local cache = M.get_buffer_cache(buf)
    local first_head = nil
    for i = 1, #cache.line_type do
      if cache.line_type[i] == "head" then
        first_head = i
        break
      end
    end
    start_line = 1
    end_line = (first_head and first_head - 1) or #cache.line_type
  end
  local cache = M.get_buffer_cache(buf)
  local local_vars = {}
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  for i, line in ipairs(lines) do
    local line_num = start_line + i - 1
    local lt = cache.line_type[line_num]
    if lt == "pre_script" or lt == "post_script" then
      local after_local = line:match("local%s+(.*)")
      if after_local then
        local names_part = after_local:match("^(.-)%s*=") or after_local
        for name in names_part:gmatch("([%w_]+)") do
          if name ~= "function" then
            local_vars[name] = true
          end
        end
      end
    end
  end
  return local_vars
end

--- Collect variable names set via `request.variables.set("name", ...)` in pre-script blocks.
--- These variables are available for `{{name}}` expansion in HTTP templates.
--- @param buf number  Buffer number
--- @param cursor_line number  Cursor line number (1-indexed)
--- @return table  { name = true, ... }
function M.collect_script_set_vars(buf, cursor_line)
  local cache = M.get_buffer_cache(buf)
  local first_head = nil
  for i = 1, #cache.line_type do
    if cache.line_type[i] == "head" then
      first_head = i
      break
    end
  end
  local file_head_end = (first_head and first_head - 1) or #cache.line_type

  local block = M.get_block_at_line(buf, cursor_line)
  local scan_end = file_head_end
  if block then
    scan_end = math.max(scan_end, block.end_line)
  end

  local set_vars = {}
  local lines = vim.api.nvim_buf_get_lines(buf, 0, scan_end, false)
  for i, line in ipairs(lines) do
    local line_num = i
    local lt = cache.line_type[line_num]
    if lt == "pre_script" then
      for _, name in line:gmatch("request%.variables%.set%((['\"])([%w_]+)%1") do
        set_vars[name] = true
      end
    end
  end
  return set_vars
end

--- Get environment variables from env.json (cached by path + mtime + env).
function M.collect_env_vars()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then return {} end

  local dir = vim.fn.fnamemodify(bufname, ":h")
  local env_file

  while dir and dir ~= "" and dir ~= "/" do
    local candidate = vim.fs.joinpath(dir, "env.json")
    if vim.fn.filereadable(candidate) == 1 then
      env_file = candidate
      break
    end
    dir = vim.fn.fnamemodify(dir, ":h")
  end

  if not env_file then return {} end

  -- Check cache: skip re-read if mtime and env name unchanged.
  -- Compare at nanosecond granularity so edits within the same second
  -- still invalidate the cache.
  local info = vim.uv.fs_stat(env_file)
  local mtime = (info and info.mtime and (info.mtime.sec * 1e9 + (info.mtime.nsec or 0))) or 0

  local state = require("poste-http.state")
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
      -- Trailing comment lines still belong to this block: returning nil
      -- here made run.lua silently skip the request when the cursor sat on
      -- a comment below the request body.
      if block.last_content_line and line > block.last_content_line then
        local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
        if not block_boundary.is_comment(text) then
          return nil
        end
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
  local import_mod = require("poste-http.http.import")
  local directives = import_mod.collect_directives(full_content)

  local buf_name = vim.api.nvim_buf_get_name(buf)
  local buf_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
  local index = import_mod.build_import_index(directives.imports, buf_dir)

  cache.import_index = index
  return index
end

---------------------------------------------------------------------------
-- Semantic block metadata (single parse authority)
-- method / path / headers come from tree-sitter describe, not Lua scanning.
--------------------------------------------------------------------------
--- Normalize buffer-cache block shape to semantic block shape.
--- Buffer cache blocks use start_line; semantic blocks use line.
--- This lets describe.block_at_line and boundary_indicator work on fallback blocks.
local function normalize_to_semantic(blocks)
  local out = {}
  for _, b in ipairs(blocks or {}) do
    table.insert(out, {
      name = b.name,
      line = b.start_line,
      end_line = b.end_line,
      last_content_line = b.last_content_line,
      block_vars = b.block_vars,
      has_pre = b.has_pre,
      has_post = b.has_post,
      has_run = b.has_run,
    })
  end
  return out
end


--- Get structured block metadata for a buffer via tree-sitter describe.
--- Cached by changedtick. Returns empty table if the parser is unavailable.
---
--- @param buf number|nil
--- @return table  array of BlockMeta { name, line, end_line, method, path, headers, body, request_line }
function M.get_semantic_blocks(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ct = vim.api.nvim_buf_get_changedtick(buf)
  local cached = semantic_caches[buf]
  if cached and cached.changedtick == ct then
    return cached.blocks
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, "\n")
  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then
    file = vim.fn.getcwd() .. "/untitled.http"
  end

  local describe = require("poste-http.http.describe")
  local blocks, err = describe.describe_content(content, file)
  if not blocks then
    if err then
      pcall(function()
        require("poste-http.state").log("WARN", "describe failed: " .. tostring(err))
      end)
    end
    blocks = {}
  end

  -- If tree-sitter returned no blocks, fall back to buffer cache blocks.
  -- This avoids a divergence where semantic_caches holds [] while
  -- buffer_caches holds populated blocks from the text scan.
  if #blocks == 0 then
    local buffer_cache = M.get_buffer_cache(buf)
    blocks = normalize_to_semantic(buffer_cache.blocks)
  end

  semantic_caches[buf] = { changedtick = ct, blocks = blocks }
  M.ensure_cache_autocmd(buf)
  return blocks
end

--- Get semantic metadata for the block containing `line`.
--- @param buf number
--- @param line number  1-indexed
--- @return table|nil  BlockMeta
function M.get_semantic_block_at_line(buf, line)
  local describe = require("poste-http.http.describe")
  return describe.block_at_line(M.get_semantic_blocks(buf), line)
end

-------------------------------------------------------------------------------
-- Request block extraction (moved from indicators.lua during protocol split)
-------------------------------------------------------------------------------

--- Extract the full request block from the buffer at the given line.
--- Returns { request_line = "GET ...", headers = { { "Key", "Value" }, ... } }.
function M.extract_request_block(buf, start_line)
  local header_line = nil
  for i = start_line, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      header_line = i
      break
    end
  end
  if not header_line then return { request_line = "", headers = {}, name = "" } end

  local total = vim.api.nvim_buf_line_count(buf)
  local request_line = nil
  local headers = {}
  local name = ""

  for i = header_line, total do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      if i == header_line then
        name = text:match("^%s*###%s+(.*)$") or ""
      else
        break
      end
    end

    -- skips: comment-ish lines (`#`, `--`) and file references (`<<`)
    if not (text:match("^%s*#") or text:match("^%s*%-%-") or text:match("^%s*<<")) then
      if not request_line and text:match("%S") then
        request_line = text
      elseif request_line then
        if text:match("^%s*$") then
          break
        end
        local key, val = text:match("^([^:]+):%s*(.*)")
        if key then
          table.insert(headers, { vim.trim(key), vim.trim(val) })
        end
      end
    end
  end

  return { request_line = request_line or "", headers = headers, name = name }
end

--- Find the request definition line using the block index.
--- Skips pre-request script blocks and variable definitions.
--- Returns (line_number_1indexed, nil) or (nil, nil) if not found.
function M.find_request_line(buf, start_line)
  local block = M.get_block_at_line(buf, start_line)
  if not block then return nil end

  local in_prescript = false

  for i = block.start_line + 1, block.end_line do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    local trimmed = vim.trim(text)

    if text:match("^%s*###") then break end

    if in_prescript then
      if trimmed == "%}" then
        in_prescript = false
      end
    elseif trimmed:match("^<%s*{%%") and not trimmed:match("%%}$") then
      in_prescript = true
    elseif -- skips: single-line script blocks, Lua file includes, @var
      -- definitions, file references, blanks, and comments
      trimmed:match("^<%s*{%%.*%%}$")
      or (trimmed:match("^<%s*%.?%.") and trimmed:match("%.lua%s*$"))
      or trimmed:match("^@%S+%s*[= ]")
      or trimmed:match("^<<")
      or trimmed == "" or block_boundary.is_comment(text) then
      -- keep scanning for the request line
    else
      return i
    end
  end

  return nil
end

--- Find the request block boundaries for a given cursor line.
--- Returns (start_line, end_line) as 1-indexed inclusive ranges.
function M.find_request_block_bounds(buf, cursor_line)
  local block = M.get_block_at_line(buf, cursor_line)
  if not block then return nil, nil end
  return block.start_line, block.end_line
end

return M
