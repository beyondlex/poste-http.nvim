---
name: sql-completion
description: >
  Systematic guide for modifying SQL completion or SQL statement context
  analysis in the Poste project. Covers the current Rust + Lua architecture,
  source-of-truth rules, schema/alias propagation, dialect considerations,
  testing requirements, and common pitfalls.
---

# SQL Completion & Context Analysis — Agent Skill

## When to Load This Skill

Load this skill when working on:

- SQL completion items in Poste SQL buffers
- SQL context detection (`SELECT`, `FROM`, `WHERE`, `JOIN`, DDL, DCL, dialect syntax)
- SQL tokenizer changes
- Table, alias, schema, or column extraction logic
- Statement boundary detection for SQL request blocks
- New SQL constructs such as CTEs, window functions, `SHOW`, `COPY`, or `FOR UPDATE`
- Any change in `crates/poste-core/src/sql_context/` or `lua/poste/sql/completion*.lua`

## Current Architecture

```text
User types in a SQL buffer
        |
        v
lua/poste/sql/completion.lua
  |
  |-- try_rust_context()
  |     spawns: poste context detect <offset>
  |     stdin: full ### SQL block
  |     |
  |     v
  |   crates/poste-core/src/sql_context/
  |     |-- mod.rs        detect_context(), ContextType, tests
  |     |-- tokenizer.rs  tokenization, keyword classification
  |     |-- tables.rs     table/schema/alias extraction
  |     |-- functions.rs  SQL function list
  |
  |-- completion dispatch
  |     |-- completion_data.lua  async introspection, cache, fallback lists
  |     |-- completion_ctx.lua   legacy Lua regex fallback
  |     |-- context.lua          connection/database resolution
```

### Completion Modes

`vim.g.poste_sql_legacy_completion` controls the execution path:

| Value | Mode | Behavior |
|-------|------|----------|
| `nil` | Hybrid default | Rust first, currently may let Lua override `keyword` with a typed prefix |
| `true` | Lua-only legacy | Skips Rust entirely |
| `"rust"` | Rust-only | Pure Rust, useful for regression tests |

Important: the current hybrid default is a known risk. The desired direction is Rust as the syntax authority, with Lua fallback only when the Rust binary is unavailable or explicit legacy mode is selected.

## Source-of-Truth Rules

### Rust Owns Syntax

Put syntax-level analysis in `crates/poste-core/src/sql_context/`.

Rust owns:
- Tokenization and keyword classification
- String/comment awareness
- Cursor offset interpretation
- Context type detection
- Table/schema/alias extraction
- Statement boundary detection

Lua owns:
- Completion UI item construction
- Filtering, sorting, and dispatching
- Async introspection calls
- Cache storage
- Explicit legacy fallback behavior

Do not add new SQL syntax detection only in Lua. If Lua detects a case better than Rust, add the case to Rust first.

### Data Lists Need Clear Roles

Rust `functions.rs` is the authoritative normal-mode function source.
Lua `SQL_FUNCTIONS` is fallback-only unless a generated/shared source is introduced.

Rust `is_known_keyword()` classifies tokens. Lua `KEYWORDS` contains display snippets and may include compound insertions like `ORDER BY`; it is not the same concept. When updating keywords, make sure single-word snippet parts that affect parsing are known by Rust.

### Preserve Schema and Alias End-to-End

When a change touches column completion, verify the full chain:

```text
Rust TableRef / DotColumn
  -> CLI JSON response
  -> Lua alias map
  -> ensure_columns()
  -> introspect --schema
  -> cache key
```

Known current gap: Rust stores schema, but the CLI/Lua completion path drops or ignores it. Do not treat `public.users` and `auth.users` as the same table.

## Systematic Workflow

### Step 1: Identify the Layer

| Change | Primary file(s) |
|--------|-----------------|
| New SQL keyword recognition | `tokenizer.rs` |
| New context type | `mod.rs` |
| New table/column trigger group | `tokenizer.rs`, `mod.rs` |
| Table/schema/alias extraction | `tables.rs` |
| SQL function completion | `functions.rs` |
| CLI response shape | `crates/poste-cli/src/main.rs` |
| Completion dispatch/UI | `completion.lua` |
| Async introspection or cache | `completion_data.lua` |
| Legacy fallback behavior | `completion_ctx.lua` |
| Connection/database resolution | `context.lua` |

### Step 2: Establish Baseline

Run:

```bash
cargo test -p poste-core
```

For a specific context case, reproduce through the CLI:

```bash
printf 'SELECT * FROM users WHERE ' | target/debug/poste context detect 26
```

Use the CLI result to check what Lua receives, not only what Rust unit tests assert.

### Step 3: Implement Rust First

1. Tokenizer: add keywords, operators, or literal handling in `tokenizer.rs`.
2. Context detection: add special cases before generic backward scan when SQL grammar needs lookahead.
3. Table extraction: update `tables.rs` for schema, alias, join, CTE, or qualified-name behavior.
4. Functions: update `functions.rs`, preferably with dialect metadata if the change is dialect-specific.
5. CLI: expose any new structured context fields needed by Lua.

### Step 4: Update Lua Minimally

Update Lua only when:
- A new `ContextType` needs dispatch.
- A structured field from Rust must be consumed.
- Async introspection needs new arguments such as `--schema`.
- Legacy fallback needs a small compatibility update.

Avoid expanding `completion_ctx.lua` unless the task is explicitly about legacy fallback.

### Step 5: Add Tests

Add Rust tests for parser behavior:

```rust
#[test]
fn test_detect_table_after_from() {
    let result = detect_context("SELECT * FROM ", 14).unwrap();
    assert_eq!(result.context_type, ContextType::Table);
}
```

Add table extraction tests that assert all structured fields:

```rust
#[test]
fn test_extract_schema_alias() {
    let result = detect_context("SELECT * FROM public.users AS u WHERE ", 38).unwrap();
    assert!(result.tables.iter().any(|t| {
        t.name == "users" && t.schema.as_deref() == Some("public") && t.alias.as_deref() == Some("u")
    }));
}
```

When Lua orchestration changes, add Lua tests for all three completion modes.

## Context Type Reference

```text
ContextType::Keyword       -> SQL keywords + functions
ContextType::Table         -> table names
ContextType::Column        -> columns from referenced tables
ContextType::DotColumn     -> columns after table_or_alias.
ContextType::InsertColumn  -> columns inside INSERT INTO table (...)
ContextType::Connection    -> @connection directive
ContextType::Database      -> USE / @database
ContextType::DataType      -> data types after column definitions
```

If adding a new context type, update:
- Rust enum and `name()`
- CLI JSON response if extra fields are needed
- Lua dispatch in `completion.lua`
- Tests in Rust and Lua

## Dialect Guidance

Keep `poste-core` lightweight. Do not directly import the `poste-exec` dialect trait into `poste-core` unless the dependency direction is explicitly approved.

For dialect-specific completion:
1. Add a lightweight dialect enum/string to the context API or CLI.
2. Pass the active dialect from Lua/CLI when known.
3. Keep dialect-agnostic behavior as the fallback.
4. Test at least two dialects when behavior differs.

Examples:
- MySQL: `SHOW DATABASES`, `SHOW TABLES`, `SHOW COLUMNS FROM`
- PostgreSQL: `COPY`, `LISTEN`, `NOTIFY`, schema-qualified tables
- SQLite: dot commands or SQLite-only functions if supported later

## Common Pitfalls

### Hybrid Override Hides Rust Bugs

Default completion currently may replace Rust `keyword` with Lua regex output. When debugging, test both default and `"rust"` mode. Fix missing detection in Rust rather than relying on Lua.

### Schema Loss Produces Wrong Columns

Do not pass only a bare table name when schema is known. Column cache keys and introspection calls must distinguish `schema.table`.

### Fixed Token Offsets Break Qualified Names

Qualified table parsing should use token navigation helpers such as `skip_forward()`, not fixed indexes like `i + 3`, because whitespace and optional `AS` matter.

### `skip_one_ident` Affects Prefix Cases

`detect_scan_backward()` skips the user's current typed identifier so `WHERE us` can still resolve to column context. Test both cursor-after-space and prefix-typed forms.

### `after_comma` Affects List Contexts

Commas continue lists:
- `SELECT id, ` should remain column context.
- `FROM users, ` should remain table context if table-list support is intended.
- `UPDATE users SET a = 1, ` should remain column context.

### String/Comment Awareness Is Non-Negotiable

Tokenizer changes must preserve:
- `';'` inside strings does not split statements.
- Keywords in `-- comments` and `/* comments */` do not trigger completion.
- Dollar-quoted strings remain single string tokens.

## Testing Checklist

- [ ] `cargo test -p poste-core` passes.
- [ ] Context tests cover no-prefix and typed-prefix cases.
- [ ] Table extraction tests assert `name`, `schema`, and `alias`.
- [ ] CLI `poste context detect` output contains fields Lua needs.
- [ ] Lua tests cover default, legacy, and rust-only modes when orchestration changes.
- [ ] String/comment cases remain quiet.
- [ ] Dialect-specific behavior has at least two dialect expectations.
- [ ] Column cache tests cover same table name in different schemas when schema handling changes.

## Quick File Reference

| File | Purpose |
|------|---------|
| `crates/poste-core/src/sql_context/mod.rs` | Context detection, ContextType, Rust tests |
| `crates/poste-core/src/sql_context/tokenizer.rs` | Tokenizer and keyword groups |
| `crates/poste-core/src/sql_context/tables.rs` | Table/schema/alias extraction |
| `crates/poste-core/src/sql_context/functions.rs` | SQL function list |
| `crates/poste-cli/src/main.rs` | `poste context detect` JSON shape |
| `lua/poste/sql/completion.lua` | Completion orchestrator |
| `lua/poste/sql/completion_ctx.lua` | Legacy Lua regex fallback |
| `lua/poste/sql/completion_data.lua` | Async introspection, cache, fallback lists |
| `lua/poste/sql/context.lua` | Connection/database resolution |
| `crates/poste-exec/src/sql_dialect.rs` | Runtime dialect behavior for introspection/execution |
