# Developer Documentation

> File-driven HTTP request executor (Lua + curl)

| Document | Description |
|----------|-------------|
| [Architecture Overview](./architecture-overview.md) | Layers, request lifecycle, dependency graph |
| [File Index](./file-index.md) | Quick reference for every source file |
| [Testing Guide](./testing.md) | How to run tests (tree-sitter + Lua + contract) |
| [Error Patterns](./error-patterns-review.md) | Recurring bug patterns and antidotes |
| [GUI Harness Design](./gui-harness-design.md) | Test harness for GUI-coupled modules |

## HTTP Protocol

| Document | Description |
|----------|-------------|
| [TDD Guide](./tdd-guide.md) | TDD workflow and test patterns |
| [Multi-Protocol Design](./multi-protocol-design.md) | GraphQL / gRPC / WebSocket via executor abstraction |

## Archived

Executed plans, completed reviews and superseded designs — kept as records,
paths inside them reflect the era they were written:

| Document | Description |
|----------|-------------|
| [Prompt Enhance Plan](./archived/PROMPT_ENHANCE_PLAN.md) | Structured prompt options design (implemented) |
| [Variable Resolver](./archived/variable-resolver.md) | Rust-era variable resolver design (superseded) |
| [Rust Retirement](./archived/rust-retirement-plan.md) | Rust CLI removal log (all phases done) |
| [Code Review 2026-08-13](./archived/code-review-2026-08-13.md) | Full review report (29 findings + doc drift) |
| [Code Review 2026-08-30](./archived/code-review-2026-08-30.md) | Review round record |
| [Code Review 2026-09-05](./archived/code-review-2026-09-05.md) | Quality audit: DRY / responsibilities / coverage / conventions |
| [Review Todo](./archived/code-review-todo.md) | Fix tracking checklist (done; F28 GUI-coupled coverage deferred to the GUI harness) |
| [Refactoring Plan](./archived/refactoring-plan.md) | R1–R7 roadmap (superseded by the 2026-08/09 review cycles) |
| [Block Index Proposal](./archived/block-index-proposal.md) | Structured buffer index for completion (not adopted) |
| [JSON Response UX](./archived/json-response-ux.md) | JSON folding and jq filter design (implemented) |
| [HTTP History Design](./archived/http-history.md) | Request history UI and persistence design (implemented) |
| [Tree-sitter Migration](./archived/treesitter-migration.md) | Tree-sitter as single parse authority (implemented) |

The ongoing quality ledger lives in [`docs/REVIEW-2026-*.md`](../) (one file
per review session, newest last).

---

*Developer documentation — Last updated: 2026-09-13 (release prep: executed
plans/reviews archived, living docs trimmed)*