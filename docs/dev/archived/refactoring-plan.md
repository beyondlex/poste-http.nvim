# Refactoring Plan

**Date:** 2026-06-10
**Based on:** `docs/refactoring-report.md`
**Skill:** `poste-refactor`

---

## Summary

This plan addresses 24 findings from the full-repo scan. Changes are grouped by theme and ordered from low-risk (safe, mechanical) to higher-risk (behavior-sensitive). Each change is designed to be applied and verified independently.

---

## Change 1: Fix Test Compilation Errors

**Target:** `crates/poste-exec/src/sql_introspect.rs:770-820`
**Risk:** Low
**Description:** Replace all 9 occurrences of `IntrospectType::from_str("...").unwrap()` with `IntrospectType::parse_str("...").unwrap()` in test code. The enum has a `parse_str` method but no `FromStr` trait impl.

**Files to modify:**
- `crates/poste-exec/src/sql_introspect.rs`

**Verify:** `cargo test -- -D warnings` (should fix 9 of the 9 errors)

---

## Change 2: Fix Clippy `collapsible_match` Warning

**Target:** `crates/poste-core/src/sql_context/tokenizer.rs:312`
**Risk:** Low
**Description:** Collapse the nested `if` into the outer `match` arm as suggested by clippy.

**Before:**
```rust
TokenKind::Ident | TokenKind::Keyword | TokenKind::NumLit => {
    if tokens[prev].end == offset {
        return tokens[prev].text(sql).to_string();
    }
}
```

**After:**
```rust
TokenKind::Ident | TokenKind::Keyword | TokenKind::NumLit
    if tokens[prev].end == offset =>
{
    return tokens[prev].text(sql).to_string();
}
```

**Files to modify:**
- `crates/poste-core/src/sql_context/tokenizer.rs`

**Verify:** `cargo clippy -- -D warnings`

---

## Change 3: Extract Shared Row-to-JSON Conversion

**Target:** `crates/poste-exec/src/sql_executor.rs:260-736`
**Risk:** High
**Description:** `pg_value_to_json()` (234 lines) and `mysql_value_to_json()` (237 lines) are structurally identical — both take a typed row + index, check for null, then match on type names to produce a `serde_json::Value`. Extract the shared pattern into a helper trait or macro to eliminate duplication.

**Approach:**
1. Create a `DbValueConverter` trait with methods like `try_get_int`, `try_get_float`, `try_get_bool`, `try_get_string`, `try_get_json` etc., parameterized by the row type
2. Implement for `PgRow` and `MySqlRow` (and possibly `SqliteRow`)
3. Reduce each function to a thin wrapper that delegates to the trait

**Files to modify:**
- `crates/poste-exec/src/sql_executor.rs`

**Verify:**
- `cargo test -- -D warnings`
- Functional check: run a Postgres and MySQL query and verify identical JSON output

---

## Change 4: Split `column_def_sql()` into Per-Dialect Trait Methods

**Target:** `crates/poste-exec/src/sql_ddl.rs:39-598`
**Risk:** High
**Description:** `column_def_sql()` is a 560-line free function that takes a `quote` closure and dispatches internally on dialect. The `DdlGenerator` trait already defines per-dialect structs (`PostgresDdl`, `MysqlDdl`, `SqliteDdl`) but `column_def_sql()` is not a trait method.

**Approach:**
1. Add `fn column_def_sql(&self, col: &ColumnDef) -> String` to the `DdlGenerator` trait
2. Implement on `PostgresDdl`, `MysqlDdl`, `SqliteDdl` with their respective logic
3. Keep the free function as a dispatcher calling `ddl_for(dialect)?.column_def_sql(col)` for backward compat, or inline callers

**Files to modify:**
- `crates/poste-exec/src/sql_ddl.rs`

**Verify:**
- `cargo test -- -D warnings`
- Verify `poste run` produces identical DDL output for all 3 dialects

---

## Change 5: Split `lua/poste/init.lua` into Submodules

**Target:** `lua/poste/init.lua` (1448 lines)
**Risk:** Medium
**Description:** Split the large init.lua into focused submodules following the project's existing pattern (see `sql/init.lua` → `statement.lua` + `introspect.lua`).

**Proposed split:**
- `lua/poste/commands.lua` — `M.run_request()`, `M.jump_next()`, `M.jump_prev()` (~250 lines)
- `lua/poste/navigation.lua` — `M.goto_definition()`, `M.goto_references()`, `M.show_view()` (~600 lines)
- `lua/poste/setup.lua` — `M.setup()`, `M.set_env()`, `M.get_env()` (~530 lines)
- `lua/poste/init.lua` — re-exports from submodules (~70 lines)

**Files to create/modify:**
- `lua/poste/commands.lua` (new)
- `lua/poste/navigation.lua` (new)
- `lua/poste/setup.lua` (new)
- `lua/poste/init.lua` (rewrite as re-export hub)

**Verify:**
- `tests/run.sh` — Lua tests pass
- Manual smoke test: open an `.http` file, run a request, trigger completion, verify navigation still works

---

## Change 6: Split `lua/poste/http/completion.lua` into Submodules

**Target:** `lua/poste/http/completion.lua` (1330 lines)
**Risk:** Medium
**Description:** Split the large completion module into focused submodules.

**Proposed split:**
- `lua/poste/http/completion_context.lua` — `detect_context()`, `detect_script_context()`, `get_items_for_context()` (~300 lines)
- `lua/poste/http/completion_cache.lua` — `ensure_cache_autocmd()`, `get_buffer_cache()` (~50 lines)
- `lua/poste/http/completion_sources.lua` — `collect_file_vars()`, `collect_request_vars()`, `collect_env_vars()`, `collect_request_names()` (~100 lines)
- `lua/poste/http/completion.lua` — `M.new()`, `M.register()`, `M.status()` (~700 lines remaining)

**Files to create/modify:**
- `lua/poste/http/completion_context.lua` (new)
- `lua/poste/http/completion_cache.lua` (new)
- `lua/poste/http/completion_sources.lua` (new)
- `lua/poste/http/completion.lua` (trimmed)

**Verify:**
- `tests/run.sh` — Lua tests pass
- Manual smoke test: trigger HTTP completion in Neovim

---

## Change 7 (Optional): Replace Safe `unwrap()` with `?` / `expect()`

**Target:** Multiple files (see report items 19-22)
**Risk:** Low
**Description:** Replace production `unwrap()` calls with proper error propagation where easy. The `Regex::new()` calls on static strings are infallible and can stay as-is.

**Files to modify:**
- `crates/poste-core/src/sql_parser.rs:82,101` — `chars.next().unwrap()` → handle `None` branch
- `crates/poste-cli/src/main.rs:164` — `parent().unwrap()` → `context("...")?`
- `crates/poste-cli/src/main.rs:173,493` — `to_str().unwrap()` → `context("...")?`
- `crates/poste-core/src/sql_context/statements.rs:13` — `offsets.last().unwrap()` → safe via `if let Some(last) = offsets.last()`

**Verify:** `cargo test -- -D warnings`

---

## Execution Order

| Step | Change | Risk | Depends On |
|------|--------|------|------------|
| 1 | Fix test compilation errors | Low | Nothing |
| 2 | Fix clippy collapsible_match | Low | Nothing |
| 3 | Extract shared row-to-JSON conversion | High | Step 1 (tests must compile to verify) |
| 4 | Split column_def_sql() into per-dialect methods | High | Step 1 |
| 5 | Split lua/poste/init.lua | Medium | Nothing |
| 6 | Split lua/poste/http/completion.lua | Medium | Nothing |
| 7 | Replace safe unwrap() calls | Low | Nothing |

Steps 5 and 6 are independent of each other and of the Rust changes.

---

## Verification Commands

```bash
# After each Rust change:
cargo test -- -D warnings

# After each Lua change:
tests/run.sh

# Functional verification (critical refactors):
cargo build && cargo run -- run tests/sql/queries/postgres.sql --line 4 --env dev > /tmp/output-before.txt
# (apply change)
cargo build && cargo run -- run tests/sql/queries/postgres.sql --line 4 --env dev > /tmp/output-after.txt
diff /tmp/output-before.txt /tmp/output-after.txt

# Final validation:
cargo test -- -D warnings
tests/run.sh
cargo clippy -- -D warnings
```

---

## Validation Checklist

- [ ] `cargo test -- -D warnings` passes
- [ ] `tests/run.sh` passes (Lua tests)
- [ ] `cargo clippy -- -D warnings` has no new warnings
- [ ] Public APIs (Rust `pub`, Lua `M.*`) remain unchanged in name and shape
- [ ] CLI output format and JSON response fields are identical
- [ ] No new external dependencies added
- [ ] HTTP/SQL isolation boundaries respected
- [ ] No dead code left behind