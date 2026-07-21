# Poste Documentation

> **Poste** — File-driven, keyboard-first HTTP request executor (Rust CLI + Neovim plugin)
>
> `.http` / `.redis` → execute → results in editable Vim buffers

See the [project README](../README.md) for features, installation, quick start, and configuration.

---

## User Documentation

| Area | Document | Description |
|------|----------|-------------|
| **HTTP** | [User Docs](./user/http/README.md) | Syntax, variables, form-data, quick reference |
| General | [Installation](./user/plugin-install.md) | Plugin setup with lazy/packer/vim-plug |
| General | [Keymaps](./user/keymaps.md) | All keybindings and customization |

## Developer Documentation

| Area | Document | Description |
|------|----------|-------------|
| General | [Architecture](./dev/architecture-overview.md) | Layered architecture, protocol isolation, data flow |
| General | [File Index](./dev/file-index.md) | Key files quick reference |
| General | [Testing Guide](./dev/testing.md) | Rust + Lua testing workflows |
| **HTTP** | [Dev Docs](./dev/http/README.md) | TDD guide, formatter design, JSON UX, history |

---

## Protocol Support

| Protocol | Extension | Status |
|----------|-----------|--------|
| HTTP | `.http` / `.rest` | ✅ Complete |
| Redis | `.redis` | ✅ Complete |

---

*Documentation center — Last updated: 2026-07-21*