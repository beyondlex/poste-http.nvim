# P0 Design Review — Meeting Agenda

**Goal**: Align on Poste SQL file syntax contract, context JSON contract, and implementation priorities before P1-P4 execution.

**Prep**: Read `poste-sql-file-syntax.en.md` + `design-decisions.en.md` before meeting.

---

## 1. Recap: Why P0 (5 min)

- Current state: dual truth (Lua heuristic + Rust context), boundary bugs, scattered tests
- P0 goal: define correctness before adding more code
- This meeting decides the rules that P1-P4 will implement

## 2. File Syntax Contract (15 min)

Walk through these sections of `poste-sql-file-syntax.en.md`:

| Section | Key questions |
|---------|--------------|
| 1. File structure | Header vs block boundary. `.sql`/`.mysql`/`.sqlite` uniform? |
| 2. Directive rules | `@connection` / `@database` placement and override semantics. **DECIDE**: does a block-level `@connection` reset `@database`? |
| 3. Statement boundaries | Hard (`;`, `###`, EOF) vs soft (blank lines). **DECIDE**: single blank line = boundary or not? |
| 8. Open questions | 5 items flagged for discussion |

### Must-decide:
- [ ] **Q3.1**: Remove `is_blank_line_separator()` in P1 or keep until P3?
- [ ] **Q3.5**: Is single blank line a soft boundary for completion? (Current: no, requires 2+)

## 3. JSON Context Contract (10 min)

| Section | Key questions |
|---------|--------------|
| 4.2 Additive fields | `version`, `statement`, `block` — which to add now vs later? |
| 8. Open Q2 | `statement` computed in Rust or Lua? |
| 8. Open Q3 | `block` computed in Rust or Lua? |

### Must-decide:
- [ ] **Q4.1**: `version` field — single int vs `{protocol, data}`?
- [ ] **Q4.2**: Add `version` in P1 or P2?
- [ ] **Q4.3**: `statement`/`block` fields — add JSON field now (computed in Lua) or defer?

## 4. Design Decisions to Close (20 min)

Walk through `design-decisions.en.md`, decide each:

| # | Decision | Options | **Decision** |
|---|----------|---------|:---:|
| D1 | Blank line boundary | Keep → P3 / Remove in P1 | |
| D2 | `in_string`/`in_comment` ambiguity | Keep / Option 2 / Option 3 | |
| D3 | `ctx_schema` for `SchemaTable` | Add in P2 / Leave as-is | |
| D4 | `version` granularity | Single int / `{protocol, data}` | |
| D5 | Lua `completion_ctx.lua` future | Keep indefinitely / Deprecate after P4 | |
| D6 | Rust knows `###`? | No / Yes (future LSP) | |
| D7 | `BUG` tests update timing | Immediately in P1 / Wait until P2 | |
| D8 | Directive ownership | Lua owns / Both keep | |
| D9 | `prefix` semantics | No change / Include dot | |
| D10 | Functions in Rust or Lua | Keep in Rust / Move to Lua | |

## 5. P1 Priority Confirmation (10 min)

| Action | Owner | Effort |
|--------|-------|--------|
| Strip `-- @` before Rust call | Rust | Small |
| Remove `try_directive()` from Rust detectors | Rust | Small |
| Fix CLI fallback `in_string`/`in_comment` | Rust | Small |
| Add `version` field | Rust | Tiny |
| `statement`/`block` in Lua | Lua | Medium |
| Update `BUG`-marked edge tests | Lua | Medium |
| Routing wrapper `detect_context_for_completion()` | Lua | Medium |
| Legacy switch semantics | Lua | Small |

## 6. Action Items & Next Steps (5 min)

- [ ] Confirm P0 document finalization (any edits from this meeting)
- [ ] Assign P1 implementation owner
- [ ] Set P1 target date
- [ ] Schedule P1 review
- [ ] Decide: golden fixture format review before P2 starts?

---

## Time Budget

| Item | Time |
|------|------|
| 1. Recap | 5 min |
| 2. Syntax contract | 15 min |
| 3. JSON contract | 10 min |
| 4. Design decisions | 20 min |
| 5. P1 priorities | 10 min |
| 6. Action items | 5 min |
| **Total** | **65 min** |
