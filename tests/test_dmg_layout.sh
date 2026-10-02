#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:?usage: test_dmg_layout.sh APP_PATH}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-auto-dmg-test.XXXXXX")"
MOUNTPOINT=""

cleanup() {
    if [ -n "$MOUNTPOINT" ]; then
        hdiutil detach "$MOUNTPOINT" >/dev/null 2>&1 || true
    fi
    rm -rf "$OUT"
}
trap cleanup EXIT

[ -d "$APP_PATH" ] || {
    printf 'app not found: %s\n' "$APP_PATH" >&2
    exit 1
}

"$ROOT/packaging/make-dmg.sh" --app "$APP_PATH" --output "$OUT" --version 1.0.1
hdiutil verify "$OUT/Sidecar-Auto-Setup.dmg" >/dev/null
hdiutil attach -readonly -nobrowse -plist "$OUT/Sidecar-Auto-Setup.dmg" > "$OUT/attach.plist"
MOUNTPOINT="$(python3 - "$OUT/attach.plist" <<'PY'
import plistlib
import sys

for entity in plistlib.load(open(sys.argv[1], "rb")).get("system-entities", []):
    if entity.get("mount-point"):
        print(entity["mount-point"])
        break
else:
    raise SystemExit("DMG did not expose a mount point")
PY
)"

[ -d "$MOUNTPOINT/Sidecar Auto Setup.app" ] || {
    printf 'DMG is missing Sidecar Auto Setup.app\n' >&2
    exit 1
}
[ -L "$MOUNTPOINT/Applications" ] || {
    printf 'DMG is missing the Applications shortcut\n' >&2
    exit 1
}
[ "$(readlink "$MOUNTPOINT/Applications")" = "/Applications" ] || {
    printf 'Applications shortcut points to the wrong target\n' >&2
    exit 1
}

printf 'DMG layout test passed\n'
