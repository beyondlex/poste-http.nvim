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

  -- Source file syntax highlight groups (linked to standard groups).
  -- These provide sensible defaults for any colorscheme. Users can
  -- override individual groups with :highlight PosteMethod guifg=#ff0000
  -- and the override persists across colorscheme switches.
  local syntax_links = {
    { "PosteSeparator",    "Delimiter" },
    { "PosteRequestName",  "Title" },
    { "PosteVarRef",       "Identifier" },
    { "PosteMagicVar",     "Special" },
    { "PosteMethodGET",    "Keyword" },
    { "PosteMethodPOST",   "Keyword" },
    { "PosteMethodPUT",    "Keyword" },
    { "PosteMethodDELETE", "Keyword" },
    { "PosteMethodPATCH",  "Keyword" },
    { "PosteMethodHEAD",   "Keyword" },
    { "PosteMethodOPTIONS", "Keyword" },
    { "PosteMethodOther",  "Keyword" },
    { "PosteUrl",          "Underlined" },
    { "PosteHttpVersion",  "Constant" },
    { "PosteHeaderKey",    "Type" },
    { "PosteDirective",    "PreProc" },
    { "PostePreScript",    "PreProc" },
    { "PosteAssertion",    "PreProc" },
    { "PosteScriptMarker", "Special" },
    { "PosteExternalScript", "Include" },
    { "PosteFileInclude",  "Include" },
    { "PosteJsonString",   "String" },
    { "PosteJsonNumber",   "Number" },
    { "PosteJsonBoolean",  "Boolean" },
    { "PosteJsonNull",     "Special" },
    { "PosteJsonBraces",   "Delimiter" },
    { "PosteJsonBrackets", "Delimiter" },
    { "PosteJsonColon",    "Delimiter" },
    { "PosteJsonComma",    "Delimiter" },
    { "PosteJsonEscape",   "SpecialChar" },
  }
  for _, pair in ipairs(syntax_links) do
    local existing = vim.api.nvim_get_hl(0, { name = pair[1] })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, pair[1], { link = pair[2] })
    end
  end

  -- HTTP method colors: GET=green, POST=yellow, PUT=orange, DELETE=red
  vim.api.nvim_set_hl(0, "PosteMethodGET",    { fg = 0x98c379, bold = true }) -- green
  vim.api.nvim_set_hl(0, "PosteMethodPOST",   { fg = 0xe5c07b, bold = true }) -- yellow
  vim.api.nvim_set_hl(0, "PosteMethodPUT",    { fg = 0xd19a66, bold = true }) -- orange
  vim.api.nvim_set_hl(0, "PosteMethodDELETE", { fg = 0xe06c75, bold = true }) -- red
  vim.api.nvim_set_hl(0, "PosteMethodPATCH",  { fg = 0xc678dd, bold = true }) -- magenta
  vim.api.nvim_set_hl(0, "PosteMethodHEAD",   { fg = 0x56b6c2, bold = true }) -- cyan
  vim.api.nvim_set_hl(0, "PosteMethodOther",  { fg = 0x5c6370, bold = true }) -- gray

  -- Request name: bold with a distinct color
  vim.api.nvim_set_hl(0, "PosteRequestName", { fg = 0x61afef, bold = true }) -- blue bold

  -- Symbol outline highlights
  vim.api.nvim_set_hl(0, "PosteSymbolCurrent", { bg = 0x3e4452, bold = true }) -- highlighted bg
  vim.api.nvim_set_hl(0, "PosteSymbolMethod", { fg = 0x98c379, bold = true })  -- green for [GET] [POST] etc

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

  -- SQL dataset highlight groups
  vim.api.nvim_set_hl(0, "PosteSqlHeader",       { bold = true })
  vim.api.nvim_set_hl(0, "PosteSqlNull",         { fg = 0x5c6370, italic = true })  -- gray italic
  vim.api.nvim_set_hl(0, "PosteSqlMeta",         { fg = 0x5c6370 })                 -- gray
  vim.api.nvim_set_hl(0, "PosteSqlBorder",       { fg = 0x3e4452 })                 -- dim
  vim.api.nvim_set_hl(0, "PosteSqlCellSelected", { bg = 0x3e4452, bold = true })    -- visual-like
  vim.api.nvim_set_hl(0, "PosteSqlModified",     { bg = 0x4a3d00 })                 -- yellow tint
  vim.api.nvim_set_hl(0, "PosteSqlDeleted",      { bg = 0x3d0000 })                 -- red tint
  vim.api.nvim_set_hl(0, "PosteSqlAdded",        { bg = 0x003d00 })                 -- green tint
end

-- Apply highlights immediately on require
M.setup()

-- Re-apply when colorscheme changes or after full startup
vim.api.nvim_create_autocmd("ColorScheme", { callback = M.setup })
vim.api.nvim_create_autocmd("VimEnter", { callback = M.setup, once = true })

return M
