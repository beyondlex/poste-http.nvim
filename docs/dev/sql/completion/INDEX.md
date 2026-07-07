# Poste SQL Completion — Agent Entry Point

> **Status**: P0 ✅ | P1 ✅ | P2 ✅ | P3 ✅ | P4 ✅

If you're an AI agent encountering this codebase for the first time, read and follow the steps below in order.

---

## 1. Required Reading (In Order)

| Order | File | After reading you should understand |
|-------|------|-------------------------------------|
| ① | `p0/poste-sql-file-syntax.en.md` | File structure, directive rules, statement boundaries, JSON contract, context type semantics (8 sections) |
| ② | `plan.en.md` | Per-phase step checklist, verification commands, commit checklist |

Reference material:

| Reference | File | When to consult |
|-----------|------|-----------------|
| Design decisions D1-D10 trade-off analysis | `p0/design-decisions.en.md` | When encountering edge cases or questioning current design choices |
| Meeting debate records + subsequent decisions | `p0/meeting-minutes.zh.md` (Chinese only) | To understand why a particular decision was made |

**Don't read**: `README.en.md` / `README.zh.md` (original plan, superseded by `plan.*.md`), `p0/meeting-agenda.*.md` (historical meeting agendas).

---

## 2. Implementation Rules

### 2.1 TDD First

```
1. Write test (or golden fixture) first
2. Confirm test fails (red)
3. Implement until test passes (green)
4. Refactor
```

- Rust new features: add fixture/test in `tests/sql_context_golden.rs` or `sql_context/tests.rs` first
- Lua new features: add test in `tests/sql_completion_*_spec.lua` first
- Tests marked `BUG`/`BEFORE FIX`: after fixing, **update test assertions** to match correct behavior, don't preserve tests encoding wrong behavior

### 2.2 Verification Commands

```bash
# Rust tests
cargo test -p poste-core sql_context

# Rust golden fixture tests (P2+)
cargo test -p poste-core --test sql_context_golden

# Lua tests
tests/run.sh

# Clippy
cargo clippy -p poste-core -p poste-cli -p poste-exec -- -D warnings
```

### 2.3 Change Boundaries

| Don't modify | Reason |
|-------------|--------|
| `lua/poste/http/*` | HTTP completion isolation |
| `lua/poste/http/completion.lua` | HTTP completion entry (not SQL) |
| `lua/poste/sql/buffer.lua` | SQL result rendering |
| SQL executor behavior | Unless phase explicitly needs metadata/cache support |

### 2.4 Progress Tracking

After each implementation step, update the progress bar and checkboxes at the top of `plan.en.md`:

```markdown
> **Progress**: P0 ✅ | P1 ⬜/⬜/⬜/⬜ | P2 ⬜ | P3 ⬜ | P4 ⬜
```

Use `[x]` for completed checkboxes, `⬜` for not started. Partial progress can use `⬜/⬜/⬜/⬜` to show sub-step completion.

### 2.5 Contract Compatibility Rules

- **Don't delete JSON fields**. Only add, never remove. The `version` field must always exist.
- Lua side ignores unknown fields (`deep_clean()` already handles this).
- `###` no longer appears in the file format. Code handling `###` in old code should be removed.

---

## 3. Quick Reference

| Need | Path |
|------|------|
| Current implementation step | `plan.en.md` — find the first unchecked `[ ]` |
| Complete context type table (14 types + 42 edge cases) | `p0/poste-sql-file-syntax.en.md` §5 |
| JSON contract field definitions | `p0/poste-sql-file-syntax.en.md` §4 |
| Statement boundary rules (current) | `p0/poste-sql-file-syntax.en.md` §3 |
| Semantic-level statement boundaries (future) | `archived/semantic-statement-boundary.en.md` |
| Per-phase changed file list | `plan.en.md` — "Files:" lists in each P1-P4 step |
| Global commit checklist | `plan.en.md` §Global Commit Checklist (file end) |
