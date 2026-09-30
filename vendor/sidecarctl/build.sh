#!/usr/bin/env bash
# Build the private-API sidecarctl CLI without installing or launching it.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
# The normal developer path follows the host architecture.  Release builds
# can set TARGET_ARCH explicitly (for example, arm64 or x86_64) so the app
# packager can build each helper before combining them with lipo.
TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"
TARGET_OS_VERSION="${TARGET_OS_VERSION:-13.0}"
TARGET="${TARGET_ARCH}-apple-macosx${TARGET_OS_VERSION}"
BUILD_ONLY=0
CLI_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=1 ;;
        --cli-only) CLI_ONLY=1 ;;
        *) printf 'unknown option: %s\n' "$arg" >&2; exit 64 ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || { echo 'this project builds on macOS only' >&2; exit 1; }
command -v swiftc >/dev/null 2>&1 || { echo 'swiftc not found; run xcode-select --install' >&2; exit 1; }

case "$TARGET_ARCH" in
    arm64|x86_64) ;;
    *) printf 'unsupported TARGET_ARCH: %s\n' "$TARGET_ARCH" >&2; exit 64 ;;
esac

if [ -z "${SDKROOT:-}" ] && command -v xcrun >/dev/null 2>&1; then
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    [ -z "$SDKROOT" ] || export SDKROOT
fi

mkdir -p "$BUILD_DIR"
swiftc -O -target "$TARGET" \
    "$HERE"/Sources/Shared/*.swift \
    "$HERE/Sources/CLI/main.swift" \
    -o "$BUILD_DIR/sidecarctl"

if [ "$BUILD_ONLY" -eq 1 ] || [ "${CI:-}" = "true" ]; then
    printf 'built (not installed): %s\n' "$BUILD_DIR/sidecarctl"
    exit 0
fi

if [ "$CLI_ONLY" -eq 1 ]; then
    DEST="${CLI_DEST:-$HOME/.local/bin}"
    mkdir -p "$DEST"
    install -m 0755 "$BUILD_DIR/sidecarctl" "$DEST/sidecarctl"
    printf 'installed: %s/sidecarctl\n' "$DEST"
    exit 0
fi

printf 'sidecarctl built. Use --build-only for a reproducible non-installing build.\n'
