# Testing Guide

> How to run and verify Poste at each layer.

## Quick Start

```bash
# Build the CLI (from poste.nvim)
cargo build --manifest-path ../poste.nvim/Cargo.toml

# Run all Rust tests
cargo test --manifest-path ../poste.nvim/Cargo.toml

# Run Lua tests (requires Neovim)
tests/run.sh

# SQL integration tests (requires Docker)
cd tests/sql && docker compose up -d
cargo run --manifest-path ../../poste.nvim/Cargo.toml -- run tests/sql/queries/postgres.sql --line 4 --env dev
```

## Test Layers

| Layer | Tool | Command | Location |
|-------|------|---------|----------|
| Rust unit | `#[cfg(test)]` | `cargo test -p <crate>` | `crates/*/src/` |
| Rust integration | `#[test]` | `cargo test` | `crates/*/tests/` |
| Lua unit | busted | `tests/run.sh` | `tests/*.lua` |
| SQL integration | Docker Compose | See above | `tests/sql/` |

## Rust Tests

```bash
# Core (parser, resolver, formatter, importer)
cargo test --manifest-path ../poste.nvim/Cargo.toml -p poste-core

# Executor (HTTP, SQL, connections)
cargo test --manifest-path ../poste.nvim/Cargo.toml -p poste-exec

# CLI (subcommands, integrations)
cargo test --manifest-path ../poste.nvim/Cargo.toml -p poste-cli

# All + clippy
cargo test --manifest-path ../poste.nvim/Cargo.toml && cargo clippy --manifest-path ../poste.nvim/Cargo.toml -- -D warnings
```

## Lua Tests

```bash
# Run all Lua tests
tests/run.sh

# Run specific test file
busted tests/http_completion_spec.lua
```

## Manual Testing

```bash
# Create a playground environment
cd playground/http

# Run a request by line number
poste run playground/http/requests/api.http --line 2 --env dev

# Resolve a variable
poste resolve --file playground/http/requests/api.http --block 2 --var host --env dev

# Introspect database
poste introspect --connection pg-dev --env dev
```

## Troubleshooting

- **"Poste binary not found"** — Run `cargo build --manifest-path ../poste.nvim/Cargo.toml` first. The plugin looks for `poste` in PATH or `stdpath("data")/poste/bin/poste`.
- **Request doesn't execute** — Make sure cursor is on a request line (not on `###` separator) and `env.json` exists.
- **Response doesn't appear** — Check `:messages` for errors. Verify the binary works: `poste run <file> --line 2 --env dev`.

---

*Testing guide — Last updated: 2026-07-21*