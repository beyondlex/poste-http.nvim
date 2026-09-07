--- Winbar rendering shared by the response window, history detail, and the
--- request buffer's env bar.
---
--- All winbar string assembly lives here: only this module may build
--- %#highlight#/%= winbar strings (docs/dev/agent-guardrails.md §1).

local M = {}

--- Render the request-buffer env bar: env name on the left, help hint on
--- the right. Moved here from http/env.lua so the exact shape is defined
--- once — env.sync_winbar compares against this string to decide whether a
--- window's current winbar is ours and should be restored.
--- @param env_name string
--- @return string
function M.http_env(env_name)
  local left = string.format(" Env: %s ", env_name)
  local right = " g? help "
  return "%#PosteSqlMeta#" .. left .. "%=" .. "%#PosteSqlMetaDim#" .. right
end

--- Render tab descriptors into a winbar string.
--- @param tabs table[]  array of { id = string, label = string }
--- @param active_id string|nil  id of the highlighted tab
--- @return string
function M.render_tabs(tabs, active_id)
  local parts = {}
  for _, tab in ipairs(tabs or {}) do
    if tab.id == active_id then
      parts[#parts + 1] = "%#TabLineSel# " .. tab.label .. " %*"
    else
      parts[#parts + 1] = "%#TabLine# " .. tab.label .. " %*"
    end
  end
  return table.concat(parts)
end

--- Id of the tab after stepping direction (-1/+1) from current_id, wrapping
--- around the ends. Unknown ids start from the first tab.
--- @param tabs table[]  array of { id = string }
--- @param current_id string|nil
--- @param direction number|nil  default 1
--- @return string|nil  next tab id, or nil when there are no tabs
function M.cycle(tabs, current_id, direction)
  if not tabs or #tabs == 0 then return nil end
  local idx = 1
  for i, tab in ipairs(tabs) do
    if tab.id == current_id then idx = i end
  end
  local next_idx = ((idx - 1 + (direction or 1)) % #tabs) + 1
  return tabs[next_idx].id
end

return M
