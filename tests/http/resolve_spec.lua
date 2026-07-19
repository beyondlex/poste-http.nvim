local resolve = require("poste.http.resolve")

describe("resolve.resolve", function()
  local original_handlers

  before_each(function()
    original_handlers = resolve._test.get_handlers()
  end)

  after_each(function()
    resolve._test.set_handlers(original_handlers)
  end)

  it("runs request mode as prompts then dependencies", function()
    local calls = {}

    resolve._test.set_handlers({
      prompts = function(content, opts, on_complete)
        table.insert(calls, {
          stage = "prompts",
          content = content,
          mode = opts.mode,
          cursor_line = opts.cursor_line,
        })
        on_complete(content .. " -> prompts")
      end,
      dependencies = function(content, opts, on_complete)
        table.insert(calls, {
          stage = "dependencies",
          content = content,
          mode = opts.mode,
          block_line = opts.block_line,
        })
        on_complete(content .. " -> deps")
      end,
    })

    local result = nil
    resolve.resolve("body", {
      mode = "request",
      cursor_line = 12,
      block_line = 10,
    }, function(resolved)
      result = resolved
    end)

    assert.equals("body -> prompts -> deps", result)
    assert.equals(2, #calls)
    assert.equals("prompts", calls[1].stage)
    assert.equals("dependencies", calls[2].stage)
    assert.equals("request", calls[1].mode)
    assert.equals("request", calls[2].mode)
  end)

  it("runs import mode as dependencies then prompts", function()
    local calls = {}

    resolve._test.set_handlers({
      prompts = function(content, opts, on_complete)
        table.insert(calls, {
          stage = "prompts",
          content = content,
          mode = opts.mode,
        })
        on_complete(content .. " -> prompts")
      end,
      dependencies = function(content, opts, on_complete)
        table.insert(calls, {
          stage = "dependencies",
          content = content,
          mode = opts.mode,
        })
        on_complete(content .. " -> deps")
      end,
    })

    local result = nil
    resolve.resolve("body", {
      mode = "import",
      cursor_line = 12,
      block_line = 10,
    }, function(resolved)
      result = resolved
    end)

    assert.equals("body -> deps -> prompts", result)
    assert.equals(2, #calls)
    assert.equals("dependencies", calls[1].stage)
    assert.equals("prompts", calls[2].stage)
    assert.equals("import", calls[1].mode)
    assert.equals("import", calls[2].mode)
  end)
end)
