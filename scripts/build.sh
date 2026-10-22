#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT" --configuration release
BIN="$(swift build --package-path "$ROOT" --configuration release --show-bin-path)"
APP="$ROOT/dist/resh.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BIN/resh" "$APP/Contents/MacOS/resh"
install -m 644 "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
install -m 644 "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
install -m 644 "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
install -m 644 "$ROOT/integration/resh.lua" "$APP/Contents/Resources/resh.lua"
ditto "$BIN/resh_Resh.bundle" "$APP/Contents/Resources/resh_Resh.bundle"
codesign --force --sign - --identifier io.github.CruelAddict.resh "$APP"
printf '%s\n' "$APP"
