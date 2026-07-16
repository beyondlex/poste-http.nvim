# Poste Refactoring Plan

> Based on the architecture review in `ignore/review.md`. This plan translates the 8 findings (F1–F8) into actionable stages, ordered by risk/reward and dependency.

---

## Overview

| Finding | Issue | Prio | Effort | Risk |
|---------|-------|------|--------|------|
| **F1** | HTTP request parsed in 3 places independently | P1 | Medium | Medium |
| **F2** | `request_vars.lua` is a second execution engine | P1→P2 | Large | High |
| **F3** | God modules (`format.lua`, `executor.rs`, `parser.rs`, `editor.lua`) | P1 | Medium | Low |
| **F4** | No contract tests for Rust↔Lua JSON shapes | P1 | Medium | Low |
| **F5** | Mutable global state lacks lifecycle invariants | P1 | Medium | Medium |
| **F6** | Redis lives under `lua/poste/http/` | P2 | Small–Medium | Low |
| **F7** | `prototype.lua` and heavy `poste-core` import deps | P3 | Small | Low |
| **F8** | Scattered child-process invocations across Lua | P2 | Medium | Medium |

### Execution order (recommended)

```
Phase 0: F4 — Contract tests (safety net for everything below)
Phase 1: F3 — Split god modules (behaviour-preserving, reduces friction)
Phase 2: F1+F5 — Single parse authority + session lifecycle
Phase 3: F2 — Unify resolve entry, then consider Rust
Phase 4: F8 — Centralise child-process calls
Phase 5: F6+F7 — Redis isolation & housekeeping
```

---

## Phase 0: Contract Tests (F4)

**Goal**: Lock down the Rust→Lua JSON contract so every subsequent refactor has a regression guard.

### Problem

`Response` (and friends) are typed in Rust and decoded with `vim.json.decode` in Lua, but there is no shared schema or golden test. SQL completion has golden fixtures; HTTP run/context do not. A silent break on field rename or nesting change is a matter of time.

### Approach

Introduce `tests/contract/` with static fixtures and one test per JSON-consuming Lua path.

```
tests/contract/
├── fixtures/
│   ├── http-run-response.json       # poste run --json output
│   ├── context-detect.json
│   ├── context-stmt.json
│   └── context-stmt-ranges.json
└── test_contract.lua               # Lua-side consumer assertions
```

### Key checks per fixture

- `http-run-response.json` → assert status, body, headers from Lua's `vim.json.decode`
- `context-detect.json` → assert filetype, protocol, start_line
- `context-stmt.json` → assert sql dialect, statement boundaries
- `context-stmt-ranges.json` → assert range map shape

### Work items

1. Pick one JSON path (e.g. `poste run --json`) and write a Lua contract test
2. Generate a golden fixture by running the CLI on a known `.http` file
3. Assert the Lua decode matches expected fields
4. Repeat for `context` subcommands (model on existing SQL context golden tests)
5. Document the pattern so new features add a fixture

### Acceptance

- [ ] Every `--json` consumer has at least one contract test
- [ ] CI runs `tests/run.sh` which includes contract assertions
- [ ] Adding a field to a Rust response struct requires updating the fixture (test fails until done)

---

## Phase 1: Split God Modules (F3)

**Goal**: Break up the four largest files by responsibility without changing behaviour.

### 1a — `format.lua` (~1697 lines)

Sits under `lua/poste/http/format.lua` and handles: body formatting, verbose mode, multipart, image preview, Redis highlighting.

#### Proposed split

```
lua/poste/http/
├── format.lua              ← ~200 lines: public API, dispatches to sub-modules
├── format/
    ├── body.lua            ← HTTP response body formatting
    ├── verbose.lua         ← Verbose response rendering
    ├── multipart.lua       ← Multipart body parsing & display
    ├── image.lua           ← Image preview (iTerm imgcat / kitty protocol)
    └── redis.lua           ← Future: Redis response formatting (moved from here)
```

**Order**: Extract one sub-module at a time. Each extraction:
1. Move functions + their direct dependencies into the new file
2. Keep a thin re-export in `format.lua` (deprecated path)
3. Run `tests/run.sh` to confirm no regression
4. After all extractions, update importers to use the new paths and drop re-exports

### 1b — `executor.rs` (~1248 lines)

HTTP curl execution + Redis execution + MIME tools live in one file. SQL already split out.

#### Proposed split

```
crates/poste-exec/src/
├── mod.rs
├── executor.rs             ← Current file (will be split)
└── ...
```

Move Redis execution into `redis.rs`, MIME helpers into `mime.rs`, keeping HTTP-specific code in `executor.rs`. Follow the same crate-internal module pattern SQL used.

### 1c — `parser.rs` (~1173 lines)

HTTP parser. This is trickier because the parsing logic is tightly coupled. For now, extract the clearly separable sections:
- Multipart/form-data parsing → `parser/multipart.rs`
- Variable interpolation (`{{var}}`) → `parser/vars.rs`

Keep the main parse loop in `parser.rs`; these are purely structural moves.

### 1d — `sql/editor.lua` (~1050 lines)

SQL dataset editor. Split transient concerns:
- Cell manipulation → `sql/editor/cell.lua`
- Column operations → `sql/editor/column.lua`
- Row navigation → `sql/editor/nav.lua`

Leave the orchestration in `editor.lua`.

### Acceptance

- [ ] `format.lua` < 300 lines (from ~1700)
- [ ] `executor.rs` < 600 lines (from ~1250)
- [ ] `parser.rs` < 800 lines (from ~1170)
- [ ] `sql/editor.lua` < 500 lines (from ~1050)
- [ ] All existing tests pass at each extraction step
- [ ] Behaviour is identical — no functional change

---

## Phase 2: Single Parse Authority + Session Lifecycle (F1 + F5)

**Goal**: Eliminate the three-way parse duplication and ensure mutable state is reset per request.

### 2a — Single parse authority (F1)

#### Problem

`parser.rs`, `cache.lua` (`build_cache`), and `run.lua` (`build_pending_request`) each scan for `###` delimiters, method lines, and headers. Minor semantic differences cause bugs (`--line` vs stdin inconsistency, lost file-level `@var`, etc.).

#### Approach

Make the CLI JSON output the single source of truth for request metadata.

1. **Add a new CLI subcommand** (or extend `poste run --describe`) that emits structured block metadata as JSON:
   ```json
   [
     {
       "name": "Get Users",
       "line": 5,
       "method": "GET",
       "path": "/api/users",
       "headers": [["Accept", "application/json"]]
     }
   ]
   ```
2. **Replace `cache.lua`** block indexing with a call to this CLI command. `cache.lua` keeps only UI-level indexing (line → block name mappings for navigation).
3. **Replace `build_pending_request`** in verbose mode with the same CLI metadata source.
4. **Remove** the redundant parse passes from Lua.

#### Work items

1. Design the JSON schema for block metadata
2. Implement `poste run --describe` in Rust (reuses existing parser)
3. Wire `cache.lua` to call it
4. Wire verbose pending display to call it
5. Remove `build_pending_request` Lua code
6. Add contract tests for the new JSON output

### 2b — Session lifecycle (F5)

#### Problem

~27% of historic bugs are orphaned state (`response_index`, `_json`, indicator spinner, `global_vars`, `block_end`). State set in one request leaks into the next.

#### Approach

Introduce an explicit `Session` object per protocol that is created at `run_*` entry and discarded on completion.

```
lua/poste/http/session.lua     ← new
lua/poste/sql/session.lua      ← new
```

Each session owns:
- `response` — current response data
- `meta` — request metadata (name, line, duration)
- `assertions` — assertion results
- `logs` — script logs

The `run_request()` / `run_sql_request()` entry point:
1. Creates a fresh `Session`
2. Passes it through the request pipeline
3. Stores it in a stack (support multi-tab) or ephemeral reference
4. The old `state.lua` fields become deprecated aliases reading from the active session

#### Work items

1. Design `Session` struct for HTTP (fields, nesting)
2. Design `Session` struct for SQL
3. Create `http/session.lua` constructor + reset
4. Create `sql/session.lua` constructor + reset
5. Wire `run.lua` to create session on entry, discard on completion
6. Add a `state.deprecated_*` shim that logs on write
7. Add CI check: `tests/relation-check.sh` or equivalent verifies SET↔CLEAR symmetry

### Acceptance

- [ ] `cache.lua` no longer parses HTTP semantics (only UI indexing)
- [ ] `run.lua` no longer re-parses request blocks from buffer text
- [ ] Each `run_*` entry creates a fresh session
- [ ] No `state.*` field written in one request survives into the next
- [ ] `tests/relation-check.sh` (or CI equivalent) passes

---

## Phase 3: Unify Resolve Entry (F2)

**Goal**: Eliminate `request_vars.lua` as a second execution engine by having all variable/import resolution go through one API.

### Problem

`request_vars.lua` (~1247 lines) does dependency topology, sub-requests via `jobstart`, prompt handling, `<<var` syntax, magic variables, and file-var preprocessing. Meanwhile Rust `run`/`resolve` does `{{env}}` and `< file`. The split happens at "semi-processed string" — a fragile boundary.

### Short-term (Phase 3a)

**All Lua-side consumers call the same resolve API.**

Currently `run.lua`, `resolve.lua`, and `dep.lua` each assemble their own resolve pipeline. Centralise:

```lua
-- lua/poste/http/resolve.lua (cleaned up)
local M = {}

-- Single entry point for request variable resolution
function M.resolve(content, opts)
  -- 1. Handle prompt variables (<<var)
  -- 2. Resolve magic variables
  -- 3. Resolve file variables (< file)
  -- 4. Resolve {{var}} / {{env:VAR}}
  -- 5. Resolve imports (@import, COPY, RUN)
  return resolved_content, resolved_vars
end

return M
```

All callers switch to `resolve.resolve(content, opts)`.

### Long-term (Phase 3b)

**Move the resolve pipeline into Rust.**

`poste resolve --deps <file>` would:
1. Parse the file
2. Resolve variable chains (env → file vars → imports → prompts)
3. Resolve import/RUN/COPY dependency graph
4. Output fully resolved, executable content as JSON

Lua then only needs to send content → Rust → receive executable content.

This is a large change — only begin after Phases 0–2 are stable.

### Work items (Phase 3a only)

1. Audit all callers of `request_vars` functions
2. Design the unified `resolve()` signature
3. Refactor `request_vars.lua` internals to serve the unified entry point
4. Update each caller to use the single API
5. Add tests for the unified resolve entry point
6. Mark old per-function exports as deprecated

### Acceptance

- [ ] One function resolves all variable types for all callers
- [ ] No caller independently assembles a resolve pipeline
- [ ] All existing tests pass

---

## Phase 4: Centralise Child-Process Calls (F8)

**Goal**: A thin wrapper around CLI invocation so argument construction, error handling, and JSON parsing happen in one place.

### Problem

`run.lua`, `resolve.lua`, `dep.lua`, `context.lua`, `introspect.lua`, `import/*.lua` — each constructs its own `vim.fn.system` / `vim.system` / `jobstart` call with different argv conventions and error handling.

### Approach

```lua
-- lua/poste/cli.lua
local M = {}

local default_opts = {
  json = false,
  stdin = nil,
  timeout_ms = 30000,
}

--- Run a poste CLI subcommand.
--- @param cmd table  e.g. {"run", "--json", "--line", "5", file}
--- @param opts? table  Overrides for default_opts
--- @return table|string  Parsed JSON table or raw stdout string
function M.run(cmd, opts)
  opts = vim.tbl_deep_extend("keep", opts or {}, default_opts)
  local full_cmd = vim.list_extend({"poste"}, cmd)
  local result = vim.fn.system(full_cmd, opts.stdin)
  local ok, parsed = pcall(vim.json.decode, result)
  if opts.json and ok then
    return parsed
  end
  return result
end

return M
```

### Work items

1. Create `lua/poste/cli.lua`
2. Migrate all `vim.fn.system("poste ...")` calls to the wrapper
3. Standardise error handling: non-zero exit → `vim.notify` with stderr
4. Add `timeout_ms` handling for long-running commands
5. For the hot path (`run.lua`), keep `jobstart` for async but use the same argv construction

### Acceptance

- [ ] No call site constructs `"poste ..."` string or `{"poste", ...}` table manually
- [ ] All JSON-consuming callers use `cli.run(cmd, {json=true})`
- [ ] Error messages are consistent

---

## Phase 5: Redis Isolation & Housekeeping (F6 + F7)

**Goal**: Complete protocol isolation for Redis; remove dead code.

### 5a — Redis isolation (F6)

Move Redis Lua code out of `lua/poste/http/`:

```
lua/poste/
├── http/          ← HTTP-only (was: http/format.lua handled Redis)
├── redis/         ← NEW
│   ├── init.lua   ← Filetype dispatch for poste_redis
│   ├── format.lua ← Redis response formatting (moved from http/format.lua)
│   └── ...        ← highlight.lua, etc.
```

Update `init.lua` to dispatch `poste_redis` → `redis.init.*`.

### 5b — Housekeeping (F7)

- Remove or move `lua/poste/sql/prototype.lua` to `experiments/` (it's dead experimental code)
- Audit `poste-core` import dependencies (`import/*` + `openapiv3`, ~3.3k lines). Consider splitting into a `poste-import` crate if the dependency weight is significant for non-import consumers. **(P3, defer unless directly blocking)**

### Acceptance

- [ ] No Redis code lives under `lua/poste/http/`
- [ ] `poste_redis` filetype dispatches to `lua/poste/redis/`
- [ ] `prototype.lua` removed or moved to `experiments/`
- [ ] All existing tests pass

---

## Implementation Notes

### How to approach each item

1. **Write the test first** — even for a pure refactor (behaviour-preserving split), write a contract test that asserts the current behaviour, then refactor, then confirm the test still passes.
2. **One extraction per PR** — never combine two F-items in one change. Each is independently reviewable and revertible.
3. **Deprecation, not deletion** — Phase 2/3 should introduce the new path while keeping the old path as a thin wrapper. Remove the old path after 1–2 weeks of real use.
4. **Update `LEARNINGS.md`** — every non-obvious edge case encountered during refactoring should be logged.

### Cross-cutting concerns

All findings except F4 are interrelated: fixing F1 makes F5 easier (state has fewer writers), fixing F5 makes F8 less risky (centralised CLI calls go through a known lifecycle). **Start with F4** — contract tests are the cheapest safety net and every subsequent phase benefits from them.

### When to stop

A refactoring phase is complete when:
- All acceptance criteria listed above are met
- All existing tests pass
- `cargo test` + `tests/run.sh` are green
- No new bug reports linked to the changes in the first week after merge