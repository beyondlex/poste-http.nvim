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
| `sql_source` | SQL | SQL source file (`.sql` / `.mysql` / `.sqlite`) |
| `sql_dataset` | SQL | SQL dataset result buffer |
| `sql_table_ops` | SQL | SQL table operations menu |
| `sql_db_browser` | SQL | Database browser |
| `sql_introspect` | SQL | Introspect structure popup |

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

## 4. SQL Source (`sql_source`)

| Key | Action | Description |
|-----|--------|-------------|
| `<CR>` | `run` | Execute SQL statement |
| `K` | `show_ddl` | Show DDL / column info |
| `<leader>ff` | `format` | Format SQL |
| `<leader>cr` | `clear_filter` | Clear filter / search |
| `<leader>db` | `toggle_db_browser` | Toggle database browser |
| `<C-Space>` | `trigger_completion` | Trigger completion |
| `g?` | `help` | Open help window |

## 5. SQL Dataset Buffer (`sql_dataset`)

### Cell Navigation

| Key | Action | Description |
|-----|--------|-------------|
| `q` | `close` | Close dataset window |
| `h` | `move_left` | Move left one cell |
| `j` | `move_down` | Move down one cell |
| `k` | `move_up` | Move up one cell |
| `l` | `move_right` | Move right one cell |
| `H` | `prev_page` | Previous page |
| `L` | `next_page` | Next page |
| `0` | `first_col` | First column |
| `$` | `last_col` | Last column |
| `gg` | `first_row` | First row |
| `G` | `last_row` | Last row |

### Data Operations

| Key | Action | Description |
|-----|--------|-------------|
| `K` | `preview_cell` | Preview cell content (float) |
| `yy` | `yank_cell` | Copy current cell |
| `yc` | `yank_column` | Copy current column |
| `s` | `sort_column` | Sort by current column |
| `i` | `edit_cell` | Edit cell |
| `cc` | `edit_cell_replace` | Replace cell content |
| `dd` | `delete_row` | Delete row |
| `o` | `insert_row` | Insert row |
| `<leader>w` | `commit_edits` | Commit edits (generate DML) |
| `E` | `export` | Export dataset |

### Display Options

| Key | Action | Description |
|-----|--------|-------------|
| `zh` | `toggle_cell_highlight` | Toggle cell highlight |
| `zH` | `toggle_header_float` | Toggle floating header |
| `zN` | `toggle_row_numbers` | Toggle row numbers |
| `<leader>gp` | `toggle_raw_mode` | Toggle compact mode |
| `<leader>hh` | `goto_first_page` | First page |
| `<leader>ll` | `goto_last_page` | Last page |
| `<leader>pa` | `toggle_pagination` | Toggle pagination |
| `<leader>fc` | `find_column` | Find column |
| `<leader>ce` | `filter_by_cell` | Filter by current cell value |
| `<leader>/` | `show_search` | Search in results |
| `<leader>cr` | `clear_filter_search` | Clear filter / search |

### Search

| Key | Action | Description |
|-----|--------|-------------|
| `n` | `next_search` | Next match |
| `N` | `prev_search` | Previous match |

### Tabs

| Key | Action | Description |
|-----|--------|-------------|
| `<Tab>` | `next_tab` | Next result tab |
| `<S-Tab>` | `prev_tab` | Previous result tab |
| `R` | `rerun` | Re-execute query |

## 6. SQL Table Operations (`sql_table_ops`)

| Key | Action | Description |
|-----|--------|-------------|
| `ma` | `select_all` | SELECT * |
| `mr` | `refresh_all` | Refresh table list |
| `md` | `describe_all` | DESCRIBE table |
| `mt` | `toggle_menu` | Toggle operations menu |

## 7. Database Browser (`sql_db_browser`)

| Key | Action | Description |
|-----|--------|-------------|
| `<CR>` | `toggle_node` | Expand/collapse node |
| `h` | `move_left` | Collapse / go to parent |
| `l` | `move_right` | Expand / go to first child |
| `x` | `context_menu` | Open context menu |
| `r` | `refresh_node` | Refresh child nodes |
| `/` | `search_filter` | Fuzzy search tree |
| `s` | `select_query` | Generate SELECT query |
| `d` | `describe_query` | Generate DESCRIBE query |
| `q` | `close` | Close browser |
| `n` | `search_next` | Next search match |
| `N` | `search_prev` | Previous search match |

## 8. Introspect Popup (`sql_introspect`)

| Key | Action | Description |
|-----|--------|-------------|
| `q` | `close` | Close popup |
| `<Esc>` | `close_alt` | Close popup |

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
a starting point for customization:

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
    sql_source = {
      run = "<CR>",
      show_ddl = "K",
      format = "<leader>ff",
      clear_filter = "<leader>cr",
      toggle_db_browser = "<leader>db",
      trigger_completion = "<C-Space>",
      help = "g?",
    },
    sql_dataset = {
      close = "q",
      move_left = "h",
      move_down = "j",
      move_up = "k",
      move_right = "l",
      prev_page = "H",
      next_page = "L",
      first_col = "0",
      last_col = "$",
      first_row = "gg",
      last_row = "G",
      preview_cell = "K",
      yank_cell = "yy",
      yank_column = "yc",
      sort_column = "s",
      toggle_cell_highlight = "zh",
      toggle_header_float = "zH",
      toggle_row_numbers = "zN",
      toggle_raw_mode = "<leader>gp",
      next_tab = "<Tab>",
      prev_tab = "<S-Tab>",
      rerun = "R",
      goto_first_page = "<leader>hh",
      goto_last_page = "<leader>ll",
      toggle_pagination = "<leader>pa",
      find_column = "<leader>fc",
      filter_by_cell = "<leader>ce",
      show_search = "<leader>/",
      clear_filter_search = "<leader>cr",
      next_search = "n",
      prev_search = "N",
      edit_cell = "i",
      edit_cell_replace = "cc",
      delete_row = "dd",
      insert_row = "o",
      commit_edits = "<leader>w",
      export = "E",
    },
    sql_table_ops = {
      select_all = "ma",
      refresh_all = "mr",
      describe_all = "md",
      toggle_menu = "mt",
    },
    sql_db_browser = {
      toggle_node = "<CR>",
      move_left = "h",
      move_right = "l",
      context_menu = "x",
      refresh_node = "r",
      search_filter = "/",
      select_query = "s",
      describe_query = "d",
      close = "q",
      search_next = "n",
      search_prev = "N",
    },
    sql_introspect = {
      close = "q",
      close_alt = "<Esc>",
    },
    http_history = {
      close = "q",
      delete_entry = "dd",
      focus_detail = "<CR>",
    },
  },
})
```
