#!/usr/bin/env bash
# Copies the built app into /Applications and launches it.
# Run ./Scripts/build-app.sh first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/dist/QuotaWidget.app"
TARGET="/Applications/QuotaWidget.app"

if [[ ! -d "$SOURCE" ]]; then
  echo "No build found at $SOURCE — run ./Scripts/build-app.sh first" >&2
  exit 1
fi

echo "==> Quitting a running copy"
pkill -f "$TARGET/Contents/MacOS/QuotaWidget" 2>/dev/null || true
sleep 1

echo "==> Installing to $TARGET"
rm -rf "$TARGET"
cp -R "$SOURCE" "$TARGET"

echo "==> Launching"
open "$TARGET"
echo "Installed. Look for the gauge icon in your menu bar."
