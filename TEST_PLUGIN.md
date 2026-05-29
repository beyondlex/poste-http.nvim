# Testing the Poste Neovim Plugin

## Quick Test

1. Build the CLI:
```bash
cargo build
```

2. Open Neovim with the plugin:
```bash
cd /Users/lex/code/github/poste
nvim --cmd "set rtp+=." examples/api.http
```

3. Test the plugin:
   - Press `<leader>rr` to run a request
   - Press `]]` to jump to next request
   - Press `[[` to jump to previous request
   - Type `:PosteEnv prod` to switch environment
   - Type `:PosteEnv` to see current environment
   - Press `q` in response buffer to close it

## Test Cases

### 1. Basic Request Execution
- Open `examples/api.http`
- Move cursor to any request
- Press `<leader>rr`
- Verify response appears in vertical split
- Verify response is formatted (JSON should be pretty-printed)

### 2. Navigation
- Open `examples/api.http`
- Press `]]` multiple times to jump forward
- Press `[[` multiple times to jump backward
- Verify cursor moves to `###` lines

### 3. Environment Switching
- Type `:PosteEnv` to see current environment (should be "dev")
- Type `:PosteEnv staging` to switch
- Type `:PosteEnv` again to verify it changed
- Run a request and verify it uses the new environment

### 4. Response Buffer
- Run a request
- In the response buffer, try:
  - `gg` to go to top
  - `G` to go to bottom
  - `/` to search
  - `v` for visual mode
  - `y` to yank
  - `q` to close

## Expected Behavior

- Response should appear in a vertical split (80 columns wide)
- JSON responses should be pretty-printed
- Status code and latency should be visible
- All Vim operations should work in response buffer
- Pressing `q` should close the response window

## Troubleshooting

### "Poste binary not found"
- Make sure you've run `cargo build`
- The plugin looks for `./target/debug/poste` or `poste` in PATH

### Request doesn't execute
- Make sure cursor is on a request line (not on `###` separator)
- Check that `env.json` exists in the same directory or parent
- Verify the environment name is correct (`:PosteEnv`)

### Response doesn't appear
- Check `:messages` for errors
- Verify the poste binary is working: `./target/debug/poste run examples/api.http --line 2 --env dev`
