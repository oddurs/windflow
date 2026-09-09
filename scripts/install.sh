#!/usr/bin/env bash
# Installs the built screensaver for the current user.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/build/Windflow.saver"
DEST="$HOME/Library/Screen Savers/Windflow.saver"

[ -d "$SRC" ] || { echo "build first: scripts/build.sh" >&2; exit 1; }

mkdir -p "$HOME/Library/Screen Savers"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

# System Settings caches the module list aggressively; restarting the host
# process is the difference between seeing your change and not.
killall legacyScreenSaver 2>/dev/null || true
killall ScreenSaverEngine 2>/dev/null || true

echo "installed: $DEST"
echo "open System Settings -> Screen Saver -> Other -> Windflow"
