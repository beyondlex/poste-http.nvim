# Learnings

Agent self-evolution log. When you fix a non-obvious bug or encounter a
pitfall, log it here. Check this file before starting any task.

## Format

```
- YYYY-MM-DD: <scope> — <one-line problem>. Fix: <one-line fix>. See <file>:<line>.
```

## Entries

- 2026-06-26: keymaps — renamed `source_buffer` → `http_source`, `db_browser` → `sql_db_browser`, `introspect_float` → `sql_introspect` for consistency. Breaking change for users with custom configs using old names. See `lua/poste/state.lua:25-133`.
- 2026-06-24: http — pre-script/global var injection adds lines to buf_content but `--line` not adjusted, causing wrong block selection in Rust parser. Fix: add `line = line + injected_count` after each injection. See `lua/poste/http/run.lua:133,154`.
- 2026-06-24: http — jq filter state (`_json.query`, `original_lines`, `is_filtered`) persists across requests, showing stale filter in winbar. Fix: clear `state._json` before setting `state.last_response`. See `lua/poste/http/run.lua:199-201`.
- 2026-06-24: docs — `docs/dev/http/impl-guide.md` was a specific Phase 0-4 feature plan, not a general TDD guide. Fix: archive it, create `docs/dev/http/tdd-guide.md` as general TDD reference. See `docs/dev/http/tdd-guide.md`.
- 2026-06-25: http — child windows within a Neovim float (`relative = "win"`) get auto-closed when parent float closes, triggering `on_detach` → callbacks. Fix: use `hiding` guard in `hide()` to prevent recursion. See `lua/poste/http/history.lua:262-280`.