# Poste HTTP Formatter Design

> **Status**: ✅ Implemented — `poste fmt` is available as a CLI subcommand (see `crates/poste-core/src/formatter.rs` and `crates/poste-cli/src/fmt.rs`)

## 1. Background

`.http` / `.rest` files contain mixed content: `###` request blocks, `@variable` definitions, HTTP request lines, headers, JSON bodies, `< {% %}` pre-scripts, `> {% %}` assertions. No existing formatter understands this hybrid format.

Syntax specification is in [user syntax doc](../../user/http/syntax.md).

## 2. Architecture Decision: Rust `poste fmt`

**Not using a Lua implementation.**

### Rationale

| Dimension | Rust `poste fmt` | Lua-only |
|-----------|------------------|----------|
| Reuse existing infra | ✅ `poste-core` token/region capability | ❌ Would need re-parsing |
| CI / pre-commit | ✅ `poste fmt --check` | ❌ Requires Neovim |
| Cross-editor | ✅ Helix, VS Code, etc. | ❌ Neovim-only |
| conform.nvim integration | ✅ `format_command` | ✅ Also works |
| Maintenance | One parsing logic | Two (Rust parser + Lua formatter) |

Users already have the Rust binary — `poste fmt` is just a subcommand, zero additional install cost.

### Overall Architecture

```
poste fmt [--check] [--stdin] [file...]
```

Flow:

```
Input (.http text)
    ↓
Tokenizer ──→ Region list (lossless, preserves comments/whitespace/scripts)
    ↓
Formatter  ──→ Apply rules by region type
    ↓
Output (.http text)
```

Tokenizer vs Parser:

| | `parser.rs` (existing) | Tokenizer (new) |
|---|---|---|
| Goal | Extract `Request` struct | Mark all region boundaries |
| Preserves whitespace | ❌ Merges | ✅ Preserves as-is |
| Handles scripts | ❌ Strips | ✅ Marks as PreScript/PostScript region |
| File includes | ❌ Ignores | ✅ Marks FileInclude region |
| Output | `Request { name, body }` | `Vec<Region>` |

### Region Types

```rust
enum Region {
    /// ### Request Name line
    Separator(String),
    /// # comment line
    Comment(String),
    /// @var = value definition (file-level or block-level, including @env = value)
    VarDef { name: String, value: String, raw: String, style: VarStyle },
    /// METHOD URL [HTTP/version]
    RequestLine { method: String, url: String, version: Option<String>, raw: String },
    /// Key: Value header
    Header { key: String, value: String, raw: String },
    /// Blank line
    BlankLine,
    /// Request body (text/JSON/form-url-encoded)
    Body { content: String, content_type: Option<String> },
    /// < {% code %} or < {% ... %}
    PreScript { code: String, style: ScriptStyle },
    /// > {% code %} or > {% ... %}
    PostScript { code: String, style: ScriptStyle },
    /// External script reference: < ./path.lua or > ./path.lua
    ExternalScript { path: String, script_type: ScriptType },
    /// < path — file content include or upload
    FileUpload(String),
    /// <<varname [opts] — kept as-is
    Prompt(String),
    /// import ./path[ as alias] — file-level reference
    Import { path: String, alias: Option<String>, raw: String },
    /// run #Name|#alias.Name|./path [(@var=val)]
    Run { target: String, raw: String },
    /// Other unknown content (kept as-is)
    Raw(String),
}

enum VarStyle { Simple, Multiline { terminator: String } }
enum ScriptStyle { Inline(String), Multiline(Vec<String>) }
enum ScriptType { Pre, Post }
```

## 3. Formatting Rules (Phased)

### Phase 1 — Structural Formatting

Text-only operations, no semantic understanding needed.

**Rule 1: File-level spacing**
```
import ./auth.http                         ← import (multiple allowed)
import ./orders.http as orders
                                           ← one blank line
@base_url = https://api.example.com        ← file-level @var (multiple allowed)
@token = eyJ...
                                           ← one blank line
### Get users                              ← first ###
```

- One blank line between `import`/`run` and file-level `@var`
- One blank line between file-level `@var` and first `###`
- When no `import`/`run`, still one blank line between `@var` and first `###`

**Rule 2: `###` separator**
- Ensure **exactly one blank line** before `###`
- First `###` at file start doesn't need preceding blank line (but does after file-level area)
- Title after `###` preserved as-is, trailing whitespace trimmed

```
### Get users
...
                              ← blank line (exactly one)
### Create user
```

**Rule 3: Header key normalization**
- Capitalize first letter of header keys (`content-type` → `Content-Type`)
- One space after colon in `Key:`
- Don't change header order

```
content-type: application/json        ← before
Content-Type: application/json        ← after
```

**Rule 4: `@variable` definition formatting**
- One space before and after `=` (`@var=val` → `@var = val`)
- Multi-line `@xxx =>>> ... <<<` content preserved as-is
- `{{}}` references within values left unchanged

```
@base_url=https://api.example.com     ← before
@base_url = https://api.example.com   ← after
```

**Rule 5: `import` / `run` lines**
- Entire line preserved as-is
- Spacing per Rule 1

**Rule 6: Special directive lines (`<<name`)**
- Entire line preserved as-is

**Rule 7: Whitespace cleanup**
- File end: ensure one trailing newline
- Consecutive blank lines: collapse to at most one

**Rule 8: Trailing whitespace**
- Remove all trailing whitespace

**Rule 9: Post-`###` formatting**
- Lines after `###` should directly follow (vars or request line)
- Extra blank lines → collapse to at most one

### Phase 2 — JSON Body Pretty-printing

**Rule 10: JSON body formatting**
- Detect if `Content-Type` header contains `json` (case-insensitive)
- Parse with `serde_json` → `serde_json::to_string_pretty`
- If parse fails → keep as-is

```
{"name":"test","value":123}
              ↓
{
  "name": "test",
  "value": 123
}
```

### Phase 3 — Script Formatting

**Rule 11: `{% %}` internal formatting**
- Keep `{%` and `%}` boundary lines
- Internal code: 2-space indent
- Optional: detect `prettierd` and call via `jobstart` (if available)

```
> {% client.test("ok", function() {
client.assert(response.status == 200);
}) %}
              ↓
> {%
  client.test("ok", function() {
    client.assert(response.status == 200);
  })
%}
```

## 4. CLI Integration

```
USAGE:
    poste fmt [OPTIONS] [FILE]...

ARGS:
    <FILE>...    Files to format (default: stdin)

OPTIONS:
    --check          Check formatting without modifying (exit 1 if unformatted)
    --stdin          Read from stdin (default if no file args)
    -i, --in-place   Modify files in-place (default)
    -h, --help       Print help
```

### conform.nvim Integration

```lua
require("conform").formatters.poste_http = {
  command = "poste",
  args = { "fmt", "--stdin" },
  stdin = true,
}

require("conform").formatters_by_ft["poste_http"] = { "poste_http" }
```

### CI / pre-commit Integration

```yaml
# .pre-commit-config.yaml
- repo: local
  hooks:
    - id: poste-http-fmt
      name: Format .http files
      entry: poste fmt --check
      language: system
      files: \.(http|rest)$
```

## 5. Future

- [ ] `kulala-fmt` compatibility adaptation

