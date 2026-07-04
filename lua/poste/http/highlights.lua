--- Highlight group definitions for the Poste plugin.
--- Called at module-load time and on ColorScheme/VimEnter autocmds.
local state = require("poste.state")
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
    { "PosteMethodScript", "Keyword" },
    { "PosteMethodOther",  "Keyword" },
    { "PosteUrl",          "Normal" },
    { "PosteHttpVersion",  "Constant" },
    { "PosteHeaderKey",    "Type" },
    { "PosteImport",       "Include" },
    { "PosteImportPath",   "String" },
    { "PosteImportAliasOpt", "Operator" },
    { "PosteImportAlias",  "Identifier" },
    { "PosteRunVarDef",    "PosteVarDef" },
    { "PosteRunVarAssign", "Operator" },
    { "PosteRunVarValue",  "String" },
    { "PostePromptMarker", "PreProc" },
    { "PostePromptVar",    "PosteVarDef" },
    { "PostePromptOpts",   "String" },
    { "PostePreScript",    "PreProc" },
    { "PosteAssertion",    "PreProc" },
    { "PosteScriptMarker", "Special" },
    { "PosteExternalScript", "Include" },
    { "PosteFileUpload",  "Include" },
    { "PosteFileRef",     "Include" },
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

  -- File references (< ./path / > ./path): underline like Include
  local include_hl = resolve_hl("Include")
  vim.api.nvim_set_hl(0, "PosteFileRef", {
    fg = include_hl.fg or 0x5c6370,
    sp = include_hl.fg or 0x5c6370,
    underline = true,
    bold = include_hl.bold,
    italic = include_hl.italic,
  })

  -- HTTP method colors: GET=green, POST=yellow, PUT=orange, DELETE=red
  vim.api.nvim_set_hl(0, "PosteMethodGET",    { fg = 0x98c379, bold = true }) -- green
  vim.api.nvim_set_hl(0, "PosteMethodPOST",   { fg = 0xe5c07b, bold = true }) -- yellow
  vim.api.nvim_set_hl(0, "PosteMethodPUT",    { fg = 0xd19a66, bold = true }) -- orange
  vim.api.nvim_set_hl(0, "PosteMethodDELETE", { fg = 0xe06c75, bold = true }) -- red
  vim.api.nvim_set_hl(0, "PosteMethodPATCH",  { fg = 0xc678dd, bold = true }) -- magenta
  vim.api.nvim_set_hl(0, "PosteMethodHEAD",   { fg = 0x56b6c2, bold = true }) -- cyan
  vim.api.nvim_set_hl(0, "PosteMethodScript", { fg = 0x8a5cf5, bold = true }) -- purple-blue
  vim.api.nvim_set_hl(0, "PosteMethodOther",  { fg = 0x5c6370, bold = true }) -- gray

  -- Run directive: bold purple for "run", green for target
  vim.api.nvim_set_hl(0, "PosteRun", { fg = 0xAA66FF, bold = true })
  vim.api.nvim_set_hl(0, "PosteRunTarget", { fg = 0x44CC88 })

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

  -- Statement boundary indicator (JetBrains-style box border)
  vim.api.nvim_set_hl(0, "PosteSqlBoundary", { bg = 0x664400 })
  vim.api.nvim_set_hl(0, "PosteSqlBoundaryBorder", { fg = 0xff8800, bold = true })

  -- HTTP request block boundary (same visual style)
  vim.api.nvim_set_hl(0, "PosteHttpBoundaryBorder", { fg = 0xff8800, bold = true })

  -- Status code coloring in verbose view
  vim.api.nvim_set_hl(0, "PosteStatus2xx", { fg = 0x98c379, bold = true })          -- green
  vim.api.nvim_set_hl(0, "PosteStatus3xx", { fg = 0x56b6c2, bold = true })          -- cyan
  vim.api.nvim_set_hl(0, "PosteStatus4xx", { fg = 0xe5c07b, bold = true })          -- yellow
  vim.api.nvim_set_hl(0, "PosteStatus5xx", { fg = 0xe06c75, bold = true })          -- red

  -- Verbose view extmark highlights
  vim.api.nvim_set_hl(0, "PosteVerboseSeparator", { fg = 0x3e4452 })                -- dim line
  vim.api.nvim_set_hl(0, "PosteVerboseSection", { fg = 0x61afef, bold = true })      -- blue bold
  vim.api.nvim_set_hl(0, "PosteVerboseSubHeader", { fg = 0xABB2BF, bold = true })    -- bright bold
  vim.api.nvim_set_hl(0, "PosteVerboseKey", { fg = 0xC678DD })                       -- magenta
  vim.api.nvim_set_hl(0, "PosteVerboseValue", { fg = 0x5c6370 })                     -- grey value

  -- Request tab extmark highlights (Key: bold, Value: gray)
  vim.api.nvim_set_hl(0, "PosteRequestKey", { fg = 0xABB2BF, bold = true })            -- bright bold
  vim.api.nvim_set_hl(0, "PosteRequestValue", { fg = 0x5c6370 })                       -- grey

  -- Assertions view extmark highlights
  vim.api.nvim_set_hl(0, "PosteAssertSummary", { fg = 0x98c379, bold = true })       -- green bold
  vim.api.nvim_set_hl(0, "PosteAssertSummaryFail", { fg = 0xe06c75, bold = true })   -- red bold
  vim.api.nvim_set_hl(0, "PosteAssertPass", { fg = 0x98c379 })                       -- green
  vim.api.nvim_set_hl(0, "PosteAssertFail", { fg = 0xe06c75, bold = true })          -- red bold
  vim.api.nvim_set_hl(0, "PosteAssertIconPass", { fg = 0x98c379, bold = true })      -- green bold ✓
  vim.api.nvim_set_hl(0, "PosteAssertIconFail", { fg = 0xe06c75, bold = true })      -- red bold ✘
  vim.api.nvim_set_hl(0, "PosteAssertError", { fg = 0xe06c75, italic = true })       -- red italic
  vim.api.nvim_set_hl(0, "PosteAssertLogHeader", { fg = 0x61afef, bold = true })     -- blue bold
  vim.api.nvim_set_hl(0, "PosteAssertLog", { fg = 0xABB2BF })                        -- bright
  vim.api.nvim_set_hl(0, "PosteAssertSep", { fg = 0x3e4452 })                        -- dim line
  vim.api.nvim_set_hl(0, "PosteAssertHint", { fg = 0x5c6370, italic = true })        -- gray italic for hints

  -- File link for binary response Open file: line — blue, underlined, clickable feel
  vim.api.nvim_set_hl(0, "PosteFileLink", { fg = 0x61afef, underline = true, sp = 0x61afef })

  state.apply_highlight_overrides({
    "PosteLatency", "PosteSpinner", "PosteSuccess", "PosteError",
    "PosteSeparator", "PosteRequestName", "PosteVarRef", "PosteMagicVar",
    "PosteMethodGET", "PosteMethodPOST",     "PosteMethodPUT", "PosteMethodDELETE",
    "PosteMethodPATCH", "PosteMethodHEAD", "PosteMethodOPTIONS", "PosteMethodScript", "PosteMethodOther",
    "PosteUrl", "PosteHttpVersion", "PosteHeaderKey",
    "PosteImport", "PosteImportPath", "PosteImportAliasOpt", "PosteImportAlias",
    "PosteRun", "PosteRunTarget", "PosteRunVarDef", "PosteRunVarAssign", "PosteRunVarValue",
    "PostePromptMarker", "PostePromptVar", "PostePromptOpts",
    "PostePreScript", "PosteAssertion", "PosteScriptMarker", "PosteExternalScript",
    "PosteFileUpload", "PosteFileRef",
    "PosteJsonString", "PosteJsonNumber", "PosteJsonBoolean", "PosteJsonNull",
    "PosteJsonBraces", "PosteJsonBrackets", "PosteJsonColon", "PosteJsonComma",
    "PosteJsonEscape",
    "PosteSymbolCurrent", "PosteSymbolMethod",
    "PosteRedisString", "PosteRedisHash", "PosteRedisList", "PosteRedisSet",
    "PosteRedisZset", "PosteRedisStream", "PosteRedisMeta", "PosteRedisError",
    "PosteRedisOk", "PosteRedisNil", "PosteRedisSep", "PosteRedisIndex",
    "PosteRedisField", "PosteRedisScore",
    "PosteSqlHeader", "PosteSqlNull", "PosteSqlMeta", "PosteSqlBorder",
    "PosteSqlCellSelected", "PosteSqlModified", "PosteSqlDeleted", "PosteSqlAdded",
    "PosteSqlBoundary", "PosteSqlBoundaryBorder",
    "PosteHttpBoundaryBorder",
    "PosteStatus2xx", "PosteStatus3xx", "PosteStatus4xx", "PosteStatus5xx",
    "PosteVerboseSeparator", "PosteVerboseSection", "PosteVerboseSubHeader", "PosteVerboseKey", "PosteVerboseValue",
    "PosteRequestKey", "PosteRequestValue",
    "PosteAssertSummary", "PosteAssertSummaryFail",
    "PosteAssertPass", "PosteAssertFail",
    "PosteAssertIconPass", "PosteAssertIconFail",
    "PosteAssertError", "PosteAssertLogHeader", "PosteAssertLog",
    "PosteAssertSep", "PosteAssertHint",
    "PosteFileLink",
  })
end

-- Apply highlights immediately on require
M.setup()

-- Re-apply when colorscheme changes or after full startup
vim.api.nvim_create_autocmd("ColorScheme", { callback = M.setup })
vim.api.nvim_create_autocmd("VimEnter", { callback = M.setup, once = true })

return M
