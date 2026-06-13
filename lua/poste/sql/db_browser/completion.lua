--- SQL column type completion for Modify Column / New Column forms.
--- Supports both blink.cmp and nvim-cmp; gracefully degrades if neither is installed.

local M = {}
local compat = require("poste.compat")

-- Lazy-loaded kind constant
local _Kind = nil
local function kind_type_param()
  if not _Kind then
    _Kind = (compat.blink_types_ok and compat.blink_types.CompletionItemKind) or { TypeParameter = 25 }
  end
  return _Kind.TypeParameter or 25
end

-- Dialect-specific type lists
local types = {
  postgres = {
    "smallint", "integer", "bigint", "smallserial", "serial", "bigserial",
    "decimal", "numeric", "real", "double precision", "money",
    "varchar", "character varying", "char", "character", "text",
    "bytea",
    "timestamp", "timestamptz", "timestamp with time zone",
    "timestamp without time zone", "date", "time", "timetz",
    "time with time zone", "time without time zone", "interval",
    "boolean",
    "point", "line", "lseg", "box", "path", "polygon", "circle",
    "cidr", "inet", "macaddr", "macaddr8",
    "bit", "bit varying", "varbit",
    "tsvector", "tsquery",
    "json", "jsonb", "uuid", "xml",
    "int4range", "int8range", "numrange", "tsrange", "tstzrange", "daterange",
    "oid",
  },
  mysql = {
    "tinyint", "smallint", "mediumint", "int", "integer", "bigint",
    "decimal", "numeric", "float", "double", "double precision", "real",
    "bit", "char", "varchar",
    "tinytext", "text", "mediumtext", "longtext",
    "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob",
    "date", "datetime", "timestamp", "time", "year",
    "json", "enum", "set", "boolean", "bool",
    "geometry", "point", "linestring", "polygon",
  },
  sqlite = {
    "integer", "real", "text", "blob", "numeric",
  },
}

--- Shared filtering logic.
--- @return blink.cmp.CompletionItem[]
local function filter_types(keyword, dialect)
  local list = types[dialect] or types.postgres
  local lowered = keyword:lower()
  local kind = kind_type_param()

  local items = {}
  local exact = {}
  local prefix = {}
  local contain = {}

  for _, t in ipairs(list) do
    local tl = t:lower()
    local item = { label = t, kind = kind, insertText = t, word = t }
    if lowered == "" then
      table.insert(items, item)
    elseif lowered == tl then
      table.insert(exact, item)
    elseif vim.startswith(tl, lowered) then
      table.insert(prefix, item)
    elseif tl:find(lowered, 1, true) then
      table.insert(contain, item)
    end
  end

  for _, item in ipairs(exact) do table.insert(items, item) end
  for _, item in ipairs(prefix) do table.insert(items, item) end
  for _, item in ipairs(contain) do table.insert(items, item) end

  return items
end

----------------------------------------------------------------------
-- blink.cmp source
----------------------------------------------------------------------

function M.ensure_registered_blink()
  if not compat.blink_config_ok or not compat.blink_config then return end
  if not compat.blink_config.sources then return end
  if compat.blink_config.sources.providers["poste-sql-types"] then return end
  compat.blink_config.sources.providers["poste-sql-types"] = {
    name = "SQL Types",
    module = "poste.sql.db_browser.completion",
  }
end

function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

function M:enabled() return true end

function M:get_completions(context, callback)
  local dialect = vim.g.poste_sql_dialect or "postgres"
  local keyword = context:get_keyword() or ""
  local items = filter_types(keyword, dialect)
  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

function M:get_trigger_characters() return {} end

----------------------------------------------------------------------
-- nvim-cmp source
----------------------------------------------------------------------

local _cmp_registered = false
local _cmp_source = {
  name = "poste-sql-types",
  complete = function(self, params, callback)
    local dialect = vim.g.poste_sql_dialect or "postgres"
    local keyword = ""
    if params.context then
      local line = params.context.cursor_before_line or ""
      keyword = line:sub((params.offset or 0) + 1)
    end
    local items = filter_types(keyword, dialect)
    callback({ items = items, isIncomplete = false })
  end,
}

function M.ensure_registered_cmp()
  if _cmp_registered then return end
  if not compat.cmp_ok then return end
  compat.cmp.register_source("poste-sql-types", _cmp_source)
  _cmp_registered = true
end

----------------------------------------------------------------------
-- Unified injection (called by forms.lua before vim.ui.input)
----------------------------------------------------------------------

-- Internal state
local _enabled = false
local _orig_blink_providers = nil
local _cmp_autocmd_setup = false

--- Enable SQL type completion for the next DressingInput buffer.
--- Must call M.cleanup() after the input is done.
function M.enable_for_next_input()
  if _enabled then return end
  _enabled = true

  -- blink.cmp
  if compat.blink_sources_ok and compat.blink_sources then
    M.ensure_registered_blink()
    _orig_blink_providers = compat.blink_sources.per_filetype_provider_ids["DressingInput"]
    compat.blink_sources.per_filetype_provider_ids["DressingInput"] = { "poste-sql-types" }
    return
  end

  -- nvim-cmp: autocmd hooks into DressingInput buffer creation
  if not _cmp_autocmd_setup then
    _cmp_autocmd_setup = true
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "DressingInput",
      callback = function(ev)
        if not _enabled then return end
        if not compat.cmp_ok then return end
        M.ensure_registered_cmp()
        compat.cmp.setup.buffer(ev.buf, {
          sources = compat.cmp.config.sources({
            { name = "poste-sql-types" },
          }),
        })
      end,
    })
  end
end

--- Clean up after input is done.
function M.cleanup()
  _enabled = false

  -- blink.cmp: restore original providers
  if compat.blink_sources_ok and compat.blink_sources then
    compat.blink_sources.per_filetype_provider_ids["DressingInput"] = _orig_blink_providers
    _orig_blink_providers = nil
  end
end

return M
