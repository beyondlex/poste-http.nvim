---
name: sql-completion
description: >
  Agent guide for SQL completion changes in Poste. Source-of-truth rules,
  workflow, common pitfalls, file index. Syntax spec in docs/dev/sql/completion/.
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - AskUserQuestion
metadata:
  trigger: sql completion|context detect|tokenizer|sql_context|completion.lua|keyword|table extraction|alias|schema
---

# SQL Completion — Agent Skill

Architecture and completion modes: see `docs/dev/sql/completion/`. This skill
covers what docs don't: workflow, rules of thumb, historical pitfalls.

## When to Load

- SQL completion items in Poste SQL buffers
- SQL context detection (`SELECT`, `FROM`, `WHERE`, `JOIN`, DDL, DCL, dialect syntax)
- SQL tokenizer changes
- Table, alias, schema, or column extraction logic
- Statement boundary detection
- New SQL constructs (CTEs, window functions, `SHOW`, `COPY`, `FOR UPDATE`)
- Any change in `crates/poste-core/src/sql_context/` or `lua/poste/sql/completion*.lua`

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

Do not add new SQL syntax detection only in Lua. If Lua detects a case better
than Rust, add the case to Rust first.

### Data Lists Need Clear Roles

Rust `functions.rs` is the authoritative function source. Lua `SQL_FUNCTIONS`
is fallback-only.

Rust `is_known_keyword()` classifies tokens. Lua `KEYWORDS` has display
snippets (e.g. `ORDER BY`). Single-word snippet parts that affect parsing
must be known by Rust.

### Preserve Schema and Alias End-to-End

Verify the full chain when schema changes:

```
Rust TableRef / DotColumn
  -> CLI JSON response
  -> Lua alias map
  -> ensure_columns()
  -> introspect --schema
  -> cache key
```

Do not treat `public.users` and `auth.users` as the same table.

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

```bash
cargo test -p poste-core
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

```rust
#[test]
fn test_detect_table_after_from() {
    let result = detect_context("SELECT * FROM ", 14).unwrap();
    assert_eq!(result.context_type, ContextType::Table);
}
```

Assert all structured fields (`name`, `schema`, `alias`). When Lua orchestration
changes, add Lua tests for all three completion modes (nil, true, "rust").

## Dialect Guidance

Keep `poste-core` lightweight. Do not import `poste-exec` dialect trait into
`poste-core` unless explicitly approved.

For dialect-specific completion:
1. Add a lightweight dialect enum/string to the context API or CLI.
2. Pass the active dialect from Lua/CLI when known.
3. Keep dialect-agnostic behavior as the fallback.
4. Test at least two dialects when behavior differs.

## Common Pitfalls

### Hybrid Override (Fixed in P1)

Lua no longer overrides Rust. When debugging, test with
`vim.g.poste_sql_legacy_completion = "rust"` to isolate Rust behavior.
Fix missing detection in Rust rather than adding Lua heuristics.

### Schema Loss Produces Wrong Columns

Do not pass only a bare table name when schema is known. Column cache keys
and introspection calls must distinguish `schema.table`.

### Fixed Token Offsets Break Qualified Names

Use `skip_forward()` / `skip_back()`, not fixed indexes like `i + 3`,
because whitespace and optional `AS` vary.

### `skip_one_ident` Affects Prefix Cases

`detect_scan_backward()` skips the user's typed identifier so `WHERE us`
resolves to column context. Test both cursor-after-space and prefix-typed forms.

### `after_comma` Affects List Contexts

Commas continue lists:
- `SELECT id, ` → column context
- `FROM users, ` → table context (if table-list support is intended)
- `UPDATE users SET a = 1, ` → column context

### String/Comment Awareness Is Non-Negotiable

Tokenizer changes must preserve:
- `';'` inside strings does not split statements
- Keywords in comments do not trigger completion
- Dollar-quoted strings remain single tokens

## Testing Checklist

- [ ] `cargo test -p poste-core` passes
- [ ] Context tests cover no-prefix and typed-prefix cases
- [ ] Table extraction tests assert `name`, `schema`, and `alias`
- [ ] CLI output contains `version` field and all fields Lua needs
- [ ] Lua tests cover all three completion modes (nil/true/"rust")
- [ ] String/comment cases return `String`/`Comment` type, Lua suppresses items
- [ ] Dialect-specific behavior has at least two dialect expectations
- [ ] Column cache tests cover same table name in different schemas

## Quick File Reference

| File | Purpose |
|------|---------|
| `crates/poste-core/src/sql_context/mod.rs` | Context detection, ContextType, Rust tests |
| `crates/poste-core/src/sql_context/tokenizer.rs` | Tokenizer and keyword groups |
| `crates/poste-core/src/sql_context/tables.rs` | Table/schema/alias extraction |
| `crates/poste-core/src/sql_context/functions.rs` | SQL function list |
| `crates/poste-cli/src/main.rs` | `poste context detect` JSON shape |
| `lua/poste/sql/completion.lua` | Completion orchestrator |
| `lua/poste/sql/completion_ctx.lua` | Legacy Lua regex fallback (deprecated) |
| `lua/poste/sql/completion_data.lua` | Async introspection, cache, fallback lists |
| `lua/poste/sql/context.lua` | Connection/database resolution |
| `crates/poste-exec/src/sql_dialect.rs` | Runtime dialect behavior for introspection/execution |
