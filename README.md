# poste-http.nvim

[![CI](https://github.com/beyondlex/poste-http.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/beyondlex/poste-http.nvim/actions/workflows/ci.yml)

**HTTP request execution for Neovim.** Define requests in plain `.http`/`.rest`
files, press `<CR>`, and read the response in an editable, jq-filterable
buffer — JetBrains HTTP Client ergonomics, Vim-native.

Fully self-contained: pure Lua + tree-sitter, `curl` as the only hard
subprocess — no binary to install, no plugin host. Part of the
[Poste](https://github.com/beyondlex/poste.nvim) family, whose plugins are
independent and release on their own.

<!--
Hero screenshot: a .http buffer with the cursor on a request block and the
response panel beside it — Body view with the jq filter prompt active and
the multi-tab strip (Body / Verbose / Assertions / Script logs) visible.
Drop the image at .github/assets/hero.png and uncomment.
![poste-http.nvim — request file + response panel](.github/assets/hero.png)
-->

## Features

- **File-based requests** — Define requests in `.http`/`.rest` files
- **Environment variables** — JetBrains-style `env.json` with `{{var}}` substitution
- **Assertions & scripts** — Inline `> {% ... %}` assertions, pre/post-request scripts
- **Request chaining** — `{{RequestName.response.body.X}}` to extract values from prior responses
- **Request orchestration** — `SCRIPT` blocks call imported requests sequentially via `client.run()`: chain tokens, loop, and assert across requests
- **Prompt variables** — Interactive `<<var` prompts with picker/text input
- **Completion** — HTTP methods, headers, values, env vars (blink.cmp / nvim-cmp)
- **jq filtering** — Interactive JSON exploration in response view

<!--
Screenshot: the response panel mid-exploration — JSON body folded to a
depth, the interactive jq filter line showing a live query, image preview
via K in a second tab.
Suggested path: .github/assets/json-ux.png
-->

- **Multi-protocol** — `GRAPHQL` (real POST with query+variables), `GRPC` (via
  grpcurl: unary, server-streaming, reflection), and `WEBSOCKET` (via websocat:
  batch collect and interactive sessions) in the same `.http` files. See
  [Multi-protocol design](docs/dev/multi-protocol-design.md)
- **Multi-tab response** — Body, verbose, request, messages (WebSocket frames),
  assertions, script logs
- **History** — Request history with quick re-runs
- **Import** — Convert OpenAPI 3.x, Swagger 2.0, and Postman collections to `.http` files
- **AI chat** (optional) — With [poste-ai.nvim](https://github.com/beyondlex/poste-ai.nvim)
  installed: ask about requests/responses with real context, and execute
  AI-generated ```http blocks through the regular pipeline. See
  [AI integration](docs/dev/ai-integration.md).

## Requirements

- Neovim (0.10+)
- `curl` — required, the only hard subprocess
- `grpcurl` — optional, for `GRPC` requests
- `websocat` — optional, for `WEBSOCKET` requests
- A C compiler — to compile the bundled tree-sitter parsers on first setup
- [snacks.nvim](https://github.com/folke/snacks.nvim) — optional, nicer picker UI (built-in float fallback)

Run `:checkhealth poste-http` to verify your installation.

## Install

```lua
-- lazy.nvim
{
  "beyondlex/poste-http.nvim",
  dependencies = {
    "saghen/blink.cmp",        -- completion (nvim-cmp also works)
    "folke/snacks.nvim",       -- optional: picker UI
    "beyondlex/finder",        -- optional: spec import (OpenAPI/Swagger/Postman)
  },
  config = function()
    require("poste-http").setup()
  end,
}
```

Tree-sitter parsers are compiled automatically on first setup (requires a C compiler).
Run `:PosteHttpBuildParsers` to recompile after an update.

### Create a request file

`requests/api.http`:

```http
### List users
GET {{api_base}}/users
Authorization: Bearer {{api_token}}

### Create user
POST {{api_base}}/users
Content-Type: application/json

{"name": "John", "email": "john@test.com"}
```

### Define environments

`env.json` (walk-up discovery from file directory):

```json
{
  "dev": {
    "api_base": "http://localhost:8080",
    "api_token": "dev-token-xxx"
  },
  "prod": {
    "api_base": "https://api.example.com",
    "api_token": "prod-token-xxx"
  }
}
```

### Execute

Open a `.http` file. With cursor on a request block, press `<CR>` to execute. Results open in a side panel.

## Keymaps

### Source buffer (`.http`)

| Key | Action |
|-----|--------|
| `<CR>` | Execute request at cursor |
| `]]` / `[[` | Jump next/previous block |
| `gd` | Go to definition |
| `grr` | Go to references |
| `gs` | Symbol outline |
| `<leader>rp` | Paste curl from clipboard |
| `<leader>rc` | Copy request as curl |
| `K` | Show variable value / response chain |
| `<leader>vv` | Pick environment |
| `<leader>l` | Open request history |

<!--
Screenshot: the history float — request list with method/status/latency
columns, one entry's detail pane open, quick re-run hint visible.
Suggested path: .github/assets/history.png
-->

| Key | Action |
|-----|--------|
| `ga` | Ask the AI about the request under cursor (poste-ai.nvim) |
| `g?` | Open help window |

### HTTP response buffer

| Key | Action |
|-----|--------|
| `q` | Close |
| `B` / `E` | View Body / Verbose |
| `A` / `S` | View Assertions / Script logs |
| `<Tab>` / `<S-Tab>` | Next/previous tab |
| `r` | Re-run request |
| `K` | Image preview |
| `<leader>j` | Interactive jq filter |
| `<leader>jc` | Restore original JSON |
| `<leader>jr` | Toggle raw/pretty |
| `<leader>jo` | JSON outline |
| `a` | Ask the AI about this response / errors (poste-ai.nvim) |

## Configuration

```lua
require("poste-http").setup({
  default_env = "dev",
  split_direction = "vertical",
  -- Response window share (0–1) restored after the whole window is resized
  -- (e.g. terminal maximize → restore), so neither split disappears.
  result_window_ratio = 0.5,
  log_file = vim.fn.stdpath("cache") .. "/poste.log",

  keymaps = {
    http_source = {
      run = "<CR>",
      jump_next = "]]",
      jump_prev = "[[",
      goto_definition = "gd",
      goto_references = "grr",
      paste_curl = "<leader>rp",
      copy_as_curl = "<leader>rc",
      toggle_outline = "gs",
      help = "g?",
    },
    http_response = {
      close = "q",
      view_body = "B",
      view_verbose = "E",
      view_assertions = "A",
      view_script_logs = "S",
      next_tab = "<Tab>",
      prev_tab = "<S-Tab>",
      rerun = "r",
      json_filter = "<leader>j",
      json_restore = "<leader>jc",
      json_toggle_raw = "<leader>jr",
      json_outline = "<leader>jo",
    },
    http_history = {
      close = "q",
      delete_entry = "dd",
      focus_detail = "<CR>",
    },
  },
})
```

## Orchestration

Define requests in one file (like Postman), then run them as a flow from a
`SCRIPT` block. `client.run()` executes an imported request and returns its
typed response, so you can chain tokens, loop, and assert:

```http
import ./requests.http as api

### Login then fetch profile
SCRIPT
> {%
  local login = client.run("#api.Login", { username = "alice", password = "secret" })
  assert(login.status == 200, "login failed")
  local profile = client.run("#api.GetProfile", { auth_token = login.body.token })
  assert(profile.status == 200, "get profile failed")
  client.log("profile: " .. profile.body.username)
%}
```

`gd` jumps to the request definition, completion/highlighting work like
`run #alias.Name`, and every call's response appears in the multi-response
chain. Full docs: [Scripts](https://github.com/beyondlex/poste-http.nvim/wiki/Scripts).

## Import

Convert API specs to `.http` files. Supports OpenAPI 3.x, Swagger 2.0, and Postman collections
(uses the optional [finder](https://github.com/beyondlex/finder) file picker).

```vim
:PosteHttpImportOpenAPI      " Browse for spec → choose output directory
:PosteHttpImportSwagger
:PosteHttpImportPostman
```

## Completion

Poste provides context-aware completions for HTTP files.

- **HTTP methods** — `GET`, `POST`, `PUT`, `DELETE`, etc.
- **Header names** — `Content-Type`, `Authorization`, `Accept-Encoding`, etc.
- **Header values** — `application/json`, `Bearer `, `gzip`, etc.
- **Variables / env vars** — `{{...}}` references from env.json

Works with both **nvim-cmp** and **blink.cmp**. Auto-registers as `poste_http` source.

## Prompt Variables

Prompt variables allow interactive input when running a request.

```
<<username                                    -- Text input
<<method [GET, POST, PUT, DELETE]             -- Picker from list
<<email [{{1.response.body | {name: ..., key: ..., desc: ...} }}]  -- Dynamic from prior response
```

## CLI-style Commands

There is no standalone CLI. Requests run directly from Neovim:

- `:PosteHttpRun` (or the `run` keymap) to run the request under the cursor
- `:PosteHttpCopyAsCurl` to copy the request as a curl command
- `:PosteHttpChat` to open the AI chat scoped to the current `.http` file (needs poste-ai.nvim)
- `:PosteHttpImportOpenAPI` / `:PosteHttpImportSwagger` / `:PosteHttpImportPostman` to import specs

## Documentation

- `:h poste-http` — full help (`doc/poste-http.txt`)
- [User docs](docs/user/README.md) — syntax, variables, form-data, keymaps, [quick reference](docs/user/quick-reference.md)
- [Developer docs](docs/dev/README.md) — architecture, testing, agent guardrails

## Testing

```bash
./tests/run.sh          # Lua + tree-sitter + contract suites
```

## License

MIT
