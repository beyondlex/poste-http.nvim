# Developer Documentation

> Architecture, implementation guides, design documents

---

## General

| Document | Description |
|----------|-------------|
| [Architecture Overview](./architecture-overview.md) | Layered architecture, protocol isolation, data flow |
| [File Index](./file-index.md) | Key files quick reference |
| [Testing Guide](./testing.md) | Rust + Lua + Docker SQL testing |
| [Archived Docs](./archived/README.md) | Outdated design documents |

## HTTP

| Document | Description |
|----------|-------------|
| [TDD Guide](./http/tdd-guide.md) | HTTP TDD workflow and test patterns |
| [Formatter Design](./http/format-design.md) | `poste fmt` architecture (✅ implemented) |
| [JSON Response UX](./http/json-response-ux.md) | JSON folding and jq exploration |
| [OpenAPI/Swagger/Postman Import](./http/openapi-import-plan.md) | TDD import feature plan (18 steps) |
| [HTTP History Design](./http/http-history.md) | Request history UI design |
| [Block Index Proposal](./http/block-index-proposal.md) | Structured buffer index proposal |

## SQL

| Document | Description |
|----------|-------------|
| [Completion System](./sql/completion/INDEX.md) | P0-P4 implementation guide (✅ complete) |
| [Context Architecture](./sql/context-architecture.md) | Context detection architecture |
| [DB Browser Context Menu](./sql/db-browser-context-menu.md) | Browser context menu design |

## Build

```bash
cargo build          # Build CLI
cargo test           # Run Rust tests
tests/run.sh         # Run Lua tests
```

### SQL Integration Tests

```bash
cd tests/sql && docker compose up -d   # PG 16 + MySQL 8.0
cargo run -- run tests/sql/queries/postgres.sql --line 4 --env dev
```

---

## Documentation Conventions

- New features: add design docs under `dev/<protocol>/`
- User syntax references go under `user/<protocol>/`
- Keep cross-references up to date
- English preferred for all documentation

---

*Developer documentation - Last updated: 2026-07-07*