# Learnings

Agent self-evolution log. When you fix a non-obvious bug or encounter a
pitfall, log it here. Check this file before starting any task.

## Format

```
- YYYY-MM-DD: <scope> — <one-line problem>. Fix: <one-line fix>. See <file>:<line>.
```

## Entries

- 2026-06-26: agent — `lua local function f()` defined after its first caller causes "nil value" at runtime. Lua requires local functions to be declared before use, or forward-declared via `local f`. Fix: always order helper functions top-down, or add `local f` forward decl at module top. See `lua/poste/http/request_vars.lua:155-160`.
- 2026-06-26: keymaps — renamed `source_buffer` → `http_source`, `db_browser` → `sql_db_browser`, `introspect_float` → `sql_introspect` for consistency. Breaking change for users with custom configs using old names. See `lua/poste/state.lua:25-133`.
- 2026-06-24: http — pre-script/global var injection adds lines to buf_content but `--line` not adjusted, causing wrong block selection in Rust parser. Fix: add `line = line + injected_count` after each injection. See `lua/poste/http/run.lua:133,154`.
- 2026-06-24: http — jq filter state (`_json.query`, `original_lines`, `is_filtered`) persists across requests, showing stale filter in winbar. Fix: clear `state._json` before setting `state.last_response`. See `lua/poste/http/run.lua:199-201`.
- 2026-06-24: docs — `docs/dev/http/impl-guide.md` was a specific Phase 0-4 feature plan, not a general TDD guide. Fix: archive it, create `docs/dev/http/tdd-guide.md` as general TDD reference. See `docs/dev/http/tdd-guide.md`.
- 2026-06-27: indicators — sign group name collision: `"poste_indicator"` conflicts with other plugins' cleanup. Signs confirmed by `sign_getplaced` at t+0, removed by t+50ms. Fix: use unique group name (`"poste_sg_4a7f"`). See `lua/poste/indicators.lua:6`.
- 2026-06-27: indicators — spinner race: `update_spinner` callback `vim.schedule_wrap`'d before `set_indicator("success")` could still redefine spinner sign after success sign placed, if `spinner_gen` not incremented inside `stop_timer()`. Fix: `spinner_gen = spinner_gen + 1` in `stop_timer()`. See `lua/poste/indicators.lua:197-203`.
- 2026-06-27: indicators — stale sign accumulation: executing a new request left previous requests' ✓/✘ signs visible. Fix: `clear_other_requests(buf, line_0)` removes all signs except the current line before starting spinner. See `lua/poste/indicators.lua:219-230`.
- 2026-06-27: formatter — `sql-formatter` default_dialect "sql" can't parse PostgreSQL syntax (`::type` casts, etc). Fix: change default to "postgresql" — covers the most common case and handles PG-specific syntax. See `lua/poste/sql/source_format.lua:64`.
- 2026-06-29: indicators — spinner animation in sign column still broken after initial unplace+re-place fix. Root cause: `spinner_gen` was incremented TWICE per `set_indicator` call — once at function entry (line 263) and once inside `stop_timer()` (line 198). The closure's `my_gen` captured the value AFTER the first increment but BEFORE the second, so `my_gen ~= spinner_gen` was always true inside `update_spinner`, silently dropping every timer callback. Fix: call `stop_timer()` BEFORE setting `my_gen`, not after. See `lua/poste/indicators.lua:264-268`.
- 2026-06-30: sql-completion — `vim.system` in `try_rust_context_async` made callback fire asynchronously, breaking 29 tests that expect synchronous `get_items` behavior. `vim.system` deferred even fast subprocess exits to next event loop iteration. Fix: use sync `vim.fn.system` instead; `_ctx_cache` prevents re-running binary on repeated calls. See `lua/poste/sql/completion.lua:100-159`.