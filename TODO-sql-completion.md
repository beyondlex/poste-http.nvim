# SQL Completion & Context Detection — TODO

Last audited: 2026-06-08

Priority: P0 = correctness blocker / P1 = important robustness gap / P2 = quality or performance

Current baseline:
- `cargo test -p poste-core` passes: 178 tests + 1 doc test.
- Rust tokenizer/context detection is the right primary path and is much more robust than Lua regex fallback.
- The system is not fully robust yet because the default path is still hybrid, schema is not preserved end-to-end, and several dialect/context cases still return generic `keyword`.

---

## P0: Make Completion Semantics Deterministic

### [x] P0-1: Stop Lua from overriding Rust context in default mode

Current default mode runs Rust first, then lets Lua override when Rust returns `keyword` with a non-empty prefix.
That makes completion behavior depend on two independent parsers.

**Observed code:**
- `completion.lua:146-164` documents default hybrid mode and performs the override.
- `completion_ctx.lua:84-134` is regex-based and does not have Rust's string/comment/paren awareness.

**Action:**
1. Audit known cases where Lua currently returns a better result than Rust.
2. Add those cases to Rust tests and Rust context detection.
3. Change default mode to trust Rust when Rust returns a valid response.
4. Keep Lua context detection only for binary-missing legacy mode.
5. Add debug logging when Lua fallback is used outside explicit legacy mode.

**File(s):** `lua/poste/sql/completion.lua`, `lua/poste/sql/completion_ctx.lua`, `crates/poste-core/src/sql_context/mod.rs`

### [x] P0-2: Preserve schema through Rust → CLI → Lua → introspection

Rust has `schema` in `TableRef` and `ContextType::DotColumn`, but the completion path drops it.
This makes `public.users` and `auth.users` collide and can fetch the wrong columns.

**Observed code:**
- `ContextType::DotColumn { table, schema }` exists in `mod.rs`.
- `TableRef { name, alias, schema }` exists in `mod.rs`.
- CLI `TableRefInfo` serializes only `name` and `alias`.
- Lua column cache key is only `connection/database`.
- `ensure_columns(tbl)` has no schema parameter and never passes `--schema`.

**Action:**
1. Add `schema: Option<String>` to CLI `TableRefInfo`.
2. Add a structured `ctx_schema` or equivalent field for `dot_column` responses.
3. Update `get_tables_and_alias()` to preserve alias → `{ table, schema }`, not just alias → table.
4. Update `ensure_columns(table, opts, callback)` to accept schema.
5. Add schema to the column cache dimension, or key columns by `schema.table`.
6. Pass `--schema` for PostgreSQL column introspection when schema is known.
7. Add tests for `public.users u WHERE u.` and `auth.users WHERE users.` style cases.

**File(s):** `crates/poste-cli/src/main.rs`, `crates/poste-core/src/sql_context/mod.rs`, `lua/poste/sql/completion_ctx.lua`, `lua/poste/sql/completion.lua`, `lua/poste/sql/completion_data.lua`

### [x] P0-3: Fix schema-qualified alias extraction in Rust

`public.users u` and `public.users AS u` should map alias `u` to table `users` with schema `public`.
Current parser checks fixed token positions after `schema.table` and does not skip whitespace in that branch.

**Observed evidence:**
- `tables.rs:75-99` handles `schema.table`, then looks at `i + 3` directly.
- The existing `test_extract_schema_alias` only asserts that `users` exists, not that alias/schema are correct.
- `test_extract_join_with_schema_and_alias` currently has no assertions.

**Action:**
1. Refactor `parse_table_ref()` to parse qualified names using `skip_forward()`.
2. Support `schema.table alias` and `schema.table AS alias`.
3. Decide how to represent `database.schema.table`; for PostgreSQL use `schema=database?` is wrong, so document and test the intended behavior.
4. Strengthen tests to assert `name`, `schema`, and `alias`.

**File(s):** `crates/poste-core/src/sql_context/tables.rs`, `crates/poste-core/src/sql_context/mod.rs`

### [x] P0-4: Make Rust/Lua function and keyword data intentionally sourced

The Rust and Lua function lists are currently very similar, but still duplicated. Lua keywords are display snippets while Rust keywords classify tokens, so they are related but not identical.

**Action:**
1. Treat Rust `functions.rs` as authoritative for normal completion.
2. Mark Lua `SQL_FUNCTIONS` as fallback-only with a comment and a drift test or generation script.
3. Add a small test or script that checks Lua fallback functions are a subset of Rust functions.
4. For keywords, split concepts clearly:
   - Rust tokenizer keyword list: token classification.
   - Lua display keywords: completion snippets, allowed to include compound snippets like `ORDER BY`.
5. Add a drift check that every single-word Lua keyword/snippet part that should be classified is known by Rust.

**File(s):** `crates/poste-core/src/sql_context/functions.rs`, `crates/poste-core/src/sql_context/tokenizer.rs`, `lua/poste/sql/completion_data.lua`, `tests/`

### [x] P0-5: Add integration coverage for all completion modes

Rust unit tests are strong, but the Lua orchestrator behavior is where several correctness risks live.

**Action:**
1. Add tests for `vim.g.poste_sql_legacy_completion = nil`, `true`, and `"rust"`.
2. Cover Rust success, binary missing fallback, and Rust `keyword` with prefix.
3. Include a schema-qualified dot-column case.
4. Include string/comment cases where Lua fallback must not re-enable noisy completions.
5. **[done]** 69 tests covering 3 modes, Rust CLI integration (7 cases), schema-qualified dot-column, comment/string fallback, toggle_legacy cycle.
6. **[bonus]** Fixed missing `local data` in drift test (hidden when binary absent). Fixed table context tests to pre-cache databases when binary exists.

**File(s):** `tests/sql_completion_spec.lua`, `tests/completion_spec.lua`, `tests/`

---

## P1: Fill SQL Context Gaps

### [x] P1-1: Add missing common SQL keywords to Rust tokenizer

`OVER` and `PARTITION` are already present, but many common command keywords are still missing.

**Add or verify:**
`EXPLAIN`, `ANALYZE`, `VACUUM`, `REINDEX`, `CLUSTER`, `CALL`, `DO`, `PREPARE`, `EXECUTE`, `DEALLOCATE`, `LISTEN`, `NOTIFY`, `GRANT`, `REVOKE`, `LOCK`, `COPY`, `REPLACE`, `FOR`, `OF`, `SHARE`, `NOWAIT`, `SKIP`, `LOCKED`, `DATABASES`, `SCHEMAS`, `COLUMNS`, `FIELDS`.

**Action:**
1. Add missing words to `is_known_keyword()`.
2. Add tests that assert context behavior, not just token classification.
3. Avoid adding words only to Lua unless they are fallback display snippets.
4. **[done]** 27 keywords added to `is_known_keyword()`. `COPY`, `ANALYZE`, `VACUUM` added to `is_table_keyword()` for table context. 8 new context tests added. Updated existing `test_detect_copy_from` to expect `Table`.

**File(s):** `crates/poste-core/src/sql_context/tokenizer.rs`, `crates/poste-core/src/sql_context/mod.rs`

### [x] P1-2: Add explicit MySQL `SHOW` context handling

Current sample: `SHOW TABLES ` returns `keyword`, not table/database/column context.

**Action:**
1. Add a Rust special-case before generic backward scan.
2. `SHOW DATABASES|SCHEMAS` → `ContextType::Database`.
3. `SHOW TABLES` → `ContextType::Table` or a dedicated metadata context if table names should not be inserted.
4. `SHOW COLUMNS FROM|FIELDS FROM <table>` → table context before table name, column/keyword after table depending cursor position.
5. Decide whether this is always enabled or dialect-gated.

**File(s):** `crates/poste-core/src/sql_context/mod.rs`, `crates/poste-core/src/sql_context/tokenizer.rs`

### [x] P1-3: Add `COPY` / DCL / transaction command contexts

Current sample: `COPY ` returns `keyword`. For PostgreSQL, `COPY table` should suggest tables.

**Action:**
1. `COPY ` → table context.
2. `COPY table (` → column or insert-column-like context.
3. `GRANT ... ON ` / `REVOKE ... ON ` should not blindly return `column`; decide table/schema/function contexts.
4. Add tests for `EXPLAIN`, `EXPLAIN ANALYZE`, `CALL`, `PREPARE`, `EXECUTE`.

**File(s):** `crates/poste-core/src/sql_context/mod.rs`, `crates/poste-core/src/sql_context/tokenizer.rs`

### [x] P1-4: Add `FOR UPDATE` / `FOR SHARE` clause handling

`SELECT ... FOR UPDATE OF table` should suggest tables after `OF`.
`NOWAIT` and `SKIP LOCKED` should be recognized as keywords.

**Action:**
1. Add missing keywords.
2. Add special handling for `FOR UPDATE OF` and `FOR SHARE OF`.
3. Add tests for `NOWAIT`, `SKIP LOCKED`, and table completion after `OF`.

**File(s):** `crates/poste-core/src/sql_context/tokenizer.rs`, `crates/poste-core/src/sql_context/mod.rs`

### [x] P1-5: Dialect-aware function completion

Rust currently returns all known functions regardless of the active connection dialect.
Example: PostgreSQL users see MySQL-only functions such as `GET_LOCK` and `BENCHMARK`.

**Action:**
1. Add a lightweight dialect parameter to the context detection CLI/API.
2. Do not make `poste-core` depend directly on `poste-exec` unless the dependency graph is explicitly accepted.
3. Annotate functions with dialect tags.
4. Filter functions when dialect is known; keep current all-functions behavior when dialect is unknown.
5. Add tests for at least PostgreSQL and MySQL.

**File(s):** `crates/poste-core/src/sql_context/functions.rs`, `crates/poste-core/src/sql_context/mod.rs`, `crates/poste-cli/src/main.rs`, `lua/poste/sql/completion.lua`

---

## P2: Polish and Performance

### [x] P2-1: Revisit window completion behavior

`OVER` and `PARTITION` are now keywords and tests pass for `PARTITION BY` / `ORDER BY`.
The remaining question is product behavior: should `OVER (` suggest window keywords/functions first, or keep generic keywords/functions?

**Action:**
1. Decide whether to add `ContextType::Window`.
2. If added, expose dedicated items for `PARTITION BY`, `ORDER BY`, frame clauses, and window functions.
3. Keep `PARTITION BY` column completion.

**File(s):** `crates/poste-core/src/sql_context/mod.rs`, `lua/poste/sql/completion.lua`, `lua/poste/sql/completion_data.lua`

### [x] P2-2: Verify `SET` behavior in UPDATE vs session settings

`UPDATE users SET name = 'x', ` should suggest columns.
`SET statement_timeout = ` should not suggest table columns.

**Current status:** Rust has a passing `test_detect_set_statement`; still add/update tests for comma-after-update-set.

**File(s):** `crates/poste-core/src/sql_context/mod.rs`

### [ ] P2-3: Subprocess reuse optimization

Each completion request spawns `poste context detect`.

**Action:**
1. Measure context detection latency in realistic large SQL files.
2. Add debounce/cache if needed.
3. Consider a persistent Neovim job/RPC process only if measurements justify it.

**File(s):** `lua/poste/sql/completion.lua`

### [ ] P2-4: Keep statement-boundary fallback minimal

Rust `find_statement_span()` handles semicolons in strings/comments, but Lua still has fallback statement extraction.

**Action:**
1. Keep Rust as the preferred path.
2. Keep Lua only for binary-missing legacy behavior.
3. Add tests for directives, blank lines, `###`, and semicolons inside strings/comments.

**File(s):** `lua/poste/sql/init.lua`, `crates/poste-core/src/sql_context/mod.rs`, `tests/`

### [ ] P2-5: Clean up stale tests/comments

Some tests still contain `BUG`, `BEFORE FIX`, or `CURRENT/Ideal` comments that no longer match the current behavior.

**Action:**
1. Audit `tests/sql_completion_edge_spec.lua` and Rust sql_context tests.
2. Convert stale comments into assertions or remove them.
3. Fix the unused variable warning in `test_extract_join_with_schema_and_alias`.

**File(s):** `tests/`, `crates/poste-core/src/sql_context/mod.rs`

---

## Summary by Priority

| Priority | Done | Total | Theme |
|----------|------|-------|-------|
| P0 | 5/5 | 5 | Deterministic authority, schema correctness, test the real orchestration path |
| P1 | 5/5 | 5 | SQL coverage gaps and dialect awareness |
| P2 | 3/5 | 5 | UX polish, performance, stale test cleanup |

Total: 15 items

---

## Quick Start for Agent

1. Read `.opencode/skills/sql-completion/SKILL.md`.
2. Run `cargo test -p poste-core` to get the Rust baseline.
3. Reproduce the target case with `target/debug/poste context detect <offset>`.
4. Implement Rust-side parsing/context first.
5. Preserve `schema` and `alias` through CLI/Lua when table columns are involved.
6. Update Lua only for orchestration, UI dispatch, async fetching, or explicit legacy fallback.
7. Add Rust tests plus Lua integration tests when the orchestrator behavior changes.
8. Run `cargo test -p poste-core` and the relevant Lua tests.
