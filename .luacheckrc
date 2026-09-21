-- Luacheck configuration for Poste
-- https://github.com/mpeterv/luacheck

-- Don't warn about unused arguments (_ prefix convention)
unused_args = false

-- Don't warn about global variables; they are Neovim API calls
allow_defined = true
read_globals = {
  -- Neovim API
  "vim",

  -- Busted test framework
  "describe",
  "it",
  "before_each",
  "after_each",
  "assert",
  "pending",
  "setup",
  "teardown",
}

-- Ignore line length
max_line_length = false

-- Ignore "setting read-only field" (Neovim bo/wo/g metatable patterns)
ignore = { "122" }

-- Example pre/post scripts run inside the plugin's Lua sandbox, which
-- injects these objects as globals (see http/script_sandbox.lua). Not
-- defined at parse time, so declare them instead of warning on each use.
files["examples"] = {
  globals = {
    "client",
    "response",
    "request",
  },
}
