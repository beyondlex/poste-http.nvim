# TODO: Poste HTTP Client Plugin

## ✅ Completed Features

### Core Functionality
- [x] HTTP request execution with variable resolution
- [x] Go to definition (gd) for variables and named requests
- [x] Go to references (grr) with preview
- [x] Jump between requests (`]]` and `[[`)
- [x] Environment variable support (env.json)
- [x] Pre/post request scripts
- [x] Assertions
- [x] Response caching

### Syntax Highlighting
- [x] HTTP methods (GET, POST, PUT, DELETE, etc.)
- [x] Header names and values
- [x] URLs
- [x] Variables (`{{var}}`)
- [x] Comments
- [x] Named requests (`### Name`)
- [x] Request body (JSON)

### nvim-cmp Completion
- [x] HTTP methods completion (G → GET, POST, etc.)
- [x] Header names completion (Con → Content-Type, Connection, etc.)
- [x] Header values completion (Content-Type: app → application/json, etc.)
- [x] Smart context detection (method/header name/header value areas)
- [x] Fuzzy matching with hyphenated words
- [x] LazyVim integration

## 🎯 High Priority

### Migration to blink.cmp
**Why:** LazyVim defaults to blink.cmp, which is faster and has better built-in fuzzy matching.

**Tasks:**
- [x] Research blink.cmp source API
- [x] Rewrite `lua/poste/completion.lua` for blink.cmp
- [x] Update `ftplugin/poste_http.vim` buffer configuration
- [x] Support both blink.cmp and nvim-cmp (backward compatible)
- [ ] Test with LazyVim's default setup (no `lazyvim.json` changes needed)
- [x] Document migration in README

**Benefits:**
- No need to enable nvim-cmp in `lazyvim.json`
- Better performance (Rust core)
- Smarter built-in fuzzy matching (may not need manual hyphen handling)
- Less configuration for users

### Completion Enhancements
- [ ] URL completion (common endpoints)
- [x] Variable name completion (`{{var_name}}`)
- [x] Request name completion in variable references
- [x] Environment variable completion from env.json
- [x] Magic variable completion (`{{$timestamp}}`, `{{$uuid}}`, etc.)
- [x] Pre/post script keyword completion
- [x] Assertion keyword completion

### Performance
- [x] Profile completion startup time
- [x] Lazy load completion data (only load when needed)
- [x] Cache parsed env.json data
- [x] Optimize `detect_context()` function

## 🔧 Medium Priority

### Developer Experience
- [x] Add more HTTP headers to completion list
- [x] Add more MIME types to completion list
- [x] Support for common authentication schemes (Bearer, Basic, Digest, OAuth)
- [x] Cookie completion
- [x] HTTP status code completion in assertions

### Documentation
- [ ] Update README with completion examples
- [ ] Add GIF/screenshot demos
- [ ] Document configuration options
- [ ] Add troubleshooting guide
- [ ] Create user guide for common workflows

### Testing
- [x] Unit tests for `detect_context()`
- [x] Unit tests for `make_items()`
- [x] Integration tests with nvim-cmp
- [x] Integration tests with blink.cmp (after migration)
- [ ] Test with different LazyVim configurations

## 📝 Low Priority

### Advanced Features
- [ ] Auto-complete request variables based on previous responses
- [ ] Suggest variables based on request context
- [ ] Smart header value suggestions (e.g., suggest common User-Agent strings)
- [ ] History-based completion (frequently used values first)
- [ ] Fuzzy matching for variable names (partial match)

### Integrations
- [ ] Telescope integration for variable picker
- [ ] fzf-lua integration
- [ ] LSP-like hover for variables (show current value)
- [ ] Inline variable value preview
- [ ] Request dependency graph visualization

### Code Quality
- [ ] Refactor `completion.lua` into smaller modules
- [ ] Add type annotations
- [ ] Improve error messages
- [ ] Add logging for debugging
- [ ] Code review and cleanup

## 🐛 Known Issues

### nvim-cmp
- ~~[x] Hyphenated words not matching correctly (Con → Content-Type)~~ **FIXED**
- ~~[x] Context detection issues~~ **FIXED**
- [ ] May conflict with other completion sources
- ~~[ ] Requires manual `lazyvim.json` configuration~~ **RESOLVED** (blink.cmp support added)

### General
- [ ] No completion for `@variable` definitions
- [ ] No completion inside request bodies (only headers)
- [ ] No completion for file paths in `< ./script.lua`
- [ ] Environment switching doesn't update completion cache

## 📚 Resources

### blink.cmp
- Repository: https://github.com/saghen/blink.cmp
- LazyVim docs: https://www.lazyvim.org/extras/coding/blink
- Source API docs: (need to research)

### nvim-cmp
- Repository: https://github.com/hrsh7th/nvim-cmp
- Source API: https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/types/source.lua

### HTTP References
- HTTP Headers: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers
- MIME Types: https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/MIME_types
- HTTP Methods: https://developer.mozilla.org/en-US/docs/Web/HTTP/Methods

## 🚀 Release Checklist

Before v1.0:
- [x] Migrate to blink.cmp
- [ ] Complete all high priority items
- [ ] Add comprehensive tests
- [ ] Update documentation
- [ ] Performance benchmarks
- [ ] User feedback collection
- [ ] Final code review

---

**Last Updated:** 2026-06-03
**Current Version:** Dual completion engine (blink.cmp + nvim-cmp)
**Next Goal:** Completion enhancements (URL, variables, env vars)
