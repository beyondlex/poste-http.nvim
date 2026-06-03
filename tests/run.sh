#!/bin/bash
# Run tests with plenary
# Usage: ./tests/run.sh

set -e

cd "$(dirname "$0")/.."

# Check if plenary is available
PLENARY_PATH="$HOME/.local/share/nvim/lazy/plenary.nvim"
if [ ! -d "$PLENARY_PATH" ]; then
    echo "Error: plenary.nvim not found at $PLENARY_PATH"
    exit 1
fi

echo "Running tests..."

nvim --headless \
  -c "set rtp+=$PLENARY_PATH" \
  -c "set rtp+=." \
  -c "runtime plugin/poste.lua" \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}" \
  -c "qa"
