# Keymaps Reference

> All Poste keybindings are customizable. Pass a `keymaps` table to `setup()` to override.

```lua
require("poste").setup({
  keymaps = {
    -- Only specify what you want to change; the rest stay at defaults
    http_source = {
      run = "<leader>r",  -- Change <CR> to <leader>r
    },
    http_response = {
      view_body = false,  -- false = disable this key
    },
  },
})
```

`<leader>` is resolved to your actual mapleader value. Special characters are
automatically mapped to readable names (e.g., space → `<Space>`).

---

## Keymap Group Index

Poste keymaps are grouped by UI element. Each group has a unique config name:

| Config Name | Protocol | UI |
|-------------|----------|----|
| `http_source` | HTTP | HTTP source file (`.http` / `.rest`) |
| `http_response` | HTTP | HTTP response buffer |
| `http_history` | HTTP | HTTP request history popup |

SQL keymap groups (`sql_source`, `sql_dataset`, `sql_table_ops`, `sql_db_browser`, `sql_introspect`) are configured in the [poste-sql.nvim](https://github.com/beyondlex/poste-sql.nvim) plugin.

Override in `setup({ keymaps = { <group_name> = { ... } } })`.

---

## 1. HTTP Source (`http_source`)

| Key | Action | Description |
|-----|--------|-------------|
| `<CR>` | `run` | Execute request under cursor |
| `]]` | `jump_next` | Jump to next request block |
| `[[` | `jump_prev` | Jump to previous request block |
| `gd` | `goto_definition` | Go to variable definition |
| `grr` | `goto_references` | Show variable references |
| `]q` | `quickfix_next` | Next quickfix item |
| `[q` | `quickfix_prev` | Previous quickfix item |
| `<leader>rp` | `paste_curl` | Paste curl command from clipboard |
| `<leader>rc` | `copy_as_curl` | Copy request as curl command |
| `gs` | `toggle_outline` | Toggle outline sidebar |
| `<leader>vv` | `pick_env` | Select environment |
| `K` | `show_var_value` | Show variable value / response chain |
| `<leader>l` | `show_history` | Open request history |
| `g?` | `help` | Open help window |

## 2. HTTP Response Buffer (`http_response`)

| Key | Action | Description |
|-----|--------|-------------|
| `q` | `close` | Close response window |
| `B` | `view_body` | Switch to Body tab |
| `R` | `view_request` | Switch to Request tab |
| `E` | `view_verbose` | Switch to Verbose tab |
| `A` | `view_assertions` | Switch to Assertions tab |
| `S` | `view_script_logs` | Switch to Script Logs tab |
| `<Tab>` | `next_tab` | Next tab |
| `<S-Tab>` | `prev_tab` | Previous tab |
| `r` | `rerun` | Re-execute current request |
| `]` | `next_response` | Next response (multi-response mode) |
| `[` | `prev_response` | Previous response (multi-response mode) |
| `K` | `image_preview` | Inline image preview; fallback to external viewer |
| `<leader>j` | `json_filter` | Interactive jq filter |
| `<leader>jc` | `json_restore` | Restore original JSON |
| `<leader>jr` | `json_toggle_raw` | Toggle raw/pretty mode |
| `<leader>jo` | `json_outline` | JSON structure outline |

## 3. HTTP Request History (`http_history`)

| Key | Action | Description |
|-----|--------|-------------|
| `q` | `close` | Close history window |
| `dd` | `delete_entry` | Delete current entry |
| `<CR>` | `focus_detail` | Focus detail panel |

---

## Key Display Rules

UI labels (winbar) and the help window display keys according to these rules:

| Config Value | mapleader | Display |
|-------------|-----------|---------|
| `B` | — | `B` |
| `<Tab>` | — | `Tab` |
| `<leader>j` | `\` (default) | `\j` |
| `<leader>j` | `,` | `,j` |
| `<leader>j` | `<Space>` | `<Space>j` |

---

## Disabling Keys

Set to `false` to disable:

```lua
require("poste").setup({
  keymaps = {
    sql_dataset = {
      sort_column = false,
      toggle_raw_mode = false,
    },
  },
})
```

Disabled keys are not registered and won't show `[key]` hints in UI labels.

---

## Viewing Current Keys

Press `g?` in any source file to open the help window showing all currently
configured keybindings.

---

## Full Default Configuration

Below is the complete default keymap config from `state.lua`, ready to use as
a starting point for customization. SQL keymap defaults are in the
[poste-sql.nvim](https://github.com/beyondlex/poste-sql.nvim) plugin.

```lua
require("poste").setup({
  keymaps = {
    http_source = {
      run = "<CR>",
      jump_next = "]]",
      jump_prev = "[[",
      goto_definition = "gd",
      goto_references = "grr",
      quickfix_next = "]q",
      quickfix_prev = "[q",
      paste_curl = "<leader>rp",
      copy_as_curl = "<leader>rc",
      toggle_outline = "gs",
      pick_env = "<leader>vv",
      show_var_value = "K",
      show_history = "<leader>l",
      help = "g?",
    },
    http_response = {
      close = "q",
      view_body = "B",
      view_request = "R",
      view_verbose = "E",
      view_assertions = "A",
      view_script_logs = "S",
      next_tab = "<Tab>",
      prev_tab = "<S-Tab>",
      rerun = "r",
      next_response = "]",
      prev_response = "[",
      json_filter = "<leader>j",
      json_restore = "<leader>jc",
      json_toggle_raw = "<leader>jr",
      json_outline = "<leader>jo",
    },
    http_history = {
      close = "q",
      delete_entry = "dd",
      focus_detail = "<CR>",
    },
  },
})
```
