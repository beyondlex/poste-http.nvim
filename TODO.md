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
- [ ] Research blink.cmp source API
- [ ] Rewrite `lua/poste/completion.lua` for blink.cmp
- [ ] Update `ftplugin/poste_http.vim` buffer configuration
- [ ] Remove nvim-cmp dependency from user configuration
- [ ] Test with LazyVim's default setup (no `lazyvim.json` changes needed)
- [ ] Document migration in README

**Benefits:**
- No need to enable nvim-cmp in `lazyvim.json`
- Better performance (Rust core)
- Smarter built-in fuzzy matching (may not need manual hyphen handling)
- Less configuration for users

### Completion Enhancements
- [ ] URL completion (common endpoints)
- [ ] Variable name completion (`{{var_name}}`)
- [ ] Request name completion in variable references
- [ ] Environment variable completion from env.json
- [ ] Magic variable completion (`{{$timestamp}}`, `{{$uuid}}`, etc.)
- [ ] Pre/post script keyword completion
- [ ] Assertion keyword completion

### Performance
- [ ] Profile completion startup time
- [ ] Lazy load completion data (only load when needed)
- [ ] Cache parsed env.json data
- [ ] Optimize `detect_context()` function

## 🔧 Medium Priority

### Developer Experience
- [ ] Add more HTTP headers to completion list
- [ ] Add more MIME types to completion list
- [ ] Support for common authentication schemes (Bearer, Basic, Digest, OAuth)
- [ ] Cookie completion
- [ ] HTTP status code completion in assertions

### Documentation
- [ ] Update README with completion examples
- [ ] Add GIF/screenshot demos
- [ ] Document configuration options
- [ ] Add troubleshooting guide
- [ ] Create user guide for common workflows

### Testing
- [ ] Unit tests for `detect_context()`
- [ ] Unit tests for `make_items()`
- [ ] Integration tests with nvim-cmp
- [ ] Integration tests with blink.cmp (after migration)
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
- [ ] Requires manual `lazyvim.json` configuration

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
- [ ] Migrate to blink.cmp
- [ ] Complete all high priority items
- [ ] Add comprehensive tests
- [ ] Update documentation
- [ ] Performance benchmarks
- [ ] User feedback collection
- [ ] Final code review

---

**Last Updated:** 2026-01-02
**Current Version:** Working on nvim-cmp completion
**Next Goal:** Migrate to blink.cmp
