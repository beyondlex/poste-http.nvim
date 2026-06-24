# Data Import: CSV / TSV / JSON → SQL INSERT

Import external data (CSV, TSV, JSON) into a database table from the DB Browser
context menu.

## Entry Point

DB Browser, table node context menu (press `x` on a `BASE TABLE` node):

```
[I] Import Data
```

Only shown for `table_type == "BASE TABLE"` — not for views.

## Target Resolution

The context menu handler receives the table node, which carries all the info
needed to target the INSERTs:

```
table_name = node.name
schema     = node.meta.schema        -- "public" / nil
database   = node.meta.database      -- "mydb" / nil
conn       = get_connection_name()   -- "pg-dev"
dialect    = get_dialect()           -- "postgres" / "mysql" / "sqlite"
dir        = get_search_dir()        -- for connections.json discovery
```

## Column Metadata

Column info is fetched asynchronously via `poste introspect --type columns`
if the table isn't already expanded in the tree. No manual expand required.

Per-column info collected:

```
{ name, type, is_pk, nullable, default, extra }
```

## Primary Key Handling

| Scenario | Behaviour |
|----------|-----------|
| PK column **not present** in import data | Omitted from INSERT → DB auto-generates |
| PK column **present, non-null** | Included in INSERT |
| PK column **present, null** | Rejected (bad row) |

## Supported File Formats

| Format | Extension | Detection |
|--------|-----------|-----------|
| CSV | `.csv` | Extension / content heuristic |
| TSV | `.tsv` | Extension / content heuristic |
| JSON | `.json` | Extension / `vim.json.decode` |

JSON must be an array of objects (`[{col: val, ...}]`) — each object is one row.

## File Selection

Uses the existing [`beyondlex/finder`](https://github.com/beyondlex/finder)
plugin (same as export):

```lua
finder.open({
  mode = "file",
  initial_path = "~",
  extensions = { "csv", "tsv", "json" },
  on_confirm = function(path) ... end,
  on_cancel = function() ... end,
})
```

## Clipboard Import

In the source-picker step, user chooses **File** or **Clipboard**:

- Clipboard: `vim.fn.getreg("+")` — the system clipboard
- Format auto-detected from content (JSON → CSV → TSV heuristic)

## Format Auto-Detection

1. If a file has an extension → use that
2. Clipboard or unknown extension → try `vim.json.decode` first
3. If JSON fails → count delimiters on first line (`\t` vs `,`)

## Column Mapping

- CSV/TSV with header row → matched by name (case-insensitive) against table columns
- JSON object keys → matched by name
- CSV without header → positional mapping (first column → first table column, with a warning)
- Unmatched columns → skipped (with notification)
- Missing table columns → left as `nil` (DB uses DEFAULT)

## Validation (per cell)

Reuses `editor.lua:validate_value()` — type-aware checking against column
metadata:

- `integer` / `numeric` / `boolean` / `date` / `UUID` / `json`

## Import Flow

```
DB Browser → x → context menu → I
  │
  ├─ Fetch column metadata (async, if table not expanded)
  │
  ├─ Source: [F]ile / [C]lipboard
  │   ├─ File → finder.open()
  │   └─ Clipboard → vim.fn.getreg("+")
  │
  ├─ Detect format → parse → column mapping → validate
  │
  ├─ Preview:
  │   ├─ Total rows / bad rows / column mapping
  │   ├─ First 10 rows shown
  │   └─ Options: [P]roceed / [A]bort / [S]kip bad rows
  │
  ├─ Execute:
  │   ├─ Split into chunks (configurable, default 100 rows)
  │   ├─ Each chunk → generate INSERT(s) → execute via `poste run --stdin`
  │   └─ Parse each response, collect per-statement errors
  │
  └─ Done:
      ├─ Notify: "Imported N rows (S skipped, E errors)"
      ├─ Refresh any open dataset tab for this table
      └─ Refresh the DB Browser table node
```

## Execution Strategy

Each valid row becomes a single `INSERT INTO t (cols) VALUES (vals);`.

Rows are grouped into chunks. Each chunk is sent as a batch via the existing
`--stdin` pipeline:

```
poste run --stdin --line 2 --json <src_file>
```

The SQL content includes the `-- @connection <name>` directive, then each
INSERT statement separated by `;`.

The CLI response is parsed per-chunk. If one statement in a chunk fails,
the remaining statements in that chunk still execute (the executor already
handles per-statement error reporting).

### Why not multi-row INSERT / COPY?

- Multi-row `INSERT INTO t (cols) VALUES (r1), (r2), ...` is more efficient
  but introduces ambiguity when a single row fails (partial insert).
- `COPY FROM stdin` (PostgreSQL) is fastest but PostgreSQL-only, and adds
  complexity to the executor.
- Single-row INSERTs are simple, correct, and easy to report errors on.
  This can be optimized later.

## Configuration

In `state.lua`, add to config defaults:

```lua
import_chunk_size = 100   -- rows per chunk sent to --stdin
```

No other import-specific config keys.

## Error Handling

| Scenario | Behaviour |
|----------|-----------|
| File not found / unreadable | Notify error, stop |
| Malformed CSV (column count mismatch) | Notify with line number, stop |
| Invalid JSON structure | Notify error, stop |
| No columns matched | Notify, stop |
| All rows fail validation | Notify, no INSERTs sent |
| Some rows fail validation | Preview shows count; user chooses Skip or Abort |
| DB connection error | Notify the error from CLI response |
| Unique key / FK violation | Collected per-statement; reported in summary |
| Huge file (100 MB+) | Not recommended — no streaming support |

## SQL File Import (Future)

Importing a `.sql` file containing raw INSERT statements is **not** part of
this feature. It belongs in a separate "Execute SQL File" context menu item:

```
[X] Execute SQL File...
```

Implementation sketch: beyondlex/finder picks a `.sql` file → read content →
prepend `-- @connection <conn>` → `--stdin` execution → results displayed
in a result buffer. Straightforward, but a different workflow from data import.

## Files to Change

| File | Change |
|------|--------|
| `lua/poste/sql/db_browser/context_menu.lua` | Add `Import Data` to table menu |
| `lua/poste/sql/db_browser/operations.lua` | Add `import_data()` handler |
| `lua/poste/sql/import.lua` | **New** — core logic |
| `lua/poste/state.lua` | Add `import_chunk_size = 100` to config defaults |

## Module Structure (`import.lua`)

```
M.run(table_node, context)
  ├─ pick_source()              — File / Clipboard
  ├─ read_source()              — read file or clipboard text
  ├─ detect_format()            — extension or content heuristic
  ├─ parse_csv/tsv/json()       — raw string → rows[]
  ├─ build_column_map()         — match import columns → table columns
  ├─ validate_and_type()        — type-check each cell
  ├─ show_preview()             — mapping + first rows + proceed/abort/skip
  ├─ execute_import()           — chunked INSERTs via --stdin
  └─ report_and_refresh()       — notify count, refresh dataset + browser
```
