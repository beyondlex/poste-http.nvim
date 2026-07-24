local M = {}

local ns = vim.api.nvim_create_namespace("poste_http_var_refs")

local function highlight_var_refs(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for l, line in ipairs(lines) do
    local row = l - 1
    local s = 1
    while s <= #line do
      local a, b, inner = line:find("{{($?)([^}]-)}}", s)
      if not a then break end
      local hl = inner and inner ~= "" and "$" == line:sub(a + 2, a + 2) and "PosteMagicVar" or "PosteVarRef"
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, a - 1, {
        end_row = row,
        end_col = b,
        hl_group = hl,
        priority = 150,
      })
      s = b + 1
    end
  end
end

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "poste_http" then
    return
  end
  local ok, err = pcall(vim.treesitter.start, bufnr, "poste_http")
  if not ok then
    vim.notify("[Poste] tree-sitter: " .. tostring(err), vim.log.levels.WARN)
  end
  highlight_var_refs(bufnr)
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function() highlight_var_refs(bufnr) end,
  })
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.treesitter.stop, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

--- Inspect the treesitter parse tree for the current buffer.
--- Displays as a notification for debugging highlight issues.
function M.inspect(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "poste_http")
  if not ok or not parser then
    vim.notify("[Poste] No tree-sitter parser active", vim.log.levels.WARN)
    return
  end
  local ok, trees = pcall(parser.parse, parser)
  if not ok or not trees or #trees == 0 then
    vim.notify("[Poste] No parse tree available", vim.log.levels.WARN)
    return
  end
  local root = trees[1]:root()
  local lines = {}
  local function dump(node, depth)
    depth = depth or 0
    local indent = string.rep("  ", depth)
    local name = node:type()
    local start_row, start_col, end_row, end_col = node:range()
    table.insert(lines, string.format("%s%s [%d:%d - %d:%d]", indent, name, start_row, start_col, end_row, end_col))
    for child in node:iter_children() do
      dump(child, depth + 1)
    end
  end
  dump(root)
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M