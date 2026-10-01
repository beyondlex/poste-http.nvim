local notify = require("poste-http.ui.notify").notify
local M = { _handlers = {} }

function M.on(event, handler)
  M._handlers[event] = M._handlers[event] or {}
  table.insert(M._handlers[event], handler)
  return function()
    local handlers = M._handlers[event]
    if not handlers then return end
    for i, h in ipairs(handlers) do
      if h == handler then
        table.remove(handlers, i)
        return
      end
    end
  end
end

function M.once(event, handler)
  local wrapper
  wrapper = function(data)
    -- pcall first: a bare handler(data) here would let the error propagate
    -- to emit()'s pcall and skip the self-removal below, so a failing
    -- "once" handler fired again on the next emit. Re-raise (via error)
    -- keeps emit's notify-on-error behavior intact.
    local ok, err = pcall(handler, data)
    local handlers = M._handlers[event]
    if handlers then
      for i, h in ipairs(handlers) do
        if h == wrapper then
          table.remove(handlers, i)
          break
        end
      end
    end
    if not ok then error(err, 0) end
  end
  return M.on(event, wrapper)
end

function M.emit(event, data)
  local handlers = M._handlers[event]
  if not handlers then return end
  local copy = vim.deepcopy(handlers)
  for _, handler in ipairs(copy) do
    local ok, err = pcall(handler, data)
    if not ok then
      vim.schedule(function()
        notify(
          string.format("event '%s' handler error: %s", event, tostring(err)),
          vim.log.levels.ERROR
        )
      end)
    end
  end
end

function M.clear(event)
  if event then
    M._handlers[event] = nil
  else
    M._handlers = {}
  end
end

function M.handler_count(event)
  return #(M._handlers[event] or {})
end

return M