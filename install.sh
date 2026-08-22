#!/bin/bash
# One-step setup after cloning this plugin: enable it, add the menu rows, and
# restart the shell. Safe to re-run — every step is idempotent.

set -euo pipefail

PLUGIN_ID="io.github.sumdahl.livewallpaper"
BIN_DIR="$HOME/.local/bin"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -Dm755 "$HERE/bin/omarchy-live" "$BIN_DIR/omarchy-live" 2>/dev/null ||
  echo "note: bin/omarchy-live not bundled; assuming omarchy-live is already on PATH"

omarchy-plugin-enable "$PLUGIN_ID" 2>/dev/null || true

if command -v omarchy-live >/dev/null; then
  omarchy-live menu-install || true
fi

echo
echo "Done. Restart the shell to load it:"
echo "  omarchy restart shell"
