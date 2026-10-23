#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT" --configuration release \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
  -Xlinker "$ROOT/Packaging/Info.plist"
BIN="$(swift build --package-path "$ROOT" --configuration release --show-bin-path)"
DIST="$ROOT/dist/resh"
rm -rf "$DIST"
mkdir -p "$DIST"
install -m 755 "$BIN/resh" "$DIST/resh"
install -m 644 "$ROOT/LICENSE" "$DIST/LICENSE"
install -m 644 "$ROOT/THIRD_PARTY_NOTICES.md" "$DIST/THIRD_PARTY_NOTICES.md"
install -m 644 "$ROOT/integration/resh.lua" "$DIST/resh.lua"
install -m 644 "$ROOT/integration/rex-actions.lua" "$DIST/rex-actions.lua"
install -m 755 "$ROOT/install.sh" "$DIST/install.sh"
ditto "$BIN/resh_Resh.bundle" "$DIST/resh_Resh.bundle"
codesign --force --sign - --identifier io.github.CruelAddict.resh "$DIST/resh"
printf '%s\n' "$DIST"
