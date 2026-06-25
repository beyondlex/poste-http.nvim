--- Virtual text hint + Tab expansion for script block snippets.
--- Shows gray hint after typing > or < on its own line,
--- Tab expands to {% ... %} structure with cursor in between.
local M = {}

local ns = vim.api.nvim_create_namespace("poste_script_snippet")
local active = nil

function M.setup()
  local group = vim.api.nvim_create_augroup("PosteScriptSnippet", { clear = true })

  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    pattern = { "*.http", "*.rest" },
    callback = function()
      M.refresh()
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    pattern = { "*.http", "*.rest" },
    callback = function()
      M.clear()
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    pattern = { "*.http", "*.rest" },
    callback = function()
      active = nil
    end,
  })

  vim.keymap.set("i", "<Tab>", function()
    if require("poste.http.script_snippet").expand() then
      return ""
    end
    return "<Tab>"
  end, { expr = true })
end

function M.refresh()
  local buf = vim.api.nvim_get_current_buf()
  local cur_line = vim.fn.line(".")
  local line_content = vim.api.nvim_buf_get_lines(buf, cur_line - 1, cur_line, false)[1] or ""
  local trimmed = vim.trim(line_content)

  if trimmed ~= ">" and trimmed ~= "<" then
    M.clear()
    return
  end

  vim.api.nvim_buf_set_extmark(buf, ns, cur_line - 1, #line_content, {
    virt_text = {{" {%", "Comment"}},
    virt_lines = {{{"%}", "Comment"}}},
  })

  active = { buf = buf, line = cur_line, prefix = trimmed }
end

function M.clear()
  if active then
    pcall(vim.api.nvim_buf_clear_namespace, active.buf, ns, 0, -1)
    active = nil
  end
end

function M.expand()
  if not active then return false end

  local buf = active.buf
  local cur_line = vim.fn.line(".")

  if not vim.api.nvim_buf_is_valid(buf) or cur_line ~= active.line then
    M.clear()
    return false
  end

  local line_content = vim.api.nvim_buf_get_lines(buf, cur_line - 1, cur_line, false)[1] or ""
  local trimmed = vim.trim(line_content)

  if trimmed ~= ">" and trimmed ~= "<" then
    M.clear()
    return false
  end

  local prefix = trimmed
  local replacement = { prefix .. " {%", "", "%}" }

  M.clear()

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    pcall(vim.api.nvim_buf_set_lines, buf, cur_line - 1, cur_line, false, replacement)
    pcall(vim.api.nvim_win_set_cursor, 0, { cur_line + 1, 2 })
  end)

  return true
end

return M