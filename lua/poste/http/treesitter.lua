local M = {}

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "poste_http" then
    return
  end
  local ok, err = pcall(vim.treesitter.start, bufnr, "poste_http")
  if not ok then
    vim.notify("[Poste] tree-sitter: " .. tostring(err), vim.log.levels.WARN)
  end
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.treesitter.stop, bufnr)
end

return M