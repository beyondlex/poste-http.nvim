# Poste SQL File Syntax & Context Contract

## 1. File Structure

A Poste SQL file (`.sql`, `.mysql`, `.sqlite`) consists of directives and SQL statements separated by `;`. Directives can appear at the top of the file or inline between statements:

```
-- @connection my-pg                   ← file-level directive (optional)
-- @database blog                      ← file-level directive (optional)

SELECT * FROM users WHERE id = 1;

-- @connection my-analytics            ← inline directive (switches connection)
SELECT COUNT(*) FROM events;
SELECT * FROM page_views;             ← still uses my-analytics
```

### 1.1 Directive Placement & Scope

- **File-level**: at the top of the file (before the first SQL statement), applies to all statements.
- **Inline**: between SQL statements, switches connection/database from that point forward, overrides file-level, stays active until the next same-typed directive or EOF.

### 1.2 Extension Semantics

| Extension | Dialect | Behavior |
|-----------|---------|----------|
| `.sql` | Postgres (default) | Same block rules. Auto-detect from connection URL. |
| `.mysql` | MySQL | Same block rules. |
| `.sqlite` | SQLite | Same block rules. |

Dialect only affects:
- SQL context detection (keyword/function sets, `|` operator, etc.)
- Metadata introspection (table/column queries)
- Not Poste file structure.

---

## 2. Directive Rules

### 2.1 Supported Directives

| Directive | Value | Purpose |
|-----------|-------|---------|
| `-- @connection <name-or-url>` | Connection name or URL | Select database connection |
| `-- @database <name>` | Database/schema name | Override default database |

### 2.2 Placement

Directives can appear in two positions:
- **File top** (before the first SQL statement) — file-level defaults for all statements.
- **Between SQL statements** (inline) — switches connection/database from that point, overrides file-level, stays active for subsequent statements.
- A later same-typed directive overrides the previous one (last wins).

### 2.3 Completions on Directive Lines

| Cursor position | Completion items |
|-----------------|------------------|
| After `-- @connection ` | Connection names (from `connections.json`) |
| After `-- @database ` | Database/schema names (from `introspect databases`) |
| After `-- @` (partial) | `@connection`, `@database` directive names |

### 2.4 Directive Lines vs SQL

- Directive lines are **excluded** from SQL statement parsing.
- A cursor ON a directive line MUST NOT trigger SQL keyword/table/column completion.
- **Completion pipeline**: Lua strips all directive lines before sending the full SQL body to Rust. The Rust `try_directive()` safety net is retained but returns `None` when encountering `@connection`/`@database` tokens.
- **Execution pipeline**: Lua maintains the current active connection/database state as it scans the file. When extracting a statement at cursor via `;` boundaries, it uses the nearest preceding directive as the effective context.

### 2.5 `-- @connection` Without Database

When `-- @database` is absent after `-- @connection`, the completion for `@database` falls back to showing connection names with a special insert behavior (inserts both `@connection` and `@database` lines). This is a UI convenience, not a syntax rule.

---

## 3. Statement Boundaries

### 3.1 Hard Boundaries (always split)

| Boundary | Token | Notes |
|----------|-------|-------|
| Semicolon | `;` | Tokenizer-aware: skips `;` inside `'strings'`, `-- comments`, `/* blocks */`, `$$ dollar strings $$` |
| EOF | — | Ends current statement |

### 3.2 Soft Boundaries (completion only, removed after P3)

| Boundary | Token | Behavior |
|----------|-------|----------|
| Consecutive blank lines | `\n\n` (2+ newlines) | Pre-P3: Rust `context.rs` uses `is_blank_line_separator()` to prevent table leakage across blank-line-separated statements. Removed after P3 ScopeResolver. |

### 3.3 Rationale

- The 2+ blank line boundary is a **temporary guard** until ScopeResolver handles statement scope properly.
- A single blank line is NOT a boundary (users may use blank lines for readability).
- **Execution statement extraction** always uses `;` only, unaffected.

### 3.4 Current Implementation (Pre-P3 Temporary)

| Layer | Boundary detection | Notes |
|-------|-------------------|-------|
| Rust `context.rs` | Semicolons + 2+ blank lines | `find_statement_token_range()`, blank line logic removed after P3 |
| Rust `statements.rs` | Semicolons only | `find_statement_span()` for execution |
| Lua `completion.lua` | Strips all directive lines | Sends full SQL body to Rust |
| Lua `statement.lua` | Semicolons only | `extract_stmt_at_cursor()` (execution layer) |

### 3.5 Conclusion

- 2+ blank line boundary is a **pre-P3 temporary guard**, removed after P3 ScopeResolver.
- Post-P3 completion relies **only** on `;` + EOF, with ScopeResolver handling intra-statement scope (CTE/subquery/aliases).

### 3.6 Visual Boundary Indicator (Suggested UI Feature)

`;` boundaries are invisible to the user, creating a gap between perceived and actual execution scope. Suggested Neovim plugin enhancement:

- On `CursorMoved`, call `find_statement_span()` to get `(start_line, end_line)` for the statement under the cursor.
- Use `vim.api.nvim_buf_set_extmark()` to highlight the range with a background color or sign column marker.
- Result: the current statement lights up as the cursor moves, giving the user clear visual feedback of execution boundaries.
- This replaces the visual grouping that `###` previously provided, and is more accurate — based on real `;` semantics rather than manual separators.
- **Relationship to semantic boundary detection** (see `future/semantic-statement-boundary.en.md`): the indicator only calls `find_statement_span()` and consumes its result. It does not care how boundaries are computed. If `;`-free semantic boundaries are implemented later, the indicator benefits automatically with zero changes.

---

## 4. Cursor Context JSON Contract

### 4.1 Current Fields (stable, will not be removed)

```json
{
  "ctx_type": "column",
  "ctx_data": null,
  "ctx_schema": null,
  "prefix": "us",
  "tables": [{ "name": "users", "alias": null, "schema": null }],
  "functions": ["COUNT", "SUM", "MAX", "MIN", ...],
  "in_string": false,
  "in_comment": false
}
```

| Field | Type | Always present | Description |
|-------|------|---------------|-------------|
| `ctx_type` | string | yes | One of: `keyword`, `table`, `column`, `dot_column`, `schema_table`, `insert_column`, `connection`, `database`, `datatype`, `string`, `comment` |
| `ctx_data` | string\|null | yes | Context-dependent data (e.g., table name for `dot_column`, schema name for `schema_table`) |
| `ctx_schema` | string\|null | yes | Schema for `dot_column` |
| `prefix` | string | yes | Partial identifier typed so far |
| `tables` | array | yes | Visible tables at cursor position |
| `functions` | array | yes | Known functions for current dialect |
| `in_string` | bool | yes | Cursor is inside a string literal |
| `in_comment` | bool | yes | Cursor is inside a line/block comment |

### 4.2 Additive Fields (P0 contract, add to Rust output)

```json
{
  "version": 1
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `version` | int | 1 | Protocol version. Increment on breaking changes. |

> **`statement`/`block` fields are NOT in Rust output**. These are execution-layer information:
> - `statement`: Computed at the Lua layer from `poste context stmt` (when needed)
> - `block`: `###` has been removed, not in Rust output

### 4.3 Null/NIL Handling

- JSON `null` in Rust → `null` in JSON → `vim.NIL` in Neovim → normalize to `nil` in Lua (already handled in `completion.lua:deep_clean()`).
- Empty prefix: `""`.
- Empty tables: `[]`.

### 4.4 Versioning Policy

- `version` field is always present.
- Backward-compatible additions (new fields): increment minor version? Current recommendation: always `1` until a breaking change.
- Breaking changes (field removal, type change): increment to `2`, add migration path in Lua.
- **Rust will not remove existing fields.** It may add new fields (e.g., `ctx_schema` for `SchemaTable`).

---

## 5. Context Type Semantics

### 5.1 Type Definitions

| `ctx_type` | `ctx_data` | `ctx_schema` | When triggered | Completion items |
|------------|-----------|--------------|----------------|------------------|
| `keyword` | `null` | ignored | Default / no specific context matched | SQL keywords, functions, data types |
| `table` | `null` | ignored | After `FROM`, `JOIN`, `INTO`, `UPDATE`, `TABLE`, `DELETE FROM`, `SHOW TABLES`, `COPY`, `ANALYZE`, `VACUUM`, `CALL`, `GRANT ... ON`, `REVOKE ... ON`, `FOR UPDATE OF`, `FOR SHARE OF` | Tables, views, databases/schemas |
| `column` | `null` | ignored | After `WHERE`, `SET`, `ON`, `HAVING`, `SELECT`, `ORDER BY`, `GROUP BY`, `RETURNING`, `DISTINCT`, `NOT`, comma in select list, `AND`/`OR` in WHERE, after function `(`, after `(` in WHERE expression, `ON CONFLICT DO UPDATE SET`, window `PARTITION BY`/`ORDER BY`, `INSERT INTO ... SELECT`, `MODIFY COLUMN` | Columns from visible tables, functions |
| `dot_column` | `table_name` (string) | `schema_name` or `null` | After `alias.` or `table.` (`users.`, `u.`) | Columns of the named table or alias |
| `schema_table` | `schema_name` (string) | `null` | After `FROM schema.` or `JOIN schema.` | Tables within that schema |
| `insert_column` | `table_name` (string) | ignored | Inside `INSERT INTO table (` | Columns of the target table (with quick-insert all-cols / without-id shortcuts) |
| `connection` | `null` | ignored | After `-- @connection` | Connection names |
| `database` | `null` or `"directive"` | ignored | After `-- @database` or `USE` | Database/schema names |
| `datatype` | `null` | ignored | After `ALTER TABLE ... ADD/MODIFY COLUMN col_name` | Data types (INT, VARCHAR, TEXT, etc.) |
| `string` | `null` | ignored | Cursor inside a string literal (`'hello'`) | No completions. Lua suppresses all items. |
| `comment` | `null` | ignored | Cursor inside a comment (`-- line` or `/* block */`) | No completions. Lua suppresses all items. |

### 5.2 Edge Cases

| Input | Expected context | Rationale |
|-------|-----------------|-----------|
| `SELECT *` (cursor on whitespace after `*`) | `keyword` | After `FROM` is needed for table; suggest keywords |
| `SELECT col` (cursor on whitespace after `col`) | `keyword` | Column expression complete; suggest FROM/WHERE |
| `WHERE col =` (cursor after `=`) | `keyword` | Value expression; don't suggest column names |
| `WHERE col >` (cursor after `>`) | `keyword` | Same as `=` |
| `WHERE col BETWEEN` | `keyword` | Between values expected, not column |
| `WHERE col LIKE` | `keyword` | Pattern expected, not column |
| `WHERE col IS` | `keyword` | NULL/TRUE/FALSE expected, not column |
| `WHERE col NOT` | `keyword` | IN/LIKE/BETWEEN expected, not column |
| `WHERE col IN` | `keyword` | `(` or value list expected |
| `WHERE col IN (` | `keyword` | Subquery or value list |
| `WHERE id BETWEEN 1 AND` | `column` | AND after BETWEEN resumes column context |
| `WHERE status IS NOT` | `column` | IS NOT provides negation, column follows |
| `SELECT FROM (` | `keyword` | Subquery start, not table |
| `WHERE id IN (` | `keyword` | IN subquery start |
| `WHERE EXISTS (` | `keyword` | EXISTS subquery start |
| `INSERT INTO tbl VALUES (` | `keyword` | Value list, not column names |
| `INSERT INTO tbl (` | `insert_column` | Column list for INSERT |
| `INSERT INTO tbl` (cursor at `(` ) | `insert_column` | Open paren triggers insert column mode |
| `SELECT RANK() OVER` | `keyword` | Window function expects BY, PARTITION BY, etc. |
| `SET statement_timeout =` | `keyword` | SET statement (not UPDATE) should not suggest columns |
| `UPDATE SET col =` | `column` | Column value expected? Actually keyword for expressions. But current Rust returns `keyword` which is acceptable. |
| Cursor inside string `'hello'` | `ctx_type: "string"`, `in_string=true`, no item suggestions | Explicit `string` type returned, Lua suppresses all items |
| Cursor inside `-- comment` | `ctx_type: "comment"`, `in_comment=true`, no item suggestions | Explicit `comment` type returned, Lua suppresses all items |
| Empty buffer | `keyword`, empty `tables`, empty `prefix` | Default fallback |

### 5.3 Old Test Markings (to be updated)

The following tests in `tests/sql_completion_edge_spec.lua` encode CURRENT behavior that contradicts this contract. They will be updated during P1/P2:

| Test | Marking | Issue |
|------|---------|-------|
| "BUG: schema.table extracts only the schema name" | `BUG` | Lua fallback limitation; Rust handles correctly |
| "BUG: tables from subquery-FROM leak to outer scope" | `BUG` | Lua fallback limitation; Rust's paren tracking handles this |
| "BUG: CTE inner tables leak" | `BUG` | Lua fallback limitation; Rust should handle (P3) |
| "BUG: -- FROM → table context" | `BUG` | Lua lacks comment awareness; Rust returns `None` |
| "BUG: string 'WHERE ' at end triggers column context" | `BUG` | Lua lacks string awareness; Rust returns `None` |
| "CURRENT: WHERE col = → keyword" | `CURRENT` | Correct per this contract |

---

## 6. Implementation Boundary: Poste vs SQL

The following rules define where Poste file format ends and SQL grammar begins:

### 6.1 Poste file format (processed by Lua)

| Construct | Handler | Layer | Notes |
|-----------|---------|-------|-------|
| `-- @connection` directive | `completion.lua:get_items()` | Completion | Complete from connection names |
| `-- @database` directive | `completion.lua:get_items()` | Completion | Complete from database names |
| Directive context tracking | `context.lua:resolve_context()` | Execution | Resolves effective connection/database from nearest preceding directive |
| `USE database` statement | `context.lua:resolve_context()` | Execution | Database context switching |

> **Completion pipeline**: Lua strips only directive lines, sending the full SQL body to Rust.

### 6.2 SQL grammar (processed by Rust)

| Construct | Handler | Notes |
|-----------|---------|-------|
| Tokenization | `tokenizer.rs` | Keywords, identifiers, strings, comments, operators |
| Context detection | `context.rs` / `detectors.rs` / `scanner.rs` | Returns `ContextType` + tables + prefix |
| Table extraction | `tables.rs` | FROM/JOIN/INTO/UPDATE, schema-qualified, aliases |
| Statement span | `statements.rs` | `;`-boundaries with string/comment awareness |
| Known functions | `functions.rs` | Dialect-specific function lists |

### 6.3 Never-to-cross Boundary

- Rust MUST NOT resolve `-- @connection` names (no access to `connections.json`).
- In the completion pipeline, Lua strips directive lines and sends the full SQL body to Rust.
- Lua MUST NOT attempt heuristic SQL grammar analysis in `completion_ctx.lua` beyond what Rust provides, unless Rust binary is unavailable.
- `-- @` is Poste file syntax, not SQL syntax.

---

## 7. Test Coverage Requirements

Every rule in this document must be covered by at least one test:

| Section | Test location | Type |
|---------|--------------|------|
| 1.1 File structure | `tests/sql_completion_spec.lua` | Lua integration |
| 1.2 Request block | `tests/sql_completion_spec.lua` | Lua integration |
| 2. Directive completions | `tests/sql_completion_spec.lua` | Lua + Rust |
| 2.4 Directive exclusion | `tests/sql_completion_edge_spec.lua` → Rust golden | Rust unit |
| 3. Statement boundaries | `crates/poste-core/src/sql_context/tests.rs` | Rust unit |
| 4. JSON contract | Rust golden fixtures (P2) | Rust integration |
| 5. Context types | `crates/poste-core/src/sql_context/tests.rs` | Rust unit |
| 5.2 Edge cases | `crates/poste-core/src/sql_context/tests.rs` | Rust unit |

---

## 8. Closed Questions (Decided in P0 Review)

The following questions were decided in the P0 design review meeting (`meeting-minutes.md`). No longer open for discussion:

1. **Blank line boundary**: `is_blank_line_separator()` is a **pre-P3 temporary guard**, removed after P3 ScopeResolver completes. ScopeResolver replaces blank line heuristics by understanding statement structure (CTE/subquery/alias scopes). ✅ **Decided**

2. **Statement field in JSON**: Not in Rust output. Computed at the Lua layer via `poste context stmt` when needed. ✅ **Decided**

3. **Block field in JSON**: `###` has been removed and is no longer part of the Poste file syntax. Not in Rust output. ✅ **Decided**

4. **`in_string` + `in_comment` → explicit ctx_type**: Implement **Option 3** in P1—Rust adds `ContextType::String` and `ContextType::Comment`, returning them explicitly to Lua instead of `None` + ambiguous fallback. ✅ **Decided**

5. **`ctx_schema` for `SchemaTable`**: Add in P1 alongside the `version` field. ✅ **Decided**
