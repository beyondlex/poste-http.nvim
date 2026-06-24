# Poste Code Smells & Technical Debt Report

**Generated**: 2026-06-18  
**Scope**: Lua (SQL module), Rust (executor), architecture  
**Priority**: High to Low

---

## 🔴 Critical Issues (Refactor Now)

### 1. **Massive God Function: `M.edit_cell()` in `editor.lua`** (Lines 815-987)
**Severity**: 🔴 HIGH  
**Issue**: Single function handles 5+ distinct responsibilities:
- Cell value editing UI
- Type-specific UI dispatch (boolean selector, date picker, enum selector, text input)
- Validation & error tracking
- Edit state management

**Impact**:
- **173 lines** of deeply nested if-else chains
- Testing: Impossible to test individual UI flows without full setup
- Maintenance: Adding a new type requires modifying a single massive function

**Code Smell Pattern**:
```lua
-- Lines 856-916: Boolean branch
if M.is_boolean_column(col_meta) then
  -- 20 lines of UI setup

-- Lines 877-916: Date branch  
if M.is_datetime_column(col_meta) then
  -- 40 lines of UI setup

-- Lines 918-946: Enum branch
if M.is_enum_column(col_meta) then
  -- 30 lines of UI setup

-- Lines 948-987: Text input branch
-- 40 lines of UI setup
```

**Fix Strategy**: Extract type-specific UI handlers into strategy pattern:
```lua
-- NEW: editor_ui_strategies.lua
local strategies = {
  boolean = function(old_val, col_meta) ... end,
  datetime = function(old_val, col_meta) ... end,
  enum = function(old_val, col_meta) ... end,
  text = function(old_val, col_meta) ... end,
}

-- Modified: editor.lua
function M.edit_cell()
  -- Guards...
  local handler = strategies[M.detect_type(col_meta)]
  if handler then handler(old_val, col_meta) end
end
```

**Effort**: 2-3 hours | **ROI**: High (testability + maintainability)

---

### 2. **Scattered Type Classification Boilerplate** in `editor.lua` (Lines 11-53)
**Severity**: 🔴 HIGH  
**Issue**: 8 separate lookup tables for type classification:
```lua
NUMERIC_TYPES = { integer=true, int=true, ... }
INTEGER_TYPES = { integer=true, int=true, ... }
BOOLEAN_TYPES = { boolean=true, bool=true }
DATE_TYPES = { date=true, timestamp=true, ... }
JSON_TYPES = { json=true, jsonb=true }
UUID_TYPE = { uuid=true }
TEXT_TYPES = { text=true, varchar=true, ... }
INEDITABLE_TYPES = { binary=true, bytea=true, ... }
```

Then 8+ functions (lines 59-108) implement the same pattern:
```lua
function M.is_numeric_type(ctype)
  if not ctype then return false end
  return NUMERIC_TYPES[ctype:lower()] or false
end

function M.is_integer_type(ctype)
  if not ctype then return false end
  return INTEGER_TYPES[ctype:lower()] or false
end
-- ... repeat 6+ times
```

**Impact**:
- **200+ lines** of boilerplate
- DRY violation: Each new type category needs table + function pair
- No hierarchy: `NUMERIC_TYPES` should include `INTEGER_TYPES` conceptually, but don't

**Fix Strategy**: Unified type registry:
```lua
local TYPES = {
  numeric = {
    integer = true, int = true, bigint = true, ...,
    subtypes = { "integer", "int", ... }
  },
  datetime = { ... },
  editable = { ... },
}

local function is_type(ctype, category)
  if not ctype or not TYPES[category] then return false end
  return TYPES[category][ctype:lower()] or false
end

M.is_numeric = function(c) return is_type(c, "numeric") end
M.is_integer = function(c) return is_type(c, "integer") end
-- ... single pattern
```

**Effort**: 1-2 hours | **ROI**: Medium (less cognitive load, easier to extend)

---

### 3. **Massive Primary Key Introspection Function** in `editor.lua` (Lines 508-711)
**Severity**: 🔴 HIGH  
**Issue**: 204-line monolithic function `ensure_primary_key()` contains:
- Connection string parsing
- Dialect-specific SQL query generation (MySQL, PostgreSQL, SQLite)
- Enum value extraction (3 separate code paths)
- Error handling & retry logic
- Multi-stage async job management

**Code Structure Problem**:
```lua
function M.ensure_primary_key(tab)
  -- 25 lines: setup, cache checks
  -- 10 lines: MySQL query generation
  -- 15 lines: PostgreSQL query generation  
  -- 10 lines: SQLite query generation
  -- 80 lines: sys call + response parsing
  -- 50 lines: enum extraction (again 3 dialect-specific paths)
end
```

**Impact**:
- Testing: Impossible without full system setup
- Maintenance: Changing dialect logic requires editing one massive function
- Performance: Enum query runs AFTER PK query, no parallelization

**Fix Strategy**: Split into modules:
```lua
-- NEW: editor_pk_detect.lua
local function detect_pk_postgres(table_name, schema) ... end
local function detect_pk_mysql(table_name, db) ... end
local function detect_pk_sqlite(table_name) ... end

local function run_introspection_query(query, dialect) ... end

-- Modified: editor.lua
function M.ensure_primary_key(tab)
  if cache_hit(tab) then return end
  
  local pk_query = select("detect_pk_" .. tab.layout.dialect, 
    tab.layout.table_name, tab.layout.database)
  
  run_introspection_query(pk_query, tab)
end
```

**Effort**: 3-4 hours | **ROI**: High (testability, code reusability for other introspection tasks)

---

## 🟡 Major Issues (Refactor Soon)

### 4. **Duplicate Quad-state Cell Modification Tracking** in `editor.lua` + `edit_commit.lua`
**Severity**: 🟡 MAJOR  
**Issue**: Edit state tracking is split across two files with overlapping concerns:

**editor.lua** (Lines 297-427):
```lua
edit_state = {
  dirty = false,
  modified_cells = {},
  deleted_rows = {},
  added_rows = {},
  original_rows_snapshot = {},
  cell_errors = {},
}

function M.track_cell_edit(es, row_key, col, old_val, new_val)
  -- 25 lines of tracking logic
end

function M.get_edit_summary(es)
  -- Count changes
end
```

**edit_commit.lua** (Lines 195-261):
```lua
function M.generate_dml(es, tab, dialect)
  -- 60 lines: iterate edit_state to build SQL
  
function M.generate_combined_dml(es, tab, dialect)
  -- Build UPDATE/INSERT/DELETE SQL
  
function M.generate_update(schema, table_name, columns, modifications, row_values, dialect)
  -- 25 lines per statement
end
```

**Problem**: 
- `editor.lua` manages state mutations
- `edit_commit.lua` queries state to build SQL
- No clear state lifecycle, scattered validation
- Testability: Must test both modules together

**Fix Strategy**: Unified edit state machine:
```lua
-- NEW: edit_state.lua
local EditState = {}

function EditState:new()
  return {
    modifications = {},  -- unified tracking
    integrity_check = function() ... end,
  }
end

function EditState:apply_change(row_idx, col_idx, new_val)
  -- Mutation + validation
end

function EditState:get_dml_statements()
  -- Generate SQL
end

-- Usage in editor.lua
local es = EditState:new()
es:apply_change(row, col, val)

-- Usage in edit_commit.lua
local sql_stmts = es:get_dml_statements()
```

**Effort**: 2-3 hours | **ROI**: High (single source of truth for edit state)

---

### 5. **Deep Nesting in Search/Filter Pipeline** in `buffer_search.lua` (Lines 70-160)
**Severity**: 🟡 MAJOR  
**Issue**: `show_search()` function contains deeply nested callbacks:
- vim.ui window creation
- prompt buffer setup with callbacks
- Nested async callback chains
- Multiple state mutations in callbacks

**Nesting Level: 5**
```lua
function M.show_search()
  -- Setup window
  vim.fn.prompt_setcallback(buf, function(text)  -- LEVEL 1
    -- Process search text
    tab.rows_source = ...
    -- ... 40 lines of business logic in callback
    jump_to_search_match(1)
  end)
end

local function jump_to_search_match(idx)
  -- More state mutations
  require("poste.sql.buffer_page").refresh_page()
  sql_highlights.highlight_cell(...)
  M.apply_search_highlights()
  update_winbar()  -- LEVEL 2+
end
```

**Impact**:
- Difficult to trace state changes
- Callback-hell: Hard to understand execution order
- Testing: Can't mock vim.ui.select easily

**Fix Strategy**: Extract state management from UI:
```lua
-- NEW: search_state.lua
local function execute_search(text, rows_source, tab)
  -- Pure logic: no vim.* calls
  return { matches = {}, by_page = {}, ... }
end

-- In buffer_search.lua
vim.fn.prompt_setcallback(buf, function(text)
  vim.schedule(function()  -- SINGLE async point
    local search_result = execute_search(text, ...)
    jump_to_search_match(search_result, 1)  -- Pass result, not global state
  end)
end)
```

**Effort**: 2-3 hours | **ROI**: Medium (testability, easier to compose with other features)

---

### 6. **Repeated Log Entry Escaping** in `edit_commit.lua` (Lines 284-325)
**Severity**: 🟡 MAJOR  
**Issue**: Multiple similar log formatting patterns (duplicated escape logic):

```lua
-- Line 303: SQL escape
local escaped = entry.sql:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")

-- Line 313: Error message escape (SAME PATTERN)
local escaped = entry.error_msg:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")

-- Line 318-322: Manual JSON building (should use vim.json.encode)
table.insert(parts, '"edit_summary": {'
  .. '"updates": ' .. tostring(s.updates or 0) .. ', '
  -- ... error-prone manual JSON
end
```

**Impact**:
- DRY: Escape logic repeated 2+ times
- Bug risk: Inconsistent escaping between fields
- Maintainability: JSON serialization should use stdlib, not manual concatenation

**Fix Strategy**:
```lua
-- Helper
local function escape_json_string(s)
  return s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
end

-- Use vim.json where possible
function M.format_log_entry(entry)
  local data = {
    ts = os.date("!%Y-%m-%dT%H:%M:%S"),
    sql = entry.sql,
    edit_summary = entry.edit_summary,
    -- ...
  }
  return vim.json.encode(data)
end
```

**Effort**: 1 hour | **ROI**: High (prevents bugs, cleaner code)

---

## 🟠 Medium Issues (Refactor When Time Permits)

### 7. **Type Guard Overhead in Completion Module** in `completion.lua` (Lines 105-166)
**Severity**: 🟠 MEDIUM  
**Issue**: Completion detection has multiple fallback layers with unclear precedence:

```lua
function try_rust_context(bufnr, line_before, cursor_line)
  -- Check filetype
  local ok_ft, ft = pcall(vim.api.nvim_buf_get_option, bufnr, "filetype")
  if not ok_ft or (ft ~= "poste_sql" and ft ~= "poste_sqlite") then return nil end
  
  -- Extract SQL
  local sql_text, offset = extract_sql_block(bufnr, ...)
  if not sql_text then return nil end
  
  -- Check cache
  local ckey = cache_key(bufnr, cursor_line, line_before)
  if _ctx_cache[ckey] then return _ctx_cache[ckey] end
  
  -- Check binary exists
  local binary = data.find_binary()
  if not binary then return nil end
  
  -- Run system command
  -- ... 20+ more lines with multiple error checks
end
```

**Impact**:
- Hard to debug: 7+ guard clauses, unclear which one failed
- Performance: Redundant cache checks on every completion
- Testability: Tight coupling to vim.* APIs

**Fix Strategy**: Extract guard clauses:
```lua
local function can_use_rust_context(bufnr)
  local ok_ft, ft = pcall(vim.api.nvim_buf_get_option, bufnr, "filetype")
  return ok_ft and (ft == "poste_sql" or ft == "poste_sqlite") and data.find_binary() ~= nil
end

function try_rust_context(bufnr, line_before, cursor_line)
  if not can_use_rust_context(bufnr) then return nil end
  
  -- Single responsibility: actual Rust call
end
```

**Effort**: 1-2 hours | **ROI**: Medium (testability, debuggability)

---

### 8. **Hardcoded Query Strings Scattered Across Modules**
**Severity**: 🟠 MEDIUM  
**Issue**: SQL metadata queries embedded in multiple places:

**editor.lua (Lines 534-565)**:
```lua
-- MySQL PK query (hardcoded)
meta_query = string.format(
  "SELECT c.COLUMN_NAME, c.COLUMN_DEFAULT, c.EXTRA, "
  .. "CASE WHEN k.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS IS_PK "
  .. "FROM INFORMATION_SCHEMA.COLUMNS c "
  -- ... 5 more lines
```

**Problem**: 
- DRY: Each dialect has its own query embedded
- Maintenance: Updating schema query requires editing buried in function
- Testing: Can't test SQL independently

**Fix Strategy**: Metadata query registry:
```lua
-- NEW: metadata_queries.lua
local QUERIES = {
  postgres = {
    primary_keys = [[
      SELECT c.column_name, c.column_default, ...
    ]],
    enums = [[
      SELECT t.typname, e.enumlabel, ...
    ]],
  },
  mysql = { ... },
  sqlite = { ... },
}

-- Usage in editor.lua
local query = QUERIES[dialect].primary_keys
```

**Effort**: 2-3 hours | **ROI**: Medium (maintainability, testability)

---

### 9. **Implicit State Coupling in Buffer Navigation** in `buffer_nav.lua`
**Severity**: 🟠 MEDIUM  
**Issue**: Global state mutations in cell navigation cascade effects:

```lua
function M.move_cell(drow, dcol)
  -- ... update state.sql.cell
  state.sql.cell.row = row
  state.sql.cell.col = col
  
  -- Then trigger 3 side effects in sequence
  sql_highlights.highlight_cell(...)  -- Updates extmark namespace
  if dcol ~= 0 then
    M.update_header_float()  -- Reads state.sql, mutates float window
  end
  T_report()  -- Logs timing
end
```

**Problem**:
- Silent assumptions: `update_header_float()` assumes `state.sql.cell` already updated
- Testability: Must set up full state tree to test cell highlighting
- Order dependency: Calling functions in wrong order causes bugs

**Fix Strategy**: Event-driven approach:
```lua
-- NEW: event_system.lua
local function emit_cell_moved(row, col, direction)
  vim.api.nvim_exec_autocmds("User", { pattern = "PosteCellMoved" })
end

-- In buffer_nav.lua
function M.move_cell(drow, dcol)
  state.sql.cell.row = new_row
  state.sql.cell.col = new_col
  emit_cell_moved(new_row, new_col, {drow = drow, dcol = dcol})
end

-- In highlights.lua
vim.api.nvim_create_autocmd("User", {
  pattern = "PosteCellMoved",
  callback = function() highlight_cell(...) end,
})

-- In buffer_nav.lua (separate autocmd)
vim.api.nvim_create_autocmd("User", {
  pattern = "PosteCellMoved",
  callback = function(ev)
    if ev.data.dcol ~= 0 then update_header_float() end
  end,
})
```

**Effort**: 3-4 hours | **ROI**: Low (improvement is subtle, low priority)

---

## 🟡 Minor Issues (Nice to Have)

### 10. **Inconsistent Error Handling in Rust Executor**
**Location**: `crates/poste-exec/src/executor.rs`

**Issue**: Mixed error strategies:
- HTTP: Uses `anyhow::bail!` macros (lines 34, 35)
- Redis: Uses `anyhow::bail!` (lines 166, 169, 183, 189)
- MongoDB/AMQP: Uses `anyhow::bail!` (lines 235, 239)

But response building varies:
- HTTP: Returns custom `Response` struct
- Redis: Builds response inline
- SQL: Delegates to `sql_executor` module

**Impact**: Low-priority, but inconsistent error context makes debugging harder.

---

### 11. **Magic Numbers Throughout Codebase**
**Severity**: 🟡 MINOR  
**Examples**:
- `buffer_nav.lua:246`: `range.cursor_col = next_sep + 2` — Why +2?
- `editor.lua:1060`: `#tab.layout.rows > 5000` — Hard limit on editing
- `edit_commit.lua:327`: `MAX_LOG_ENTRIES = 1000` — Arbitrary cap
- `format.lua:436`: Column width cap at 200

**Fix**: Extract to configuration module:
```lua
-- NEW: config.lua
local CONFIG = {
  EDITOR = {
    MAX_ROWS = 5000,
    LOG_MAX_ENTRIES = 1000,
  },
  FORMAT = {
    MAX_COL_WIDTH = 200,
  },
  NAVIGATION = {
    CELL_PADDING = 2,  -- +2 for left/right boundaries
  },
}
```

---

## 📊 Summary Table

| Issue | File | Lines | Severity | Effort | ROI |
|-------|------|-------|----------|--------|-----|
| God function: `edit_cell()` | editor.lua | 173 | 🔴 | 2-3h | High |
| Type classification boilerplate | editor.lua | 200+ | 🔴 | 1-2h | Medium |
| `ensure_primary_key()` monolith | editor.lua | 204 | 🔴 | 3-4h | High |
| Edit state tracking scatter | editor.lua + edit_commit.lua | 150+ | 🟡 | 2-3h | High |
| Deep nesting: `show_search()` | buffer_search.lua | 90 | 🟡 | 2-3h | Medium |
| Log entry escaping duplication | edit_commit.lua | 40+ | 🟡 | 1h | High |
| Type guard overhead | completion.lua | 60+ | 🟠 | 1-2h | Medium |
| Hardcoded query strings | editor.lua + others | 100+ | 🟠 | 2-3h | Medium |
| Implicit state coupling | buffer_nav.lua | 30+ | 🟠 | 3-4h | Low |
| Inconsistent error handling | executor.rs | 100+ | 🟡 | 1-2h | Medium |

---

## 🎯 Recommended Refactoring Order

1. **Phase 1** (Sprint 1): Fix critical issues that block testing
   - Extract `edit_cell()` into strategy pattern
   - Unify type classification system
   - Split primary key introspection

2. **Phase 2** (Sprint 2): Improve code maintainability
   - Merge scattered edit state tracking
   - Extract search state management
   - Deduplicate log escaping

3. **Phase 3** (Later): Architecture improvements
   - Event-driven state mutations
   - Configuration registry for magic numbers
   - Metadata query registry

---

## 🔗 Related Documents

- **Performance Analysis**: [PERFORMANCE_ANALYSIS.md](./PERFORMANCE_ANALYSIS.md) — h/l scrolling bottlenecks, caching issues
- **TODO**: [TODO.md](./TODO.md) — Known issues & feature requests
