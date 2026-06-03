# Refactoring Plan: poste/init.lua Module Decomposition

## Overview
Refactor `lua/poste/init.lua` (2,391 lines) into 8 focused modules while preserving the external API `require("poste").setup()`.

---

## 1. Shared State Strategy

**Recommendation: Option (a) — Central state module (`poste.state`)**

### Rationale
- Three cross-cutting variables (`config`, `current_env`, `last_response`, `last_assertion_results`) are read/written by multiple modules
- Passing state via parameters would require threading through 15+ function signatures
- Distributed state ownership creates circular dependencies (e.g., formatters need both `config` and `last_response`)
- Central state module is the simplest, most maintainable approach

### Implementation
Create `lua/poste/state.lua` as a singleton module:

```lua
-- lua/poste/state.lua
local M = {}

M.config = {
  -- default config (currently lines 1-7)
}

M.current_env = nil
M.last_response = nil
M.last_assertion_results = nil

-- Convenience setter for config (used by M.setup)
function M.set_config(new_config)
  M.config = new_config
end

return M
```

**Usage pattern:**
```lua
local state = require("poste.state")
-- Read: state.config, state.current_env
-- Write: state.current_env = "production"
```

---

## 2. Module Boundaries and Public APIs

### Module 1: `poste.state` (~30 lines)
**Purpose:** Centralized shared mutable state

**Exports:**
- `M.config` (table)
- `M.current_env` (string)
- `M.last_response` (table)
- `M.last_assertion_results` (table)
- `M.set_config(new_config)` (function)

**Dependencies:** None

---

### Module 2: `poste.highlights` (~50 lines)
**Purpose:** Highlight group resolution and setup

**Functions to extract:**
- `resolve_hl(name, fallback)` (local → exported)
- `setup_hl()` (local → exported)

**Exports:**
- `M.setup()` — calls `setup_hl()` and registers ColorScheme autocmd
- `M.resolve_hl(name, fallback)` — for use by other modules if needed

**Dependencies:** None (pure Vim API calls)

**Notes:** Currently called at module-load time. After extraction, `poste.init` will call `highlights.setup()` during its own setup.

---

### Module 3: `poste.select` (~200 lines)
**Purpose:** Reusable select/picker UI component

**Functions to extract:**
- `poste_select(items, opts, callback)` (local → exported)

**Exports:**
- `M.select(items, opts, callback)`

**Dependencies:** None (pure UI, uses Vim API only)

**Notes:** Completely self-contained. Used by prompt variables and potentially other modules.

---

### Module 4: `poste.indicators` (~150 lines)
**Purpose:** Request detection, spinner animation, and visual indicators

**State to extract:**
- `spinner_frames` (table)
- `spinner_gen` (function)
- `spinner_timer` (uv_timer)
- `indicator_ns` (namespace)
- `indicator_mark` (extmark)
- `indicator_buf` (buffer) — **NOTE: This is dead code, remove it**

**Functions to extract:**
- `extract_request_block()` (local → exported)
- `find_request_line()` (local → exported)
- `set_indicator(buf, line, text, hl)` (local → exported)
- `start_spinner(buf, line)` (new, wraps timer logic)
- `stop_spinner()` (new, wraps timer logic)

**Exports:**
- `M.extract_request_block(buf, cursor_line)` → table
- `M.find_request_line(buf, line)` → number
- `M.set_indicator(buf, line, text, hl)`
- `M.start_spinner(buf, line)`
- `M.stop_spinner()`
- `M.cleanup()` — stops timer, clears namespace

**Dependencies:** `vim.uv` only

**Dead code removal:** Delete `indicator_buf` (never used)

---

### Module 5: `poste.format` (~500 lines)
**Purpose:** Response formatting, pretty-printing, content-type detection

**State to extract:**
- `content_type_map` (table, currently ~line 500)
- `redis_ns` (namespace for Redis syntax highlighting)

**Functions to extract:**
- `split_lines(s)` (local)
- `json_pretty(s)` (local)
- `pretty_body(body, content_type)` (local)
- `format_body(body, content_type)` → **FIX FORWARD REFERENCE BUG**
- `format_redis_body(body)` → **MOVE BEFORE format_body**
- `apply_redis_highlights(buf, body)` (local)
- `format_headers(headers)` (local)
- `extract_connection_info(verbose_output)` (local)
- `format_verbose(verbose_output, env)` (local)
- `format_assertions(results)` (local) — **NOTE: This is a formatter, not the assertion runner**
- `detect_filetype(content_type)` (local → exported)
- `md_table(headers, rows)` — **DELETE: Dead code**

**Exports:**
- `M.format_body(body, content_type)` → string
- `M.format_headers(headers)` → string
- `M.format_verbose(verbose_output, env)` → string
- `M.format_assertions(results)` → string
- `M.detect_filetype(content_type)` → string
- `M.apply_redis_highlights(buf, body)`
- `M.split_lines(s)` → table (used by other modules)

**Dependencies:** `poste.state` (reads `state.current_env`, `state.last_response`, `state.last_assertion_results`)

**Bug fix:** Move `format_redis_body` definition BEFORE `format_body` to fix forward reference.

---

### Module 6: `poste.buffer` (~100 lines)
**Purpose:** Response buffer management and rendering

**State to extract:**
- `response_buffer` (buffer handle)
- `response_window` (window handle)
- `current_view` (string: "body" | "headers" | "verbose")

**Functions to extract:**
- `get_response_buffer()` (local → internal)
- `render_buffer()` (local → exported)
- `update_winbar()` (local → exported)

**Exports:**
- `M.get_or_create_buffer()` → buffer
- `M.render_buffer(view)` — renders `state.last_response` into buffer
- `M.update_winbar()` — updates winbar based on `state.last_assertion_results`
- `M.get_response_window()` → window (if needed by orchestrator)
- `M.set_response_window(win)`
- `M.set_current_view(view)`

**Dependencies:** `poste.state`, `poste.format`

---

### Module 7: `poste.assertions` (~200 lines)
**Purpose:** Assertion parsing, sandboxed execution, result formatting

**Functions to extract:**
- `extract_assertion_blocks(body)` (local)
- `run_assertions(body, response)` (local → exported)
- `format_assertions(results)` — **WAIT: This is already in poste.format. Remove duplicate.**

**Exports:**
- `M.extract_assertion_blocks(body)` → table (used by request_vars)
- `M.run_assertions(body, response)` → table

**Dependencies:** None (pure functions + sandboxed execution)

**Notes:** The `format_assertions` function belongs in `poste.format`, not here. This module only runs assertions and returns results.

---

### Module 8: `poste.request_vars` (~530 lines)
**Purpose:** Request variable resolution, prompt variables, form data processing

**State to extract:**
- `request_response_cache` (table)

**Functions to extract:**
- `collect_requests(buf)` (local)
- `get_nested_value(tbl, path)` (local)
- `resolve_request_variable(ref, requests, current_buf)` (local)
- `find_request_variable_refs(buf)` (local)
- `execute_dependent_request(request, requests, current_buf)` (local)
- `resolve_request_variables(buf)` (local → exported)
- `strip_prompt_lines(lines)` (local)
- `handle_prompt_variables(buf, requests)` (local → exported)
- `process_form_data(buf, requests)` (local → exported)
- `find_request_block_bounds(buf, line)` (local → exported)

**Exports:**
- `M.resolve_request_variables(buf)` — mutates buffer content
- `M.handle_prompt_variables(buf, requests)`
- `M.process_form_data(buf, requests)`
- `M.find_request_block_bounds(buf, line)` → start_line, end_line
- `M.clear_cache()` — clears `request_response_cache`

**Dependencies:** `poste.state`, `poste.assertions`, `poste.select`, logging function

**Notes:** This is the largest module (~530 lines) but is cohesive around the "variable resolution" concern.

---

### Module 9: `poste.init` (orchestrator, ~300 lines)
**Purpose:** Main entry point, orchestration, navigation, environment, setup

**Functions:**
- `M.run_request()` — orchestrates request execution
- `M.show_view(view)` — switches between body/headers/verbose views
- `M.jump_next()` — navigation
- `M.jump_prev()` — navigation
- `M.set_env(env)` — environment setter
- `M.get_env()` — environment getter
- `M.setup(opts)` — main setup function

**Exports:**
- `M.setup(opts)`
- `M.run_request()`
- `M.show_view(view)`
- `M.jump_next()`
- `M.jump_prev()`
- `M.set_env(env)`
- `M.get_env()`

**Dependencies:** All other modules

**Orchestration logic:**
```lua
function M.run_request()
  local state = require("poste.state")
  local indicators = require("poste.indicators")
  local format = require("poste.format")
  local buffer = require("poste.buffer")
  local assertions = require("poste.assertions")
  local request_vars = require("poste.request_vars")
  
  -- 1. Extract request block
  local block = indicators.extract_request_block(...)
  
  -- 2. Resolve variables
  request_vars.resolve_request_variables(...)
  
  -- 3. Execute request (call binary)
  -- ...
  
  -- 4. Run assertions
  state.last_assertion_results = assertions.run_assertions(...)
  
  -- 5. Store response
  state.last_response = {...}
  
  -- 6. Render
  buffer.render_buffer(state.current_view)
end
```

---

## 3. Dead Code to Remove

1. **`md_table(headers, rows)`** (~20 lines, ~line 900)
   - Defined but never called
   - **Action:** Delete

2. **`M.complete_prompt_options()`** (~30 lines, ~line 1800)
   - Defined but never called
   - **Action:** Delete

3. **`indicator_buf`** (1 line, ~line 450)
   - Declared but never used
   - **Action:** Delete declaration

**Total dead code removed:** ~50 lines

---

## 4. Forward Reference Bug Fix

**Problem:** `format_body` (line ~608) calls `format_redis_body` (line ~616), but `format_redis_body` is declared AFTER `format_body` as a local function.

**Current code (broken):**
```lua
local function format_body(body, content_type)
  -- ...
  if content_type:match("redis") then
    return format_redis_body(body)  -- ERROR: format_redis_body not yet defined
  end
end

local function format_redis_body(body)
  -- ...
end
```

**Fix:** Move `format_redis_body` definition BEFORE `format_body`:
```lua
local function format_redis_body(body)
  -- ...
end

local function format_body(body, content_type)
  -- ...
  if content_type:match("redis") then
    return format_redis_body(body)  -- OK: now defined
  end
end
```

**Action:** Apply this fix when extracting to `poste.format`.

---

## 5. Extraction Order (Risk Minimization)

**Strategy:** Extract leaf modules first (fewest dependencies), then work toward the orchestrator.

### Phase 1: Foundation (no dependencies)
1. **`poste.state`** — trivial, 30 lines, no logic
2. **`poste.highlights`** — pure Vim API, no deps
3. **`poste.select`** — pure UI, no deps

**Verification:** After each extraction, run `:lua require("poste").setup()` and verify no errors.

### Phase 2: Independent utilities
4. **`poste.indicators`** — self-contained, uses only `vim.uv`
5. **`poste.assertions`** — pure functions, no deps

**Verification:** Test request detection (hover over request block), run a request with assertions.

### Phase 3: Formatters (depends on state)
6. **`poste.format`** — depends on `poste.state`, fixes forward-ref bug

**Verification:** Run a request, verify response formatting (JSON, headers, verbose).

### Phase 4: Buffer management (depends on format, state)
7. **`poste.buffer`** — depends on `poste.format`, `poste.state`

**Verification:** Run a request, verify response window renders correctly, test view switching.

### Phase 5: Variable resolution (depends on assertions, select, state)
8. **`poste.request_vars`** — largest module, most complex

**Verification:** Test request variables (`@variable`), prompt variables (`{{prompt}}`), form data.

### Phase 6: Orchestrator
9. **`poste.init`** — slim down to orchestration only

**Verification:** Full end-to-end test: setup, run request, view switching, navigation, environment switching.

---

## 6. Final File Structure

```
lua/poste/
├── init.lua          (300 lines) — orchestrator, setup, navigation
├── state.lua         (30 lines)  — shared mutable state
├── highlights.lua    (50 lines)  — highlight group management
├── select.lua        (200 lines) — picker UI
├── indicators.lua    (150 lines) — request detection, spinners
├── format.lua        (500 lines) — response formatting
├── buffer.lua        (100 lines) — response buffer management
├── assertions.lua    (200 lines) — assertion parsing/execution
└── request_vars.lua  (530 lines) — variable resolution

Total: ~2,060 lines (after removing ~50 lines of dead code)
```

**Note:** Total is less than original 2,391 due to:
- Dead code removal (~50 lines)
- Eliminated duplicate `format_assertions` (~20 lines)
- Removed redundant comments/whitespace during extraction (~260 lines)

---

## 7. Migration Checklist

For each module extraction:

- [ ] Create new file `lua/poste/<module>.lua`
- [ ] Move functions and state to new module
- [ ] Update `require()` statements in `init.lua`
- [ ] Remove moved code from `init.lua`
- [ ] Run `:lua require("poste").setup()` — verify no errors
- [ ] Test affected functionality manually
- [ ] Commit with message: `refactor: extract <module> module`

**Final step:**
- [ ] Update `plugin/poste.lua` if needed (should not be needed — it only calls `require("poste").setup()`)
- [ ] Update README if module structure is documented
- [ ] Add note to README about new module structure for contributors

---

## 8. Risk Assessment

**Low risk:**
- `poste.state` — trivial
- `poste.highlights` — isolated
- `poste.select` — isolated
- `poste.indicators` — isolated
- `poste.assertions` — isolated

**Medium risk:**
- `poste.format` — forward-ref bug fix, but well-understood
- `poste.buffer` — depends on format, but clear interface

**High risk:**
- `poste.request_vars` — largest, most complex, most dependencies
- `poste.init` — orchestrator, must wire everything together correctly

**Mitigation:**
- Extract in order (leaf modules first)
- Test after each extraction
- Keep `init.lua` as the orchestrator throughout (don't try to move orchestration logic to a separate module)

---

## 9. Example: Extracting `poste.state`

**Step 1: Create `lua/poste/state.lua`**
```lua
local M = {}

M.config = {
  default_view = "body",
  wrap = false,
  -- ... (copy from init.lua lines 1-7)
}

M.current_env = nil
M.last_response = nil
M.last_assertion_results = nil

function M.set_config(new_config)
  M.config = new_config
end

return M
```

**Step 2: Update `init.lua`**
```lua
-- Remove lines 1-7 (config table)
-- Add at top:
local state = require("poste.state")

-- Replace all `config` references with `state.config`
-- Replace all `current_env` references with `state.current_env`
-- Replace all `last_response` references with `state.last_response`
-- Replace all `last_assertion_results` references with `state.last_assertion_results`

-- In M.setup():
-- Replace: config = vim.tbl_deep_extend("force", config, opts)
-- With: state.set_config(vim.tbl_deep_extend("force", state.config, opts))
```

**Step 3: Test**
```vim
:lua require("poste").setup({ default_view = "headers" })
:lua print(vim.inspect(require("poste.state").config))
```

---

## 10. Summary

**Modules:** 8 focused modules + 1 orchestrator (init.lua)
**State strategy:** Central state module (`poste.state`)
**Lines of code:** ~2,060 (after removing ~330 lines of dead/redundant code)
**Extraction order:** state → highlights → select → indicators → assertions → format → buffer → request_vars → init
**Risk mitigation:** Leaf modules first, test after each extraction
**Bug fixes:** Forward reference in `format_body`, dead code removal

**External API preserved:** `require("poste").setup()` remains unchanged.
