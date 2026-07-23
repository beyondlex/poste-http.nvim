# Poste HTTP

**HTTP request execution for Neovim.** Part of the [Poste](https://github.com/beyondlex/poste.nvim) family.

**Requires**: [poste.nvim](https://github.com/beyondlex/poste.nvim) (shared infra + Rust binary)

## Features

- **File-based requests** — Define requests in `.http`/`.rest` files
- **Environment variables** — JetBrains-style `env.json` with `{{var}}` substitution
- **Assertions & scripts** — Inline `> {% ... %}` assertions, pre/post-request scripts
- **Request chaining** — `{{RequestName.res.body.X}}` to extract values from prior responses
- **Prompt variables** — Interactive `<<var` prompts with picker/text input
- **Completion** — HTTP methods, headers, values, env vars (blink.cmp / nvim-cmp)
- **jq filtering** — `:PosteJqFilter` for interactive JSON exploration
- **Multi-tab response** — Body, verbose, request, assertions, script logs
- **History** — Request history with quick re-runs
- **Import** — Convert OpenAPI 3.x, Swagger 2.0, and Postman collections to `.http` files

## Import

Convert API specs to `.http` files. Supports OpenAPI 3.x, Swagger 2.0, and Postman collections.

### Neovim

```vim
:PosteImportOpenAPI      " Browse for spec → choose output directory
:PosteImportSwagger
:PosteImportPostman
```

### CLI

```bash
poste import openapi spec.json --out ./http-requests
poste import swagger petstore.yaml --out ./http-requests
poste import postman collection.json --out ./http-requests
```

## Quick Start

### Install

```lua
-- lazy.nvim
{
  "beyondlex/poste-http.nvim",
  dependencies = {
    "beyondlex/poste.nvim",
    "saghen/blink.cmp",
    "stevearc/dressing.nvim",
    "beyondlex/finder",
  },
  config = function()
    require("poste").setup()
  end,
}
```

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

## Configuration

```lua
require("poste").setup({
  -- Binary path
  poste_binary = vim.fn.stdpath("data") .. "/poste/bin/poste",
  default_env = "dev",
  split_direction = "vertical",
  split_size = 80,
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

## CLI

```bash
# Run a request
poste run requests/api.http --line 4 --env dev

# Import API specs
poste import openapi spec.json --out ./http-requests
poste import swagger spec.yaml --out ./http-requests
poste import postman collection.json --out ./http-requests
```

## License

MIT