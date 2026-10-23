#!/bin/sh
# Package already-built files; this script never publishes or creates a Git tag.
set -eu
COPYFILE_DISABLE=1
export COPYFILE_DISABLE
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$root/dist/releases"
mkdir -p "$out"
stage=$(mktemp -d "${TMPDIR:-/tmp}/resh-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$root/integration/rex-actions.lua" "$stage/rex-actions.lua"
cp "$root/install.sh" "$stage/install.sh"
cp "$root/LICENSE" "$stage/LICENSE"
tar -czf "$out/resh-remote.tar.gz" -C "$stage" .
if [ -f "$root/dist/resh/resh" ]; then
    case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64) arch=x86_64 ;; *) echo 'Unsupported architecture.' >&2; exit 1 ;; esac
    tar -czf "$out/resh-macos-$arch.tar.gz" -C "$root/dist/resh" .
fi
# Recompute the manifest for all architectures present in this release directory.
for archive in "$out"/*.tar.gz; do
    if command -v sha256sum >/dev/null 2>&1; then digest=$(sha256sum "$archive" | awk '{print $1}')
    else digest=$(shasum -a 256 "$archive" | awk '{print $1}'); fi
    printf '%s  %s\n' "$digest" "$(basename "$archive")"
done > "$out/checksums.txt"
printf '%s\n' "$out"
