#!/usr/bin/env bash
# Create a compressed drag-and-drop DMG from a previously built Sidecar Auto Setup.app.
# Signing and notarization are deliberately separate release steps.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${SIDECAR_AUTO_APP_PATH:-$ROOT/dist/Sidecar Auto Setup.app}"
OUTPUT_DIR="${SIDECAR_AUTO_APP_OUT_DIR:-$ROOT/dist}"
VERSION="${SIDECAR_AUTO_VERSION:-1.0.1}"

usage() {
    cat <<USAGE
usage: $0 [--app PATH] [--output PATH] [--version VERSION]

Create Sidecar-Auto-Setup.dmg with the app and an Applications shortcut.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; APP_PATH="$2"; shift 2 ;;
        --output) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; OUTPUT_DIR="$2"; shift 2 ;;
        --version) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; VERSION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 64 ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || { printf 'DMG creation requires macOS\n' >&2; exit 1; }
[ -d "$APP_PATH" ] || { printf 'app not found: %s\n' "$APP_PATH" >&2; exit 1; }
command -v hdiutil >/dev/null 2>&1 || { printf 'hdiutil not found\n' >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/Sidecar-Auto-Setup.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-auto-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP_PATH" "$STAGE/Sidecar Auto Setup.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "Sidecar Auto Setup" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG_PATH" >/dev/null

printf 'created %s (version %s)\n' "$DMG_PATH" "$VERSION"
