# Semantic Statement Boundary — Design Notes

> **Status**: Not planned. Design notes for future reference.
> **Filed**: After P4 (Persistent Context Service) — 2026-06-11

## Problem

Poste currently relies on `;` (semicolon) for statement boundary detection in both the completion path (Rust `find_statement_token_range` / `find_statement_span`) and the execution path (Lua `find_stmt_lines` / `extract_stmt_at_cursor`).

This means:

1. A SQL file like `SELECT 1\nSELECT 2` (no `;`) is treated as one statement.
2. Users must remember to terminate every statement with `;`.
3. DataGrip and similar tools handle `;`-free files by recognizing statement boundaries from SQL grammar alone.

## Scope of Change

### Path 1: Completion (Rust)

**Files**: `crates/poste-core/src/sql_context/statements.rs`, `context.rs`

Current flow: tokenize → find `Semi` tokens → return statement span before/after cursor.

Proposed: tokenize → identify statement-start keywords (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `CREATE`, `ALTER`, `DROP`, `WITH`, `SHOW`, `COPY`, `EXPLAIN`, `CALL`, `BEGIN`, `COMMIT`, `ROLLBACK`, `GRANT`, `REVOKE`, `TRUNCATE`, `VACUUM`, `SET`, `USE`, etc.) → return statement span based on keyword boundaries + paren-depth tracking (already exists in scope.rs) to avoid subquery confusion.

**Subquery/CTE safety**: The paren-depth tracking from `scope.rs` already handles `SELECT * FROM (SELECT 1)` — the inner `SELECT` is not treated as a new top-level statement. The same tracking prevents `SELECT id IN (SELECT id FROM t)` from splitting on the inner `SELECT`.

**Edge cases**:
- `WITH` clause: `WITH cte AS (SELECT ...) SELECT ...` — one statement.
- `UNION` / `INTERSECT` / `EXCEPT`: part of the same statement.
- `;` still works as a hard boundary for disambiguation.
- `BEGIN ... END` blocks (PL/pgSQL, stored procedures): complex, may need explicit boundaries.

### Path 2: Execution (Lua)

**Files**: `lua/poste/sql/statement.lua` (no Rust equivalent — see below)

Current: `find_stmt_lines()` scans for `;` characters (with known bugs: `;` in strings/comments causes false splits).

Proposed: either (a) add a Rust function `find_statement_ranges` that takes raw SQL text and returns `Vec<(usize, usize)>` for all statement line ranges, or (b) port the keyword-based boundary logic to Lua.

**Complexity**: Higher than Path 1. Lua currently handles multi-statement execution with visual selection, which involves directive extraction, statement counting, and indicator placement. The execution path also needs to handle `BEGIN ATOMIC ... END`, `CREATE FUNCTION ... $$ ... $$`, and other multi-line constructs that `;`-free detection may struggle with.

## Key Decisions Still Open

| Question | Options |
|----------|---------|
| Should `;` remain as an optional hard boundary? | Yes — keeping it makes disambiguation trivial when present |
| Should the Rust completion path and Lua execution path share boundary logic? | Ideally yes — add a Rust function callable by both |
| What about `CREATE FUNCTION ... AS $$ ... $$` (dollar-quoted bodies)? | Dollar-quoted strings are already single tokens in the tokenizer — they should not affect boundaries |
| What about `BEGIN` / `COMMIT` / `ROLLBACK` in transaction blocks? | These ARE statement-start keywords, not block delimiters — each is its own statement |

## Relationship to Scope Resolver (P3)

P3's `scope.rs` introduced `resolve_scope()` which knows about:
- Paren depth (subquery isolation)
- CTE registration
- Derived table aliases

The same paren-depth tracking is essential for semantic boundary detection — it prevents inner `SELECT` from being treated as a new top-level statement.

## Estimated Effort

| Sub-task | Effort | Dependencies |
|----------|--------|-------------|
| Add statement-start keyword list to Rust tokenizer | Small | None |
| Replace `find_statement_token_range` with keyword-based detection | Medium | Keyword list, paren-depth |
| Replace `find_statement_span` (CLI serve `stmt` method) | Medium | Same |
| Update golden fixtures for statement boundaries | Small | After Rust changes |
| Update Lua execution path | Large | Requires Rust API or port |

## Testing

- Update `statement_boundaries.json` golden fixture (remove `;` requirement)
- Add test cases: `SELECT 1\nSELECT 2`, `WITH cte AS (SELECT 1) SELECT * FROM cte`, subquery not splitting, `;`-optional cases
- Lua tests for execution path if changed

## References

- `crates/poste-core/src/sql_context/statements.rs` — current `find_statement_span`
- `crates/poste-core/src/sql_context/context.rs:170` — `find_statement_token_range`
- `crates/poste-core/src/sql_context/scope.rs` — paren-depth tracking for subquery isolation
- `lua/poste/sql/statement.lua` — `find_stmt_lines`, `extract_stmt_at_cursor`
- `docs/sql-completion-p0-p4/p0/poste-sql-file-syntax.en.md §3` — current boundary rules
