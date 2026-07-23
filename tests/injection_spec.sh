#!/usr/bin/env bash
# Injection test: verify JSON body injection works in Neovim
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

cat > "$TEST_DIR/test.http" << 'EOF'
### Create user
POST /users
Content-Type: application/json

{
  "name": "John",
  "email": "john@test.com"
}

### Next
GET /test
EOF

nvim --headless -u NONE +"set rtp+=$PROJECT_DIR" +"set rtp+=/opt/homebrew/share/nvim/runtime" \
  -c "lua << EOF
local bufnr = vim.api.nvim_create_buf(false, true)
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
-- Actually, just load the test file
vim.cmd('edit $TEST_DIR/test.http')
vim.bo[bufnr].filetype = 'poste_http'
vim.treesitter.start(bufnr, 'poste_http')

-- Wait for parser
vim.wait(500, function() return pcall(vim.treesitter.get_parser, bufnr) end)

-- Check injection query
local q = vim.treesitter.query.get('poste_http', 'injections')
local root = vim.treesitter.get_parser(bufnr):parse()[1]:root()

local found_json = false
for pattern, match, metadata in q:iter_matches(root, bufnr, 0, -1) do
  if metadata['injection.language'] == 'json' then
    for id, nodes in pairs(match) do
      if q.captures[id] == 'injection.content' then
        for _, node in ipairs(nodes) do
          if node:type() == 'request_body' then
            found_json = true
            print('INJECTION_OK: request_body -> json')
          end
        end
      end
    end
  end
end

if not found_json then
  print('INJECTION_FAIL: no request_body -> json injection found')
  vim.cmd('cq!')
end
vim.cmd('qall!')
EOF" 2>&1 | grep -E 'INJECTION_'

if grep -q 'INJECTION_OK' <<< "$(cat /dev/stdin 2>/dev/null)"; then
  echo "PASS: JSON injection works"
  exit 0
else
  echo "FAIL: JSON injection not working"
  exit 1
fi