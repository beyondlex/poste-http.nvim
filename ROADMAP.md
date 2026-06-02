# Poste Roadmap

## Phase 1 — MVP: HTTP + CLI ✅

**Goal:** Execute HTTP requests from `.http` files via CLI.

- [x] Workspace structure (3 crates)
- [x] Environment variable loading from `.reqq/env.json`
- [x] `{{variable}}` substitution
- [x] Request file parsing (extract request at cursor line)
- [x] HTTP execution (GET/POST/PUT/DELETE/PATCH/HEAD)
- [x] Response output (status, headers, body)
- [x] CLI interface (`poste run <file> --line N --env <name>`)
- [x] JSON response pretty-printing
- [x] Response timing (latency display)
- [x] Unit tests for parser (8 tests passing)

## Phase 2 — Neovim Plugin ✅

**Goal:** Native Neovim experience for editing and executing requests.

- [x] Plugin skeleton (`lua/poste/init.lua`)
- [x] `<leader>rr` — execute request at cursor
- [x] `[[` / `]]` — jump between `###` separators
- [x] Response opens in a split buffer (not a floating window)
- [x] Response buffer is a normal Vim buffer (yank, visual select, search all work)
- [x] `:PosteEnv <name>` — switch environment
- [x] File type detection for `.http` files
- [x] Plugin documentation (README_PLUGIN.md)
- [x] Installation instructions (lazy.nvim, packer, vim-plug)
- [x] Status line integration (poste_status function)
- [ ] JSON auto-formatting in response buffer (depends on CLI pretty-printing)

## Phase 3 — Database Protocols

**Goal:** Support SQL databases and Redis.

- [ ] PostgreSQL execution (sqlx or tokio-postgres)
- [ ] MySQL execution (sqlx or mysql-async)
- [ ] Redis execution (redis crate)
- [ ] SQL ResultSet → table format in response buffer
- [ ] Redis response formatting (bulk strings, arrays, etc.)
- [ ] Connection URL parsing from `@connection` directive
- [ ] Connection pooling / reuse within a session

## Phase 4 — MongoDB + AMQP

**Goal:** Full protocol coverage matching Ocular.

- [ ] MongoDB execution (mongodb crate)
- [ ] MongoDB shell syntax parsing (`db.collection.find({...})`)
- [ ] MongoDB response formatting (JSON documents)
- [ ] RabbitMQ publish/consume (lapin crate)
- [ ] AMQP message format in request files

## Phase 5 — Ocular Integration

**Goal:** Bidirectional workflow between Ocular (observe) and Poste (send).

- [ ] Ocular TUI: `s` key to save event as request
- [ ] Ocular → Poste: format captured event into correct file type
- [ ] Ocular component → Poste connection mapping
- [ ] Auto-append to the correct request file based on protocol
- [ ] Timestamp and source metadata in exported requests

## Phase 6 — Advanced Features

**Goal:** Power-user capabilities.

- [ ] Request chaining (use response from request A as input to request B)
- [ ] Response history (browse past responses)
- [ ] Response diff (compare two executions)
- [ ] Environment variable secrets (read from env vars or keychain)
- [ ] Export to curl / other formats
- [x] Test assertions (`> {% assert response.status == 200 %}`)
- [x] Pre/post request scripts (`< {% ... %}` pre-request, `> {% ... %}` post-request with `request.variables` and `client.global` APIs)

## Completed Milestones

| Date | Milestone |
|------|-----------|
| 2026-05-29 | Project created, workspace structure, HTTP execution working |
