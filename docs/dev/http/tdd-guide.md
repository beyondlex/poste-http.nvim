# HTTP TDD Guide

> General TDD workflow for HTTP features in Poste.
> Every HTTP change must start with a test.

## Principle

1. Write the test before the implementation.
2. Test fails → implement → test passes → refactor.
3. No coverage, no change.

## Test Locations

| Layer | Tool | Location |
|-------|------|----------|
| Rust parser unit | `#[cfg(test)] mod tests` | `crates/poste-core/src/parser.rs` |
| Rust executor unit | `#[cfg(test)] mod tests` | `crates/poste-exec/src/executor.rs` |
| Lua unit | busted (`tests/run.sh`) | `tests/http_*_spec.lua` |
| Lua integration | busted (`tests/run.sh`) | `tests/` |

## Workflow

### Rust (parser / executor)

```rust
#[test]
fn test_feature_name() {
    // Arrange: build input content / Request
    // Act: call parser / executor
    // Assert: verify Request.body / Response fields
}
```

Add the test to the existing `mod tests` block in the source file. Run:

```bash
cargo test -p poste-core   # parser changes
cargo test -p poste-exec   # executor changes
```

### Lua (UI / scripts / assertions)

```lua
describe("module_name", function()
  it("behaves correctly when ...", function()
    -- Arrange: set up state, mock buffer content
    -- Act: call the function
    -- Assert: verify output / state mutations
  end)
end)
```

Add to `tests/http_*_spec.lua` or create a new `tests/` file. Run:

```bash
tests/run.sh
```

## Testing Patterns

### Testing parser behavior

Feed content to `parse_at_line` or `parse_block` and assert on `Request` fields:

```rust
let parser = Parser::new(env_vars);
let request = parser.parse_at_line(content, line_num, "http")?;
assert!(request.body.contains("expected"));
assert!(!request.body.contains("should be stripped"));
```

### Testing Lua script execution

Mock `state` fields, call the function, check side effects:

```lua
it("injects variables after ### header", function()
  local result = scripts.inject_pre_script_vars(content, block_start, { token = "abc" })
  assert.is.truthy(result:match("@token = abc"))
end)
```

### Testing result rendering

Set `state.last_response` with a known shape, call format function, check output lines:

```lua
it("shows request body in Body tab", function()
  state.last_response = { metadata = { request_body = "hello" } }
  local lines = M.format_response(state.last_response, "body")
  assert.is.truthy(vim.tbl_contains(lines, "hello"))
end)
```

## Common Rules

- **Rust assertion tests** go in `parser.rs` inline, not in a separate test file
- **Lua tests** go in `tests/` directory, named `http_<feature>_spec.lua`
- **Do not add SQL tests** when changing HTTP code — CI separates the two
- **Test both success and error paths** — parser errors, curl failures, JSON decode failures
- **New `state` fields** need tests that verify they're set/cleared at the right time