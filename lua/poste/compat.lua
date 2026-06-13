--- Centralized compatibility detection.
--- Detection is lazy (runs on first access), so blink.cmp / nvim-cmp
--- can be loaded after Poste without stale cached results.

local M = {}

local detected = false

local function ensure()
  if detected then return end
  detected = true

  M.blink_ok, M.blink = pcall(require, "blink.cmp")

  M.cmp_ok, M.cmp = pcall(require, "cmp")

  if M.blink_ok then
    M.blink_config_ok, M.blink_config = pcall(require, "blink.cmp.config")
    M.blink_sources_ok, M.blink_sources = pcall(require, "blink.cmp.sources.lib")
    M.blink_types_ok, M.blink_types = pcall(require, "blink.cmp.types")
    M.blink_trigger_ok, M.blink_trigger = pcall(require, "blink.cmp.completion.trigger")
  else
    M.blink_config_ok, M.blink_config = false, nil
    M.blink_sources_ok, M.blink_sources = false, nil
    M.blink_types_ok, M.blink_types = false, nil
    M.blink_trigger_ok, M.blink_trigger = false, nil
  end
end

return setmetatable(M, {
  __index = function(t, k)
    ensure()
    return rawget(t, k)
  end,
})