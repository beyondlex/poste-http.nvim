# Poste Documentation

> **Poste** — File-driven, keyboard-first HTTP request executor (Lua + tree-sitter + curl)
>
> `.http` → execute → results in editable Vim buffers

See the [project README](../README.md) for features, installation, quick start, and configuration.

---

## User Documentation

| Area | Document | Description |
|------|----------|-------------|
| General | [User Docs](./user/README.md) | Syntax, variables, form-data, keymaps, installation |
| General | [Keymaps](./user/keymaps.md) | All keybindings and customization |
| General | [Installation](./user/plugin-install.md) | Plugin setup with lazy/packer/vim-plug |

## Developer Documentation

| Area | Document | Description |
|------|----------|-------------|
| General | [Architecture](./dev/architecture-overview.md) | Layered architecture, protocol isolation, data flow |
| General | [File Index](./dev/file-index.md) | Key files quick reference |
| General | [Testing Guide](./dev/testing.md) | Lua + tree-sitter grammar testing workflows |
| General | [Dev Docs](./dev/README.md) | TDD guide, architecture, error patterns, executed-plan archive |
| General | [Multi-Protocol Design](./dev/multi-protocol-design.md) | GraphQL / gRPC / WebSocket executor design |
| General | [Agent Guardrails](./dev/agent-guardrails.md) | Hard rules for AI agents working in this repo |
| General | [Quality Ledger](./REVIEW-2026-09-13.md) | Per-session review records (newest: 2026-09-13) |

---

*Documentation center — Last updated: 2026-09-13 (release prep: executed
plans/reviews moved to docs/dev/archived/)*