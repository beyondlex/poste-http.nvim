--- Messages view formatter: renders WebSocket frames into lines (pure).
---
--- Frame transcript shape (docs/dev/multi-protocol-design.md):
---   → outgoing text frames (Sent)
---   ← incoming text frames (Received)
--- Lives in format/ per the layering guardrail: response → lines only,
--- no windows, no IO.

local M = {}

--- Normalize a frame entry: tables carry .data, plain strings are the data.
local function frame_data(f)
  if type(f) == "table" then return f.data end
  return f
end

--- Format the messages view for a response carrying metadata.frames.
--- @param r table|nil  canonical response
--- @return table lines, string filetype
function M.format_messages(r)
  local frames = (r and r.metadata and r.metadata.frames) or {}
  local sent = frames.sent or {}
  local received = frames.received or {}

  local lines = {}
  if #sent == 0 and #received == 0 then
    return { "(no messages received)" }, "text"
  end

  if #sent > 0 then
    table.insert(lines, "Sent (" .. #sent .. ")")
    for _, f in ipairs(sent) do
      -- Same normalization as received frames: a frame entry may be a plain
      -- string (the ws_session send path today) or a { data = ... } table.
      table.insert(lines, "→ " .. frame_data(f))
    end
    if #received > 0 then
      table.insert(lines, "")
    end
  end

  if #received > 0 then
    table.insert(lines, "Received (" .. #received .. ")")
    for _, f in ipairs(received) do
      table.insert(lines, "← " .. frame_data(f))
    end
  end

  return lines, "text"
end

return M
