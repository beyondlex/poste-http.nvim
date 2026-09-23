# Learnings

Agent self-evolution log. When you fix a non-obvious bug or encounter a
pitfall, log it here. Check this file before starting any task.

- 2026-09-23: http/json-body-region — a grammar TOKEN is not a boundary.
  `json_body: token(seq(/[\[{][^\n]*/, /(?:\n[^\n]+)*/))` ends at the first
  blank line, so `{"a":1,\n\n"b":2}` silently sent `{"a": 1,` (array bodies the
  same), while a `> {%` written directly after `}` had the OPPOSITE problem —
  the continuation swallowed the assertion block into the body and shipped it.
  A whole-body `< ./payload.json` include vanished too: the grammar types it
  `external_script`/`file_upload`, describe marks those lines non-body, and
  `file_include` never saw them. describe.lua now derives the region line-wise
  from `block_boundary.last_content_line`, stopping at script delimiters
  (`[<>] {%`, `%}`, `[<>] ….lua`) and keeping `< path` includes; the node text
  is only the hint that a JSON body starts here. Fixing bodies in the send path
  (curl_exec) rather than in display code also meant `Copy as cURL` had to be
  wired to the same `json_body.normalize` — copy.lua is a SECOND, independent
  body assembly (it splits headers/body on the first blank line), so any
  body-shape rule has to be applied twice until that is ever unified.
  See `lua/poste-http/http/describe.lua`, `lua/poste-http/http/json_body.lua`,
  `tests/http/describe_spec.lua`, `tests/http/json_body_spec.lua`.

- 2026-09-23: indicators BufDelete-vs-BufWipeout — `nvim_buf_delete` on an
  UNLOADED SCRATCH buffer (the normal .http nofile case) fires only
  `BufWipeout`; `BufDelete` stayed at 0 in a headless probe, so a cleanup
  autocmd hung on BufDelete never ran and spinner timers leaked per wiped
  buffer. When a scratch buffer's teardown matters, hook BufWipeout
  (folding.lua and indicators.lua now share the _evict shape). See
  `lua/poste-http/indicators.lua`, `tests/http/indicators_eviction_spec.lua`.

- 2026-09-19: curl-import-fidelity — verify importer claims against the real
  binary's wire behavior, not from memory: three bugs this round (multi `-d`
  last-wins instead of `&`-joined, quoted `boundary="x"` leaking quotes into
  delimiter lines, `-G` ignored) were only provable by capturing actual curl
  8.7.1 requests through a netcat listener. The same probes also killed a
  plausible "fix" (reuse the user's multipart boundary) — modern curl appends
  its OWN boundary as a second `boundary=` param and never uses the header's.
  Probe recipe: `(nc -l 127.0.0.1 PORT > cap.txt &) ; sleep 0.5; curl -s ... ;
  cat cap.txt`. See `lua/poste-http/http/curl.lua`, `tests/http/curl_spec.lua`.

- 2026-09-07: lua-patterns/SDL-parsing — two traps hit while writing the
  graphql_schema SDL slicer: (1) greedy backtracking splits identifier tails —
  `^%s*%a+%s+[_%w]*([%a][%w_]*)` on "type Query" yields name "y" (the `[_%w]*`
  class gives back chars one at a time until the next class matches); capture
  the whole identifier in one class instead (`^%s*%a+%s+([%w_]+)`). (2) A
  definition-keyword scanner over free text must track `(`/`{` depth and only
  accept keywords at depth 0 — otherwise a legal argument named `type`/`input`
  (`createUser(input: ...)`) splits the type's slice mid-field. See
  `lua/poste-http/http/graphql_schema.lua` parse_sdl,
  `tests/http/graphql_schema_spec.lua`.

- 2026-09-07: treesitter/injection-testing — nvim 0.12 no longer exposes
  injected LanguageTree children: `parser:children()` returns `{}` even after
  `vim.treesitter.start` + `:parse()`, and `for_each_child` is gone, so a
  "did my injection produce a tree" assertion cannot be written directly.
  Injection specs must split in two halves: (1) wiring — iterate the
  `injections` query matches and assert the capture node type +
  `metadata["injection.language"]`; (2) language — parse the injected range's
  text with the injected parser directly (`vim.treesitter.get_parser(buf,
  lang)`) and run its highlights query. Also: `pcall(vim.treesitter.language.add, lang)`
  succeeds even when the parser .so is missing — guard availability with
  `pcall(vim.treesitter.get_parser, ...)` instead. See
  `tests/http/graphql_highlights_spec.lua`.

- 2026-09-02: http/history-ghost-cursor — `gg`/`G` (native buffer motions) in the history list window moved the visible cursor but not the module-local `current_index`, so the next `j`/`k` moved from a stale "ghost baseline" (jumped-to line + 1; `G` then `k` wrapped to the top) and the detail pane kept showing the old entry. Fix: map `gg`/`G` in `setup_list_keymaps` to a `jump_to(index)` that syncs `current_index` + buffer cursor + detail pane (`G` honors `v:count`), and resync `navigate_list` from `nvim_win_get_cursor(list_win)` first so any unmapped motion (mouse, `<C-d>`) can't desync it either. See `lua/poste-http/http/history.lua`, `tests/http/history_spec.lua`.

- 2026-08-30: read `docs/dev/agent-guardrails.md` before UI or test work —
  it distills this log into MUST rules (ui/ primitives only, format/ layer
  purity, require-shadowing/pcall traps, headless test recipes) with
  machine-checkable greps. Repeat-offense pitfalls get promoted there.

- 2026-08-30: ui/picker headless testing — the picker queues `vim.cmd("startinsert!")`
  on open; under headless `nvim_feedkeys` that deferred mode switch races with
  multi-key blobs (`feedkeys("jj<CR>", "mx")` ran one normal-mapped `j`, then the
  queued startinsert swallowed the second). Rules: feed one key per feedkeys call
  with a wait between; headless never actually enters insert mode, so drive the
  TextChangedI search path by editing the search line + `doautocmd TextChangedI`.
  Also: `PlenaryBustedFile` does NOT pass `minimal_init`, so specs needing
  `package.path` extras (`helpers.*`) only run under `PlenaryBustedDirectory`
  (i.e. `tests/run.sh`) — single-file runs fail with "module 'helpers.mock_nvim'
  not found" for unrelated-looking reasons.

- 2026-08-30: ui/ primitives — consolidated the hand-rolled UI boilerplate into
  `lua/poste-http/ui/`: `float.lua` (centered float with failure cleanup,
  q/Esc close keys, `WinClosed`→`on_close`; callers with their own keymaps pass
  `close_keys = {}`), `render.lua` (`set_lines` = modifiable toggle + set-lines
  + optional filetype), `text.lua` (display-width `truncate`/`middle`), 
  `semantics.lua` (`method_hl`/`status_hl` single mapping source),
  `winbar.lua` (`render_tabs`/`cycle`). Pitfalls hit during the extraction:
  (1) outline.lua has a local function named `render` — alias the module
  require (`ui_render`) or the local shadows it and `render.set_lines`
  explodes with "attempt to index upvalue"; (2) `float.open` returns
  `(buf, win)` — wrapping it in `pcall(function() return float.open(...) end)`
  truncates to the first value, so you close the buf id as a "window";
  (3) in `nvim_buf_get_keymap`, `<Esc>` is reported as lhs `"<Esc>"`, not
  `"\27"`; (4) `nvim_win_get_config().title` is a chunk table `{{text}}`, and
  `row`/`col` are numbers for `relative="editor"` floats. See
  `docs/dev/code-review-2026-08-30.md`, `tests/ui_*_spec.lua`.

- 2026-08-12: http/history-empty-list — `render_list` only wrote buffer lines in the non-empty branch; after deleting the last entry the list window kept showing stale rows (and a fresh window showed a blank float instead of "(no history)"). Fix: the "(no history)" line now goes through the same modifiable/set-lines path in `render_list`. See `lua/poste-http/http/history.lua`.
- 2026-08-13: http/dual-cache-consistency — `get_semantic_blocks` (tree-sitter via `describe.lua`) and `get_buffer_cache` (plain-text scan) both cached `blocks` independently, keyed by `changedtick`. When tree-sitter was unavailable, `get_semantic_blocks` cached `[]` while `get_buffer_cache` held populated blocks — divergent state. `boundary_indicator.find_block` then fell through to the text-scan path every call, and any caller reading `get_semantic_blocks` got empty data while others saw real blocks. Fix: when `describe.describe_content` returns `[]`, `get_semantic_blocks` falls back to `get_buffer_cache().blocks` re-keyed via `normalize_to_semantic` (`start_line` → `line`) so `describe.block_at_line` works. Both caches now always agree. See `lua/poste-http/http/cache.lua:528-590`, `tests/http/cache_spec.lua` (4 new regression tests).
- 2026-08-12: tests/run.sh — `PlenaryBustedDirectory` was undefined ("Not an editor command"): adding plenary to rtp via `-c "set rtp+=..."` happens after startup, so `plugin/plenary.vim` is never auto-sourced. Fix: source it explicitly (`-c "runtime plugin/plenary.vim"`) before the busted command. See `tests/run.sh`.
- 2026-08-12: http/history-timestamp — `vim.uv.gettimeofday()` (nvim 0.12) returns a `sec, usec` VALUE PAIR, not a table; capturing `local t = vim.uv.gettimeofday()` silently grabs only the seconds number ("attempt to index a number"). History timestamps now render `HH:MM:SS.mmm` from `{time, time_usec}` stored at `add_entry`; list window widened 46 → 53 so the 12-char timestamp doesn't squeeze the flex name column. See `lua/poste-http/http/history.lua`.

- 2026-08-12: ui/columns — new reusable column layout component (`lua/poste-http/ui/columns.lua`, `render(rows, cols, opts)`). Column spec: align (left/right), width (fixed), max (natural capped), flex (stretch, needs opts.width), lead (per-column gap), ellipsis (default true). Returns lines + per-cell byte `col`/`end_col` for extmarks. Width/truncation math is display-width based (`strdisplaywidth`/`strcharpart`), so CJK cells align and are never split mid-character. history.lua list rendering now uses it: `format_list_line(entry, width)` where width is the total list width. See `lua/poste-http/ui/columns.lua`, `tests/ui_columns_spec.lua`.

- 2026-08-07: http/orchestration — SCRIPT blocks (`> {% %}` body) now run as
  orchestration scripts via a coroutine scheduler (`orchestration.run_script`):
  `client.run(target, args)` resolves `#Name`/`#alias.Name` through
  `import.execute_request_reference` and yields until the curl callback resumes
  it, so scripts read sequentially. Pitfalls: (1) the `calls` chain stores raw
  curl responses for the multi-response view, while the script receives the
  typed wrapper — don't mix them; (2) synthesized assertion results for script
  errors must include `tests = {}` and `logs = {}` or
  `assertions.format_assertions` crashes. See `lua/poste-http/http/orchestration.lua`,
  `lua/poste-http/http/run.lua` (handle_orchestration_result).
- 2026-08-07: http/script-grammar — Bare `SCRIPT` request lines (no URL) were
  invalid in the tree-sitter grammar (`request_line` required `method WS url`),
  so describe produced a block with empty `method`/`request_line` and the
  SCRIPT orchestration path silently fell through to the normal request path
  ("Could not determine request URL"). Fix: `request_line` is now a choice that
  also accepts bare `method_script` + NL (reuses the `request_line` node, so
  describe/queries unchanged); added corpus test "Script request line (no URL)".
  See `tree-sitter-poste-http/grammar.js`.
- 2026-08-07: http/orchestration-render — `render_orchestration_result` called
  `state.set_script_logs(logs)` then `state.set_assertion_results(results)` with
  the same `logs` table; `set_assertion_results` appends its `logs` into
  `last_script_logs`, so it inserted into the table it was iterating → LuaJIT
  "table overflow" in the scheduled callback → `state._busy` stayed true forever.
  Fix: set assertion results BEFORE script logs; split the renderer out of the
  `vim.schedule` wrapper and unit-test it directly. See `lua/poste-http/http/run.lua`.
- 2026-08-07: http/import-response-meta — Responses from
  `execute_import_via_curl` (import/run directives AND orchestration client.run
  calls) never carried request metadata, so the verbose view showed empty
  request name/headers/body: `prepare_multi_responses` renders each response
  standalone (no `pending_request` fallback), and only `handle_curl_response`
  enriched `metadata` from `state.pending_request`. Fix: attach resolved
  method/headers/body/timestamp/env + `request_name` onto the response in
  `execute_import_via_curl` before the callback. See `lua/poste-http/http/import.lua`.

- 2026-08-04: http/dep-post-scripts — Auto-executed dependencies ran through `curl_exec` directly, so their post-scripts (`> {% client.global.set(...) %}`) never ran; a target that referenced `{{recolor.response...}}` stayed literal for globals the dep was supposed to set until the user manually re-ran the dep. Fix: `request_deps.execute_dependent_request_async` now calls `run_dep_post_scripts` (extract + `assertions.run_assertions`) after caching the dep response. See `lua/poste-http/http/request_deps.lua`.
- 2026-08-04: http/busy-wedge — `prepare_request` early-returned on `find_request_line == nil` (cursor on a separator/blank/file-head line) WITHOUT resetting `state._busy`, permanently wedging the plugin: every later `run_request` silently no-oped ("Request already in progress"), looking like "only one request takes effect" + stale buffers. Same leak in `start_curl_exec` when URL resolves empty. Fix: reset `_busy = false` in both early-returns. See `lua/poste-http/http/run.lua`.
- 2026-08-04: http/file-level-@var-refs — File-level `@var = {{req.response...}}` (before first `###`) never resolved: `execute_deps_for_block` only scanned block text, so the refs never triggered dep execution or inline substitution, and the Lua `VarResolver` can't resolve `{{req.response...}}`. Fix: `execute_deps_for_block` now also scans the file-level region (lines before first `###`), merges those refs into the dep set, and substitutes them inline in the file-level lines — so deps referenced only by file-level vars execute and the @var value resolves via the normal resolver. See `lua/poste-http/http/request_deps.lua`.

- 2026-07-20: tests — headless Neovim test runs try to write loader cache, ShaDa, and LSP logs under `~/.cache` / `~/.local/state`, which trips sandbox EPERM. Fix: set `XDG_CACHE_HOME` and `XDG_STATE_HOME` to `/private/tmp` for focused `nvim --headless` validation commands. See `tests/run.sh:1`.
- 2026-07-08: infra — Added `tools/relation-check.sh` for pre-flight code relation scanning. Run before modifying HTTP Lua code. Covers: `nvim_buf_set_lines` + `sanitize_lines` coverage, state field lifecycle (SET/READ/CLEAR), format function callers, pre-render consistency, session lifecycle. See `tools/relation-check.sh`.
- 2026-07-21: protocol-split Phase 1 — Decoupled 8 cross-coupling points. Key moves: `extract_request_block`/`find_request_line`/`find_request_block_bounds` moved from `indicators.lua` to `http/cache.lua`; HTTP state fully isolated from SQL modules; SQL delegation removed from `http/run.lua` and `buffer_setup.lua`; `.sql`/`.sqlite` removed from `ftdetect/`. SQL modules now only load when user opens a `.sql` file.
- 2026-07-21: protocol-split — This plugin is now standalone `poste-http.nvim`; no runtime dependency on `poste.nvim`, `poste-sql.nvim`, or `poste-core.nvim`.

- 2026-07-05: HTTP Verbose tab shows `{{base_url}}/users/42` instead of resolved URL. Fix: `build_pending_request` in `run.lua:212` only resolved `@var` definitions but not `{{var}}` from env.json. Added env.json var resolution with iterative chaining. See `lua/poste-http/http/run.lua:212`.
- 2026-07-05: Picker forced to snacks.nvim. Removed auto-detection (telescope/fzf/mini/snacks chain). `select.lua` now requires snacks as hard dependency, with built-in float + vim.ui.select fallbacks. Normalizes items to `{key, name, description}` format. See `lua/poste-http/select.lua`.
- 2026-07-06: `run` directive bypassed pre/post script processing — raw content sent to Rust binary without Lua sandbox. Fix: `import.lua` now runs target block's pre-script before sending; injects both `request.variables.set()` AND `client.global.set()` vars as `@var` lines into the content sent to the Rust binary. Post-script runs after response to persist `client.global.set()` from target block. See `lua/poste-http/http/import.lua:374-424`.

- 2026-07-08: http/rqst-verbose-body-preamble — `r.metadata.request_body` contained full HTTP request (method + headers + body), not just body. Both Rqst tab and Verbose tab's "Request Body" section displayed the preamble. Fix: extracted `strip_request_preamble()` helper to strip method line + header lines before formatting; applied in both `format_verbose` and `format_request_payload`. See `lua/poste-http/http/format.lua:1132-1146`.
- 2026-07-08: http/pending-body-truncated — `strip_request_preamble` was called on pending body content that had no HTTP preamble, causing the first N body lines to be skipped. Fix: detect whether the body starts with an HTTP method line; skip stripping when it's already body-only. See `lua/poste-http/http/format.lua:931-939`.

## Format

```
- YYYY-MM-DD: <scope> — <one-line problem>. Fix: <one-line fix>. See <file>:<line>.
```

- 2026-09-22: curl-import/shell-escape — shell quoting and curl flag
  parsing are DIFFERENT layers, and only the shell layer is fixable by an
  escape function. Netcat probe (curl 8.7.1): `--data-binary -foo` sends
  `-foo` as the body — getopt consumes the next argv as the optarg even
  when it starts with `-`, short or long form, quoted or not. So
  "leading-dash value could parse as a flag" is only real in FREE
  positions (curl's trailing URL); the fix there is an explicit `--`
  separator, not quotes. See `lua/poste-http/http/curl_exec.lua`,
  `lua/poste-http/http/curl.lua` (combined `-sSo out.txt` blob walk),
  `docs/dev/review-2026-09-22.md`.

- 2026-07-07: http/dep-resolution — Rust parser (parser.rs:318-325) treats `<<var` as request line (not `@`, `#`, `>`). Before CLI execution, `<<var` MUST be converted to `@var = value` via Lua `handle_prompt_variables`. Fix: removed depth-1 limit and prompt skip from `resolve_request_variables` and `resolve_content_dependencies`; added recursive sub-dep resolution with depth tracking; added prompt handling for same-file deps via `handle_prompt_variables`; added `handle_import_prompts` with scratch buffer for imported file prompts. See `lua/poste-http/http/request_vars.lua:871-977,1027-1142` and `lua/poste-http/http/import.lua:347-383,530-619`.
- 2026-07-07: http/dep-execution — `execute_dependent_request_async` (line 298) used `dep_req.start_line` as `--line` but sent only the dep's block text via stdin. Rust parser's `parse_at_line` counts lines from stdin, finds `--line` > stdin line count, bails with "No request found". Dep silently fails, ref stays unresolved. Fix: use `--line 1` since stdin always has only the block (starting at `###`). This bug existed before the recursive change — old code also passed block text with wrong line. See `lua/poste-http/http/request_vars.lua:323`.
- 2026-07-07: http/dep-file-vars — `execute_dependent_request_async` sends only dep's block text via stdin, so Rust parser's `extract_file_variables` sees NO file-level `@var` lines (they're above `###` in the original file). `{{base_url}}` (from `@base_url = https://...`) stays unresolved → CLI builds request to `{{base_url}}/path` → HTTP fails with status 0 + empty body → `resolve_request_variable` returns nil at `if not body or body == "" then return nil end` → ref stays as `{{...}}`. Fix: `read_file_vars_from_path` helper reads `@var` lines (before first `###`) from the source file on disk; `execute_dependent_request_async` prepends them to stdin content and adjusts `--line` to point at the dep's `###` within the combined content. See `lua/poste-http/http/request_vars.lua:290-321`.

- 2026-07-08: http/multi-response-lag — `[`/`]` felt laggy even though Lua code ran <10ms. Root cause: missing `nowait = true` in keymap opts. If any global mapping uses `[` as prefix (e.g. `[c` from vim-unimpaired), Neovim waits up to `timeoutlen` before firing, creating perceived delay. Fix: add `nowait = true` to all response buffer keymaps. See `lua/poste-http/http/buffer.lua:257`.

- 2026-07-08: http/pre-render-extmarks — Pre-rendered buffers for multi-response only ran treesitter, skipping view-specific extmarks (`apply_verbose_highlights`, `apply_request_highlights`, file link highlight, JSON buffer setup). Body tab "works" because JSON treesitter handles it; other tabs lost all custom highlighting. Fix: apply all view-specific extmarks during `prepare_multi_responses`. See `lua/poste-http/http/buffer.lua:157-183`.

- 2026-07-23: tree-sitter — Implemented tree-sitter grammar for `.http` files under `tree-sitter-poste-http/`. Key learnings: (1) tree-sitter's regex engine (Oniguruma) does NOT support lookahead/lookbehind, so negative lookahead can't be used to exclude catch-all patterns. (2) A flat `choice()` + catch-all `body_text` regex causes the lexer to prefer the longest match (entire line) over multi-token sequences (e.g. `method` + `url`). (3) Solution: remove `body_text` from the grammar; unrecognized lines become `ERROR` nodes, which is acceptable for highlighting. (4) WASM (`tree-sitter build --wasm`) doesn't work with Neovim 0.12 — use C shared library instead: `gcc -shared -fPIC -O2 src/parser.c -o parser/poste_http.so`. (5) `extras: $ => [/\s/]` includes newlines, making blank lines invisible to the grammar. (6) `prec()` in `choice()` does NOT affect lexer token selection — use for reduce/shift only. (7) Queries go in `queries/poste_http/highlights.scm` (runtime path). (8) Neovim's treesitter highlighter looks for `@CaptureName.LanguageName` highlight groups (e.g. `@PosteVarDef.poste_http`), NOT bare `PosteVarDef`. Must define all three variants: `PosteXxx`, `@PosteXxx`, `@PosteXxx.poste_http`. (9) `[\s\S]*?` (lazy quantifier) inside `token()` doesn't work correctly — matches to the LAST `%}` instead of the FIRST. Use `repeat(choice(/[^%]+/, /%[^}]/))` instead. See `tree-sitter-poste-http/grammar.js`.

- 2026-07-08: http/stale-response-index — `state.response_index` persisted across requests. After running a multi-response chain, a subsequent single request triggered `view.show_view` fast path (because `response_index` was still set) and swapped to a stale pre-rendered buffer. Fix: reset `state.last_responses`/`state.response_index` + delete pre-rendered buffers before every new request, in both chain and non-chain branches. See `lua/poste-http/http/buffer.lua:105-116` and `lua/poste-http/http/run.lua:138-163`.

- 2026-07-08: http/embedded-newlines — `format.format_request_payload`, `format.format_verbose` and `format.format_body` may return line strings containing embedded `\n` (e.g. URL-decoded form values, multipart parts). `nvim_buf_set_lines` rejects these with "replacement string item contains newlines". Fix: `sanitize_lines()` splits any line containing `\n` into separate entries. Must sanitize BEFORE both `nvim_buf_set_lines` AND highlight functions that use `#line` as `end_col` — using unsanitized lines for highlights causes "Invalid end_col: out of range". See `lua/poste-http/http/buffer.lua:454-468`.

## Entries

- 2026-09-12: http/dep-resolution — the `.res.` shorthand was normalized to `.response.` for ref DETECTION but substitution gsub'd the normalized `{{...}}` against the UN-normalized block text: the dependency executed while the literal ref stayed in the request (detection and substitution used different spellings of the same ref). Fix: refs carry the raw spelling for substitution plus a normalized form for lookup — normalize once per ref, never mutate the scanned copy of the text. See `lua/poste-http/http/request_deps.lua` (`make_ref`).

- 2026-09-12: http/ts_query — `.luacheckrc` sets `allow_defined = true`, which silences "setting global variable" warnings: `ok, parent = pcall(...)` silently wrote `_G.parent` and worked by accident. When a multi-assignment pcall reuses a local from a previous line, check whether the second name is actually declared. See `lua/poste-http/http/ts_query.lua` (`parent_of_type`).

- 2026-09-04: http/executors — async executor tests (grpcurl/websocat) need three stubs working together: stub `vim.fn.jobstart` to capture opts and return a fake id, invoke `captured_opts.on_stdout/on_exit` manually, then `vim.wait` to pump `vim.schedule` callbacks; also stub `vim.fn.chansend/chanclose/jobstop` — real `chansend` on a fake id throws. A uv-timer deadline fires only inside `vim.wait`, so a spec that never pumps hangs silently. Session-style modules with a singleton (`ws_session.active`) leak state across tests — close the session in `after_each`. See `tests/http/executors_grpc_spec.lua`, `tests/http/ws_session_spec.lua`.

- 2026-06-26: agent — `lua local function f()` defined after its first caller causes "nil value" at runtime. Lua requires local functions to be declared before use, or forward-declared via `local f`. Fix: always order helper functions top-down, or add `local f` forward decl at module top. See `lua/poste-http/http/request_vars.lua:155-160`.
- 2026-06-26: keymaps — renamed `source_buffer` → `http_source` for consistency. Breaking change for users with custom configs using old names. See `lua/poste-http/state.lua:25-133`.
- 2026-06-30: openapi/http — `string.gsub` returns 2 values (modified + count). Using it directly inside `table.insert()` spills the count as 3rd arg, causing "number expected, got string". Fix: wrap gsub in extra parens to discard count. See `lua/poste-http/http/format.lua:469`.
- 2026-06-30: openapi/http — `string.gsub` returns 2 values (modified + count). Using it directly inside `table.insert()` spills the count as 3rd arg, causing "number expected, got string". Fix: wrap gsub in extra parens to discard count. See `lua/poste-http/http/format.lua:469`.
- 2026-06-24: http — pre-script/global var injection adds lines to buf_content but `--line` not adjusted, causing wrong block selection in Rust parser. Fix: add `line = line + injected_count` after each injection. See `lua/poste-http/http/run.lua:133,154`.
- 2026-06-24: http — jq filter state (`_json.query`, `original_lines`, `is_filtered`) persists across requests, showing stale filter in winbar. Fix: clear `state._json` before setting `state.last_response`. See `lua/poste-http/http/run.lua:199-201`.
- 2026-06-24: docs — `docs/dev/http/impl-guide.md` was a specific Phase 0-4 feature plan, not a general TDD guide. Fix: archive it, create `docs/dev/http/tdd-guide.md` as general TDD reference. See `docs/dev/http/tdd-guide.md`.
- 2026-06-27: indicators — sign group name collision: `"poste_indicator"` conflicts with other plugins' cleanup. Signs confirmed by `sign_getplaced` at t+0, removed by t+50ms. Fix: use unique group name (`"poste_sg_4a7f"`). See `lua/poste-http/indicators.lua:6`.
- 2026-06-27: indicators — spinner race: `update_spinner` callback `vim.schedule_wrap`'d before `set_indicator("success")` could still redefine spinner sign after success sign placed, if `spinner_gen` not incremented inside `stop_timer()`. Fix: `spinner_gen = spinner_gen + 1` in `stop_timer()`. See `lua/poste-http/indicators.lua:197-203`.
- 2026-06-27: indicators — stale sign accumulation: executing a new request left previous requests' ✓/✘ signs visible. Fix: `clear_other_requests(buf, line_0)` removes all signs except the current line before starting spinner. See `lua/poste-http/indicators.lua:219-230`.
- 2026-06-29: indicators — spinner animation in sign column still broken after initial unplace+re-place fix. Root cause: `spinner_gen` was incremented TWICE per `set_indicator` call — once at function entry (line 263) and once inside `stop_timer()` (line 198). The closure's `my_gen` captured the value AFTER the first increment but BEFORE the second, so `my_gen ~= spinner_gen` was always true inside `update_spinner`, silently dropping every timer callback. Fix: call `stop_timer()` BEFORE setting `my_gen`, not after. See `lua/poste-http/indicators.lua:264-268`.
- 2026-07-01: http/executor — URL extracted from HTTP request line includes ` HTTP/1.1` suffix (`request_line.trim_start()` keeps trailing tokens). curl gets `https://host/path HTTP/1.1` (embedded space), fails silently on some platforms/curl versions. Fix: strip whitespace-delimited suffix via `split_whitespace().next()`. See `crates/poste-exec/src/executor.rs:41`.
- 2026-07-01: http/format — `parse_multipart_parts` boundary detection fails when `< path` file inclusion brings in `\r\n` line endings. `\n + delim` search misses boundaries after CRLF content. Fix: normalize `body:gsub("\r\n", "\n")` before parsing, simplify header split. See `lua/poste-http/http/format.lua:415`.
- 2026-07-02: http/post-script — `inject_global_vars` adds lines at `block_start` but `block_end` not updated, causing `extract_assertion_blocks` to use stale end bound. Post-script silently skipped when `state.global_vars` non-empty from prior request. Fix: capture `global_count` return from `inject_global_vars` and add to `block_end`. See `lua/poste-http/http/run.lua:363-366`.
- 2026-07-02: http/block-index — block head line classification priority must be applied carefully: pre-script (`< {%`) must be checked before header (`Key:`), otherwise `< {% code %}` would match header pattern on the `%}` line. `run` must be checked before body fallback. Single-line pre/post scripts (`< {% code %}`) must match before multi-line start (`< {%`). See `lua/poste-http/http/cache.lua:80-191`.
- 2026-07-02: http/block-index — inter-block separator lines (after last content line of a block, before next `###`) must NOT be associated with any block. `find_request_block_bounds` returns nil for cursor on these lines. Fix: track `last_content_line` per block during scan, set `block.end_line = last_content_line`, exclude trailing empties/comments from block range. See `lua/poste-http/http/cache.lua:150-165`.
- 2026-07-02: http/block-index — `detect_script_context` via line_type fails on buffers without `###` blocks because file-level area only classifies lines as `var` or `file`. Completion tests call `detect_script_context` on bare buffers (no `###`). Fix: add pre/post-script detection to file-level area in cache scanner. See `lua/poste-http/http/cache.lua:101-128`.
- 2026-07-02: http/build_pending_request — `build_pending_request` used `buf_content:find("\n###", ...)` to find block end, which picks up inter-block comments and wrong content after var injection. Fix: pass `block_end` through callback chain from `execute_request` → `start_curl_job` → `build_pending_request`; replace `\n###` scan with block_line extraction using numeric line bounds. See `lua/poste-http/http/run.lua:166-242`.
- 2026-07-04: http/file-include — `< file` expansion in `process_form_data` embeds raw file content into buffer content before Rust parser splits blocks on `###`. File content containing `###` at line start creates false block boundaries, truncating the request body. Fix: move `< file` expansion out of Lua `process_form_data` (now only does magic vars), into Rust `run.rs:resolve_file_includes` after `parse_at_line` so Rust parser never sees file content `###`. See `lua/poste-http/http/request_vars.lua:37-88` and `crates/poste-cli/src/run.rs:104-106`.
- 2026-07-04: http/image-preview — Kitty graphics protocol (`\033_Ga=T,f=100,m=0;BASE64\033\\`) doesn't work through Neovim's Lua `io.write()`. ESC (0x1b) bytes are stripped or mangled by Neovim's output pipeline (libvterm's stdout processing), causing raw base64 to appear as literal terminal text. `os.execute('printf ... > /dev/tty')` would bypass the pipeline, but it blocks the UI. `jobstart({stdout = 1})` inherit doesn't exist — Neovim always captures child stdout through a pipe. Fix: use system viewer (`open`/`xdg-open` via `jobstart`) which works everywhere. Kitty inline kept as best-effort commented attempt. See `lua/poste-http/http/format.lua:156-195`.
- 2026-07-04: http/image-preview — terminal preview buffers created with fake/test buffers can break if code writes `vim.bo[buf]` directly after `nvim_open_term()`. Fix: use `nvim_set_option_value(..., { buf = buf })` for preview buffer options so the path works with both real buffers and mocked test buffers. See `lua/poste-http/http/format.lua:208-240`.
- 2026-07-04: http/image-preview — `nvim_open_term()` is still an internal libvterm terminal, so kitty graphics output renders blank inside Neovim even in Kitty/WezTerm. Fix: render image previews as a small colored-cell buffer using ImageMagick sampling + extmark background highlights instead of trying to pass graphics escape codes through Neovim. See `lua/poste-http/http/format.lua:184-340`.
- 2026-07-04: http/image-preview — colored-cell fallback is not a usable image preview. Fix: remove the built-in preview path, prefer `image.nvim` when installed, and otherwise fall back to opening the file externally. See `lua/poste-http/http/format.lua:232-305` and `lua/poste-http/http/buffer.lua:267-275`.
- 2026-07-04: http/binary-upload — `< file.png` inline expanded via `String::from_utf8_lossy` corrupts binary data, and null bytes in `--data-binary <inline>` arg fail with "nul byte found in provided data" (OS rejects NUL in argv). Fix: `Request.body` changed from `String` to `Vec<u8>`, `resolve_file_includes` preserves raw bytes, executor writes body to tempfile and uses `--data-binary @path`. See `crates/poste-cli/src/run.rs:203-231`, `crates/poste-exec/src/executor.rs:117-122`.
- 2026-07-06: http/file-include-error — `resolve_file_includes` silently kept original `< path` line when file couldn't be read, causing literal path string to be uploaded as file content in multipart uploads. Fix: changed to `anyhow::bail!()` with clear error message instead of silent fallback. See `crates/poste-cli/src/run.rs:203-227`.
- 2026-07-04: http/image-preview — `image.nvim` can render against the existing response buffer/window; a separate preview popup is unnecessary. Fix: body view now auto-renders inline when `image.nvim` is installed, and `K` only falls back to external open when inline render is unavailable. See `lua/poste-http/http/format.lua:195-300` and `lua/poste-http/http/view.lua:94-151`.
- 2026-07-04: http/image-preview — `image.nvim` inline render follows the current cursor/anchor, so rendering at line 1 overlays metadata text. Fix: reserve real blank lines after the binary metadata block and move the cursor to the first blank line before calling `image.from_file(...):render()`. See `lua/poste-http/http/format.lua:155-236` and `lua/poste-http/http/view.lua:159-170`.
- 2026-07-05: http/image-preview — `snacks.nvim` image plugin can render inline via `Snacks.image.placement.new(buf, path, {inline=true})`, snacks supports SVG via imagemagick while image.nvim doesn't. Fix: try snacks first in `render_image_preview`, fall back to image.nvim. SVG exclusion moved to after snacks attempt. See `lua/poste-http/http/format.lua:166-195`, `lua/poste-http/http/view.lua:163-169`, `lua/poste-http/http/buffer.lua:316-319`.
- 2026-09-21: testing — a `grep -v "Failed : 0" | head -30` filter over run.sh output hid a real spec failure (the exit code said FAIL, the truncated greps said green). The failure was self-inflicted: a luacheck "unused variable" cleanup collapsed a 5-value destructure (`headers, qs, vars, _, prompts` → `headers, qs, _, prompts`), so `prompts` silently captured `has_body`. Multi-return destructures shift positionally — never rename a hole to `_` when `_` already exists; count the returns. And read run.sh's exit verdict before the greps, never after. See `tests/http/zero_coverage_smoke_spec.lua` (collect_parameters enum-header case).
