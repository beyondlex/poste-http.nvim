---
name: sql
description: >
  SQL execution, dataset buffer, DB browser, completion, export/import,
  connection management, and schema introspection in Poste.
  Use when working on SQL features (not HTTP/Redis). Loads ZERO HTTP files.
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
metadata:
  trigger: sql|postgres|mysql|sqlite|dataset|db_browser|export|import|introspect|connection|table_ops|editor|pagination|completion|context
---

# SQL — Agent Skill

Only load files listed below. Do NOT read `lua/poste/http/`, `crates/poste-exec/src/executor.rs`
(curl), `crates/poste-core/src/parser.rs`, or any HTTP-specific files unless the task
explicitly crosses protocols.

For SQL completion specific work, also load `.opencode/skills/sql-completion/SKILL.md`.

## File Index

### Shared (load always)

| File | Why |
|------|-----|
| `AGENTS.md` | Architecture, conventions, build |
| `lua/poste/state.lua` | Shared state object (`.sql` namespace for SQL-specific state) |
| `lua/poste/init.lua` | Entry point: dispatches SQL filetypes to `sql.init.run_sql_request()` |
| `lua/poste/buffer_setup.lua` | Shared keymap registration for source buffers |
| `lua/poste/indicators.lua` | Spinner/✓/✘ indicators |
| `lua/poste/select.lua` | Picker UI (telescope/fzf/mini.pick fallback) |
| `lua/poste/util.lua` | `clean_nil`, `find_file_upwards`, `ensure_job_data` |
| `lua/poste/help.lua` | Keymap help (SQL section) |

### SQL Lua (`lua/poste/sql/`)

#### Execution & Connection

| File | Role |
|------|------|
| `init.lua` | Entry: `run_sql_request()`, `setup()`, `ensure_sql_keymaps()` |
| `context.lua` | Execution context: `-- @connection` resolution, `USE db;` handling |
| `context_client.lua` | Context client for async introspection queries |
| `connections.lua` | Connection management UI: list, test, switch |
| `statement.lua` | Statement extraction: `extract_stmt_at_cursor()`, `extract_visual_block()` |
| `statement_indicator.lua` | Statement highlight on cursor line |

#### Dataset Buffer (results)

| File | Role |
|------|------|
| `buffer.lua` | Main dataset panel: render, tabs, pagination, filter |
| `buffer_nav.lua` | Cell navigation, raw mode |
| `buffer_page.lua` | Page-level buffer management |
| `buffer_search.lua` | Search within results |
| `format.lua` | Result formatting: table layout, error rendering, row display |
| `highlights.lua` | Extmark highlights for dataset cells |
| `syntax.lua` | SQL syntax highlighting for source buffers |
| `dataset.lua` | Dataset data model |
| `pagination.lua` | Pagination state management |

#### Data Manipulation

| File | Role |
|------|------|
| `editor.lua` | Inline cell editing (commit changes back to database) |
| `edit_commit.lua` | Edit commit logging and execution |
| `table_ops.lua` | Table operations UI (insert row, duplicate, delete) |
| `insert_hint.lua` | INSERT INTO value-to-column hint |

#### DB Browser

| File | Role |
|------|------|
| `db_browser/init.lua` | DB browser entry: toggle, tree rendering |
| `db_browser/tree.lua` | Tree rendering (schema → table → columns) |
| `db_browser/actions.lua` | Click actions (select, show DDL, etc.) |
| `db_browser/completion.lua` | Completion integration in browser |
| `db_browser/context_menu.lua` | Right-click context menu |
| `db_browser/forms.lua` | Form rendering for edits |
| `db_browser/icons.lua` | Tree node icons |
| `db_browser/operations.lua` | DB operations from browser |
| `db_browser/async.lua` | Async tree loading |

#### Export/Import

| File | Role |
|------|------|
| `export.lua` | Export dataset: CSV, JSON, SQL |
| `import.lua` | Import entry: CSV/JSON → SQL |
| `import/format.lua` | Import format detection and parsing |
| `import/mapping.lua` | Column mapping UI |
| `import/execute.lua` | Import execution |
| `import/preview.lua` | Import preview window |

#### Completion

| File | Role |
|------|------|
| `completion.lua` | Completion orchestrator (blink.cmp source) |
| `completion_ctx.lua` | Legacy Lua regex fallback (deprecated) |
| `completion_data.lua` | Async introspection, cache, fallback lists |
| `completion_debug.lua` | Debug floating window for completion |

#### Other

| File | Role |
|------|------|
| `source_format.lua` | SQL source formatting (sqlfluff/sqlfmt/pg_format) |
| `introspect.lua` | `show_table_ddl()`, schema introspection |
| `log_viewer.lua` | SQL execution log viewer |
| `prototype.lua` | Prototype/experimental code |

### SQL Rust

| File | Role |
|------|------|
| `crates/poste-exec/src/sql_executor.rs` | SQL execution: dispatch to PG/MySQL/SQLite |
| `crates/poste-exec/src/sql_connection.rs` | Connection pool management, connections.json |
| `crates/poste-exec/src/sql_dialect.rs` | Dialect trait + PG/MySQL/SQLite implementations |
| `crates/poste-exec/src/sql_introspect.rs` | Schema/table/column introspection queries |
| `crates/poste-exec/src/sql_ddl.rs` | DDL statement generation |
| `crates/poste-core/src/sql_parser.rs` | `@connection` extraction, statement splitting |
| `crates/poste-core/src/sql_context/` | Completion context detection (tokenizer, tables, functions) |
| `crates/poste-cli/src/main.rs` | CLI subcommands: `run`, `conn`, `introspect`, `context` |

## Do NOT Read (SQL tasks)

These files are HTTP-only. Skip them entirely:

- `lua/poste/http/` (any file)
- `crates/poste-exec/src/executor.rs` (curl executor — but executor.rs dispatch is OK)
- `crates/poste-core/src/parser.rs`
- `crates/poste-exec/src/cookie_jar.rs`
- `syntax/poste_http.vim`

## SQL-Specific Conventions

### Request Flow

```
source buffer → sql/init.lua → extract statement at cursor
  → resolve context (connection + database)
  → pipe to `poste run --stdin` → Rust sql_parser → sql_executor
  → JSON response → sql/format.lua → sql/buffer.lua (dataset)
```

### State Namespace

SQL state is namespaced under `state.sql` in `state.lua`:

| Field | Role |
|-------|------|
| `state.sql.context` | Current connection + database |
| `state.sql.last_dataset` | Last rendered dataset |
| `state.sql.pagination` | Pagination state (page, offset, limit) |
| `state.sql.cell` | Current cell position (row, col) |
| `state.sql.connection_info` | Connection metadata (dialect, version) |

### Connection Resolution

```
1. `-- @connection name` in the request block (highest priority)
2. `-- @connection name` between blocks (file header)
3. `connections.json` lookup with `-- @connection name`
4. Database override: `-- @database name` or `USE db;`
```

### Dialects

- PG: `Protocol::Postgres` → sqlx postgres
- MySQL: `Protocol::Mysql` → sqlx mysql
- SQLite: `Protocol::Sqlite` → sqlx sqlite

Each dialect has its own introspect queries, DDL syntax, and type mapping.

## Testing

```bash
tests/run.sh                  # Lua tests
cargo test -p poste-core      # SQL context/parser tests
cargo test -p poste-exec      # SQL executor/connection tests

# SQL integration tests (Docker)
cd tests/sql
docker compose down -v && docker compose up -d
cargo run -- run tests/sql/queries/postgres.sql --line 4 --env dev
```

## Quick Reference

| Task | Entry file | Key functions |
|------|-----------|---------------|
| New SQL execution feature | `sql_executor.rs` + `sql/init.lua` | `execute_sql()`, `run_sql_request()` |
| New dataset UI feature | `sql/buffer.lua` + `sql/format.lua` | `render_dataset()`, `format_resultset()` |
| Connection management | `connections.lua` + `sql_connection.rs` | `show_menu()`, `resolve()` |
| Inline cell editing | `editor.lua` + `edit_commit.lua` | Edit, validate, commit |
| DB browser | `db_browser/init.lua` | `toggle()` |
| Export/Import | `export.lua` + `import.lua` | `run()`, format-specific |
| Completion | `completion.lua` + sql-completion skill | See `.opencode/skills/sql-completion/` |
| Source formatting | `source_format.lua` | `format_buffer()`, `format()` |