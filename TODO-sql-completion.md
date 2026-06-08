# SQL Completion & Context Detection — TODO

Priority: P0 = blocking / P1 = important / P2 = nice to have

---

## P0: Data Drift Between Rust and Lua

### [ ] P0-1: Unify `is_known_keyword` with Lua's keyword list

Rust `tokenizer.rs:194-219` has 105 hardcoded keywords. Lua `completion_data.lua:12-28` has ~28 display keywords.
These are different lists serving different purposes — but they should NOT drift independently.

**Action:**
1. Audit both lists and identify keywords that exist in one but not the other
2. Add missing keywords to Rust's `is_known_keyword()`: `EXPLAIN`, `ANALYZE`, `VACUUM`, `REINDEX`, `CLUSTER`, `CALL`, `DO`, `PREPARE`, `EXECUTE`, `DEALLOCATE`, `LISTEN`, `NOTIFY`, `GRANT`, `REVOKE`, `LOCK`, `COPY`, `REPLACE`
3. Ensure Lua's `KEYWORDS` table is a subset of Rust's list (no unique keywords in Lua)

**File(s):** `tokenizer.rs`, `completion_data.lua`

### [ ] P0-2: Unify function lists between Rust and Lua

Rust `functions.rs` has 99 entries. Lua `completion_data.lua:51-146` has ~146 entries.
They overlap but aren't identical — drift will happen.

**Action:**
1. Design a mechanism for Rust to return the complete function list (already partially done via `ContextResult.functions`)
2. Remove the authoritative function list from Lua — let Rust drive it
3. Keep Lua's list as a fallback cache only, with a comment marking it as a fallback

**File(s):** `functions.rs`, `completion_data.lua`, `completion.lua`

### [ ] P0-3: Eliminate Lua context detection duplicate logic

`completion_ctx.lua:84-134` (`detect_context`) duplicates logic that Rust already does better (token-based, paren-aware, string-aware).

**Action:**
1. Audit whether any scenario exists where Lua detects context that Rust misses
2. If none: mark Lua path as deprecated, add warning logs when it's used
3. If gaps found: add them to Rust, then deprecate Lua path
4. Future: consider removing `completion_ctx.lua` entirely when Rust coverage is complete

**File(s):** `completion_ctx.lua`, `completion.lua`

### [ ] P0-4: Eliminate Lua table extraction duplicate logic

`completion_ctx.lua:19-61` (`extract_from_tables`) duplicates `tables.rs`.

**Action:**
1. Verify Rust's `extract_tables` covers all cases Lua handles
2. If yes: make `ctx.get_tables_and_alias` always prefer Rust, never fall back to Lua extraction
3. If no: add missing cases to Rust, then remove Lua extraction

**File(s):** `completion_ctx.lua`, `tables.rs`

### [ ] P0-5: Eliminate Lua statement boundary duplicate logic

`init.lua`'s `extract_stmt_at_cursor` duplicates `find_statement_span` in `mod.rs:559-613`.

**Action:**
1. Ensure Lua always uses Rust's `find_statement_span` when available
2. Only keep Lua implementation as last-resort fallback when binary is missing

**File(s):** `init.lua` (in `lua/poste/sql/`), `mod.rs`

---

## P1: Gaps in Context Detection

### [ ] P1-1: Add missing common SQL keywords to tokenizer

Rust `is_known_keyword()` doesn't include these widely-used keywords:

| Keyword | Dialect | Why It Matters |
|---------|---------|----------------|
| `EXPLAIN` | All | Often prefixes queries; should be recognized |
| `ANALYZE` | PG/MySQL | `EXPLAIN ANALYZE` — compound keyword |
| `CALL` | All | Stored procedure invocation |
| `GRANT`/`REVOKE` | All | DCL statements |
| `COPY` | PG | Bulk operations |
| `TRUNCATE` | Already in list — verify | |
| `SHOW` | Already in list — but needs special context (see P1-2) | |

**Action:** Add each to `KWS` array in `tokenizer.rs:194-219`.

**File(s):** `tokenizer.rs`

### [ ] P1-2: MySQL `SHOW` keyword → special context

MySQL `SHOW DATABASES` / `SHOW TABLES` / `SHOW COLUMNS FROM` etc. should trigger Database/Table/Column completion.

**Action:**
1. After `SHOW`, scan forward for the next ident/keyword
2. `SHOW DATABASES|SCHEMAS` → `ContextType::Database` (no USE needed)
3. `SHOW TABLES` → `ContextType::Table`
4. `SHOW COLUMNS FROM|FIELDS FROM` → needs table reference → `insert_column`-like context
5. Gate behind `Dialect::MySQL` or check if SHOW-like syntax is common enough

**File(s):** `mod.rs` (special case in `detect_context`)

### [ ] P1-3: Schema-aware caching in Lua

Cache key in `completion_data.lua:177-178` is `connection/database` — no schema dimension.
`public.users` and `auth.users` collide in column cache.

**Action:**
1. Add schema to cache key: `connection/database/schema`
2. Propagate schema from `tables.rs` (schema field already exists in `TableRef`)
3. When fetching columns for `dot_column`, use schema if available
4. Update introspection calls to pass `--schema` when available

**File(s):** `completion_data.lua`, `completion.lua`

### [ ] P1-4: Dialect-parameterized function completion

Rust returns all known functions regardless of connection dialect. MySQL-only functions (`GET_LOCK`, `BENCHMARK`) should not appear when connected to PostgreSQL.

**Action:**
1. Add `Dialect` parameter to `detect_context()` — optional, defaults to `None` (show all)
2. Annotate functions in `functions.rs` with dialect tags
3. Filter by dialect when dialect is known

**File(s):** `functions.rs`, `mod.rs` (signature), `completion.lua` (uses `rust_functions`)

### [ ] P1-5: Add `ContextType::Window` for `OVER` / `PARTITION BY`

Currently `OVER` and `PARTITION BY` are not keywords in `is_known_keyword` — meaning they're treated as `Ident`.

**Action:**
1. Add `OVER`, `PARTITION` to `is_known_keyword()`
2. Add `ContextType::Window` variant? Or handle inside `Column` context
3. After `OVER (` → suggest window functions (`ROW_NUMBER`, `RANK`, etc.)
4. After `PARTITION BY` → suggest columns

**File(s):** `tokenizer.rs` (keywords), `mod.rs` (context detection)

---

## P2: Quality of Life

### [ ] P2-1: Add `ContextType::Set` for `SET` in UPDATE

`UPDATE users SET name = 'x', ` → after comma, cursor should be `Column` (next column to set).
Currently works because `SET` is in `is_column_keyword`.

But `SET` in other contexts (`SET session_parameter = value`) should not trigger `Column`.

**Action:** Verify current behavior is correct for both cases. Add test if missing.

**File(s):** `mod.rs` (tests)

### [ ] P2-2: Improve Lua fallback with Rust tokenizer library

Instead of Lua regex fallback making subprocess calls, consider compiling the Rust tokenizer as a shared library or embedding a WASM build.

**Action:** Research — this is a stretch goal only if subprocess latency becomes a problem.

### [ ] P2-3: Subprocess reuse optimization

Each keystroke spawns `poste context detect` as a new process. For large `###` blocks this is wasteful.

**Action:**
1. Consider Neovim `chansend` / RPC to a persistent `poste` daemon
2. Or batch requests: debounce keystrokes and cache recent results

**File(s):** `completion.lua` (`try_rust_context`)

### [ ] P2-4: Add `FOR UPDATE` / `FOR SHARE` clause handling

`SELECT ... FOR UPDATE OF table` should trigger Table completion after `OF`.
`SELECT ... FOR UPDATE NOWAIT` / `SKIP LOCKED` should be recognized as keywords.

**Action:**
1. Add `FOR` handling in context detection (currently may not be in keyword list)
2. After `FOR UPDATE OF` → Table
3. `NOWAIT`, `SKIP LOCKED` → keywords

**File(s):** `tokenizer.rs`, `mod.rs`

### [ ] P2-5: Test baseline for hybrid mode

The default hybrid mode (Rust + Lua fallback) is not explicitly tested in Rust tests or Lua tests.

**Action:**
1. Add integration test that exercises the full path: Lua → Rust → Lua fallback
2. Verify fallback trigger conditions are correct
3. Test all three `vim.g.poste_sql_legacy_completion` modes

**File(s):** `tests/` (new integration test)

---

## Summary by Priority

| Priority | Count | Key Theme |
|----------|-------|-----------|
| P0 | 5 | Stop data drift between Rust and Lua; eliminate duplicate logic |
| P1 | 5 | Fill context detection gaps; add dialect awareness |
| P2 | 5 | Polish, performance, missing clauses |

Total: 15 items

---

## Quick Start for Agent

When starting a TODO item:

1. `cargo test -p poste-core` — get baseline
2. Read the relevant source file (listed above)
3. Read the test block at bottom of `mod.rs` for patterns
4. Implement Rust-side first
5. `cargo test -p poste-core` — verify
6. Update Lua minimally
7. Mark `[x]` when done
