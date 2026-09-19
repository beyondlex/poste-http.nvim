local M = {}

local ns = vim.api.nvim_create_namespace("poste_errors")
local jump_ns = vim.api.nvim_create_namespace("poste_errors_jump")

-- buf -> { row_0 = { file = string, line = number } }
local jump_targets = {}

--- Scan one or more content strings for unresolved {{var}} references.
--- @param parts string|string[]  Content string(s) to scan
--- @return string[]  Unique unresolved variable names
function M.find_unresolved_vars(parts)
  if not parts then return {} end
  if type(parts) == "string" then parts = { parts } end
  local seen = {}
  local result = {}
  for _, part in ipairs(parts) do
    if type(part) == "string" then
      for name in part:gmatch("{{([^}]+)}}") do
        local n = vim.trim(name)
        if n ~= "" and not seen[n] then
          seen[n] = true
          table.insert(result, n)
        end
      end
    end
  end
  return result
end

--- Find the first (1-indexed) line in `lines[begin..end]` where `{{name}}` appears.
--- Searches the full array by default. When `start_line` and `end_line` are given,
--- only scans lines in that range (1-indexed, inclusive).
--- @param lines string[]  Source buffer lines
--- @param name string     Variable name (without braces)
--- @param start_line number|nil  Optional 1-indexed start line (inclusive)
--- @param end_line number|nil    Optional 1-indexed end line (inclusive)
--- @return number|nil
function M.find_var_line(lines, name, start_line, end_line)
  if not lines or not name then return nil end
  local needle = "{{" .. name .. "}}"
  local s = start_line or 1
  local e = end_line or #lines
  for i = s, e do
    local line = lines[i]
    if line and line:find(needle, 1, true) then
      return i
    end
  end
  return nil
end

--- Format structured errors for the Error tab.
--- @param errors table[]|nil  List of error entries
--- @return string[]
function M.format_errors(errors)
  if not errors or #errors == 0 then
    return { "  No errors to display" }
  end
  local pre = 0
  local post = 0
  for _, e in ipairs(errors) do
    if e.type == "pre_request" then pre = pre + 1
    elseif e.type == "post_request" then post = post + 1 end
  end
  local lines = {
    string.format("  Errors: %d (%d pre-request, %d post-request)", pre + post, pre, post),
    "",
  }
  for _, e in ipairs(errors) do
    table.insert(lines, string.format("  %s: %s", e.stage, e.message))
    if e.source then
      local detail = {}
      if e.source.var then
        table.insert(detail, string.format("variable: %s", e.source.var))
      end
      if e.source.file and e.source.line then
        local short = vim.fn.fnamemodify(e.source.file, ":t")
        table.insert(detail, string.format("%s:%d", short, e.source.line))
      end
      if #detail > 0 then
        -- 4-space indent: detail lines must be structurally distinct from
        -- message lines for apply_highlights' prefix dispatch (a 2-space
        -- detail after a sourceless message read as the next message).
        table.insert(lines, "    " .. table.concat(detail, " · "))
      end
    end
  end
  return lines
end

--- Apply extmark highlights to the errors buffer and store jump targets.
--- Line kinds are dispatched by the prefix format_errors writes (summary,
--- 2-space message, 4-space detail), so a sourceless error between others
--- cannot shift the error/detail pairing.
--- @param buf number
--- @param lines string[]
--- @param errors table[]|nil  Error entries for jump target mapping
function M.apply_highlights(buf, lines, errors)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, jump_ns, 0, -1)
  jump_targets[buf] = {}
  local cur = 0 -- errors[] index of the most recent message line
  for i, line in ipairs(lines) do
    local row = i - 1
    if line:match("^  Errors:") then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        end_row = row, end_col = #line,
        hl_group = "PosteAssertSummary", priority = 100,
      })
    elseif line:match("^    %S") then
      -- Detail line of the error owning the previous message line:
      -- underline file:line, store jump.
      local e = errors and errors[cur]
      local src = e and e.source
      if src and src.file and src.line then
        local short = vim.fn.fnamemodify(src.file, ":t")
        local loc = string.format("%s:%d", short, src.line)
        local start_col = line:find(loc, 1, true)
        if start_col then
          vim.api.nvim_buf_set_extmark(buf, jump_ns, row, start_col - 1, {
            end_row = row, end_col = start_col - 1 + #loc,
            hl_group = "Underlined",
          })
          jump_targets[buf][row] = { file = src.file, line = src.line }
        end
      end
    elseif line:match("^  %S") then
      -- Message line: highlight with PosteAssertError
      cur = cur + 1
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        end_row = row, end_col = #line,
        hl_group = "PosteAssertError", priority = 100,
      })
    end
  end
end

--- Build a pre-request error entry.
--- @param stage string  e.g. "variable_resolution", "pre_script"
--- @param message string
--- @param source table|nil  { var = string, line = number }
--- @return table
function M.pre_request(stage, message, source)
  return { type = "pre_request", stage = stage, message = message, source = source }
end

--- Build a post-request error entry.
function M.post_request(stage, message, source)
  return { type = "post_request", stage = stage, message = message, source = source }
end

--- Set up <CR> keymap on the errors buffer to jump to the source location.
function M.setup_jump_keymap(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.keymap.set("n", "<CR>", function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local target = jump_targets[buf] and jump_targets[buf][vim.fn.line(".") - 1]
    if not target then return end
    local nr = vim.fn.bufnr(target.file)
    if nr == -1 then
      nr = vim.fn.bufadd(target.file)
    end
    local win = vim.fn.bufwinid(nr)
    if win > 0 then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("buffer " .. nr)
    end
    vim.api.nvim_win_set_cursor(0, { target.line, 0 })
    vim.cmd("normal! zz")
  end, { buffer = buf, noremap = true, silent = true })
end

function M.get_jump_targets(buf)
  return jump_targets[buf]
end

return M