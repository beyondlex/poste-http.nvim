# SQL Context Detection Architecture (v2)

## Problem

Current SQL completion uses Lua-side heuristic regex matching (`detect_context` in
`completion.lua`). It has fundamental limitations:

1. No tokenizer → can't tell strings/comments from SQL → triggers wrong context
2. No paren tracking → subquery tables leak to outer scope
3. No CTE awareness → CTE definitions pollute table lists
4. No subquery awareness → `FROM (SELECT ...)` loses alias, inner tables leak
5. Operator detection broken → operators (`>`, `!=`) are in COLUMN_CTX but never
   checked because `[%w_]+` doesn't match them
6. Two separate implementions: Rust `split_statements()` (correct) vs Lua
   `find_stmt_lines()` (simple `;` check) → inconsistent indicator placement

## Architecture

### Three Layers

```
┌───────────────────────────────────────────────┐
│  Lua Completion Layer  (thin client)           │
│  - completion.lua (cache mgmt, item building)  │
│  - init.lua (statement extraction → Rust)      │
│  - Falls back to existing Lua logic if         │
│    Rust binary not available                   │
└───────────────────┬───────────────────────────┘
                    │ JSON protocol (stdin pipe)
                    ▼
┌───────────────────────────────────────────────┐
│  Rust Context Module  (sql_context.rs)         │
│  - Position-aware tokenizer                   │
│  - Context detection from cursor position      │
│  - Table extraction (subquery-aware)           │
│  - Statement boundary detection (line-aware)   │
│  - CTE-aware table resolution                  │
└───────────────────┬───────────────────────────┘
                    │     
                    ▼
┌───────────────────────────────────────────────┐
│  Rust CLI subcommand: poste context            │
│  poste context detect <sql> <offset>           │
│  poste context stmt <sql-lines> <cursor-line>  │
└───────────────────────────────────────────────┘
```

### SQL Context Tokenizer

Single-pass O(n) tokenizer producing tokens with byte positions:

| Token | Examples |
|-------|---------|
| Keyword | SELECT, FROM, WHERE, JOIN, ... |
| Ident | users, id, my_table |
| QuotedIdent | "table name", `column` |
| StrLit | 'hello', 'it''s', "hello" |
| NumLit | 42, 3.14 |
| Op | =, >, <, >=, <=, !=, <> |
| Dot | . |
| Comma | , |
| Semi | ; |
| Paren | (, ) |
| LineComment | -- ... |
| BlockComment | /* ... */ |

Key features:
- Tracks string/comment state → cursor inside a string or comment returns keyword
- Proper escape handling: `''` in strings, `""` in quoted identifiers
- Keyword detection by ident lookup in keyword set

### Context Detection Algorithm

```
find token at cursor byte offset
IF token is inside string or comment → return Keyword

scan backward from cursor token (skip whitespace/comments):
  IF token is Dot → DotColumn(table = ident before dot)
  IF token is Keyword:
    IN TABLE_CTX → TableName
    IN COLUMN_CTX → ColumnName
    FOR `IN/BETWEEN/LIKE` → PredicateValue
    FOR `PARTITION BY` → ColumnName  
  IF token is Comma → scan further back for clause keyword
  DEFAULT → Keyword
```

### Table Extraction Algorithm

```
walk tokens forward:
  track paren depth (skip subqueries when depth > 0)
  WHEN keyword IN {FROM, JOIN, UPDATE, INTO}:
    capture next identifier(s) → add to table list
    IF next token is alias (bare ident, not keyword) → record alias
  WHEN keyword = WITH AND at depth 0:
    capture CTE names → add to CTE list
    skip CTE definition body (to matching `)`)
```

### Statement Boundary Detection

Rust already has `split_statements()` in `sql_parser.rs` that correctly handles
strings, comments, and escaped quotes. The fix for indicator placement is:

1. Export a `find_statement_line_range()` function that maps cursor line to
   (start_line, end_line) using the tokenizer
2. Call this instead of the Lua-side `extract_stmt_at_cursor()`
3. Lua uses the returned start_line for indicator placement

### Fix Matrix

| Issue | Current Lua | New Rust |
|-------|------------|----------|
| `-- FROM` triggers table context | Yes (bug) | No (comment-aware) |
| `-- WHERE` triggers column context | Yes (bug) | No (comment-aware) |
| `FROM 'WHERE here'` → no context | Works by accident | Always correct |
| Subquery table leak | Leaks | Paren-tracked |
| CTE inner table leak | Leaks | Skip CTE body |
| Schema-qualified tables | Only first component | Full qualified name |
| Operators in COLUMN_CTX | Dead code | Properly handled |
| `;` in string → split on wrong line | Bug | Correct |
| Indicator placement after `;` in string | Wrong line | Correct |

### Migration Path

1. Add `sql_context.rs` with full implementation
2. Add `poste context` CLI subcommand
3. Update `completion.lua` to call Rust for context detection (fallback to Lua)
4. Update `init.lua` statement extraction to use Rust statement boundaries
5. Run existing test suite — all pass
6. Remove deprecated Lua code once stable
