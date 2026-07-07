# JSON Response UX Design

> **Status**: ✅ Implemented — see `lua/poste/http/json.lua` for the live module

## 1. Background

HTTP response JSON body display experience was previously under-developed:

| Capability | Status |
|-----------|--------|
| Syntax highlighting | ✅ treesitter (filetype=json) |
| Formatting | ✅ `pretty_body()` Lua pretty-printer |
| Folding | ❌ Missing |
| jq filtering | ❌ Missing |
| Raw/Pretty toggle | ❌ Missing |
| JSON-specific keymaps | ❌ Missing |

Goal: Add Vim-native folding and jq exploration capabilities on top of the existing body view.

---

## 2. Architecture

Pure Lua implementation, zero Rust changes. Uses `vim.api` and `vim.fn` to interact with Neovim native mechanisms.

```
view.lua (show_view "body")
  │
  ├─ filetype=json?
  │   ├─ yes → activate json.lua module
  │   └─ no → existing flow unchanged
  │
  └─ json.lua
      ├─ setup_buffer(buf)      → sets foldmethod, foldlevel, extmarks
      ├─ apply_filter(query)    → jq subprocess → replace buffer content
      ├─ restore_original()     → restore original pretty-printed body
      ├─ toggle_raw()           → raw body ↔ pretty body toggle
      └─ get_key_paths()        → extract JSON key list (for outline navigation)
```

---

## 3. Module: `lua/poste/http/json.lua`

### 3.1 `json.setup_buffer(buf)`

Called from `render_buffer()` when filetype=json.

```lua
function M.setup_buffer(buf)
  vim.wo[buf].foldmethod = "indent"
  vim.wo[buf].foldlevel = 99
  vim.wo[buf].foldcolumn = "1"
end
```

| Option | Value | Reason |
|--------|-------|--------|
| `foldmethod` | `"indent"` | `json_pretty()` outputs 2-space indent, naturally works |
| `foldlevel` | `99` | All expanded by default, users fold as needed |
| `foldcolumn` | `"1"` | Left column showing fold markers |

If `nvim-treesitter` is installed and supports `foldexpr`:

```lua
if pcall(require, "nvim-treesitter") then
  vim.wo[buf].foldexpr = "nvim_treesitter#foldexpr()"
end
```

### 3.2 `json.apply_filter(query)`

```lua
function M.apply_filter(query)
  local r = state.last_response
  if not r or not r.body then return end

  -- Cache original lines (only on first call)
  if not state._json.original_lines then
    local buf = require("poste.http.buffer").get_buf()
    state._json.original_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  local result
  if vim.fn.executable("jq") == 1 then
    local ok, output, _ = pcall(vim.fn.system, { "jq", query, "-r" }, r.body)
    if ok then
      local parsed, err = pcall(vim.json.decode, output)
      if parsed then
        result = require("poste.http.format").pretty_body(output, "application/json")
      else
        result = output
      end
    else
      vim.notify("jq error: " .. (output or "unknown"), vim.log.levels.ERROR)
      return
    end
  else
    -- Lua JSONPath fallback (simplified)
    result = M._jsonpath_query(r.body, query)
  end

  if not result then return end

  -- Replace buffer
  local buf = require("poste.http.buffer").get_buf()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result, "\n"))
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Update state
  state._json.query = query
  state._json.is_filtered = true
end
```

### 3.3 `json.restore_original()`

```lua
function M.restore_original()
  if not state._json.original_lines then return end

  local buf = require("poste.http.buffer").get_buf()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, state._json.original_lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  state._json.original_lines = nil
  state._json.query = nil
  state._json.is_filtered = false
end
```

### 3.4 `json.toggle_raw()`

```lua
function M.toggle_raw()
  state._json.pretty_mode = not state._json.pretty_mode
  local r = state.last_response
  local body = state._json.pretty_mode
    and require("poste.http.format").pretty_body(r.body, r.content_type)
    or r.body

  local buf = require("poste.http.buffer").get_buf()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body, "\n"))
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end
```

### 3.5 `json.get_key_paths()` — Outline Navigation (Phase 2)

```lua
--- Recursively extract JSON key paths + line numbers
function M.get_key_paths()
  local buf = require("poste.http.buffer").get_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local paths = {}  -- { { path = ".data.items[0].name", lnum = 42 }, ... }
  return paths
end
```

### 3.6 Lua JSONPath Fallback (when jq is unavailable)

Minimal usable subset:

| Expression | Meaning | Example |
|-----------|---------|---------|
| `.key` | Object property | `.data` |
| `.key1.key2` | Nested property | `.data.user.name` |
| `.[n]` | Array index | `.items[0]` |
| `.[]` | Array traversal | `.items[]` |
| `.[].key` | Property after traversal | `.items[].name` |

Filter expressions (`.key?`, `select()`, etc.) not supported — prompts user to install jq.

---

## 4. Modifications: `lua/poste/http/view.lua`

In the `show_view("body")` branch, when filetype=json, activate the json module:

```lua
if view == "body" then
  -- ... existing code ...
  lines = format.format_body(state.last_response)
  filetype = format.detect_filetype(state.last_response.content_type)
end

-- Activate json capabilities after render_buffer
buffer.render_buffer(lines, filetype)

if filetype == "json" then
  local json = require("poste.http.json")
  local buf = buffer.get_buf()
  json.setup_buffer(buf)
  json.attach_keymaps(buf)
end
```

---

## 5. Modifications: `lua/poste/http/buffer.lua`

### 5.1 Fold Configuration

New setting in `get_response_buffer()`:

```lua
vim.wo[response_window].foldenable = true
```

### 5.2 Keymap Registration

Register JSON-specific keymaps in `get_response_buffer()`:

```lua
local k = state.get_keymap("http_response", "json_filter", "<leader>j")
if k then
  vim.keymap.set("n", k, function()
    -- ... jq filter prompt ...
  end, opts)
end
```

---

## 6. Modifications: `lua/poste/state.lua`

### 6.1 JSON State Fields

```lua
M._json = {
  original_lines = nil,
  query = nil,
  is_filtered = false,
  pretty_mode = true,
}
```

### 6.2 Keymap Configuration

```lua
keymaps = {
  http_response = {
    json_filter = "<leader>j",
    json_restore = "<leader>jc",
    json_toggle_raw = "<leader>jr",
    json_outline = "<leader>jo",
  },
}
```

---

## 7. Interaction Details

### 7.1 jq Filter Flow

```
[body view, filetype=json]
  │
  ├─ <leader>j
  │   ├─ cmdline shows: jq>
  │   ├─ user enters .data.items | .[].name
  │   ├─ press <CR> to execute
  │   │   ├─ jq present → vim.fn.system({"jq", "-r", query}, body)
  │   │   ├─ jq missing → Lua JSONPath fallback
  │   │   └─ result replaces buffer content
  │   ├─ winbar updates: Body [H] | jq: .data.items | .[].name
  │   └─ buffer shows [filtered] marker
  │
  ├─ <leader>jc
  │   ├─ restores original_lines
  │   └─ winbar reverts: Body [H]
  │
  └─ q (close) / r (rerun)
      └─ filter state automatically cleared
```

### 7.2 Folding Interaction

```
za    Toggle fold at cursor
zR    Open all folds
zM    Close all folds
zr    Reduce fold level (open one level)
zm    Increase fold level (close one level)
```

### 7.3 State Cleanup on Navigation

`navigate_response()` must reset filter state:

```lua
state._json.original_lines = nil
state._json.query = nil
state._json.is_filtered = false
```

---

## 8. Implementation Plan

### Phase 1 — Folding

| # | File | Action |
|---|------|--------|
| 1 | `lua/poste/http/json.lua` | Create, implement `setup_buffer()` |
| 2 | `lua/poste/http/view.lua` | Call `json.setup_buffer()` when filetype=json |
| 3 | `lua/poste/state.lua` | Add `M._json` field + keymap entries |

### Phase 2 — jq Filtering

| # | File | Action |
|---|------|--------|
| 1 | `lua/poste/http/json.lua` | Implement `apply_filter()`, `restore_original()`, `_jsonpath_query()` |
| 2 | `lua/poste/http/buffer.lua` | Register `<leader>j`/`<leader>jc` keymaps |
| 3 | `lua/poste/http/buffer.lua` | Clean filter state in `navigate_response()` |

### Phase 3 — Raw/Pretty Toggle + Outline

| # | File | Action |
|---|------|--------|
| 1 | `lua/poste/http/json.lua` | Implement `toggle_raw()`, `get_key_paths()` |
| 2 | `lua/poste/http/buffer.lua` | Register `<leader>jr`/`<leader>jo` keymaps |

---

## 9. Dependencies

### jq Binary (Recommended)

- macOS: `brew install jq`
- Linux: `apt install jq` / `yum install jq`
- Detection: `vim.fn.executable("jq") == 1`
- Auto-fallback to Lua JSONPath subset when unavailable

### Security

- jq called as subprocess, query not shell-escaped (use list form `vim.fn.system({...}, body)` to prevent shell injection)
- Query comes from user input, no eval

---

## 10. Relationship to Existing Features

| Feature | Impact |
|---------|--------|
| HTTP curl execution | None — json.lua only affects response display |
| Redis responses | None — filetype isn't json, not activated |
| SQL responses | None — SQL uses dataset view, not body view |
| Multi-response navigation | Must clean filter state in `navigate_response()` |
| Re-execution | Re-rendering overwrites buffer, filter auto-invalidated |
| Assertion/script views | None — filetype is markdown |
