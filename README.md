# Poste

**Send requests from files. Keyboard-first. Multi-protocol.**

A Neovim plugin and Rust CLI for executing HTTP, Redis, SQL (PostgreSQL / MySQL / SQLite) requests from plain text files. Inspired by JetBrains HTTP Client, with focus on keyboard-driven workflows.

## Features

- **File-based requests** — Define requests in `.http`/`.rest`, `.sql`, `.sqlite`, `.redis`, `.mongo` files
- **Environment variables** — JetBrains-style `env.json` with `{{var}}` substitution
- **Named connections** — `connections.json` for database credentials; supports env var references
- **Keyboard-first** — Execute at cursor, navigate results with Vim keys, never leave home row
- **Multi-protocol** — HTTP, Redis, PostgreSQL, MySQL, SQLite (MongoDB/AMQP stubs)
- **SQL dataset buffer** — Paginated results, cell navigation (hjkl), vim-style search/filter, sorting
- **DB browser** — Tree-view of schemas, tables, columns; generate SELECT/DESCRIBE queries
- **Completion** — HTTP methods/headers/values (nvim-cmp or blink.cmp); SQL keywords/identifiers/columns (blink.cmp)
- **Assertions & scripts** — Inline `> {% ... %}` assertions, pre/post-request scripts
- **Request chaining** — `{{RequestName.res.body.X}}` to extract values from prior responses

## Quick Start

### Install

```lua
-- lazy.nvim
{
  "beyondlex/poste",
  config = function()
    require("poste").setup()
  end,
}
```

```bash
# Rust CLI (optional — for standalone execution or to enable context-aware features)
cargo install --path crates/poste-cli
```

### Create a request file

`requests/api.http`:

```http
### List users
GET {{api_base}}/users
Authorization: Bearer {{api_token}}

### Create user
POST {{api_base}}/users
Content-Type: application/json

{"name": "John", "email": "john@test.com"}
```

`requests/queries.sql`:

```sql
-- @connection pg-dev

SELECT * FROM users WHERE active = true;
```

`requests/cache.redis`:

```redis
# @connection redis://localhost:6379

### Get user session
GET session:user:42

### Set cache
SET post:latest "active"
EXPIRE post:latest 3600
```

### Define environments

`env.json` (walk-up discovery from file directory):

```json
{
  "dev": {
    "api_base": "http://localhost:8080",
    "api_token": "dev-token-xxx",
    "db_host": "127.0.0.1",
    "db_port": "5432",
    "db_user": "app_user",
    "db_pass": "local-pass"
  },
  "prod": {
    "api_base": "https://api.example.com",
    "api_token": "prod-token-xxx"
  }
}
```

### Define connections

`connections.json` (walk-up discovery; supports `{{var}}`):

```json
{
  "pg-dev": {
    "dialect": "postgres",
    "host": "{{db_host}}",
    "port": "{{db_port}}",
    "database": "myapp",
    "user": "{{db_user}}",
    "password": "{{db_pass}}"
  },
  "my-blog": {
    "dialect": "mysql",
    "host": "localhost",
    "port": 3306,
    "database": "blog",
    "user": "root",
    "password": ""
  }
}
```

### Execute

In Neovim, open any supported file. With cursor on a request block, press `<CR>` to execute. Results open in a side panel.

<details>
<summary><b>Default keymaps →</b></summary>

### Source buffer (`.http`, `.sql`, `.redis`)

| Key | Action |
|-----|--------|
| `<CR>` | Execute request at cursor |
| `]]` / `[[` | Jump next/previous block |
| `gd` | Go to definition |
| `grr` | Go to references |
| `gs` | Symbol outline (Telescope fallback to `vim.ui.select`) |
| `<leader>rp` | Paste curl from clipboard |
| `<leader>rc` | Copy request as curl |

### HTTP response buffer

| Key | Action |
|-----|--------|
| `q` | Close |
| `B` / `I` | View Body / Verbose |
| `A` / `S` | View Assertions / Script logs |
| `<Tab>` / `<S-Tab>` | Next/previous tab |

### SQL source buffer (additional)

| Key | Action |
|-----|--------|
| `K` | Show DDL for table under cursor |
| `<leader>db` | Toggle DB browser |
| `<leader>cr` | Clear filter/search in dataset |
| `<C-Space>` | Trigger completion (i mode) |

### SQL dataset buffer

| Key | Action |
|-----|--------|
| `q` | Close |
| `h`/`j`/`k`/`l` | Move cell left/down/up/right |
| `0`/`$` | First/last column |
| `gg`/`G` | First/last row |
| `H`/`L` | Previous/next page |
| `K` | Preview cell content in float |
| `yy` / `yc` | Yank cell / yank column |
| `s` | Sort by current column (toggle asc/desc) |
| `zh` | Toggle cell highlight |
| `zH` | Toggle header float |
| `zN` | Toggle row numbers |
| `R` | Re-run query |
| `<Tab>`/`<S-Tab>` | Next/previous result tab |
| `n`/`N` | Next/previous search match |
| `<leader>/` | Search |
| `<leader>cr` | Clear search/filter |
| `<leader>fc` | Find column |
| `<leader>ce` | Filter by current cell |
| `<leader>hh`/`<leader>ll` | First/last page |
| `<leader>pa` | Toggle pagination |
| `<leader>gp` | Toggle raw mode |

### DB browser

| Key | Action |
|-----|--------|
| `<CR>` | Toggle node expand/collapse |
| `x` | Open context menu (node-specific actions) |
| `r` | Refresh node |
| `/` | Search filter |
| `s` | Generate SELECT * query |
| `d` | Generate DESCRIBE query |
| `q` | Close |
| `ma`/`mr`/`md`/`mt` | Table ops: add/rename/drop/alter column |

</details>

### Commands

| Command | Description |
|---------|-------------|
| `:PosteRun` | Execute request at cursor |
| `:PosteEnv [name]` | Switch or show current environment |
| `:PostePasteCurl` | Paste curl from clipboard |
| `:PosteCopyAsCurl` | Copy request as curl |
| `:PosteCmpStatus` | Show HTTP completion status |
| `:PosteSQLCmpStatus` | Show SQL completion status |

## Configuration

```lua
require("poste").setup({
  -- Binary path (default: stdpath("data")/poste/bin/poste)
  poste_binary = vim.fn.stdpath("data") .. "/poste/bin/poste",

  -- Default environment
  default_env = "dev",

  -- Response window
  split_direction = "vertical",  -- "vertical" | "horizontal"
  split_size = 80,               -- columns (vertical) or rows (horizontal)

  -- Log file (set to "" to disable)
  log_file = vim.fn.stdpath("cache") .. "/poste.log",

  -- Customize keymaps — set to false to disable
  keymaps = {
    source_buffer = {
      run = "<CR>",
      jump_next = "]]",
      jump_prev = "[[",
      goto_definition = "gd",
      goto_references = "grr",
      quickfix_next = "]q",
      quickfix_prev = "[q",
      paste_curl = "<leader>rp",
      copy_as_curl = "<leader>rc",
      show_symbols = "gs",
    },
    http_response = {
      close = "q",
      view_body = "B",
      view_verbose = "I",
      view_assertions = "A",
      view_script_logs = "S",
      next_tab = "<Tab>",
      prev_tab = "<S-Tab>",
    },
    sql_source = {
      run = "<CR>",
      show_ddl = "K",
      clear_filter = "<leader>cr",
      toggle_db_browser = "<leader>db",
      trigger_completion = "<C-Space>",
    },
    sql_dataset = {
      close = "q",
      move_left = "h",  move_down = "j",  move_up = "k",  move_right = "l",
      prev_page = "H",  next_page = "L",
      first_col = "0",  last_col = "$",
      first_row = "gg", last_row = "G",
      preview_cell = "K",
      yank_cell = "yy", yank_column = "yc",
      sort_column = "s",
      toggle_cell_highlight = "zh",
      toggle_header_float = "zH",
      toggle_row_numbers = "zN",
      toggle_raw_mode = "<leader>gp",
      next_tab = "<Tab>", prev_tab = "<S-Tab>",
      rerun = "R",
      goto_first_page = "<leader>hh", goto_last_page = "<leader>ll",
      toggle_pagination = "<leader>pa",
      find_column = "<leader>fc", filter_by_cell = "<leader>ce",
      show_search = "<leader>/", clear_filter_search = "<leader>cr",
      next_search = "n", prev_search = "N",
    },
    sql_table_ops = {
      select_all = "ma",
      refresh_all = "mr",
      describe_all = "md",
      toggle_menu = "mt",
    },
    db_browser = {
      toggle_node = "<CR>",
      context_menu = "x",
      refresh_node = "r",
      search_filter = "/",
      select_query = "s",
      describe_query = "d",
      close = "q",
    },
    introspect_float = {
      close = "q",
      close_alt = "<Esc>",
    },
  },

  -- Override highlight group colors
  highlights = {
    -- Example: change HTTP method colors
    -- PosteMethodGET    = { fg = "#00ff00", bold = true },
    -- PosteMethodPOST   = { fg = "#ffff00", bold = true },
    -- PosteMethodDELETE = { fg = "#ff0000", bold = true },
    --
    -- Example: customize SQL dataset look
    -- PosteSqlHeader    = { fg = "#ff8800", bold = true },
    -- PosteSqlCellSelected = { bg = "#334455", fg = "#ffffff", bold = true },
  },
})
```

Full list of highlight groups you can override: `PosteLatency`, `PosteSpinner`, `PosteSuccess`, `PosteError`, `PosteSeparator`, `PosteRequestName`, `PosteVarRef`, `PosteMagicVar`, `PosteMethodGET`, `PosteMethodPOST`, `PosteMethodPUT`, `PosteMethodDELETE`, `PosteMethodPATCH`, `PosteMethodHEAD`, `PosteMethodOPTIONS`, `PosteMethodOther`, `PosteUrl`, `PosteHttpVersion`, `PosteHeaderKey`, `PosteDirective`, `PostePreScript`, `PosteAssertion`, `PosteScriptMarker`, `PosteExternalScript`, `PosteFileInclude`, `PosteJsonString`, `PosteJsonNumber`, `PosteJsonBoolean`, `PosteJsonNull`, `PosteJsonBraces`, `PosteJsonBrackets`, `PosteJsonColon`, `PosteJsonComma`, `PosteJsonEscape`, `PosteSymbolCurrent`, `PosteSymbolMethod`, `PosteRedisString`, `PosteRedisHash`, `PosteRedisList`, `PosteRedisSet`, `PosteRedisZset`, `PosteRedisStream`, `PosteRedisMeta`, `PosteRedisError`, `PosteRedisOk`, `PosteRedisNil`, `PosteRedisSep`, `PosteRedisIndex`, `PosteRedisField`, `PosteRedisScore`, `PosteSqlHeader`, `PosteSqlNull`, `PosteSqlMeta`, `PosteSqlMetaDim`, `PosteSqlBorder`, `PosteSqlWinbarBorder`, `PosteSqlWinbarSep`, `PosteSqlSep`, `PosteSqlCellText`, `PosteSqlCellSelected`, `PosteSqlNumber`, `PosteSqlBool`, `PosteSqlSortIndicator`, `PosteSqlRowNum`, `PosteSqlModified`, `PosteSqlDeleted`, `PosteSqlAdded`, `PosteSqlBoundary`, `PosteSearchMatch`, `PosteSearchCurrent`, `PosteFilterActive`, `PosteSearchActive`, `PosteInsertHint`, `PosteSqlBrowserHeader`, `PosteSqlBrowserSeparator`, `PosteSqlBrowserMarker`, `PosteSqlBrowserTable`, `PosteSqlBrowserType`, `PosteSqlBrowserCount`, `PosteSqlBrowserIconConn`, `PosteSqlBrowserIconDb`, `PosteSqlBrowserIconSchema`, `PosteSqlBrowserIconTable`, `PosteSqlBrowserIconCol`, `PosteSqlBrowserIconPk`, `PosteSqlBrowserIconFk`.

## Completion

Poste provides context-aware completions.

### HTTP (`.http`/`.rest`)

- **HTTP methods** — `GET`, `POST`, `PUT`, `DELETE`, etc.
- **Header names** — `Content-Type`, `Authorization`, `Accept-Encoding`, etc.
- **Header values** — `application/json`, `Bearer `, `gzip`, etc.
- **Variables / env vars** — `{{...}}` references from env.json

Works with both **nvim-cmp** and **blink.cmp**. Registration is automatic.

### SQL (`.sql`/`.sqlite`)

- **SQL keywords** — `SELECT`, `FROM`, `WHERE`, `JOIN`, etc.
- **Tables, columns, schemas** — introspected from your database
- **Functions** — aggregate and scalar functions per dialect
- **Connection-aware** — completions reflect the actual schema

Requires **blink.cmp**. Auto-registers as `poste_sql` source provider.

```vim
:PosteCmpStatus     " HTTP completion status
:PosteSQLCmpStatus  " SQL completion status
```

## SQL Features

### Connection management

Connections are defined in `connections.json` (walked up from the SQL file). Reference them in your `.sql` files:

```sql
-- @connection pg-dev
-- @connection my-blog
```

The `USE database;` statement switches the active database for parsing/completion context.

### Dataset buffer

Query results render in a rich dataset buffer with:
- **Cell navigation** — hjkl to move between cells
- **Sorting** — press `s` on any column
- **Search & filter** — `<leader>/` for search, `<leader>ce` to filter by cell value
- **Pagination** — configurable page size, `<leader>pa` to toggle
- **Multi-result tabs** — each statement gets its own tab, `<Tab>`/`<S-Tab>` to switch
- **Raw mode** — `<leader>gp` to toggle compact view

### DB Browser

Press `<leader>db` in a SQL file to open the database tree browser. Navigate schemas, tables, and columns. Press `s` to generate a `SELECT *` query or `d` for `DESCRIBE`.

### SQL Integration Tests

```bash
# Start test databases (PG 16 on 15432, MySQL 8.0 on 13306)
cd tests/sql && docker compose up -d

# Run queries
cargo run -- run tests/sql/queries/postgres.sql --line 4 --env dev

# Run Lua tests
tests/run.sh
```

## CLI

```bash
# Execute a specific request by line number
poste run requests/api.http --line 4 --env dev

# Introspect database schema
poste introspect --connection pg-dev --env dev

# List available connections
poste connection list --env dev
```

## Architecture

```
poste/
├── crates/
│   ├── poste-core/    # Request parsing, SQL parsing, env management (no I/O)
│   ├── poste-exec/    # Protocol execution, SQL connection/dialect, response
│   └── poste-cli/     # CLI binary (poste run / connection / introspect)
├── lua/
│   └── poste/         # Neovim plugin (init, http, sql, state, db_browser)
└── tests/
    ├── run.sh         # Lua tests
    └── sql/           # Docker Compose + SQL integration tests
```

## License

MIT
