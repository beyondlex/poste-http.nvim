# DB Browser Context Menu

Unified context menu for all DB Browser node types. Single trigger key (`x`) opens a
Vim-native floating menu with node-type-specific operations. DataGrip-inspired, Vim-ergonomics-first.

## Core UX

```
One key to rule them all: x

  connection  ──x──→  [r]efresh  [e]dit conn  [c]opy name  [d]isconnect
  database    ──x──→  [q]uery new  [t]able new  [v]iew new  [r]efresh  [c]opy
  schema      ──x──→  [s]et default  [t]able new  [v]iew new  [r]efresh  [c]opy
  table       ──x──→  [s]elect *  [e]dit data  [i]nsert tpl  [u]pdate tpl  [d]elete tpl  [D]DL  [n]ew col  [r]ename  [t]runcate  [x]drop  [c]opy
  view        ──x──→  [s]elect *  [D]DL  [x]drop  [c]opy
  column      ──x──→  [m]odify  [r]ename  [x]drop  [y]ank name
  index       ──x──→  [D]DL  [x]drop  [r]ebuild
  pk / fk     ──x──→  [D]DL  [x]drop  (fk also: [g]oto ref table)
```

Rules:
- Each menu item has a single-letter shortcut (case-insensitive, one-hand friendly).
- `j`/`k` navigate, `<CR>` activates highlighted item, `q`/`<Esc>` close.
- Destructive operations (drop/truncate) use red highlight + confirmation dialog.
- SQL-generating operations insert directly into the source buffer at cursor position.
- `y` = yank/copy (Vim intuition), copies the node name to `"+` register.

## Trigger Key

| Key | Action |
|-----|--------|
| `x` | Open context menu on current node |

Existing `s` (SELECT), `d` (DESCRIBE) keys are superseded by the menu but retained
for backward compatibility. Users can disable them via `keymaps.sql_db_browser` config.

## Context Menu UI

Floating buffer, anchored near cursor. Each line is `"  [x] Action Name"`. Current
line highlighted via extmark.

```
┌─ Table: users ────────────────────────┐
│                                        │
│  Query                                │
│  [s] SELECT * LIMIT 100               │
│  [e] Edit Data (LIMIT 200)            │
│                                        │
│  Generate                             │
│  [i] INSERT template                  │
│  [u] UPDATE template                  │
│  [d] DELETE template                  │
│  [D] Show DDL                         │
│                                        │
│  Modify                               │
│  [n] New Column                       │
│  [r] Rename Table                     │
│                                        │
│  Danger                               │
│  [t] Truncate Table                   │
│  [x] Drop Table                       │
│                                        │
└────────────────────────────────────────┘
```

Interaction:
- `j` / `k` — move highlight up/down
- Letter key — directly trigger that action
- `<CR>` — activate highlighted item
- `q` / `<Esc>` — close menu
- Typing filters items (optional future enhancement)

Menu groups (separated by blank lines):
- **Query** — read-only data access
- **Generate** — SQL template generation
- **Modify** — DDL changes
- **Danger** — destructive operations (group name in red)

## Form UI

For operations requiring structured input (Modify Column, New Table), a form float
is shown.

```
┌─ Modify Column: users.email ──────────┐
│                                        │
│  Type:     varchar(255)               │
│  Nullable: ✓                          │
│  Default:  NULL                       │
│                                        │
│  [<CR> Submit]  [q Cancel]            │
└────────────────────────────────────────┘
```

Interaction:
- `j` / `k` — move between fields (current field row highlighted)
- `<CR>` on field — open `vim.ui.input` to edit field value
- `<Space>` on boolean — toggle `✓` / `✗`
- `<CR>` on Submit row — generate SQL and insert into source buffer
- `q` / `<Esc>` — cancel, close form

Form definitions are data-driven:

```lua
fields = {
  { label = "Type",     key = "col_type", value = "varchar(255)", kind = "text" },
  { label = "Nullable", key = "nullable", value = true,           kind = "bool" },
  { label = "Default",  key = "default",  value = "NULL",         kind = "text" },
}
```

## Operations Catalog

### Connection

| Key | Action | Description |
|-----|--------|-------------|
| `r` | Refresh All | Reload all nodes under this connection |
| `e` | Edit Connection | Open `connections.json` at this connection entry |
| `c` | Copy Name | Yank connection name to `"+` register |
| `d` | Disconnect | Mark disconnected (placeholder — no state management yet) |

### Database

| Key | Action | Description |
|-----|--------|-------------|
| `q` | New Query | Insert `-- @connection X` + empty SQL block into source buffer |
| `t` | New Table | Open New Table form |
| `v` | New View | Open New View form (PG only) |
| `r` | Refresh | Reload schemas / tables under this database |
| `c` | Copy Name | Yank database name |
| `s` | Set as Default | Insert `USE db;` into source buffer |

### Schema

| Key | Action | Description |
|-----|--------|-------------|
| `s` | Set as Default | Set default schema (affects unqualified table references) |
| `t` | New Table | Open New Table form (schema pre-filled) |
| `v` | New View | Open New View form |
| `r` | Refresh | Reload tables under this schema |
| `c` | Copy Name | Yank schema name |

### Table

| Key | Action | Description |
|-----|--------|-------------|
| `s` | SELECT * LIMIT 100 | Insert full SELECT into source buffer |
| `e` | Edit Data (LIMIT 200) | Same, larger limit |
| `i` | INSERT template | Generate INSERT based on column info |
| `u` | UPDATE template | Generate `UPDATE ... SET ... WHERE` template |
| `d` | DELETE template | Generate `DELETE FROM ... WHERE` template |
| `D` | Show DDL | Float window with CREATE TABLE DDL |
| `n` | New Column | Open New Column form |
| `r` | Rename Table | `vim.ui.input` new table name → ALTER TABLE RENAME |
| `c` | Copy Name | Yank table name |
| `t` | Truncate Table | TRUNCATE with confirmation (red) |
| `x` | Drop Table | DROP with confirmation (red) |

### View

| Key | Action | Description |
|-----|--------|-------------|
| `s` | SELECT * | Insert SELECT into source buffer |
| `D` | Show DDL | Float window with view definition |
| `r` | Refresh | Reload columns under this view |
| `c` | Copy Name | Yank view name |
| `x` | Drop View | DROP with confirmation (red) |

### Column

| Key | Action | Description |
|-----|--------|-------------|
| `m` | Modify Column | Open Modify Column form (type / nullable / default / PK) |
| `r` | Rename Column | `vim.ui.input` new column name → ALTER TABLE RENAME COLUMN |
| `x` | Drop Column | ALTER TABLE DROP COLUMN with confirmation (red) |
| `y` | Yank Name | Copy column name to `"+` register (Vim `y` intuition) |
| `s` | Add to SELECT | Insert `table.column` at cursor in source buffer |

### Primary Key

| Key | Action | Description |
|-----|--------|-------------|
| `D` | Show DDL | Float window with PK constraint definition |
| `x` | Drop PK | ALTER TABLE DROP CONSTRAINT with confirmation (red) |

### Foreign Key

| Key | Action | Description |
|-----|--------|-------------|
| `D` | Show DDL | Float window with FK constraint definition |
| `g` | Go to Ref Table | Navigate browser to referenced table (expand + highlight) |
| `x` | Drop FK | ALTER TABLE DROP CONSTRAINT with confirmation (red) |

### Index

| Key | Action | Description |
|-----|--------|-------------|
| `D` | Show DDL | Float window with index definition |
| `x` | Drop Index | DROP INDEX with confirmation (red) |
| `r` | Rebuild Index | REINDEX (PG only) |

## Letter Key Semantics

Unified letter semantics across node types:

| Key | Semantic | Appears on |
|-----|----------|------------|
| `s` | SELECT / Set default | table, view, column, database, schema |
| `e` | Edit / Edit Data | connection, table |
| `i` | INSERT template | table |
| `u` | UPDATE template | table |
| `d` | DELETE template | table |
| `D` | Show DDL | table, view, pk, fk, index |
| `n` | New... | table, database, schema |
| `r` | Rename / Refresh | most nodes |
| `t` | Truncate / New Table | table, database, schema |
| `v` | New View | database, schema |
| `c` | Copy Name | all nodes |
| `y` | Yank Name | column (Vim: copy = `y`) |
| `x` | Drop / Delete | table, view, column, index, pk, fk |
| `m` | Modify | column |
| `g` | Go to reference | fk |
| `q` | (reserved for close) | — |

## Confirm Dialog

Destructive operations require explicit confirmation. Lightweight: `vim.ui.input`.

```
Prompt: "Type 'users' to confirm drop: "
```

For more dangerous operations (truncate, drop table), a float dialog may be used:

```
┌─ ⚠ Drop Table: users ────────────────┐
│                                        │
│  This will permanently delete the     │
│  table and all its data.              │
│                                        │
│  Type "users" to confirm:             │
│  █                                     │
│                                        │
│  [<CR> Confirm]  [q Cancel]           │
└────────────────────────────────────────┘
```

## SQL Generation Convention

All SQL-generating operations follow a consistent pattern:
1. Generate comment header `-- @connection X` + `-- @database Y`
2. Insert into source buffer (append at end; future: cursor position)
3. Cursor jumps to the new block's `###` line

## Implementation Plan

```
New files:
  lua/poste/sql/db_browser/context_menu.lua   ← menu UI + action dispatch
  lua/poste/sql/db_browser/forms.lua          ← form UI (Modify Column, New Table, ...)
  lua/poste/sql/db_browser/operations.lua     ← per-operation implementations

Modified files:
  lua/poste/sql/db_browser/init.lua           ← register x key, optionally deprecate s/d
  lua/poste/sql/db_browser/actions.lua        ← migrate logic to operations.lua
  lua/poste/state.lua                         ← new keymap: db_browser.context_menu = "x"
```

### Phase A: Menu framework + non-destructive ops
- `context_menu.lua` — floating menu renderer, keyboard dispatch, action routing
- `operations.lua` — SELECT *, Show DDL, Copy Name, Rename, Refresh
- Wire `x` key in `init.lua`

### Phase B: Forms
- `forms.lua` — data-driven form UI
- New Table, New Column, Modify Column forms
- INSERT / UPDATE / DELETE template generation

### Phase C: Destructive ops
- Drop Table / View / Column / Index / PK / FK
- Truncate Table
- Confirm dialog

### Phase D: Advanced
- FK "Go to Referenced Table" navigation
- REINDEX (PG)
- New View form (PG)
- Edit Connection (jump to connections.json)
- Filter-as-you-type in menu

## Configuration

```lua
require("poste").setup({
  keymaps = {
    sql_db_browser = {
      toggle_node = "<CR>",
      refresh_node = "r",          -- can set to false to use context menu only
      context_menu = "x",          -- new
      -- Legacy keys (retain for backward compat, or set to false)
      search_filter = "/",
      select_query = "s",          -- false → force context menu
      describe_query = "d",        -- false → force context menu
      close = "q",
    },
    sql_table_ops = {
      select_all = "ma",
      refresh_all = "mr",
      describe_all = "md",
      toggle_menu = "mt",
    },
  },
})
```

## Trade-offs

- **Letter key assignment**: high-frequency actions on home row (`s`elect, `r`ename/refresh, `c`opy, `D`DL, `x`drop); lower-frequency pushed out.
- **Form complexity**: structured field list + sequential `vim.ui.input` per field, not a full form builder. Keeps the Vim typing flow.
- **Destructive safety**: all drop/truncate ops require explicit confirmation (type table name). Prevents one-hand `x` accidents.
- **Backward compatibility**: existing `s`/`d`/`r` keys retained; users migrate via config gradually.
