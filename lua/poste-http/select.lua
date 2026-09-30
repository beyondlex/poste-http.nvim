local M = {}
local picker = require("poste-http.ui.picker")
local notify = require("poste-http.ui.notify").notify

local function normalize_items(items)
  local result = {}
  for i, v in ipairs(items) do
    if type(v) == "string" then
      result[i] = { key = v, name = v, description = "" }
    elseif type(v) == "table" then
      result[i] = {
        key = v.key or v.name or tostring(i),
        name = v.name or v.key or tostring(i),
        description = v.description or "",
      }
    else
      result[i] = { key = tostring(v), name = tostring(v), description = "" }
    end
  end
  return result
end

local function pick_snacks(items, prompt, on_select)
  local ok_snacks, snacks = pcall(require, "snacks")
  if not ok_snacks or not snacks then
    on_select(nil)
    return
  end
  local picker_items = {}
  for _, item in ipairs(items) do
    picker_items[#picker_items + 1] = {
      text = item.name,
      description = item.description,
      key = item.key,
    }
  end
  local resolved = false
  snacks.picker.select(
    picker_items,
    {
      prompt = prompt or 'Select items:',
      layout = 'select',
      format_item = function(item)
        local text = item.text
        if item.description and item.description ~= "" then
          text = text .. "  " .. item.description
        end
        return text
      end,
      close = function()
        if not resolved then
          resolved = true
          on_select(nil)
        end
      end,
    },
    function(item, _idx)
      if not resolved then
        resolved = true
        on_select(item and item.key or nil)
      end
    end
  )
end

local function pick_vimui(items, prompt, on_select)
  vim.ui.select(items, {
    prompt = prompt,
    format_item = function(item)
      if item.description ~= "" then
        return item.name .. "  (" .. item.description .. ")"
      end
      return item.name
    end,
  }, function(choice)
    on_select(choice and choice.key or nil)
  end)
end

function M.select(items, prompt, on_select)
  local normalized = normalize_items(items)
  if #normalized == 0 then
    vim.schedule(function() pcall(on_select, nil) end)
    return
  end
  local ok_picker, _ = pcall(require, "snacks.picker")
  if ok_picker then
    pick_snacks(normalized, prompt, on_select)
    return
  end
  local ok, err = pcall(picker.open, normalized, prompt, on_select)
  if not ok then
    notify("picker failed: " .. tostring(err), vim.log.levels.WARN)
    pick_vimui(normalized, prompt, on_select)
  end
end

return M
