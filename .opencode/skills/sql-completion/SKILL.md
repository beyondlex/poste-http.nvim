---
name: sql-completion
description: >
  Systematic guide for modifying SQL completion or SQL statement context
  analysis in the Poste project. Covers dual-path architecture (Rust + Lua),
  principles for deciding where logic goes, dialect considerations, testing
  requirements, and common pitfalls.
---

# SQL Completion & Context Analysis — Agent Skill

## When to Load This Skill

Load this skill when working on:

- SQL completion items (what shows up when user types in `.sql`/`.mysql`/`.sqlite`/`.pgsql` files)
- SQL context detection (detecting whether cursor is in SELECT/FROM/WHERE/JOIN etc.)
- SQL tokenizer changes (adding new keywords, operators, string literal types)
- Table/column extraction logic
- Statement boundary detection (finding which `###` sub-block the cursor is in)
- Adding support for new SQL constructs (CTEs, window functions, DDL, dialect-specific syntax)
- Any change in `crates/poste-core/src/sql_context/` or `lua/poste/sql/completion*.lua`

## Architecture Overview

```
User types in .sql buffer
        │
        ▼
lua/poste/sql/completion.lua    ← orchestrator
  ├─ try_rust_context()         ← spawns `poste context detect <offset>`
  │     │                            sends full ### block via stdin
  │     ▼
  │  crates/poste-core/src/sql_context/
  │    ├─ mod.rs                 ← detect_context() — main entry
  │    ├─ tokenizer.rs           ← position-aware tokenizer
  │    ├─ tables.rs              ← table reference extraction
  │    └─ functions.rs           ← known function list
  │
  └─ Lua fallback path (when Rust unavailable or returns Keyword on non-empty prefix)
       └─ lua/poste/sql/completion_ctx.lua    ← heuristic regex-based
       └─ lua/poste/sql/completion_data.lua   ← keyword lists + async cache
       └─ lua/poste/sql/context.lua           ← connection/database resolution
```

### Three Completion Modes (`vim.g.poste_sql_legacy_completion`)

| Mode | Value | Behavior |
|------|-------|----------|
| **Hybrid (default)** | `nil` | Rust first; falls back to Lua if Rust returns `keyword` on a non-empty prefix |
| **Lua-only (legacy)** | `true` | Skips Rust entirely |
| **Rust-only** | `"rust"` | Pure Rust, no Lua fallback (for regression testing) |

## Core Principles

### Principle 1: Rust is the Single Source of Truth for Syntax

**All** syntax-level analysis lives in `crates/poste-core/src/sql_context/`. Lua side handles:

- ✅ UI (filtering, sorting, display of completion items)
- ✅ Async data fetching (introspection for tables/columns/databases via `poste introspect`)
- ✅ Caching (connection-scoped table/column caches)
- ❌ NOT syntax parsing, NOT context detection logic, NOT tokenization

When Rust and Lua behavior disagrees, **Rust is always correct**.

### Principle 2: No Duplicated Keyword/Function Lists

The Rust `tokenizer.rs` (`is_known_keyword`) defines which tokens are Keywords vs Idents.
The Rust `functions.rs` (`known_functions`) is the sole list of SQL functions.

Lua's `completion_data.lua` has partial keyword/function lists for the fallback path only.
When adding new keywords or functions:
1. Add to Rust first (`tokenizer.rs` + `functions.rs`)
2. Add tests in `mod.rs`'s `#[cfg(test)] mod tests`
3. Only then update `completion_data.lua` if the fallback needs it

### Principle 3: Dialect Agnostic by Default, Parametrized When Needed

The `sql_context` module is deliberately dialect-agnostic. It uses the lowest common denominator of SQL keywords.
When dialect-specific behavior is needed:

1. Add a `Dialect` parameter to `detect_context()` (see `sql_dialect.rs` for existing trait)
2. Gate dialect-specific keyword lists behind the parameter
3. Keep common keywords in the main list — only specialize when behavior actually differs

Examples of what to gate:
- MySQL `SHOW DATABASES` / `SHOW TABLES` → Table/Database context
- PostgreSQL `LISTEN` / `NOTIFY` → Keyword recognition
- SQLite `.mode` / `.import` → Dot-command handling

## Systematic Workflow

### Step 1: Identify the Layer

| If the change involves... | Primary file(s) |
|---------------------------|-----------------|
| New SQL keyword recognition | `tokenizer.rs` — `is_known_keyword()` |
| New context type (e.g. `ContextType::Window`) | `mod.rs` — `ContextType` enum + `detect_scan_backward()` |
| New context keyword group (e.g. `TABLE_CTX` / `COLUMN_CTX`) | `tokenizer.rs` — `is_table_keyword()` / `is_column_keyword()` |
| New table extraction pattern | `tables.rs` — `extract_tables()` / `parse_table_ref()` |
| New SQL function for completion | `functions.rs` — `known_functions()` |
| New token type (e.g. `TokenKind::Param`) | `tokenizer.rs` + `mod.rs` (all match arms) |
| Change to completion UI/filtering | `completion.lua` + `completion_data.lua` |
| Change to async data fetching | `completion_data.lua` |
| Connection/database resolution | `context.lua` |

### Step 2: Read the Test File First

Before writing code, read `crates/poste-core/src/sql_context/mod.rs` lines 615+ (the `#[cfg(test)] mod tests` block).
This gives you the exact patterns used for:
- Context detection assertions
- Tokenizer tests
- Table extraction tests

Follow the same conventions.

### Step 3: Implement in Rust

1. **Tokenizer**: If adding new tokens (keywords, operators), modify `tokenize()` and `is_known_keyword()`
2. **Context detection**: Add new branch in `detect_scan_backward()` or add special-case function
3. **Table extraction**: If new FROM/JOIN variant, update `extract_tables()` or `parse_table_ref()`
4. **Functions**: Add to `known_functions()` in `functions.rs`

### Step 4: Add Rust Tests

Every new feature must have tests in `mod.rs`'s `mod tests` block.
Test patterns to follow:

```rust
// Context detection — test the cursor AT the context point
#[test]
fn test_detect_something() {
    let result = detect_context("SELECT * FROM ", 14).unwrap();
    assert_eq!(result.context_type, ContextType::Table);
}

// Context detection — test WITH a prefix typed
#[test]
fn test_detect_with_prefix() {
    let result = detect_context("SELECT * FROM use", 17).unwrap();
    assert_eq!(result.context_type, ContextType::Table);
    assert_eq!(result.prefix, "use");
}

// Table extraction
#[test]
fn test_extract_tables_join() {
    let tokens = tokenize("SELECT * FROM users u JOIN posts p ON u.id = p.user_id");
    let tables = extract_tables(&tokens, sql);
    assert_eq!(tables.len(), 2);
    assert_eq!(tables[0].name, "users");
    assert_eq!(tables[0].alias, Some("u".into()));
}
```

### Step 5: Update Lua Fallback (Bare Minimum)

Only update `completion_ctx.lua` if:
- The fallback path would give wrong completions without the change
- A new `ContextType` value was added (add corresponding dispatch in `completion.lua`)

Only update `completion_data.lua` keyword/function lists if the change affects the fallback path.

### Step 6: Verify with cargo test

```bash
cargo test -p poste-core sql_context 2>&1 | tail -20
```

All existing tests must pass. If a test breaks because of your change, either:
- Your change has a bug, OR
- The test expectation was wrong and needs updating (rare — only if the old behavior was itself a bug)

## Context Type Reference

```
ContextType::Keyword         → default, show SQL keywords + functions
ContextType::Table           → after FROM/JOIN/UPDATE/INTO/TABLE
ContextType::Column          → after WHERE/SET/ON/HAVING/SELECT/AND/OR/NOT/BY/DISTINCT/RETURNING/ALL/AFTER
ContextType::DotColumn       → after `table.` or `alias.` (includes schema qualifier support)
ContextType::InsertColumn    → inside `INSERT INTO table (...)`
ContextType::Connection      → after `@connection` directive
ContextType::Database        → after `USE` or `@database` directive
ContextType::DataType        → after `ALTER TABLE t ADD COLUMN c`
```

## Keyword Group Reference

| Group | Keywords | Used for |
|-------|----------|----------|
| `is_table_keyword()` | `from`, `join`, `into`, `table`, `update` | Trigger `ContextType::Table` |
| `is_column_keyword()` | `where`, `set`, `on`, `having`, `select`, `and`, `or`, `not`, `by`, `distinct`, `returning`, `all`, `after` | Trigger `ContextType::Column` |
| `is_predicate_keyword()` | `in`, `between`, `like`, `ilike`, `is`, `exists` | Trigger `ContextType::Keyword` (values, not tables/columns) |

## Common Pitfalls

### 1. Forgetting the `skip_one_ident` Flag

`detect_scan_backward()` has a `skip_one_ident` flag that skips the user's partial typing.
- `WHERE us` → skips `us`, finds `WHERE` → Column ✓
- `WHERE status ` → skips nothing (cursor after space), finds `WHERE` → Column ✓
- `WHERE status IS NOT NULL` → skips nothing, finds `NOT` → Keyword (expression complete) ✓

If adding a new clause keyword, test BOTH cases (with and without a typed identifier).

### 2. Neglecting the `after_comma` Flag

Commas continue column/table lists:
- `SELECT id, name, ` → `after_comma=true` → scan further back → finds `SELECT` → Column ✓
- `FROM users, ` → `after_comma=true` → scan further back → finds `FROM` → Table ✓

### 3. Adding Lua-Only Features

Do NOT add syntax detection logic only in Lua. If the logic is needed, add it to Rust first.
The Lua path is a fallback, not a primary implementation target.

### 4. Ignoring String/Comment Awareness

The tokenizer properly handles strings and comments. When adding new token types, ensure:
- `'string with ; inside'` does NOT split statements
- `-- comment with keyword` does NOT trigger completion
- Token ranges (`start..end`) are correct for cursor offset lookup

### 5. Overlooking the `find_statement_span` Function

When changing the tokenizer, verify that `find_statement_span()` in `mod.rs` still works.
It depends on `;` tokens being correctly placed (not inside strings/comments).

## Testing Checklist

Before submitting/committing changes:

- [ ] `cargo test -p poste-core` passes
- [ ] New `detect_context` test for each new context type
- [ ] Test with prefix (user has partially typed an identifier)
- [ ] Test without prefix (cursor after keyword/space)
- [ ] Test string/comment edge cases if tokenizer changed
- [ ] Test with both `detect_context()` and `extract_tables()` if both affected
- [ ] If Lua fallback was updated, test with `vim.g.poste_sql_legacy_completion = true`
- [ ] If dialect was involved, test with at least 2 dialect connections

## Quick File Reference

| File | Purpose | Lines |
|------|---------|-------|
| `crates/poste-core/src/sql_context/mod.rs` | Context detection, tests | ~1590 |
| `crates/poste-core/src/sql_context/tokenizer.rs` | Tokenizer, keyword lists | ~322 |
| `crates/poste-core/src/sql_context/tables.rs` | Table reference extraction | ~149 |
| `crates/poste-core/src/sql_context/functions.rs` | SQL function list | ~99 |
| `lua/poste/sql/completion.lua` | Completion orchestrator | ~583 |
| `lua/poste/sql/completion_ctx.lua` | Lua fallback context detection | ~191 |
| `lua/poste/sql/completion_data.lua` | Async data + cache layer | ~483 |
| `lua/poste/sql/context.lua` | Connection/database resolution | ~178 |
| `crates/poste-exec/src/sql_dialect.rs` | Dialect trait | ~374 |
