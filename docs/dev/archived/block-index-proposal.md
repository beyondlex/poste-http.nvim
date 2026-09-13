# Block Index Proposal (Agent-Ready)

> Based on the HTTP syntax specification.

---

## 0. Background and Motivation

### Problem

The HTTP completion system and related modules currently use "line-by-line pattern matching" to answer "where am I in the document?" — this is string guessing, not structural querying. Specific symptoms:

**A. 5+ independent `###` boundary detectors**
- `indicators.lua`, `boundary_indicator.lua`, `request_vars.lua`, `symbols.lua`, `import.lua` each implement their own `###` backtracking/forward-scan logic
- Edge case handling is inconsistent: some return 0-indexed, some 1-indexed, some skip comments, some don't
- Fixing a bug in one place doesn't propagate to others

**B. Completion hot path O(n) scanning**
- `context_detector.lua:detect_script_context` scans from buffer start to cursor line on every keystroke, line-by-line `:find("{%")` / `%}`
- `cache.lua:collect_request_vars` re-scans `find_request_block_bounds` + reads block lines + pattern matching on every completion trigger
- On a 100+ line `.http` file, each completion trigger does ~200 Lua string operations + Nvim API calls

**C. No single source of truth**
- Adding a new context type (e.g., body JSON path completion) requires a new branch in `context_detector.lua`'s if-else chain
- Can't directly answer "which block is the cursor in, and which section within the block?"

### Goal

1. Eliminate all duplicate `###` boundary scanning, unified into one code path
2. Completion hot path from O(n) to O(1) table lookup
3. Document structure explicitly modeled, future extensions don't need scanning logic changes
4. Zero behavior change — completion content and experience unchanged, only internal query mechanism

### Acceptance Criteria

- `detect_script_context` no longer calls `nvim_buf_get_lines` to scan — uses `line_type[]` table lookup
- `collect_request_vars` no longer calls `find_request_block_bounds` and `nvim_buf_get_lines`
- After Phase 3, `find_request_block_bounds` and `find_request_line` in `indicators.lua` contain no scanning logic — all delegation
- All existing tests pass
- No residual duplicate `###` boundary detection implementations

---

## 1. Data Model (Single Deterministic Structure)

Only one structure: **`line_type` array** + **`blocks` list**. No `sections`.

```lua
--- One per buffer, held by `cache.lua`
buffer_blocks[buf] = {
  changedtick = ct,          -- vim.api.nvim_buf_get_changedtick(buf)

  --- File-level area (before first `###`)
  file_vars    = { ["name"] = true, ... },
  file_imports = {
    { type = "bare",   path = "./auth.http" },
    { type = "aliased", path = "./orders.http", alias = "orders" },
  },

  --- Request block list (in document order)
  blocks = {
    [1] = {
      name       = "Get Users",     -- text after ###, trimmed, may be ""
      start_line = 7,               -- ### line number (1-indexed)
      end_line   = 42,              -- block end line (next ### - 1, or EOF)

      --- Pre-computed data
      block_vars = { ["name"] = true, ... },  -- all @var definitions in block
      has_pre    = false,           -- has pre-script
      has_post   = false,           -- has post-script
      has_run    = false,           -- has run directive
    },
    ...
  },

  --- Per-line type mapping (key structure)
  --- key = line number (1-indexed)
  --- value = line type string
  line_type = {
    [1]  = "file",         -- File-level area (import / @var / # comment / blank)
    [2]  = "file",
    ...
    [7]  = "head",         -- ### line
    [8]  = "var",          -- @var / @env definition
    [9]  = "pre_script",   -- pre-script line
    [10] = "pre_script",
    [11] = "prompt",       -- <<name prompt variable line
    [12] = "var",          -- @var definition (interleaved with pre-script)
    [13] = "request",      -- METHOD URL line
    [14] = "header",       -- Key: Value line
    [15] = "header",
    [16] = "empty",        -- Blank line (headers/body separator)
    [17] = "body",         -- body / run / file include / comment
    [18] = "run",          -- run directive line
    [19] = "body",         -- body continues
    [20] = "empty",        -- Blank line
    [21] = "post_script",  -- post-script line
    [22] = "post_script",
    [23] = "post_script",
  },
}
```

**Why `line_type` instead of `sections`:**
- Block head area has `@var` / pre-script / `<<var` arbitrarily interleaved, continuous intervals can't precisely represent this
- `line_type` answers "what is this line?" directly in O(1)
- `sections` can be derived from `line_type` without extra storage

---

## 2. Cache Ownership (Single Deterministic Location)

**Block index lives in `cache.lua`, without changing `get_buffer_cache` signature.**

Details:

```
cache.lua:
  get_buffer_cache(buf)  ← existing function, keep signature
    → scan buffer (existing logic: collect file_vars, req_names)
    → add line_type, blocks, file_imports construction in same scan pass
    → returned cache table adds: .line_type, .blocks, .file_imports

  New query functions (all in cache.lua):
    get_line_type(buf, line)        → string|nil
    get_block_at_line(buf, line)    → block|nil
    get_block_vars(buf, line)       → { name = true }
    get_file_vars(buf)              → { name = true } (already exists)
```

No new `block_index.lua` module. All logic in `cache.lua`. Reasons:
- Cache lifecycle and invalidation already handled by `get_buffer_cache`'s `changedtick` guard + `ensure_cache_autocmd`
- New module would need to re-handle `BufDelete`, `TextChanged` etc. autocmds
- Block index is an extension of `get_buffer_cache`, not an independent feature

---

## 3. Scan Algorithm (Line-by-Line Classification Rules)

Single-pass scan of all buffer lines, classifying each. Classification priority (first match wins):

```
for each line in lines:
  trimmed = vim.trim(line)

  if past_first_block == false:
    if line:match("^%s*###"):
      past_first_block = true
      type = "head"
    elseif line:match("^@(%w[%w_]*)%s*[= ]"):
      type = "var"
      file_vars[name] = true
    elseif line:match("^import "):
      type = "file"
      parse_import_line()  → file_imports[]
    else:
      type = "file"        -- # comment / blank / other

  else (inside a request block):
    if line:match("^%s*###"):
      type = "head"        ← previous block ends, new block starts
    elseif line:match("^@(%w[%w_]*)%s*[= ]"):
      type = "var"
      block_vars[name] = true
    elseif line:match("^<%s*{%%") or line:match("^<%s*%.?%."):
      type = "pre_script"
      has_pre = true
    elseif in_pre_block:                    -- inside unfinished < {% block
      type = "pre_script"
      if trimmed == "%}": in_pre_block = false
    elseif line:match("^>%s*{%%") or line:match("^>%s*%.?%."):
      type = "post_script"
      has_post = true
    elseif in_post_block:                   -- inside unfinished > {% block
      type = "post_script"
      if trimmed == "%}": in_post_block = false
    elseif line:match("^%s*<<%w") or line:match("^%s*#%s*<<"):
      type = "prompt"
    elseif line:match("^[A-Z]+%s+%S"):
      if not request_found_in_block:
        type = "request"
        request_found_in_block = true
      else:
        type = "body"      -- second uppercase-starting line treated as body
    elseif line:match("^[%w%-]+%s*:"):
      type = "header"
    elseif line:match("^run "):
      type = "run"
      has_run = true
    elseif trimmed == "":
      type = "empty"
      if request_found_in_block and not body_started:
        body_started = true   -- first empty line = headers/body separator
    else:
      type = "body"
```

Key rules:
- **Request line detection**: First word all-caps, second word non-empty. Only first match in block counts (subsequent uppercase words = body)
- **Pre-script range**: `< {%` to next `%}` all marked as `"pre_script"` (inclusive)
- **Post-script range**: Same, `> {%` to `%}`
- **Single-line pre/post**: `< {% code %}` / `> {% code %}` completed in one line, entire line marked as pre_script/post_script
- **External scripts**: `< ./path.lua` / `> ./path.lua` entire line marked pre_script/post_script
- **Header detection**: `Key: Value` format. May match `Date: 2024` type values, but doesn't affect structural classification
- **Body range**: All non-empty lines after first empty line (after request is found)

---

## 4. API Mapping (Line-Precise)

All existing module queries, mapped to new O(1) queries:

| Query | Current Implementation | New Implementation |
|-------|----------------------|-------------------|
| Inside pre-script? | `detect_script_context` O(n) scan | `line_type[line] == "pre_script"` |
| Inside post-script? | Same | `line_type[line] == "post_script"` |
| Current block's vars | `collect_request_vars` re-scan buffer | `get_block_at_line().block_vars` |
| Current block start/end | `find_request_block_bounds` scan | `get_block_at_line().start_line / end_line` |
| Inside body? | Implicit: not other = body | `line_type[line] == "body"` |
| Inside header? | `:match(":")` | `line_type[line] == "header"` |
| Inside head? | `:match("@")` / blank judgement | `{"var","pre_script","prompt","head"} ~= nil` |
| File-level vars | `get_buffer_cache().file_vars` | Same field |
| All vars (current block) | Two scans: file + block | `merge(file_vars, block_vars, env_vars)` |

---

## 5. TDD Development Process

All changes follow TDD: write tests first, then implementation.

### Test Framework

Using existing `tests/run.sh`. New additions under `tests/`:

```
tests/test_block_index.lua         ← Block index construction and query tests
tests/data/http/                   ← Test .http files
  ├── simple.http
  ├── interleave.http              ← @var and pre-script interleaved
  ├── multi_block.http
  ├── no_blocks.http               ← File with no ###
  ├── minimal.http                 ← Only ###, no other content
  ├── prompt.http                  ← With <<name prompt variables
  ├── import_run.http              ← With import / run
  └── edge_cases.http              ← Various edge cases
```

### Phase 1 Tests (`test_block_index.lua`)

Write first, then implement `cache.lua` scan extension:

```lua
-- Test 1: File-level variables
-- Test 2: Block-level variables
-- Test 3: line_type mapping
-- Test 4: Pre-script multi-line
-- Test 5: Pre-script single-line
-- Test 6: Post-script
-- Test 7: @var and pre-script interleaved
-- Test 8: No ### → all "file"
-- Test 9: Empty ### block
-- Test 10: <<name (prompt directive)
-- Test 11: run directive
-- Test 12: import file-level
-- Test 13: Empty line after body line type
-- Test 14: get_block_at_line boundaries
-- Test 15: get_block_vars
```

### Phase 1 Implementation (`cache.lua`)

Modify `get_buffer_cache` scan logic in `cache.lua`:

```
scan_lines(lines):
  → returns { file_vars, blocks[], line_type{}, file_imports[] }

Replace existing scan, keep return structure, add new fields
```

**Do not** change `get_buffer_cache` call signature. Existing callers (`collect_file_vars`, `collect_request_names`) remain unchanged.

### Phase 2 Tests + Implementation

Modify:
- `context_detector.lua:detect_script_context` — from scan to `line_type` query
- `context_detector.lua:detect_context` — from pattern to `line_type` + precise line judgement
- `cache.lua:collect_request_vars` — from re-scan to `get_block_at_line().block_vars`
- Related calls in `item_builder.lua:build_script_variable_items`

### Phase 3

Replace delegation functions one by one, run tests after each replacement:

```
1. indicators.lua:find_request_block_bounds → cache.get_block_at_line(buf, line)
2. request_vars.lua:collect_requests → cache.get_buffer_cache(buf).blocks
3. boundary_indicator.lua:find_block → delegate
4. symbols.lua:collect_requests → delegate
5. import.lua:extract_request_names → block index if buffer, not content string
```

---

## 6. Running Tests

```bash
# All tests
tests/run.sh

# Block index only
tests/run.sh test_block_index

# Completion only
tests/run.sh test_completion
```

Each Phase merge runs full test suite to verify no regression.

---

## 7. Out of Scope

- Don't cache `line_type` query results in `context_detector.lua` (cache.lua's `changedtick` is sufficient)
- Don't expose raw `line_type` / `blocks` tables outside `cache.lua` (access through query functions)
- Don't modify `data.lua`
- Don't modify `completion.lua` (adapter layer)
- Don't change `get_buffer_cache` signature
- Don't modify Rust side
