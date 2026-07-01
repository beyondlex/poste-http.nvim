--- Completion adapter for Poste SQL.
---
--- Wraps blink.cmp (and future completion plugins) behind a stable interface.
--- All SQL modules MUST go through this adapter instead of requiring blink.cmp
--- internal modules directly.
---
--- Supported operations:
---   register_source(config)    — register poste_sql provider
---   register_filetype(ft, src) — map filetype → source
---   show(opts)                 — force-show completion menu
---   is_menu_open() → bool      — check if menu is visible
---   get_config()               — access blink.cmp config safely
---   get_enabled_providers()    — list active provider IDs
---   set_provider_for_filetype(ft, providers) — override per-filetype providers
---   get_source_lib()           — access blink.cmp sources.lib for advanced use

local M = {}

-- Lazy-load blink.cmp, returning nil if not available.
local function blink()
  local ok, mod = pcall(require, "blink.cmp")
  return ok and mod or nil
end

-- Lazy-load blink.cmp.config
local function blink_config()
  local ok, mod = pcall(require, "blink.cmp.config")
  return ok and mod or nil
end

-- Lazy-load blink.cmp.sources.lib
local function blink_sources()
  local ok, mod = pcall(require, "blink.cmp.sources.lib")
  return ok and mod or nil
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

--- Check if blink.cmp is available.
function M.is_available()
  return blink() ~= nil
end

--- Register a source provider in blink.cmp.
--- @param opts { name: string, module: string, score_offset?: number, min_keyword_length?: number, should_show_items?: boolean, async?: boolean }
function M.register_source(opts)
  local b = blink()
  if not b then return end
  b.add_source_provider(opts.name, {
    module = opts.module,
    name = opts.label or opts.name,
    async = opts.async ~= false,
    score_offset = opts.score_offset or 1000,
    min_keyword_length = opts.min_keyword_length or 0,
    should_show_items = opts.should_show_items ~= false,
  })
end

--- Map a filetype to a source name.
function M.register_filetype(ft, source_name)
  local b = blink()
  if not b then return end
  b.add_filetype_source(ft, source_name)
end

--- Map filetype in config's per_filetype table.
function M.set_per_filetype(ft, sources)
  local cfg = blink_config()
  if not cfg or not cfg.sources then return end
  cfg.sources.per_filetype[ft] = sources
end

--- Set provider for a filetype in per_filetype_provider_ids.
function M.set_provider_for_filetype(ft, provider_ids)
  local src = blink_sources()
  if not src then return end
  src.per_filetype_provider_ids[ft] = provider_ids
end

--- Get enabled provider IDs for completion mode.
function M.get_enabled_providers()
  local src = blink_sources()
  if not src then return {} end
  return src.get_enabled_provider_ids("insert") or {}
end

--- Get per_filetype_provider_ids for diagnostics.
function M.get_per_filetype_provider_ids()
  local src = blink_sources()
  if not src then return {} end
  return src.per_filetype_provider_ids or {}
end

--- Show the completion menu.
--- @param opts table|nil  e.g. { force = true, trigger_kind = "manual" }
function M.show(opts)
  local b = blink()
  if b and b.show then
    b.show()
    return
  end
  -- Fallback: use completion.trigger directly
  local ok, trigger = pcall(require, "blink.cmp.completion.trigger")
  if ok then
    trigger.show(opts or { force = true })
  end
end

--- Check if the completion menu is currently open.
function M.is_menu_open()
  local ok, menu = pcall(require, "blink.cmp.completion.windows.menu")
  return ok and menu.win and menu.win:is_open() or false
end

--- Get the blink.cmp config module (for advanced use).
--- Returns nil if blink.cmp is not loaded.
function M.get_config()
  return blink_config()
end

--- Get the blink.cmp sources.lib module.
function M.get_source_lib()
  return blink_sources()
end

--- Get the completion.trigger module.
function M.get_trigger()
  local ok, trigger = pcall(require, "blink.cmp.completion.trigger")
  return ok and trigger or nil
end

--- Override show_on_blocked_trigger_characters to allow space in SQL.
function M.patch_blocked_trigger_chars()
  local cfg = blink_config()
  if not cfg or not cfg.completion or not cfg.completion.trigger then return end
  local orig = cfg.completion.trigger.show_on_blocked_trigger_characters
  cfg.completion.trigger.show_on_blocked_trigger_characters = function()
    local ft = vim.bo.filetype
    if ft == "poste_sql" or ft == "poste_sqlite" then
      local blocked = type(orig) == "function" and orig() or orig
      return vim.tbl_filter(function(c) return c ~= " " end, blocked or {})
    end
    return type(orig) == "function" and orig() or orig
  end
end

--- Check if a specific provider is registered in config.
function M.has_provider(name)
  local cfg = blink_config()
  if not cfg or not cfg.sources or not cfg.sources.providers then return false end
  return cfg.sources.providers[name] ~= nil
end

--- Get CompletionItemKind for type items.
function M.completion_item_kind(name)
  local ok, types = pcall(require, "blink.cmp.types")
  if ok and types and types.CompletionItemKind then
    return types.CompletionItemKind[name] or types.CompletionItemKind.Text
  end
  return nil
end

return M
