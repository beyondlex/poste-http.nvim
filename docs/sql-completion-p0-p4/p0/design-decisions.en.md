# P0 Design Decisions & Trade-offs

> **This document has been revised after the P0 review meeting** (2026-06-11), and subsequently revised again to reflect the complete removal of `###`. Revisions triggered by:
> 1. `###` has been fully removed from the Poste file syntax, no longer an architecture assumption
> 2. No real users yet — breaking changes have no cost, cleaner designs can be chosen
>
> See `meeting-minutes.md` for details. Decisions D1, D2, D5, D6 have been updated.

For discussion before proceeding to P1-P4.

---

## Decision 1: Blank Line Boundary — Pre-P3 Temporary, Removed After P3

**Current**: Rust `find_statement_token_range()` treats 2+ consecutive newlines as a statement boundary, preventing table leakage across visually separated statements.

**Argument for KEEP** (pre-P3):
- After `###` removal and before ScopeResolver, the blank-line boundary is the **only completion-layer mechanism** preventing cross-statement table leakage.
- It works correctly in practice, with no known defects.

**Argument for REMOVE** (post-P3):
- P3 ScopeResolver replaces blank-line heuristics by understanding statement structure (CTE/subquery/alias scopes), more accurate with no false positives.
- Users may inadvertently use 2+ blank lines within a single logical statement.

**Decision**: ✅ **Keep temporarily before P3, remove after P3 ScopeResolver is complete.**

---

## Decision 2: `in_string` / `in_comment` Return Behavior

**Current**: Rust returns `None` from `detect_context()` when cursor is in string/comment. CLI fallback emits `keyword` + `in_string=true` + `in_comment=true` (both true). Lua checks these flags to suppress items.

**Problem**: When `in_string=true` AND `in_comment=true`, Lua cannot distinguish "in string" from "in comment" from "Rust returned None for another reason".

**Options**:
1. Keep current behavior. Accept the ambiguity. (Simplest.)
2. Return separate bools: `in_string` and `in_comment` can both be false independently. Don't set both to true on error. (Better for debugging.)
3. Return an explicit context even when in string/comment, e.g., `ctx_type: "string"` or `ctx_type: "comment"`.

**Original recommendation**: **Option 2**. Fix the CLI fallback: when Rust returns `None`, set `in_string=false, in_comment=false` and let Lua decide. The string/comment detection at the Lua level is adequate for suppression.

**Revised to Option 3** in the P0 review meeting. Rationale: (a) no real users means breaking changes have no cost; (b) explicit `ctx_type` eliminates ambiguity at the contract level — a cleaner design. Rust adds `ContextType::String` and `ContextType::Comment`. Lua checks ctx_type directly.

---

## Decision 3: `ctx_schema` for `SchemaTable` Context

**Current**: `SchemaTable` returns `ctx_schema: null`. The schema name is in `ctx_data`.

**Question**: Should `ctx_schema` contain the schema name for `SchemaTable`?

| Type | ctx_data | ctx_schema (current) | ctx_schema (proposed) |
|------|----------|---------------------|----------------------|
| `dot_column` | `"users"` | `"public"` | `"public"` |
| `schema_table` | `"inventory"` | `null` | `"inventory"` |

**Pro**: Consistency. Lua code could use `ctx_schema` uniformly instead of checking `ctx_type`.

**Con**: Breaking change if any Lua code relies on `ctx_schema` being `null` for `SchemaTable`. But a spot check shows Lua `completion.lua` does NOT check `ctx_schema` for `schema_table` — it uses `ctx_data` directly.

**Recommendation**: **Add `ctx_schema` for `SchemaTable`** in P2 (alongside golden fixtures). Lua `completion.lua` can continue using `ctx_data` for now; no urgent change needed.

---

## Decision 4: `version` Field Granularity

**Question**: Should `version` be a single int or a `{protocol, data}` structure?

| Approach | Pros | Cons |
|----------|------|------|
| Single int `version: 1` | Simple. Bump on breaking change. | Coarse-grained. |
| `version: { protocol: 1, data: 1 }` | Fine-grained. Can evolve data fields without incrementing protocol. | Added complexity. |

**Recommendation**: **Single int**. Start at `1`. If we ever need field removal, bump to `2` and add a migration shim in Lua that detects old version and transforms the result.

---

## Decision 5: Lua `completion_ctx.lua` — Keep or Deprecate?

**Current**: `completion_ctx.lua` provides `detect_context()` (regex heuristic fallback), `extract_from_tables()`, `get_tables_and_alias()`. It is the source of many boundary bugs.

**P1 plan**: Demote to fallback-only. No new features in Lua fallback after P1.

**Question**: Should we deprecate it entirely after P4 (persistent context service)?

**Pros of removing**:
- Eliminates all buggy heuristic paths.
- Forces Rust to handle all SQL context.

**Cons of removing**:
- No-binary environments (e.g., users who `:Lazy` install and haven't built the Rust binary).
- Users who run Neovim without the `poste` CLI.
- "Lua-only" mode for debugging.

**Recommendation**: **Mark `@deprecated` in P1. Remove in P3 after golden fixtures validate Rust coverage.** Since there are no real users yet, we don't need to keep the fallback indefinitely. P1 marks it deprecated, P2 golden fixtures confirm Rust handles all scenarios, P3 removes it.

---

## Decision 6: Rust Should Know About `###`?

**Current**: `###` has been fully removed from the Poste file syntax. SQL files no longer contain `###` lines.

**Impact**: This decision is moot. Rust does not need to be aware of `###` because `###` no longer exists in the file format.

---

## Decision 7: Test Migration Strategy

| Current test file | P0-P2 plan |
|-------------------|------------|
| `tests/sql_completion_spec.lua` | Keep. Maintained as UI/cache/integration tests. |
| `tests/sql_completion_edge_spec.lua` | Split into: (a) Lua fallback behavior tests under `legacy_completion=true`, (b) delete/update `BUG`/`BEFORE FIX` tests that Rust now handles correctly. |
| `crates/poste-core/src/sql_context/tests.rs` | Keep and extend. Add golden fixtures (P2). |
| `crates/poste-core/tests/sql_context_golden.rs` | New (P2). Golden fixture runner. |

**Question**: Should `BUG`-marked Lua tests be updated as soon as Rust handles the case, or wait until P2 golden fixtures?

**Recommendation**: **Update immediately in P1** when routing to Rust first. If Rust handles the case correctly, the `BUG` test will produce the correct output through Rust. If the test is hardcoded to Lua heuristic, it will fail — this is the desired signal that the old behavior was wrong.

---

## Decision 8: `@connection` / `@database` — Parse in Rust or Lua?

**Current**: Handled in both:
- Lua: `completion.lua` lines 146-196 (fast paths before Rust)
- Rust: `detectors.rs` `try_directive()` (handles tokens within SQL body)

**Problem**: Double-handling creates potential for inconsistency.

**Recommendation**: **Lua owns directives completely.** P1 should:
1. Strip `-- @` lines before sending to Rust (already done for the body, but check the `--` prefix handling in Rust tokenizer).
2. Remove `try_directive()` from `detectors.rs` — or keep as a safety net by returning `None` instead of `Connection`.
3. Rust should return `keyword` for any `-- @` content it receives (which should be none if Lua strips correctly).

**But**: The current Lua implementation also handles `--@connection` (without space after `--`). Rust's `try_directive()` checks for `@connection`/`@database` tokens anywhere. Keeping both is acceptable as belt-and-suspenders.

---

## Decision 9: `prefix` Semantics

**Current**: `prefix` is the partial identifier typed so far at cursor position.

| Input | Offset | `prefix` |
|-------|--------|----------|
| `SELECT * FROM au` | 15 | `"au"` |
| `SELECT * FROM ` | 15 | `""` |
| `SEL` | 3 | `"SEL"` |
| `SELECT col` (cursor after space) | 11 | `""` |

**Question**: Should `prefix` include the dot character for `dot_column`?

| Input | Offset | Current `prefix` | Proposed |
|-------|--------|-----------------|----------|
| `users.us` | 8 | `"us"` | `"us"` (same — dot is before cursor) |
| `users.█` | 6 | `""` | `""` |
| `u.na` | 4 | `"na"` | `"na"` |

The current behavior is correct: `prefix` is the text after the last `.` (or the partial identifier). The `ctx_data` holds the table/alias name before the dot.

**Recommendation**: **No change needed.** `prefix` is always the unbroken `[a-zA-Z0-9_]` string at the cursor. Dot handling is `ctx_data`'s responsibility.

---

## Decision 10: Functions List — Inclusion Criteria

**Current**: `functions.rs` returns all known functions for the dialect. The list is used to:
1. Display functions as completion items when context is `column` or `keyword`.
2. NOT used for context detection (functions are not keywords; they're `Ident` tokens).

**Question**: Should function-completion-only be moved to Lua entirely?

**Pro**: Simplify Rust. `functions` field in JSON is just metadata, not logic.

**Con**: Rust is the authoritative source for dialect-specific functions. Keeping it in Rust ensures correctness and avoids drift.

**Recommendation**: **Keep in Rust.** The `functions` field is cheap to compute and provides the single source of truth. Lua's `SQL_FUNCTIONS` list is only used when Rust is unavailable, and drift tests (`test_lua_fallback_functions_are_subset`) ensure it stays in sync.

---

## Summary: P1 Priority Actions (Revised Post-P0 Review)

The following plan was revised during the P0 design review meeting (see `meeting-minutes.md`). Key changes in **bold**:

| # | Action | Original | Revised | Rationale |
|---|--------|----------|---------|-----------|
| 1 | Strip `-- @` lines before Rust call | Same | Same | Directives are Poste syntax, not SQL |
| 2 | `try_directive()` in Rust detectors | Remove entirely | **Degrade to safety net (return None)** | Keep belt-and-suspenders as safety |
| 3 | Fix CLI fallback: `in_string` + `in_comment` | Option 2 | **Option 3: `ContextType::String/Comment`** | No users to break; cleaner contract |
| 4 | Add `version` field | Same | Same | P0 contract requirement |
| 5 | `statement`/`block` fields | Compute in Lua | Same (not in Rust output) | `###` is not a completion concept |
| 6 | Update `BUG`-marked edge tests | Same | Same | P1 routing validates correctness |
| 7 | Blank line boundary | Keep until P3 then remove | **Remove after P3** | ScopeResolver replaces blank-line heuristics |
| 8 | Add `ctx_schema` for `SchemaTable` | P2 | **P1 (alongside version)** | No breaking change, no need to defer |
