local M = {}

function M.setup_buffer(buf)
  local win = vim.fn.bufwinid(buf)
  if win < 0 then return end
  vim.wo[win].foldmethod = "indent"
  vim.wo[win].foldlevel = 99
  vim.wo[win].foldcolumn = "1"
end

return M
