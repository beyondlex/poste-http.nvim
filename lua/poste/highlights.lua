--- Highlight group definitions for the Poste plugin.
--- Called at module-load time and on ColorScheme/VimEnter autocmds.
local M = {}

--- Resolve highlight group links fully (follow chains of `link`).
local function resolve_hl(name)
  local hl = vim.api.nvim_get_hl(0, { name = name })
  while hl.link do
    hl = vim.api.nvim_get_hl(0, { name = hl.link })
  end
  return hl
end

--- Define all Poste highlight groups and register autocmds.
function M.setup()
  -- Latency uses a distinct purple color
  vim.api.nvim_set_hl(0, "PosteLatency", { fg = 0xb48ead })

  for _, pair in ipairs({
    { "PosteSpinner", "DiagnosticInfo" },
    { "PosteSuccess", "DiagnosticOk" },
    { "PosteError",   "DiagnosticError" },
  }) do
    local src = resolve_hl(pair[2])
    local fg = src.fg or src.ctermfg
    if not fg then
      fg = pair[1] == "PosteError" and 0xff0000
        or pair[1] == "PosteSuccess" and 0x00ff00
        or 0x00aaff
    end
    -- fg only, no bg — hl_mode="combine" on extmark handles bg inheritance
    vim.api.nvim_set_hl(0, pair[1], { fg = fg })
  end

  -- Redis type-specific highlight groups
  vim.api.nvim_set_hl(0, "PosteRedisString",   { fg = 0x98c379 })   -- green
  vim.api.nvim_set_hl(0, "PosteRedisHash",     { fg = 0x56b6c2 })   -- cyan
  vim.api.nvim_set_hl(0, "PosteRedisList",     { fg = 0x61afef })   -- blue
  vim.api.nvim_set_hl(0, "PosteRedisSet",      { fg = 0xe5c07b })   -- yellow
  vim.api.nvim_set_hl(0, "PosteRedisZset",     { fg = 0xc678dd })   -- magenta
  vim.api.nvim_set_hl(0, "PosteRedisStream",   { fg = 0xd19a66 })   -- orange
  vim.api.nvim_set_hl(0, "PosteRedisMeta",     { fg = 0x5c6370 })   -- gray
  vim.api.nvim_set_hl(0, "PosteRedisError",    { fg = 0xe06c75 })   -- red
  vim.api.nvim_set_hl(0, "PosteRedisOk",       { fg = 0x98c379 })   -- green
  vim.api.nvim_set_hl(0, "PosteRedisNil",      { fg = 0x5c6370, italic = true }) -- gray italic
  vim.api.nvim_set_hl(0, "PosteRedisSep",      { fg = 0x3e4452 })   -- dim separator
  vim.api.nvim_set_hl(0, "PosteRedisIndex",    { fg = 0x5c6370 })   -- gray index
  vim.api.nvim_set_hl(0, "PosteRedisField",    { fg = 0x56b6c2 })   -- cyan field name
  vim.api.nvim_set_hl(0, "PosteRedisScore",    { fg = 0xc678dd })   -- magenta score
end

-- Apply highlights immediately on require
M.setup()

-- Re-apply when colorscheme changes or after full startup
vim.api.nvim_create_autocmd("ColorScheme", { callback = M.setup })
vim.api.nvim_create_autocmd("VimEnter", { callback = M.setup, once = true })

return M
