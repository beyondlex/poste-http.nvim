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
