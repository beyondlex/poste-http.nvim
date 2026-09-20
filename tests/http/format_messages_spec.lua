-- Tests for the messages view formatter (WebSocket frames → lines).

local messages = require("poste-http.http.format.messages")

describe("format.messages.format_messages", function()
  it("renders sent and received sections", function()
    local lines = messages.format_messages({
      metadata = {
        frames = {
          sent = { '{"type": "ping"}' },
          received = { 'pong', '{"type": "message"}' },
        },
      },
    })
    local joined = table.concat(lines, "\n")
    assert.matches("Sent", joined)
    assert.matches("Received", joined)
    assert.matches("→ %{\"type\": \"ping\"%}", joined)
    assert.matches("← pong", joined)
    assert.matches("← %{\"type\": \"message\"%}", joined)
  end)

  it("renders a hint when nothing was received", function()
    local lines = messages.format_messages({
      metadata = { frames = { sent = {}, received = {} } },
    })
    assert.matches("no messages received", table.concat(lines, "\n"))
  end)

  it("tolerates a response without frames", function()
    local lines = messages.format_messages({ metadata = {} })
    assert.is_true(#lines > 0)
  end)

  it("normalizes table-shaped sent frames like received ones", function()
    -- ws_session send paths store plain strings today, but format_messages
    -- used to concatenate sent frames raw — a { data = ... } entry would
    -- have crashed with "attempt to concatenate a table value".
    local lines = messages.format_messages({
      metadata = {
        frames = {
          sent = { { direction = "send", data = "hello" } },
          received = {},
        },
      },
    })
    assert.matches("→ hello", table.concat(lines, "\n"))
  end)
end)
