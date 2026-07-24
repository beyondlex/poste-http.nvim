# Tree-sitter Migration Design

## Motivation

`cache.lua` currently uses **regex-based line-by-line scanning** (~250 lines) to determine line types, block bounds, variables, and imports. This is brittle, slow on large files, and fundamentally cannot handle nested or ambiguous syntax correctly (e.g., JSON body with `:` inside being mistaken for a header).

Tree-sitter provides an **incremental parse tree** — the parser already runs, but its output is only used for highlighting and folds. This document plans how to make it the **single source of truth** for all editor features.

---

## Current Architecture (Regex-based)

```
cache.lua (regex scan)
  ├── line_type[]     → O(1) per line lookup
  ├── blocks[]        → request block bounds
  ├── file_vars[]     → @var / <<var names
  ├── req_names[]     → request names
  └── file_imports[]  → import paths

Consumers:
  nav.lua              → gd, grr, jump (uses regex + cache)
  context_detector.lua → completion context (uses regex + cache)
  item_builder.lua     → completion items (uses cache)
  outline.lua          → symbol list (uses regex, ignores cache)
  completion.lua       → delegate to item_builder
```

---

## Target Architecture (Tree-sitter-based)

```
tree-sitter parser (incremental)
  ├── ts_query.lua (new)  → query helpers
  │   ├── get_node_at_cursor(buf, row, col) → node
  │   ├── get_parent_of_type(buf, type)     → node
  │   ├── collect_nodes(buf, query)         → list of nodes
  │   └── get_node_text(node)               → string
  │
  ├── nav.lua            → gd via tree-sitter cursor
  ├── context_detector.lua → completion via tree-sitter node type
  ├── item_builder.lua   → completion items via tree-sitter
  ├── outline.lua        → symbols via tree-sitter query
  ├── folding.lua (new)  → foldexpr via tree-sitter
  ├── textobj.lua (new)  → text objects via tree-sitter
  ├── diagnostics.lua (new) → real-time syntax checking
  ├── format.lua         → optional: buffer-level formatting via tree-sitter
  │
  └── cache.lua (deprecated) → removed after all consumers migrate
```

---

## Phase 0: ts_query.lua (Foundation)

**File:** `lua/poste/http/ts_query.lua`

A thin abstraction over `vim.treesitter` APIs. All other modules import this instead of calling tree-sitter directly.

```lua
-- Core API:
M.node_at_point(buf, row, col)       → node or nil
M.node_text(node)                     → string
M.parent_of_type(node, type)         → node or nil
M.query_nodes(buf, query_string)     → { { node, captures } }
M.query_nodes_in_range(buf, query, start_row, end_row)
M.get_parser(buf)                    → parser or nil
```

**Why a wrapper:** If the tree-sitter API changes (Neovim 0.10 → 0.11), only this module needs updating. Also allows unit testing with mock trees.

---

## Phase 1: gd (Go to Definition)

**Current:** `nav.lua` uses regex to find `{{var}}` boundaries, then scans the buffer line-by-line matching `@var` / `<<var` patterns. Also checks `request.variables.set("var", ...)` in script blocks.

**Target:** Use tree-sitter to:

1. `node_at_point(buf, row, col)` → get the node under cursor
2. If node type is `variable`:
   - Extract identifier from child node
   - Query the document for `(variable_definition (var_name) @name (#eq? @name "xxx"))`
   - If not found, query for `(request_block (request_name) @name (#eq? @name "xxx"))`
3. If node type is `run_target`:
   - Parse `#Name` or `#alias.Name`
   - Find import alias via `import_alias_clause` node
   - Find request block in target file
4. If inside `script_block`:
   - Use tree-sitter Lua parser (injected via `injections.scm`) to find `local xxx` or `xxx =`
5. If node type is `import_path`:
   - Open the file

**Benefit:** No more buffer scanning. O(log n) tree traversal instead of O(n) line scan.

---

## Phase 2: Autocompletion Context

**Current:** `context_detector.lua` uses 181 lines of regex heuristics. It has edge cases like:
- `name: John` in JSON body detected as header
- `commit.author.name, key:` misidentified as header key
- `@example.com` parsed as header key

**Target:** Replace `detect_context()` with a single tree-sitter query:

```lua
function M.detect_context(buf, line, col)
  local node = ts_query.node_at_point(buf, line - 1, col)
  if not node then return "method" end

  local type = node:type()
  local parent = ts_query.parent_of_type(node, "request_line", "header", "json_body",
                                         "script_block", "variable_definition", ...)

  if parent:type() == "request_line" then
    if node:type() == "url" then return nil end  -- in URL, no completion
    return "method"  -- before method
  elseif parent:type() == "header" then
    if node:type() == "header_key" then return "header_value" end
    return "method_or_header"
  elseif parent:type() == "json_body" then
    return nil  -- JSON body, no HTTP completion
  elseif parent:type() == "script_block" then
    return "pre_script" or "post_script"
  elseif parent:type() == "variable" then
    return "variable"
  end
end
```

**Benefit:** Zero false positives. Tree-sitter knows exactly which node you're in.

---

## Phase 3: Folding (foldexpr)

**Current:** `folds.scm` defines fold regions at `separator`, `multiline_variable`, `pre_script`, `post_script`. Neovim will use these automatically if `foldmethod=expr` and `foldexpr=nvim_treesitter#foldexpr()`.

**Target:** Set `foldmethod=expr` and `foldexpr` in `buffer_setup.lua` for `poste_http` filetype:

```lua
vim.bo[buf].foldmethod = "expr"
vim.bo[buf].foldexpr = "v:lua.require('poste.http.folding').foldexpr()"
```

With `folding.lua` providing:

```lua
function M.foldexpr()
  local node = ts_query.node_at_point(0, vim.v.lnum - 1, 0)
  -- Walk up to find foldable parent
  while node do
    local t = node:type()
    if t == "request_block" then
      return ">" .. (node:end_row() - node:start_row())
    elseif t == "json_body" or t == "script_block" then
      return ">" .. (node:end_row() - node:start_row())
    end
    node = node:parent()
  end
  return "="
end
```

**Benefit:** Precise folding at request block boundaries, no off-by-one errors from regex.

---

## Phase 4: Text Objects

**New feature.** Define text objects for `.http` files:

| Mapping | Object | Treesitter Query |
|---------|--------|-----------------|
| `vir` | Inner request block | `(request_block) @obj` |
| `var` | Around request block | `(request_block) @obj` |
| `vih` | Inner headers | `(header) @obj` (collect all consecutive headers) |
| `vib` | Inner body | `(json_body) @obj` or `(multipart_boundary) @obj` |
| `vis` | Inner script | `(script_block) @obj` |

Implementation in `textobj.lua`:

```lua
function M.select_request_block()
  local node = ts_query.parent_of_type(
    ts_query.node_at_point(0, vim.v.lnum - 1, vim.v.col),
    "request_block"
  )
  if node then
    local sr, sc, er, ec = node:range()
    vim.api.nvim_feedkeys(string.format("%dG%d|%dG%d|", sr+1, sc, er+1, ec), "n", false)
  end
end
```

**Benefit:** Vim-native text objects for HTTP structure. No regex needed.

---

## Phase 5: Real-time Diagnostics

**New feature.** Use tree-sitter's error nodes to detect syntax errors in real-time.

```lua
function M.update_diagnostics(buf)
  local parser = ts_query.get_parser(buf)
  local tree = parser:parse()[1]
  local root = tree:root()

  local diagnostics = {}
  local function walk(node)
    if node:type():find("ERROR") or node:type():find("MISSING") then
      local sr, sc, er, ec = node:range()
      table.insert(diagnostics, {
        lnum = sr, col = sc,
        end_lnum = er, end_col = ec,
        severity = vim.diagnostic.severity.ERROR,
        message = "Syntax error: unexpected " .. node:type(),
      })
    end
    for child in node:iter_children() do
      walk(child)
    end
  end
  walk(root)

  vim.diagnostic.set(vim.api.nvim_create_namespace("poste_http"), buf, diagnostics)
end
```

**Also check semantic rules:**
- Missing method in request line
- Empty header value when required
- Unclosed `{{` or `{%`
- Duplicate `@var` definitions
- `import` with non-existent file

**Benefit:** Catches errors before execution. Reduces "run and fail" cycle.

---

## Phase 6: Outline (Symbol View)

**Current:** `outline.lua` uses regex to scan for `### Name`, `@var`, `<<var`. It re-scans every time.

**Target:** Use tree-sitter:

```lua
local query = [[
  (request_block
    (separator)
    (request_name) @name)
  (variable_definition
    (var_name) @var)
  (prompt_variable
    (prompt_name) @prompt)
]]

local items = {}
for _, match in ipairs(ts_query.query_nodes(buf, query)) do
  table.insert(items, {
    name = ts_query.node_text(match.captures[1]),
    line = node:start(),
    kind = match.captures[1]:type() == "request_name" and "request" or "variable",
  })
end
```

**Benefit:** Reactive — attach to `TextChanged` via tree-sitter's `on_did_change` callback instead of full re-scan.

---

## Phase 7: Formatting (Optional)

**Current:** `PosteFormatHttp` delegates to `poste fmt` Rust CLI.

**Target:** Optionally add an in-editor formatting path that uses tree-sitter to:
- Sort headers alphabetically
- Normalize header key capitalization
- Ensure consistent `### ` separator format
- Strip trailing whitespace

This would be a Lua-only formatter (no CLI dependency), but would be less capable than the Rust formatter. The Rust CLI remains the primary formatter.

---

## Migration Order

| Phase | Module | Effort | Risk | Value |
|-------|--------|--------|------|-------|
| 0 | `ts_query.lua` | Small | Low | Foundation |
| 1 | `nav.lua` (gd) | Medium | Medium | High — fixes gd accuracy |
| 2 | `context_detector.lua` | Medium | Medium | High — fixes completion false positives |
| 3 | `folding.lua` | Small | Low | Medium — better folds |
| 4 | `textobj.lua` | Small | Low | Medium — new ergonomics |
| 5 | `diagnostics.lua` | Medium | Medium | High — catches errors early |
| 6 | `outline.lua` | Small | Low | Medium — reactive outline |
| 7 | `format.lua` | Low | Low | Low — Rust CLI still primary |

**Phases 1-2 should be done together** since they share the same tree-sitter node-at-point infrastructure.

---

## Rollout Strategy

1. **Phase 0 first** — write `ts_query.lua`, test it with `M.inspect()` in `treesitter.lua`
2. **Per-module flag** — each module gets a `use_treesitter` config option, defaulting to `false`
3. **A/B test** — user can toggle between regex and tree-sitter for each feature
4. **Remove cache.lua scanning** — only after all consumers have migrated

This avoids breaking existing functionality while the new tree-sitter code matures.

---

## Grammar Gaps

Current grammar (`grammar.js`) needs these additions for full feature coverage:

| Missing | Needed for | Priority |
|---------|-----------|----------|
| `request_body` node (wraps all body types) | Text objects, folding | High |
| `url` field for method/URL extraction | Outline, gd | Medium |
| Field names on `request_block` (e.g., `name: (request_name)`) | Outline | Medium |
| `ERROR` node for unknown syntax | Diagnostics | Low |
| `indents.scm` | Auto-indent | Low |