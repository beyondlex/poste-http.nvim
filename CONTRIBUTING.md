# Contributing to poste-http.nvim

Thanks for considering a contribution. The bar is deliberately small: every
change lands with a regression test and a zero-warning lint.

## Setup

```bash
git clone https://github.com/beyondlex/poste-http.nvim
cd poste-http.nvim

# Lua + tree-sitter + contract tests (needs plenary.nvim and the
# tree-sitter CLI; see docs/dev/testing.md for the layer-by-layer guide)
tests/run.sh /path/to/plenary.nvim
```

Optional but useful for manual verification: the Docker test server in
`playground/http/server` (an httpbin-like FastAPI service on port 8888) with
ready-made `.http` scenarios in `playground/http/scenarios/`.

CI runs on every PR: `luacheck --codes lua plugin ftplugin tests after
queries` (zero warnings is the baseline — any new warning fails the build)
plus the full test suite on Neovim 0.10 with the tree-sitter CLI installed.

## Ground rules

- **A regression test comes with the change.** Smallest test that captures
  the behavior; assert observable results, not internals; one seam at a
  time. The test layers and when to reach for each are described in
  [docs/dev/testing.md](docs/dev/testing.md); the TDD workflow lives in
  [docs/dev/tdd-guide.md](docs/dev/tdd-guide.md).
- **Zero luacheck warnings.** The config lives in `.luacheckrc`
  (`unused_args` off, Neovim/busted globals declared).
- **Recurring bug patterns** are catalogued with antidotes in
  [docs/dev/error-patterns-review.md](docs/dev/error-patterns-review.md) —
  worth a skim before touching the request pipeline or variable resolver.
- **Hard rules for AI agents** (and humans doing mechanical refactors) are
  in [docs/dev/agent-guardrails.md](docs/dev/agent-guardrails.md).
- **Secrets never land in the repo.** Environments live in `env.json`
  (gitignored); fixtures use the playground server.
- **Commit messages** follow Conventional Commits (`feat(scope): ...`,
  `fix(scope): ...`, `docs: ...`, `chore: ...`).

## Where things live

| Path | What |
|------|------|
| `lua/poste-http/` | Plugin code; `docs/dev/file-index.md` is the per-file index |
| `lua/poste-http/http/` | Core request pipeline (parse → resolve → execute → render) |
| `tree-sitter-poste-http/` (+ `-json`, `-graphql`) | Bundled grammars; parse authority for `.http` buffers |
| `tests/` | plenary specs, grammar/injection shell specs, contract tests |
| `playground/http/` | Docker test server + manual `.http` scenarios |
| `docs/dev/architecture-overview.md` | Layers, request lifecycle, dependency graph |

## Adding a protocol or executor

The executor abstraction that GRAPHQL (grpcurl), GRPC, and WEBSOCKET
(websocat) plug into is described in
[docs/dev/multi-protocol-design.md](docs/dev/multi-protocol-design.md) —
read it before proposing a new transport.
