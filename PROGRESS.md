# SQL Dev Progress

> Design, isolation strategy, JSON format → `docs/sql-design.md`
> Dataset UI design → `docs/dataset-ui-design.md`

---

## Overview

| Phase | Description | Steps | Status |
|-------|-------------|-------|--------|
| 1A | Rust infra | 1-5 | ✅ |
| 1B | Lua dataset panel | 6-12 | ✅ |
| 1C | MySQL/SQLite exec | 13-14 | ✅ |
| 2 | Connection & context mgmt | 15-19 | ✅ |
| 3 | DB structure browser | 20-23 | ✅ |
| 4 | Table ops + DDL + completion | 24-27 | ✅ |
| 5 | Import/export + pagination | 28-31 | ⏳ |
| 6 | Advanced features | 32-38 | ⏳ |

**Tests: 90 passed** · 27/38 steps done

---

## Phase 1A — Rust Infra

[x] **Step 1: Add sqlx deps**
- Files: `Cargo.toml` (workspace), `crates/poste-exec/Cargo.toml`
- Verify: `cargo check -p poste-exec`

[x] **Step 2: Add Sqlite variant to Protocol enum**
- Files: `crates/poste-core/src/request.rs`, `parser.rs`
- Verify: `cargo test -p poste-core`

[x] **Step 3: Create sql_dialect.rs — Dialect trait**
- Deps: Step 2
- New: `crates/poste-exec/src/sql_dialect.rs`
- Verify: unit tests per dialect return correct SQL

[x] **Step 4: Create sql_parser.rs — SQL parser**
- Deps: Step 2
- New: `crates/poste-core/src/sql_parser.rs`
- Verify: unit tests for @connection/@database extraction, statement splitting

[x] **Step 5: Create sql_executor.rs — PostgreSQL executor**
- Deps: Step 1, 3, 4
- New: `crates/poste-exec/src/sql_executor.rs`
- Mod: `executor.rs` — delegate SQL protocol to sql_executor
- Verify: `cargo build` + CLI SELECT returns JSON

---

## Phase 1B — Lua Dataset Panel

[x] **Step 6: state.sql namespace**
- Mod: `lua/poste/state.lua` — add `M.sql = { context, last_dataset, pagination, cell }`

[x] **Step 7: SQL filetype detection**
- Mod: `ftdetect/poste.vim`, `after/ftdetect/poste.vim` — *.sql/*.sqlite

[x] **Step 8: SQL syntax highlighting**
- Deps: Step 7
- New: `syntax/poste_sql.vim`, `syntax/poste_dataset.vim`
- New: `ftplugin/poste_sql.vim`

[x] **Step 9: sql/format.lua — table renderer**
- Deps: Step 6
- New: `lua/poste/sql/format.lua`
- Features: unicode tables, auto column width, CJK width, NULL display

[x] **Step 10: sql/highlights.lua — extmark highlights**
- Deps: Step 9
- New: `lua/poste/sql/highlights.lua`
- Groups: Header/Null/CellSelected/Meta/Modified/Deleted/Added

[x] **Step 11: sql/buffer.lua — bottom hsplit + cell nav**
- Deps: Step 9, 10
- New: `lua/poste/sql/buffer.lua`
- Keys: h/l left/right, j/k up/down, 0/$ first/last col, H header, K preview, yy copy, q close

[x] **Step 12: sql/context.lua + sql/init.lua — exec entry**
- Deps: Step 5, 6, 7, 11
- New: `lua/poste/sql/context.lua`, `lua/poste/sql/init.lua`
- Mod: `lua/poste/init.lua` — filetype dispatch

**★ Phase 1 milestone:** ✅ SELECT/INSERT/UPDATE/DELETE/error/USE render correctly; HTTP unaffected

---

## Phase 1C — Additional Executors

[x] **Step 13: MySQL executor**
- Deps: Step 5
- Mod: `sql_executor.rs` — execute_mysql() + mysql_value_to_json()

[x] **Step 14: SQLite executor**
- Deps: Step 5
- Mod: `sql_executor.rs` — execute_sqlite() + normalize_sqlite_connection()

---

## Phase 2 — Connection & Context Mgmt

[x] **Step 15: sql_connection.rs — connections.json mgmt**
- Deps: Step 5
- New: `crates/poste-exec/src/sql_connection.rs`
- Features: ConnectionConfig, ConnectionStore::load/resolve, test_connection()

[x] **Step 16: CLI connection subcommand**
- Deps: Step 15
- Mod: `main.rs` — `poste connection list/test`

[x] **Step 17: @connection name resolution**
- Deps: Step 15
- Mod: `main.rs` — name→connections.json→URL, auto protocol detection

[x] **Step 18: sql/connections.lua — connection mgmt UI**
- Deps: Step 16, 17
- New: `lua/poste/sql/connections.lua`
- Cmd: `:PosteConnection` — select/test connection

[x] **Step 19: Context switch command**
- Deps: Step 18
- Mod: `lua/poste/init.lua` — `:PosteSQLContext` cmd + statusline integration

**★ Phase 2 milestone:** ✅ connections.json mgmt, @connection resolution, USE context update, statusline display

---

## Phase 3 — DB Structure Browser

[x] **Step 20: sql_introspect.rs — introspection queries**
- Deps: Step 3, 5
- New: `crates/poste-exec/src/sql_introspect.rs`
- Features: list_databases/schemas/tables/columns/indexes

[x] **Step 21: CLI introspect subcommand**
- Deps: Step 20
- Mod: `main.rs` — `poste introspect <conn> --type tables --json`

[x] **Step 22: sql/db_browser.lua — tree browser**
- Deps: Step 21
- New: `lua/poste/sql/db_browser.lua`
- Cmd: `:PosteDBBrowser` — sidebar 40 col, lazy load, cache, r refresh
- Keys: CR expand/collapse, / search, s gen SELECT, d gen DESCRIBE, q close

[x] **Step 23: Quick query generation**
- Deps: Step 22
- Features: press `s` in browser → insert query into current SQL file

**★ Phase 3 milestone:** ✅ DB Browser tree → gen query → exec → Dataset display

---

## Phase 4 — Table Ops + DDL + Completion

[x] **Step 24: sql_ddl.rs — DDL generator**
- Deps: Step 3
- New: `crates/poste-exec/src/sql_ddl.rs`
- Features: DdlGenerator trait + 3 dialect impls

[x] **Step 25: sql/table_ops.lua — table edit UI**
- Deps: Step 22, 24
- New: `lua/poste/sql/table_ops.lua`
- Keys: ma(add col)/mr(rename)/md(drop)/mt(change type) → gen DDL

[x] **Step 26: sql/completion.lua — SQL completion**
- Deps: Step 7, 20
- New: `lua/poste/sql/completion.lua`
- Completions: SQL keywords, connection names, tables, columns, data types

[x] **Step 27: Phase 4 integration tests**
- Deps: Step 24, 25, 26

---

## Phase 5 — Import/Export + Pagination

[ ] **Step 28: sql/export.lua — export**
- Deps: Step 12
- New: `lua/poste/sql/export.lua`
- Keys: ec(CSV)/ej(JSON)/es(SQL INSERT)

[ ] **Step 29: sql/import.lua — import**
- Deps: Step 12, 19
- New: `lua/poste/sql/import.lua`
- Cmd: `:PosteImport <file>`

[ ] **Step 30: sql/pagination.lua — result pagination**
- Deps: Step 11
- New: `lua/poste/sql/pagination.lua`
- Keys: n/p/f/l/g — LIMIT/OFFSET page

[ ] **Step 31: Phase 5 integration tests**

---

## Phase 6 — Advanced Features

[ ] **Step 32: sql/editor.lua — dataset editing**
- Deps: Step 11
- New: `lua/poste/sql/editor.lua`
- Keys: i/a/cc edit, dd delete row, o/O insert row, u undo

[ ] **Step 33: Edit commit — diff + DML gen**
- Deps: Step 32
- Cmd: `:W` submit → gen UPDATE/INSERT/DELETE → execute

[ ] **Step 34: Header sort & filter**
- Deps: Step 11, 30
- Header row: s sort(ASC/DESC/Clear), f filter

[ ] **Step 35: Column copy + FK jump**
- Deps: Step 11, 20
- Keys: yy copy cell, leader+yc copy column, gd FK jump

[ ] **Step 36: Multi-result tabs**
- Deps: Step 11
- Winbar [1] [2] tabs, number keys switch

[ ] **Step 37: Transaction support**
- Deps: Step 5
- Mod: `sql_executor.rs` — BEGIN...COMMIT wrap, auto ROLLBACK on fail

[ ] **Step 38: Query history**
- Deps: Step 12
- New: `lua/poste/sql/history.lua`
- Cmd: `:PosteHistory`

---

## Dep Graph

```
Phase 1A:  1→3→5→13    2→4→5→14
Phase 1B:  6→9→10→11→12    7→8
Phase 1C:  5→13,14
Phase 2:   5→15→16→17→18→19
Phase 3:   3,5→20→21→22→23
Phase 4:   3→24    22,24→25    7,20→26
Phase 5:   12→28,29    11→30
Phase 6:   11→32→33,34,35,36    5→37    12→38
```

---

## AI Agent Quickstart

1. **Locate**: find first `[ ]` Step above
2. **Read design**: `docs/sql-design.md` — isolation strategy + arch decisions
3. **Read step**: deps + files + requirements
4. **Implement + verify**: `[ ]` → `[x]`, run `cargo test`
5. **Commit**

**Reference files**:

| What | File |
|------|------|
| HTTP exec pattern | `lua/poste/init.lua` → `run_request()` |
| Rust executor pattern | `crates/poste-exec/src/executor.rs` → `execute_redis()` |
| Response struct | `crates/poste-exec/src/response.rs` |
| Parser pattern | `crates/poste-core/src/parser.rs` |
| Result format pattern | `lua/poste/format.lua` → `format_redis_body()` |
| Response buffer pattern | `lua/poste/buffer.lua` |
| SQL example file | `examples/queries.sql` |
| Dataset UI design | `docs/dataset-ui-design.md` |

---

## Files Created/Modified

### New — Rust (6)
| File | Step |
|------|------|
| `crates/poste-core/src/sql_parser.rs` | 4 |
| `crates/poste-exec/src/sql_dialect.rs` | 3 |
| `crates/poste-exec/src/sql_executor.rs` | 5,13,14 |
| `crates/poste-exec/src/sql_connection.rs` | 15 |
| `crates/poste-exec/src/sql_introspect.rs` | 20 |
| `crates/poste-exec/src/sql_ddl.rs` | 24 |

### New — Lua (10)
| File | Step |
|------|------|
| `lua/poste/sql/init.lua` | 12 |
| `lua/poste/sql/buffer.lua` | 11 |
| `lua/poste/sql/format.lua` | 9 |
| `lua/poste/sql/highlights.lua` | 10 |
| `lua/poste/sql/connections.lua` | 18 |
| `lua/poste/sql/context.lua` | 19 |
| `lua/poste/sql/db_browser.lua` | 22,23 |
| `lua/poste/sql/table_ops.lua` | 25 |
| `lua/poste/sql/completion.lua` | 26 |
| `lua/poste/indicators.lua` | 27 |

### New — VimScript (3)
| File | Step |
|------|------|
| `syntax/poste_sql.vim` | 8 |
| `syntax/poste_dataset.vim` | 8 |
| `ftplugin/poste_sql.vim` | 8 |

### New — Tests (1)
| File | Step |
|------|------|
| `tests/sql_multi_stmt_spec.lua` | 27 |

### Modified (16)
| File | Step | Change |
|------|------|--------|
| `Cargo.toml` | 1 | add sqlx |
| `crates/poste-exec/Cargo.toml` | 1,15 | sqlx + regex |
| `crates/poste-cli/Cargo.toml` | 16 | regex |
| `crates/poste-core/src/request.rs` | 2 | Sqlite variant |
| `crates/poste-core/src/parser.rs` | 2 | sqlite detection |
| `crates/poste-core/src/lib.rs` | 4 | pub mod sql_parser |
| `crates/poste-exec/src/executor.rs` | 5 | SQL delegation |
| `crates/poste-exec/src/sql_executor.rs` | 20 | normalize_sqlite_connection pub(crate) |
| `crates/poste-exec/src/lib.rs` | 3,5,15,20 | module exports |
| `crates/poste-cli/src/main.rs` | 16,17,21 | connection + introspect subcmds |
| `lua/poste/state.lua` | 6,22 | M.sql ns + db_browser |
| `lua/poste/init.lua` | 12,18,19,22 | filetype dispatch + cmd reg + DB Browser |
| `lua/poste/highlights.lua` | 10 | SQL highlight groups |
| `ftdetect/poste.vim` | 7 | *.sql/*.sqlite |
| `after/ftdetect/poste.vim` | 7 | override builtin detection |