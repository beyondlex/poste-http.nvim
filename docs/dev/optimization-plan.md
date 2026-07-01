# Optimization Plan

> Targeted improvements for Rust CLI + Lua plugin.
> Prioritized by impact and risk, staged for incremental delivery.

---

## P0: Zero-Risk Cleanup

Safe refactors with no behavior change. Land anytime.

### P0.1 — Deduplicate `item_builder.lua` cache code

`lua/poste/http/item_builder.lua:9-170` duplicates the entire caching layer
already in `cache.lua:1-182` (`get_buffer_cache`, `collect_file_vars`,
`collect_request_vars`, `collect_env_vars`, `collect_request_names`,
`collect_import_index`, `ensure_cache_autocmd`).

**Fix**: Delete duplicated functions; `require("poste.http.cache")` instead.

**Risk**: Zero. `cache.lua` exposes the same functions with the same signatures.

### P0.2 — Extract MD5 to shared module

`lua/poste/http/scripts.lua:10-205` and `lua/poste/http/assertions.lua:10-204`
both contain an identical 195-line MD5 implementation (`md5_init`, `F`, `G`, `H`,
`I`, `T`, `md5_transform`, `md5`).

**Fix**: Extract to `lua/poste/http/md5.lua`, require from both files.

**Risk**: Zero. Pure function extraction.

### P0.3 — Replace `Regex::new().unwrap()` with `OnceLock`

5 locations use `Regex::new(literal_pattern).unwrap()` at runtime:
- `parser.rs:204` — `extract_connection`
- `parser.rs:298` — `extract_file_variables`
- `parser.rs:348` — `substitute_vars`
- `sql_parser.rs:36` — `extract_database`
- `sql_parser.rs:48` — `strip_directives`

**Fix**: Use `std::sync::OnceLock` (or `once_cell::sync::Lazy`) to compile once,
add `expect("valid literal regex")` with the pattern as message.

**Risk**: Zero. Same semantics, better diagnostics, no repeated compilation.

### P0.4 — Replace deprecated `nvim_buf_set_option` calls

`lua/poste/http/history.lua:100,147,207,223,258` uses
`vim.api.nvim_buf_set_option(buf, "modifiable", bool)`, deprecated in Neovim 0.10+.

**Fix**: Replace with `vim.api.nvim_set_option_value("modifiable", bool, { buf = buf })`.

**Risk**: Zero. Exact same semantics, cross-version compatible.

---

## P1: Medium-Risk Performance

Fixes that change control flow but preserve all behavior.

### P1.1 — MySQL `USE` without pool recreation

`crates/poste-exec/src/sql_executor/mysql.rs:25-35` closes the entire connection
pool and creates a new one for every `USE db;` statement. MySQL `USE` is a
session-level command; no pool change is needed.

**Fix**: Execute `USE dbname;` as a SQL query on the existing connection instead
of recreating the pool. (Postgres and SQLite already handle `USE`/`ATTACH` correctly.)

**Risk**: Low. Equivalent to typing `USE dbname;` in a mysql CLI.

**Test**: Run the MySQL integration test suite; verify schema-qualified queries
resolve to the correct database after `USE`.

### P1.2 — Reverse module dependency (sql_introspect → sql_executor)

`crates/poste-exec/src/sql_introspect/sqlite.rs:8` imports
`crate::sql_executor::normalize_sqlite_connection`. This means the introspection
module depends on the executor module, which is architecturally backwards.

**Fix**: Move `normalize_sqlite_connection` to `sql_connection.rs` (or a new
`sql_util.rs`). Update both import sites.

**Risk**: Low. Pure function relocation. Verify all call sites compile.

### P1.3 — Half-buffer reads in hot paths

Several completion/cursor-move paths read the entire buffer:
- `lua/poste/http/context_detector.lua:9` — read to cursor line on every keystroke
- `lua/poste/boundary_indicator.lua:77` — read whole buffer on every CursorMoved
- `lua/poste/http/run.lua:38-62` — same buffer read twice in `run_request`

**Fix**:
- `context_detector.lua`: cache block bounds by `changedtick + bufnr`
- `boundary_indicator.lua`: use `nvim_buf_get_lines(buf, line-1, line, false)`
  for the visible window, not `0, -1`
- `run.lua`: reuse the single `lines` table from the first read instead of
  calling `get_lines` twice

**Risk**: Low. Visibility-preserving. Verify completion items and boundary
indicators still show correctly.

### P1.4 — `sign_configs` table hoist

`lua/poste/indicators.lua:239-243` creates a `sign_configs` table on every call
to `place_or_replace_sign`, which runs every 100ms in the spinner timer.

**Fix**: Hoist to module-level constant table.

**Risk**: Zero. Table literal → module constant.

---

## P2: Higher-Risk Structural Changes

Changes that touch multiple modules or alter async control flow.

### P2.1 — SQL completion: decouple from synchronous `vim.fn.system`

`lua/poste/sql/completion.lua:124` calls `vim.fn.system(cmd, sql_text)` on every
completion trigger. If the Rust binary hangs or is slow, the editor freezes.

**Fix**: Use `vim.system()` (or `jobstart`) with a timeout. Use a generation token
to discard stale responses. Cache by `(bufnr, offset, dialect, connection)`.

**Risk**: Medium. Completion item timing may shift; stale results must be guarded
by generation token. Verify ordering and dedup.

**Test**: Add Lua integration tests that exercise completion with slow/fast responses.

### P2.2 — Refactor `execute_http` (132-line function)

`crates/poste-exec/src/executor.rs:30-162` handles parsing, curl argument
construction, subprocess execution, and response assembly in one flat function.

**Fix**: Extract stages:
- `build_curl_args(request)` — arg construction
- `execute_curl(args)` — subprocess + I/O
- `parse_curl_response(stdout, stderr)` — response assembly

**Risk**: Medium. Touches the core HTTP execution path. Verify with HTTP integration
tests and edge cases (timeouts, errors, headers, cookies).

### P2.3 — SQL completion async callback race

`lua/poste/sql/completion.lua:360-362` fires the keyword callback immediately
even though `ensure_tables` and `ensure_databases` are still pending. The async
results arrive later but are silently dropped.

**Fix**: Defer the callback until all pending async operations complete (check
`pending == 0` before calling `callback()`).

**Risk**: Medium. Changes timing of completion item delivery. Verify items arrive
(eventually) with the correct set.

### P2.4 — DB browser: reuse parent connection pool

`sql_introspect/*` DDL generation opens secondary connection pools when the
caller already has an active pool (`build_create_table_from_introspect_postgres`,
`build_create_table_from_introspect_mysql`, `build_create_table_from_introspect_sqlite`).

**Fix**: Pass the pool (or a shared connection factory) to DDL builders instead
of creating a new pool.

**Risk**: Medium. Pool lifecycle management must be careful. Verify pool is not
dropped prematurely and connections are not left dangling.

---

## Tracking

| ID | Area | Est. Effort | Status |
|----|------|-------------|--------|
| P0.1 | Lua dedup (item_builder) | 15min | done |
| P0.2 | Lua dedup (MD5) | 15min | done |
| P0.3 | Rust `OnceLock` regex | 20min | done |
| P0.4 | Lua deprecated API | 10min | done |
| P1.1 | MySQL pool recreation | 30min | done |
| P1.2 | Module dependency swap | 30min | done |
| P1.3 | Hot-path buffer reads | 45min | done |
| P1.4 | sign_configs hoist | 5min | done |
| P2.1 | Async completion | 2h | done |
| P2.2 | execute_http refactor | 1.5h | done |
| P2.3 | Completion race fix | 30min | done |
| P2.4 | Pool reuse in introspection | 1h | done |

*All items complete. Last updated: 2026-06-30*
