# SQL Completion P0-P4 Implementation Checklist

> **Progress**: P0 ✅ | P1 ✅ | P2 ✅ | P3 ✅ | P4 ✅
> **Current phase**: P4 — Persistent Context Service ✅
> **Next step**: All P0-P4 complete

---

## P1 — Rust Context as SSOT ✅

**Goal**: Lua heuristic no longer overrides Rust context by default.

### Rust Side (`crates/poste-core/src/sql_context/`)

- [x] **P1a. `ContextType::String/Comment`** — Add `String` and `Comment` variants to `ContextType` enum. Return explicit type when cursor is inside string/comment instead of `None`.
  - Files: `context.rs`, `mod.rs`
  - Verify: `cargo test -p poste-core sql_context`

- [x] **P1b. `version` field** — Add `"version": 1` to `detect_context()` JSON output.
  - File: `crates/poste-cli/src/main.rs`
  - Verify: `cargo test -p poste-core sql_context`

- [x] **P1c. `ctx_schema` for `SchemaTable`** — Fill `ctx_schema` with schema name (currently null).
  - File: `crates/poste-cli/src/main.rs`
  - Verify: `cargo test -p poste-core sql_context`

- [x] **P1d. `try_directive()` demotion** — Return `None` on `@connection`/`@database` tokens (safety net only), no longer returns `Connection`.
  - File: `detectors.rs`
  - Verify: `cargo test -p poste-core sql_context`

### Lua Side (`lua/poste/sql/`)

- [x] **P1e. Detection wrapper** — Add `detect_context_for_completion(bufnr, line_before, cursor_line)` in `completion.lua`:
  - Keep Lua directive fast paths (`-- @connection`, `-- @database`)
  - For SQL body, call `try_rust_context()` first (send full body, no block pre-extraction)
  - Only fall back to `completion_ctx.detect_context()` when Rust unavailable
  - Wire `get_items()` → new wrapper

- [x] **P1f. Legacy switch** — In `completion.lua`:
  - `vim.g.poste_sql_legacy_completion = true` → Lua-only fallback
  - `vim.g.poste_sql_legacy_completion = "rust"` → Rust-only, no fallback
  - Default `nil` → Rust first, Lua never overrides

- [x] **P1g. Test export rename**:
  - `_test.detect_context` → `_test.detect_lua_context`
  - Add `_test.detect_context_for_completion` for integration path
  - Update all references in `tests/sql_completion_spec.lua`, `tests/sql_completion_edge_spec.lua`, `tests/diag_sql.lua`

- [x] **P1h. `completion_ctx.lua` deprecation** — Header comment: `@deprecated` + "fallback only when Rust unavailable". No new SQL grammar features added.

### P1 Verification

```bash
cargo test -p poste-core sql_context
tests/run.sh
```

**Acceptance**: Default completion no longer overridden by Lua heuristic. `vim.g.poste_sql_legacy_completion = "rust"` reproduces Rust-only behavior.

---

## P2 — Golden Fixture Tests

**Goal**: Every context behavior has a verifiable fixture before Rust code changes.

- [x] **P2a. Define fixture format** — Use `█` cursor marker, JSON fixture as specified in `README.md` §P2. Place in `crates/poste-core/tests/fixtures/sql_context/`.

- [x] **P2b. Write fixture files** (13 files, ~130 cases):

| File | Cases | Content |
|------|-------|---------|
| `basic_select.json` | 18 | Basic SELECT, FROM, WHERE, JOIN, UNION, comma |
| `directives.json` | 3 | `@connection`, `USE`, `USE prefix` |
| `statement_boundaries.json` | 2 | `;` boundaries, blank line separator |
| `strings_comments.json` | 4 | Cursor inside strings/comments |
| `dot_context.json` | 9 | After `alias.`, `table.`, schema qualified |
| `cte_subquery_scope.json` | 5 | CTE, subquery scope, no-leak checks |
| `dml_insert_update_delete.json` | 10 | INSERT/UPDATE/DELETE/RETURNING/ON CONFLICT |
| `ddl.json` | 10 | CREATE/ALTER/DROP/TRUNCATE/MODIFY |
| `where_complex.json` | 12 | WHERE = > LIKE IS NOT BETWEEN AND IN ( |
| `special_statements.json` | 19 | GRANT/REVOKE/COPY/SHOW/EXPLAIN/VACUUM/et al |
| `dialect_postgres/mysql/sqlite.json` | 1 each | Dialect-specific |

- [x] **P2c. Test runner** — Add `crates/poste-core/tests/sql_context_golden.rs`. Loads fixtures, strips `█`, computes offset, calls `detect_context()`, compares all fields (tables order-insensitive, functions only when present).

- [x] **P2d. Old test migration**:
  - `tests/sql_completion_spec.lua`: unchanged — keeps UI/item/cache tests
  - `tests/sql_completion_edge_spec.lua`: unchanged — correctly tests `detect_lua_context` (Lua heuristic fallback); Rust path covered by golden fixtures
  - Golden fixtures capture correct Rust behavior; no need to modify `BUG`/`BEFORE FIX` Lua tests (they document known Lua fallback limitations)

### P2 Verification ✅

```bash
cargo test -p poste-core sql_context   # 202 → 202 passes
cargo test -p poste-core --test sql_context_golden  # 13/13 passes
tests/run.sh  # 80/80 + 89/89 + all others (367 total)
```

**Acceptance**: Every context behavior has a verifiable fixture. New bug fix workflow: add failing fixture, then change Rust context. Lua tests no longer responsible for full SQL grammar coverage.

---

## P3 — Scope Resolver

**Goal**: Explicit scope model for CTE/subquery/alias/derived tables. Remove blank-line boundary + `completion_ctx.lua`.

- [x] **P3a. New `scope.rs` module** — In `crates/poste-core/src/sql_context/scope.rs`:
  - `QueryScope { tables, ctes, aliases }`, `CteRef`, `AliasRef`
  - `resolve_scope(tokens, sql) → QueryScope`
  - Handle: top-level FROM/JOIN, schema.table, aliases, CTE registration
  - Subquery/CTE body tables NOT leaked to outer scope
  - Derived table aliases visible

- [x] **P3b. Compatibility layer** — `tables::extract_tables()` calls `scope::resolve_scope()` internally, keeps `Vec<TableRef>` return type.

- [x] **P3c. Update `detect_context()`** — Resolve scope once per call, build `ContextResult` from scope, remove duplicate `extract_tables()` calls.

- [x] **P3d. Remove blank-line boundary** — Remove `is_blank_line_separator()` from `context.rs`. `find_statement_token_range()` relies only on `;`.

- [x] **P3e. Remove `completion_ctx.lua` heuristic** — Delete Lua SQL heuristic logic (non-directive paths).

### P3 Verification

```bash
cargo test -p poste-core sql_context
cargo test -p poste-core --test sql_context_golden
tests/run.sh
```

---

## P4 — Persistent Context Service

**Goal**: Replace `vim.fn.system()` per keystroke with a persistent subprocess.

### Rust CLI

- [x] **P4a. Add serve subcommand** — `ContextAction::Serve`. Read line-delimited JSON from stdin.
- [x] **P4b. Handle detect method** → `make_detect_response()`.
- [x] **P4c. Handle stmt method** → statement span extraction.
- [x] **P4d. Error isolation** — Bad request returns `{"id": N, "ok": false}`, server continues.
- [x] **P4e. Clean exit on EOF**.

### Lua Client

- [x] **P4f. `context_client.lua`** — `vim.fn.jobstart()`, request ID counter, callback map, stdout buffering, auto-restart.
- [x] **P4g. Public API** — `detect(sql, offset, dialect, cb)`, `stmt(sql, cursor_line, cb)`, `stop()`.

### Completion Integration

- [x] **P4h. `try_rust_context()` prefers persistent client** — Falls back to `vim.fn.system()` when unavailable.
- [x] **P4i. Cache extension** — Per-buffer LRU: `bufnr|changedtick|offset|dialect`.
- [x] **P4j. 50ms timeout** — Returns keyword/function fallback on timeout.

### P4 Verification

```bash
cargo test -p poste-core sql_context
cargo test -p poste-cli --test cli_context_serve
tests/run.sh
```

---

## Global Commit Checklist (every commit)

- [ ] `cargo test -p poste-core sql_context` passes
- [ ] `cargo clippy -p poste-core -p poste-cli -p poste-exec -- -D warnings` clean
- [ ] `tests/run.sh` passes (or note skipped SQL integration tests)
- [ ] No changes to `lua/poste/http/*`, `lua/poste/completion.lua`, `lua/poste/sql/buffer.lua`
- [ ] No changes to SQL execution behavior
