#!/usr/bin/env bash
# Injection test: verify body injections work in Neovim
# (json_body -> poste_json, graphql_body -> poste_graphql)
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

### GraphQL: query with variables
GRAPHQL {{graphql_url}}

query User($id: ID!) {
  user(id: $id) { id name email }
}

{
  "id": "1"
}

### Next
GET /test
EOF

cat > "$TEST_DIR/inject.lua" << EOF
vim.cmd('edit $TEST_DIR/test.http')
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = 'poste_http'
vim.treesitter.start(bufnr, 'poste_http')

-- Wait for parser
vim.wait(500, function() return pcall(vim.treesitter.get_parser, bufnr) end)

-- Check injection query
local q = vim.treesitter.query.get('poste_http', 'injections')
local root = vim.treesitter.get_parser(bufnr):parse()[1]:root()

local found_json = false
local found_graphql = false
for pattern, match, metadata in q:iter_matches(root, bufnr, 0, -1) do
  local lang = metadata['injection.language']
  local wanted = nil
  if lang == 'poste_json' then wanted = 'json_body' end
  if lang == 'poste_graphql' then wanted = 'graphql_body' end
  if wanted then
    for id, nodes in pairs(match) do
      if q.captures[id] == 'injection.content' then
        for _, node in ipairs(nodes) do
          if node:type() == wanted then
            if wanted == 'json_body' then
              found_json = true
              print('INJECTION_OK: json_body -> poste_json')
            else
              found_graphql = true
              print('INJECTION_OK: graphql_body -> poste_graphql')
            end
          end
        end
      end
    end
  end
end

if not found_json then
  print('INJECTION_FAIL: no json_body -> poste_json injection found')
end
if not found_graphql then
  print('INJECTION_FAIL: no graphql_body -> poste_graphql injection found')
end
vim.cmd('qall!')
EOF

nvim --headless -u NONE +"set rtp+=$PROJECT_DIR" -c "luafile $TEST_DIR/inject.lua" 2>&1 | grep -E 'INJECTION_' > "$TEST_DIR/out.txt" || true

if grep -q 'INJECTION_OK: json_body' "$TEST_DIR/out.txt" && grep -q 'INJECTION_OK: graphql_body' "$TEST_DIR/out.txt"; then
  echo "PASS: body injections work (poste_json + poste_graphql)"
  exit 0
else
  echo "FAIL: body injection not working"
  cat "$TEST_DIR/out.txt"
  exit 1
fi
