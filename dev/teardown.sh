#!/usr/bin/env bash
set -euo pipefail

APPNAME="poste-dev"
DIRS=(
  "${XDG_CONFIG_HOME:-$HOME/.config}/$APPNAME"
  "${XDG_DATA_HOME:-$HOME/.local/share}/$APPNAME"
  "${XDG_CACHE_HOME:-$HOME/.cache}/$APPNAME"
  "${XDG_STATE_HOME:-$HOME/.local/state}/$APPNAME"
)

echo "==> Destroying Poste dev environment: $APPNAME"
for d in "${DIRS[@]}"; do
  if [ -d "$d" ]; then
    rm -rf "$d"
    echo "  Removed: $d"
  fi
done
echo "==> Done"
