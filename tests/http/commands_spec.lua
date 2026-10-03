local harness = require("helpers.gui_harness")

describe("commands", function()
  before_each(function()
    harness.setup()
    package.loaded["poste-http.commands"] = nil
  end)

  after_each(function()
    harness.teardown()
  end)

  it("registers all commands with the PosteHttp prefix", function()
    local commands = require("poste-http.commands")
    commands.setup()

    local cmds = harness.get_user_commands()

    local expected = {
      "PosteHttpRun", "PosteHttpEnv", "PosteHttpPasteCurl",
      "PosteHttpImportOpenAPI", "PosteHttpImportSwagger", "PosteHttpImportPostman",
      "PosteHttpCopyAsCurl", "PosteHttpHelp", "PosteHttpImportResolve",
      "PosteHttpCmpStatus", "PosteHttpCmpProfile",
      "PosteHttpSymbols", "PosteHttpOutline", "PosteHttpFormat", "PosteHttpHistory",
      "PosteHttpHistoryClear", "PosteHttpClearCache", "PosteHttpTSInspect",
      "PosteHttpBuildParsers",
    }

    for _, name in ipairs(expected) do
      assert.is_not_nil(cmds[name],
        string.format("command '%s' should be registered", name))
    end
  end)

  it("PosteHttpHistoryClear wipes the history through history.clear", function()
    -- Scriptable wipe-all (family parity with :PosteMqHistoryClear); the
    -- browser's double-D guard stays the interactive route. The harness
    -- records registrations instead of dispatching vim.cmd, so fire the
    -- recorded handler directly (opts structure of a no-arg command).
    local cleared = 0
    package.loaded["poste-http.http.history"] = {
      clear = function() cleared = cleared + 1 end,
    }
    local commands = require("poste-http.commands")
    commands.setup()
    local cmd = harness.get_user_commands()["PosteHttpHistoryClear"]
    assert.truthy(cmd, "command registered")
    cmd.callback({ args = "", line1 = 0, line2 = 0, range = 0 })
    assert.equals(1, cleared)
    package.loaded["poste-http.http.history"] = nil
  end)

  it("PosteHttpBuildParsers runs install.force_build", function()
    -- health.lua/install.lua direct users at this command; the registration
    -- used to be missing, so the guidance named a command that did not exist.
    local built = 0
    package.loaded["poste-http.install"] = {
      force_build = function() built = built + 1; return true end,
    }
    local commands = require("poste-http.commands")
    commands.setup()
    local cmd = harness.get_user_commands()["PosteHttpBuildParsers"]
    assert.truthy(cmd, "command registered")
    cmd.callback({ args = "", line1 = 0, line2 = 0, range = 0 })
    assert.equals(1, built)
    package.loaded["poste-http.install"] = nil
  end)

  it("never registers a command without the PosteHttp prefix", function()
    local commands = require("poste-http.commands")
    commands.setup()

    for name in pairs(harness.get_user_commands()) do
      assert.truthy(name:match("^PosteHttp"), name .. " must start with PosteHttp")
    end
  end)
end)
