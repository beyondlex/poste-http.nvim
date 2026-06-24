# Poste SQL Completion P0-P4 Implementation Guide

This document is written for future AI agents implementing the work. The goal is to move Poste SQL completion from "Rust context + Lua heuristic fallback + scattered regression tests" to a verifiable, iterative, low-latency context completion system.

Core principles:

- Do not immediately rewrite this as a full LSP.
- Do not immediately fork `sqlparser-rs` or hand-write a complete EBNF parser.
- Productize the existing Rust `sql_context` first, and unify boundary/context decisions.
- Avoid breaking existing SQL execution, database browser, dataset panel, and HTTP completion features.
- Tests may be changed only when old tests encode known wrong behavior or old implementation details.

## Current Code State

Relevant files:

- `lua/poste/sql/completion.lua`: completion orchestrator. It currently combines Lua heuristic detection, Rust context detection, and item dispatch.
- `lua/poste/sql/completion_ctx.lua`: Lua fallback. It contains regex-based `detect_context()` and `extract_from_tables()`, which are the source of many boundary bugs.
- `lua/poste/sql/completion_data.lua`: keywords, functions, table/column cache, binary lookup, and metadata fetch.
- `lua/poste/sql/statement.lua`: SQL statement extraction. It already calls `poste context stmt`, but still has Lua fallback and SQL-file-specific patches.
- `crates/poste-core/src/sql_context/`: Rust tokenizer/context detector/table extraction/statement span.
- `crates/poste-cli/src/main.rs`: already has `poste context detect <offset> --dialect <dialect>` and `poste context stmt <cursor_line>`.
- `tests/sql_completion_spec.lua`, `tests/sql_completion_edge_spec.lua`: Lua completion tests. Some edge specs explicitly record "BEFORE FIX/CURRENT bug"; these are not long-term correct behavior.
- `crates/poste-core/src/sql_context/tests.rs`: Rust context unit tests.

Out of scope:

- Do not change HTTP completion: `lua/poste/http/*`, `lua/poste/completion.lua`.
- Do not change SQL executor behavior unless a stage explicitly needs metadata/cache support.
- Do not delegate `-- @connection` or `-- @database` semantics to a generic SQL parser. They are part of the Poste file format.

## P0: Define Poste SQL File Syntax And Context Contract

Goal: define correctness before adding more fixes.

Add documentation:

- `completion/poste-sql-file-syntax.zh.md`
- `completion/poste-sql-file-syntax.en.md`

Minimum content:

1. File structure
   - Directives + SQL statements (separated by `;`). Directives can appear at the file top or inline between statements.
   - `.sql`, `.mysql`, and `.sqlite` share the same file structure. Dialect only affects SQL context and metadata.

2. Directive rules
   - File-level directives at the top of the file apply to all statements.
   - Inline directives between statements switch connection/database from that point, staying active for subsequent statements until the next same-typed directive.
   - Directive lines are excluded from SQL statement parsing and must not trigger SQL keyword/table/column completion.
   - Cursor after `-- @connection ` completes connections.
   - Cursor after `-- @database ` completes databases/schemas.

3. Statement boundaries
   - Hard boundary: `;`, except inside strings/comments/dollar quotes.
   - EOF ends the current statement.
   - Decide and document whether blank lines are soft boundaries. Current Rust `detect_context` has a blank-line separator for token ranges, while `find_statement_span()` is mainly semicolon-based. Recommendation: completion context may treat consecutive blank lines as a soft boundary; execution statement extraction should not split solely on a single blank line.

4. Cursor context JSON contract
   `poste context detect` JSON should stably include:
   - `ctx_type`
   - `ctx_data`
   - `ctx_schema`
   - `prefix`
   - `tables`
   - `functions`
   - `in_string`
   - `in_comment`

   Suggested additive fields:
   - `version`: protocol version, e.g. `1`
   - `statement`: `{ "start_line": n, "end_line": n }`
   - `block`: `{ "start_line": n, "end_line": n }`

5. Context type semantics
   - `keyword`: SQL keywords, functions, fallback items.
   - `table`: tables, views, queryable objects, and sometimes databases/schemas.
   - `column`: visible columns and functions in the current scope.
   - `dot_column`: columns after `alias.` or `table.`.
   - `schema_table`: tables after `schema.`.
   - `insert_column`: columns inside `INSERT INTO t (`.
   - `connection`, `database`, `datatype`.

Acceptance:

- Every rule maps to an existing or planned test.
- The document clearly identifies old tests that encode wrong behavior and may be changed during P1/P2.
- This stage can pass without code changes.

## P1: Make Rust Context The Default Single Source Of Truth

Goal: remove Lua/Rust double truth. Lua should handle UI, metadata, and degraded fallback only.

Current issues:

- `get_items()` in `lua/poste/sql/completion.lua` calls `ctx.detect_context(line_before)` before trying Rust.
- `completion_ctx.lua` fallback does not have complete string/comment/subquery/CTE awareness.
- `tests/sql_completion_edge_spec.lua` still directly tests many Lua heuristic behaviors.

Implementation steps:

1. Add a thin wrapper
   - File: `lua/poste/sql/completion.lua`
   - Suggested name: `detect_context_for_completion(bufnr, line_before, cursor_line)`
   - Default flow:
     1. Keep directive fast paths in Lua, because they are Poste file syntax, not SQL grammar.
     2. For non-directive contexts, call Rust `try_rust_context()`.
     3. Use Rust result when it succeeds.
     4. Call `completion_ctx.detect_context()` only when Rust is unavailable.

2. Tighten legacy switch semantics
   - `vim.g.poste_sql_legacy_completion = true`: Lua-only fallback for debug or no-binary environments.
   - `vim.g.poste_sql_legacy_completion = "rust"`: Rust-only, no fallback, for regression testing.
   - Default `nil`: Rust first; Lua heuristic must not override Rust for non-directive SQL.

3. Clarify `_test` exports
   - Current tests use `sql_comp._test.detect_context` to test Lua heuristic directly.
   - Add:
     - `_test.detect_lua_context`
     - `_test.detect_rust_context`, when the binary exists.
     - `_test.get_items` or `_test.detect_context_for_completion`, for real completion path tests.
   - Do not keep an ambiguous `_test.detect_context` name pointing to Lua heuristic.

4. Keep Lua fallback, but demote its authority
   - Do not delete `completion_ctx.lua`.
   - Update its header comment: fallback-only when Rust binary is unavailable.
   - Add new context features to Rust first. Add to Lua fallback only when no-binary mode truly needs them.

5. Keep completion item dispatch in Lua
   - Table, column, dot-column, and related item building can stay in `completion.lua`.
   - This is the right layering: Rust decides context; Lua combines Neovim state and metadata cache into items.

Testing strategy:

- Rust unit tests stay in `crates/poste-core/src/sql_context/tests.rs`.
- Lua completion path tests should test final items or Rust strict mode, not wrong Lua heuristic behavior.
- Assertions in `tests/sql_completion_edge_spec.lua` marked `BEFORE FIX` and describing bugs may be updated to the correct behavior or moved to Lua fallback-only tests.

Acceptance commands:

```bash
cargo test -p poste-core sql_context
tests/run.sh
```

Acceptance criteria:

- Default completion is no longer overridden by Lua heuristic when Rust context exists.
- Basic keyword/table/directive completion still works in degraded mode when the Rust binary is missing.
- `vim.g.poste_sql_legacy_completion = "rust"` can reproduce Rust-only behavior.

## P2: Add Cursor-Marker Golden Tests

Goal: upgrade context testing from scattered bug cases to stable specification tests.

Suggested fixture layout:

```text
tests/fixtures/sql_context/
  basic_select.json
  directives.json
  statement_boundaries.json
  strings_comments.json
  dot_context.json
  cte_subquery_scope.json
  dml_insert_update_delete.json
  dialect_postgres.json
  dialect_mysql.json
  dialect_sqlite.json
```

Suggested fixture format:

```json
[
  {
    "name": "dot column from alias",
    "dialect": "postgres",
    "sql": "SELECT u.█ FROM users u JOIN orders o ON u.id = o.user_id",
    "expect": {
      "ctx_type": "dot_column",
      "ctx_data": "u",
      "ctx_schema": null,
      "prefix": "",
      "tables": [
        { "name": "users", "alias": "u", "schema": null },
        { "name": "orders", "alias": "o", "schema": null }
      ],
      "in_string": false,
      "in_comment": false
    }
  }
]
```

Rules:

- Use `█` as the cursor marker.
- The test runner removes the marker and computes the byte offset.
- Compare `tables` order-insensitively unless order is explicitly part of the contract.
- For `functions`, usually assert contains/does-not-contain instead of full equality.
- For cursor inside string/comment, `in_string` or `in_comment` must be accurate. Current CLI sets both to true when Rust returns `None`; P2 may either record this as a known limitation or fix it.

Runner:

- Prefer Rust integration/unit tests to avoid Neovim dependency:
  - `crates/poste-core/tests/sql_context_golden.rs`, or load fixtures inside `crates/poste-core/src/sql_context/tests.rs`.
  - If workspace fixture loading is inconvenient, start with inline Rust cases.
- Keep only a small number of Lua end-to-end item tests:
  - directive items
  - table items from cache
  - column items from cache
  - blink/nvim-cmp adapter shape

Old test handling:

- `tests/sql_completion_spec.lua`: keep UI/item/cache tests.
- `tests/sql_completion_edge_spec.lua`: split into:
  - Lua fallback behavior tests, only under legacy mode.
  - Rust context integration tests, using golden expectations.
- If old comments say `BUG`, `BEFORE FIX`, or `known limitation`, update the tests after fixing the behavior. Do not preserve wrong behavior for compatibility.

Acceptance commands:

```bash
cargo test -p poste-core sql_context
cargo test -p poste-core --test sql_context_golden
tests/run.sh
```

Acceptance criteria:

- Every new context behavior has a fixture first.
- New bug fix workflow: add failing fixture, then change Rust context.
- Lua tests are no longer responsible for full SQL grammar coverage.

## P3: Extract ScopeResolver

Goal: move from "scan tokens and collect tables" to an explicit scope model for CTEs, subqueries, aliases, and dot context.

Current issues:

- `crates/poste-core/src/sql_context/tables.rs` extracts table refs from a token stream but returns a flat `Vec<TableRef>`.
- A flat list cannot represent nested queries, CTEs, derived tables, shadowing, or visibility.
- `detect_context()` calls `tables::extract_tables(stmt_tokens, sql)` repeatedly in special detector branches.

Suggested new module:

```text
crates/poste-core/src/sql_context/scope.rs
```

Suggested data structures:

```rust
pub(crate) struct QueryScope {
    pub tables: Vec<TableRef>,
    pub ctes: Vec<CteRef>,
    pub aliases: Vec<AliasRef>,
}

pub(crate) struct CteRef {
    pub name: String,
}

pub(crate) struct AliasRef {
    pub alias: String,
    pub target: AliasTarget,
}

pub(crate) enum AliasTarget {
    Table { name: String, schema: Option<String> },
    Cte { name: String },
    DerivedTable,
}
```

First-stage requirements:

- Top-level `FROM` / `JOIN` / `UPDATE` / `INSERT INTO` / `DELETE FROM`.
- Schema-qualified `schema.table`.
- For `database.schema.table`, preserve the lookup-friendly schema/table.
- Alias support: bare alias and `AS alias`.
- CTE name registration: `WITH cte AS (...) SELECT ... FROM cte`.
- Do not leak tables from CTE bodies into outer scope.
- Do not leak tables from subqueries into outer scope.
- Derived table alias is visible: `FROM (SELECT ...) x`; `x.` may resolve to `DerivedTable`, but column completion may initially fall back to keyword/function unless derived output columns are implemented later.

Implementation steps:

1. Add `scope.rs`
   - Input: statement token slice + SQL source.
   - Output: `QueryScope`.
   - Initially reuse helpers from `tables.rs` if useful, but avoid external dependencies on flat extraction.

2. Make `tables.rs` a compatibility layer
   - `extract_tables()` can call `scope::resolve_scope()` internally and return `scope.tables`.
   - Keep current public behavior to reduce breakage.

3. Update `detect_context()`
   - Resolve scope once per detect call.
   - Use a helper to build `ContextResult`, avoiding repeated `functions::known_functions_for_dialect()` and `tables::extract_tables()` calls.

4. Dot context lookup
   - Keep the JSON contract: `DotColumn { table: "u" }`.
   - Lua can still use aliases from `tables` to find the real table.
   - Rust may add `ctx_schema`, but do not remove existing fields.

5. Required CTE/subquery tests:

```sql
WITH recent AS (SELECT * FROM orders)
SELECT * FROM recent r WHERE r.█
```

```sql
SELECT * FROM users u
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id)
AND █
```

The second case must not expose `orders` columns at the outer `AND`.

Acceptance criteria:

- Existing flat table tests still pass.
- New CTE/subquery golden fixtures pass.
- `completion.lua` does not need to understand CTE/subquery details; it only consumes the Rust result.

## P4: Add Persistent Context Service

Goal: avoid spawning `poste context detect` through `vim.fn.system()` on every completion cache miss, without implementing a full LSP.

Current issue:

- `try_rust_context()` in `completion.lua` currently executes:

```lua
vim.fn.system("<poste> context detect <offset> --dialect ...", sql_text)
```

- Process startup cost increases insert-mode latency.
- Current `_ctx_cache_key` only caches the last result and does not cover multiple buffers/cursors/blocks well.

Suggested CLI:

```bash
poste context serve
```

Protocol: line-delimited JSON over stdin/stdout. One request per line, one response per line.

Request example:

```json
{
  "id": 1,
  "method": "detect",
  "dialect": "postgres",
  "sql": "SELECT * FROM users WHERE ",
  "offset": 26
}
```

Response example:

```json
{
  "id": 1,
  "ok": true,
  "result": {
    "ctx_type": "column",
    "ctx_data": null,
    "ctx_schema": null,
    "prefix": "",
    "tables": [{ "name": "users", "alias": null, "schema": null }],
    "functions": ["COUNT"],
    "in_string": false,
    "in_comment": false
  }
}
```

Error response:

```json
{
  "id": 1,
  "ok": false,
  "error": "invalid request"
}
```

Implementation steps:

1. Rust CLI
   - Add `Serve` to `ContextAction`.
   - The serve loop only handles context/stmt; it must not do database introspection.
   - Reuse `make_detect_response()`.
   - Each line is independent; one bad request must not terminate the server.
   - Exit on EOF.

2. Lua client
   - Add `lua/poste/sql/context_client.lua`.
   - Own `vim.fn.jobstart()`, request ids, pending callbacks, stdout line buffering, and restart.
   - Public API:

```lua
detect(sql_text, offset, dialect, callback)
stmt(sql_text, cursor_line, callback)
stop()
```

3. Completion integration
   - `try_rust_context()` should prefer the persistent client.
   - If client is unavailable, job start fails, or a timeout occurs, fall back to current `vim.fn.system()` path.
   - Keep `_ctx_cache_key`, but consider extending it to a per-buffer LRU:
     - key = `bufnr|changedtick|block_start|block_end|offset|dialect`

4. Timeout policy
   - Completion must not wait forever.
   - Recommended: if no response within 50ms, callback keyword/function fallback; late results are discarded or cached for the next request.
   - Initial implementation may keep synchronous system fallback to preserve correctness before optimizing async behavior.

5. Non-goals
   - Do not implement LSP initialize/textDocument/didChange.
   - Do not build a cross-editor protocol.
   - Do not let this server access the DB. Metadata remains in the existing `completion_data.lua` CLI introspection/cache flow.

Testing strategy:

- Rust:
  - `poste context serve` accepts one detect request line and outputs correct JSON.
  - Invalid JSON outputs `ok=false` and the server continues for the next line.
- Lua:
  - Mock `context_client.detect()` and verify `completion.lua` fallback paths.
  - Do not require regular `tests/run.sh` to start a real long-running job, to avoid flaky timing.

Acceptance criteria:

- Default completion behavior is unchanged.
- If the server is unavailable, completion falls back to `vim.fn.system()` automatically.
- Debug logs can show whether completion used `serve` or `system`.

## Suggested Commit Split

Recommended PR/commit sequence:

1. `docs: define sql completion p0-p4 plan`
2. `docs: define poste sql file syntax`
3. `refactor(sql): route completion context through rust`
4. `test(sql): add context golden fixtures`
5. `refactor(sql): introduce scope resolver`
6. `feat(sql): add context serve protocol`
7. `feat(sql): use persistent context client in completion`

Each step should keep:

```bash
cargo test
tests/run.sh
```

If SQL integration Docker is not running, `tests/sql` is not required, but the final note must say it was not run.

## When Tests May Be Modified

Allowed:

- A test comment explicitly says `BUG`, `BEFORE FIX`, or `known limitation`, and the new behavior matches the P0 contract.
- A test directly calls Lua heuristic while claiming to validate overall SQL completion behavior.
- A test depends on completion item order while the product contract only requires containment.

Not allowed:

- SQL execution behavior tests.
- HTTP completion tests.
- Database browser, dataset panel, or dataset rendering tests, unless the change directly touches those modules.

When changing tests, explain why the old test no longer represented correct behavior.

## Risks And Guardrails

- Risk: Rust context JSON field changes break Lua item dispatch.
  - Guardrail: keep JSON backward-compatible. Add fields; do not remove fields.

- Risk: deleting Lua fallback too early breaks no-binary setups.
  - Guardrail: keep `completion_ctx.lua`, but mark it fallback-only.

- Risk: scope resolver becomes too large.
  - Guardrail: P3 stage one only handles table/alias/CTE visibility. Do not infer derived columns yet.

- Risk: persistent service creates flaky tests.
  - Guardrail: test the Rust line protocol; test Lua client wrapper/fallback without relying on real async timing.

- Risk: Poste file syntax gets mixed with SQL grammar.
  - Guardrail: P0 must state that directive lines are processed before SQL parsing.

## Target End State

After P0-P4, the architecture should be:

```text
Neovim completion source
  -> Poste SQL file/block resolver
  -> Rust context service
       -> tokenizer
       -> statement span
       -> scope resolver
       -> context detector
  -> Lua metadata cache
  -> completion items
```

Only then should Tree-sitter or LSP be evaluated. Tree-sitter can replace part of tokenizer/scope resolution; LSP can wrap the same context engine. Neither should redefine Poste file semantics.
