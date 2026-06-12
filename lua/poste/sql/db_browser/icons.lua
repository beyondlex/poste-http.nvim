local state = require("poste.state")

local ICONS = {
  connection = "\239\136\179",
  mysql      = "\238\156\132",
  postgres   = "\238\157\174",
  sqlite     = "\238\159\132",
  database   = "\239\135\128",
  schema     = "\239\129\187",
  table      = "\239\131\142",
  column     = "\226\151\143",
  column_pk  = "\239\130\132",
  column_fk  = "\239\131\129",
  index      = "#",
  key_group   = "\239\130\132",
  fk_group    = "\239\131\129",
  index_group = "#",
  key_item    = "\239\130\132",
  fk_item     = "\239\131\129",
  index_item  = "#",
}

local DIALECT_ICONS = {
  mysql    = ICONS.mysql,
  postgres = ICONS.postgres,
  sqlite   = ICONS.sqlite,
}

local MARKER_COLLAPSED = "\239\132\133"
local MARKER_EXPANDED  = "\239\132\135"
local MARKER_LOADING   = "\226\128\166"
local HEADER_LINES = 3

local hl_ns = vim.api.nvim_create_namespace("poste_db_browser")

local function setup_highlights()
  local function resolve_hl(name)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
    if ok and hl then return hl end
    return nil
  end

  local normal = resolve_hl("Normal")
  local is_dark = true
  if normal and normal.bg then
    local bg = normal.bg
    local r = math.floor(bg / 65536) % 256
    local g = math.floor(bg / 256) % 256
    local b = bg % 256
    local luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255
    is_dark = luminance < 0.5
  end

  if is_dark then
    vim.api.nvim_set_hl(0, "PosteSqlBrowserHeader", { fg = "#7aa2f7", bold = true })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserSeparator", { fg = "#3b4261" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserMarker", { fg = "#565f89" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserTable", { fg = "#9ece6a" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserType", { fg = "#565f89" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserCount", { fg = "#565f89" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconConn", { fg = "#7aa2f7" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconDb", { fg = "#e0af68" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconSchema", { fg = "#7dcfff" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconTable", { fg = "#9ece6a" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconCol", { fg = "#a9b1d6" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconPk", { fg = "#e0af68" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconFk", { fg = "#7dcfff" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserKeyHint", { fg = "#9ece6a", bold = true })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserSearchMatch", { bg = "#544d33", bold = true })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserSearchChar", { fg = "#bb9af7", bold = true })
  else
    vim.api.nvim_set_hl(0, "PosteSqlBrowserHeader", { fg = "#2e7de9", bold = true })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserSeparator", { fg = "#a8aecb" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserMarker", { fg = "#8990b3" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserTable", { fg = "#587539" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserType", { fg = "#8990b3" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserCount", { fg = "#8990b3" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconConn", { fg = "#2e7de9" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconDb", { fg = "#8c6c3e" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconSchema", { fg = "#1880a8" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconTable", { fg = "#587539" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconCol", { fg = "#6172b0" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconPk", { fg = "#8c6c3e" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserIconFk", { fg = "#1880a8" })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserKeyHint", { fg = "#587539", bold = true })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserSearchMatch", { bg = "#f5e6b8", bold = true })
    vim.api.nvim_set_hl(0, "PosteSqlBrowserSearchChar", { fg = "#9854f1", bold = true })
  end

  state.apply_highlight_overrides({
    "PosteSqlBrowserHeader", "PosteSqlBrowserSeparator", "PosteSqlBrowserMarker",
    "PosteSqlBrowserTable", "PosteSqlBrowserType", "PosteSqlBrowserCount",
    "PosteSqlBrowserIconConn", "PosteSqlBrowserIconDb", "PosteSqlBrowserIconSchema",
    "PosteSqlBrowserIconTable", "PosteSqlBrowserIconCol",
    "PosteSqlBrowserIconPk", "PosteSqlBrowserIconFk",
    "PosteSqlBrowserKeyHint", "PosteSqlBrowserSearchMatch",
    "PosteSqlBrowserSearchChar",
  })
end

setup_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = setup_highlights })

return {
  ICONS = ICONS,
  DIALECT_ICONS = DIALECT_ICONS,
  MARKER_COLLAPSED = MARKER_COLLAPSED,
  MARKER_EXPANDED = MARKER_EXPANDED,
  MARKER_LOADING = MARKER_LOADING,
  HEADER_LINES = HEADER_LINES,
  hl_ns = hl_ns,
}