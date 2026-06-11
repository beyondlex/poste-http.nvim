# SQL Completion P0-P4 Implementation Checklist

> **Progress**: P0 ✅ | P1 ⬜ | P2 ⬜ | P3 ⬜ | P4 ⬜
> **Current phase**: P1 — Rust Context as SSOT
> **Next step**: First unchecked item below

---

## P1 — Rust Context as SSOT

**Goal**: Lua heuristic no longer overrides Rust context by default.

### Rust Side (`crates/poste-core/src/sql_context/`)

- [ ] **P1a. `ContextType::String/Comment`** — Add `String` and `Comment` variants to `ContextType` enum. Return explicit type when cursor is inside string/comment instead of `None`.
  - Files: `context.rs`, `scanner.rs`, `detectors.rs`
  - Verify: `cargo test -p poste-core sql_context`

- [ ] **P1b. `version` field** — Add `"version": 1` to `detect_context()` JSON output.
  - File: `context.rs`
  - Verify: `cargo test -p poste-core sql_context`

- [ ] **P1c. `ctx_schema` for `SchemaTable`** — Fill `ctx_schema` with schema name (currently null).
  - File: `detectors.rs`
  - Verify: `cargo test -p poste-core sql_context`

- [ ] **P1d. `try_directive()` demotion** — Return `None` on `@connection`/`@database` tokens (safety net only), no longer returns `Connection`.
  - File: `detectors.rs`
  - Verify: `cargo test -p poste-core sql_context`

### Lua Side (`lua/poste/sql/`)

- [ ] **P1e. Detection wrapper** — Add `detect_context_for_completion(bufnr, line_before, cursor_line)` in `completion.lua`:
  - Keep Lua directive fast paths (`-- @connection`, `-- @database`)
  - For SQL body, call `try_rust_context()` first (send full body, no block pre-extraction)
  - Only fall back to `completion_ctx.detect_context()` when Rust unavailable
  - Wire `get_items()` → new wrapper

- [ ] **P1f. Legacy switch** — In `completion.lua`:
  - `vim.g.poste_sql_legacy_completion = true` → Lua-only fallback
  - `vim.g.poste_sql_legacy_completion = "rust"` → Rust-only, no fallback
  - Default `nil` → Rust first, Lua never overrides

- [ ] **P1g. Test export rename**:
  - `_test.detect_context` → `_test.detect_lua_context`
  - Add `_test.detect_rust_context` (when binary exists)
  - Add `_test.detect_context_for_completion` for integration path
  - Update all references in `tests/sql_completion_spec.lua` and `tests/sql_completion_edge_spec.lua`

- [ ] **P1h. `completion_ctx.lua` deprecation** — Header comment: `@deprecated` + "fallback only when Rust unavailable". No new SQL grammar features added.

### P1 Verification

```bash
cargo test -p poste-core sql_context
tests/run.sh
```

**Acceptance**: Default completion no longer overridden by Lua heuristic. `vim.g.poste_sql_legacy_completion = "rust"` reproduces Rust-only behavior.

---

## P2 — Golden Fixture Tests

**Goal**: Every context behavior has a verifiable fixture before Rust code changes.

- [ ] **P2a. Define fixture format** — Use `█` cursor marker, JSON fixture as specified in `README.md` §P2. Place in `tests/fixtures/sql_context/` or inline in Rust tests.

- [ ] **P2b. Write fixture files**:

| File | Cases | Content |
|------|-------|---------|
| `basic_select.json` | 8-10 | Basic SELECT, FROM, WHERE |
| `directives.json` | 4-6 | `-- @connection`, `-- @database` cursor completion |
| `statement_boundaries.json` | 6-8 | `;` boundaries, multi-statement |
| `strings_comments.json` | 4-6 | Cursor inside strings/comments |
| `dot_context.json` | 6-8 | After `alias.`, `table.` |
| `cte_subquery_scope.json` | 4-6 | CTE, subquery scope |
| `dml_insert_update_delete.json` | 6-8 | INSERT/UPDATE/DELETE |
| `dialect_postgres/mysql/sqlite.json` | 4-6 each | Dialect-specific |

- [ ] **P2c. Test runner** — Add `crates/poste-core/tests/sql_context_golden.rs`. Load fixtures, strip `█`, call `detect_context()`, compare results.

- [ ] **P2d. Old test migration**:
  - `tests/sql_completion_spec.lua`: keep UI/item/cache tests
  - `tests/sql_completion_edge_spec.lua`: split into Lua fallback tests + Rust integration tests
  - Update `BUG`/`BEFORE FIX` tests to correct behavior

### P2 Verification

```bash
cargo test -p poste-core sql_context
cargo test -p poste-core --test sql_context_golden
tests/run.sh
```

---

## P3 — Scope Resolver

**Goal**: Explicit scope model for CTE/subquery/alias/derived tables. Remove blank-line boundary + `completion_ctx.lua`.

- [ ] **P3a. New `scope.rs` module** — In `crates/poste-core/src/sql_context/scope.rs`:
  - `QueryScope { tables, ctes, aliases }`, `CteRef`, `AliasRef`
  - `resolve_scope(tokens, sql) → QueryScope`
  - Handle: top-level FROM/JOIN, schema.table, aliases, CTE registration
  - Subquery/CTE body tables NOT leaked to outer scope
  - Derived table aliases visible

- [ ] **P3b. Compatibility layer** — `tables::extract_tables()` calls `scope::resolve_scope()` internally, keeps `Vec<TableRef>` return type.

- [ ] **P3c. Update `detect_context()`** — Resolve scope once per call, build `ContextResult` from scope, remove duplicate `extract_tables()` calls.

- [ ] **P3d. Remove blank-line boundary** — Remove `is_blank_line_separator()` from `context.rs`. `find_statement_token_range()` relies only on `;`.

- [ ] **P3e. Remove `completion_ctx.lua` heuristic** — Delete Lua SQL heuristic logic (non-directive paths).

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

- [ ] **P4a. Add serve subcommand** — `ContextAction::Serve`. Read line-delimited JSON from stdin.
- [ ] **P4b. Handle detect method** → `make_detect_response()`.
- [ ] **P4c. Handle stmt method** → statement span extraction.
- [ ] **P4d. Error isolation** — Bad request returns `{"id": N, "ok": false}`, server continues.
- [ ] **P4e. Clean exit on EOF**.

### Lua Client

- [ ] **P4f. `context_client.lua`** — `vim.fn.jobstart()`, request ID counter, callback map, stdout buffering, auto-restart.
- [ ] **P4g. Public API** — `detect(sql, offset, dialect, cb)`, `stmt(sql, cursor_line, cb)`, `stop()`.

### Completion Integration

- [ ] **P4h. `try_rust_context()` prefers persistent client** — Falls back to `vim.fn.system()` when unavailable.
- [ ] **P4i. Cache extension** — Per-buffer LRU: `bufnr|changedtick|offset|dialect`.
- [ ] **P4j. 50ms timeout** — Returns keyword/function fallback on timeout.

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
