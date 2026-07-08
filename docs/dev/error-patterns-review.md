# Error Pattern Review

Analysis of 25+ bugs logged in `LEARNINGS.md` (2026-06-24 ~ 2026-07-08).

## Pattern 1: Orphaned State (~27%)

**You leave a global/cached state behind and forget to reset it before the next operation.**

- `state.response_index` persists across requests (07-08)
- jq filter state (`_json.*`) lingers after new request (06-24)
- Request signs accumulate across executions (06-27)
- `block_end` not updated after var injection (07-02)
- Inter-block separator lines misattributed to previous block (07-02)
- `spinner_gen` double-increment from entry+stop_timer (06-29)
- Post-script skipped when global_vars non-empty from prior request (07-02)
- `_dep_chain` consumed at wrong layer, leaving stale chain state for next request (07-08)

**Root cause**: You add state without simultaneously asking "when does this get cleared?" Classic caching/optimization trap.

## Pattern 2: Incorrect API Contract Assumptions (~30%)

**You assume an API behaves one way but it actually behaves differently.**

- `nvim_buf_set_lines` rejects lines containing `\n` (07-08)
- `string.gsub` returns 2 values (06-30)
- `vim.system` is async (06-30)
- Kitty graphics escapes stripped by Neovim stdout pipeline (07-04)
- `nvim_open_term()` creates libvterm, not raw terminal (07-04)
- NUL bytes in binary data break argv (07-04)
- `--line` assumes stdin format = file format (07-07)
- URL retains trailing ` HTTP/1.1` after `trim_start()` (07-01)
- `\r\n` line endings break boundary detection in multipart parsing (07-01)
- `< path` file content containing `###` creates false block boundaries (07-04)

**Root cause**: You guess API behavior instead of reading docs or writing a minimal test. Insufficient knowledge of Lua/Neovim/curl boundary conditions.

## Pattern 3: Incomplete Modification (~24%)

**You fix path A but forget that B, C, D also go through the same logic.**

- Pre-rendered buffers have treesitter but skip view-specific extmarks (07-08)
- `sanitize_lines` guards `nvim_buf_set_lines` but not highlight functions that use `#line` (07-08)
- Sanitize added in `render_view` but not in history module or verbose timer (07-08)
- `< file` expansion moved from Lua to Rust but missed `###` block-boundary effect (07-04)
- Sign collision fix missed the spinner race condition two lines away (06-27/06-29)
- Lua-to-Rust data format assumed matching but actual field names differed (07-06)

**Root cause**: You modify along one call chain without scanning all codepaths that share the same logic. Pattern is "fix → user reports new crash → fix again → user reports again" — classic whack-a-mole.

## Pattern 4: Lua Language Pitfalls (~13%)

- `local function f()` defined after caller yields nil (06-26)
- `""` is truthy, defeats `or` fallback (06-30)
- Closure captures loop variable at wrong time (06-29)
- `table.insert(f(), val)` with multi-return gsub spills extra value (06-30)

## Capability Gaps

### 1. Defensive Thinking

You don't ask "what if this state is never cleaned?" or "what if this API behaves differently than I expect?" before adding features.

**Antidote**: Before writing any state mutation, write the cleanup condition first.

### 2. Call-Chain Mapping

When modifying a function, you can't identify all callers and related paths in one pass. You rely on user reports to discover missed paths.

**Antidote**: Before any change, grep for all `nvim_buf_set_lines`, `format_*` function calls, and state references. Trace the full call graph.

### 3. Platform Boundary Knowledge

Insufficient experience with Neovim Lua API edge cases, curl argument constraints, and Lua↔Rust data serialization. Every new API boundary introduces surprise behavior.

**Antidote**: For any unfamiliar API, write a throwaway test in `tests/` or a scratch `.http` file before integrating. Never assume.

## Checklist for Future Work

| If you touch... | Also check... |
|----------------|---------------|
| `nvim_buf_set_lines` | `sanitize_lines()` on input; all highlight functions that compute `#line` as `end_col` |
| Pre-rendered buffers | The original render path runs *everything*, not just treesitter |
| Global/cached state | Lifecycle: where it's set, where it's read, where it's cleared (at both ends) |
| Lua ↔ Rust data | Field names, types, encoding, special characters (NUL, `###`, `\n`) |
| Multi-path module (history, format, buffer) | All entry points: `render_view`, `render_detail`, `prepare_multi_responses`, verbose timer |
| Job/stdout handler | Both `on_stdout` and `on_exit` paths; chain vs non-chain branches |