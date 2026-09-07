#!/bin/bash
# Development: regenerate parser.c from grammar.js and compile.
# Not needed by end users — parsers are compiled automatically by install.lua.
set -euo pipefail
cd "$(dirname "$0")/../tree-sitter-poste-graphql"

echo "Generating parser from grammar.js..."
tree-sitter generate

echo "Compiling..."
${CC:-cc} -c -Isrc -fPIC -O2 -o src/parser.o src/parser.c
${CC:-cc} -shared -o ../parser/poste_graphql.so src/parser.o
rm -f src/parser.o

echo "Done: tree-sitter-poste-graphql/src/parser.c (+ ../parser/poste_graphql.so)"
