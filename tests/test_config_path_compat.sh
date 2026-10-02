#!/usr/bin/env bash
# Legacy configs may contain literal $HOME or ~/ executable paths.  The
# declarative parser must normalize those paths without evaluating the file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-auto-path-compat.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/.config/sidecar-auto"
cat > "$HOME_DIR/.config/sidecar-auto/config" <<'CONFIG'
IPAD_NAME="iPad"
SIDECAR_BIN="$HOME/.local/bin/sidecarctl"
DISPLAY_STATE_BIN="~/.local/bin/display-state"
CONFIG
chmod 600 "$HOME_DIR/.config/sidecar-auto/config"

HOME="$HOME_DIR" bash -c '
  source "$1/scripts/sidecar-runtime-common.sh"
  config_load "$HOME/.config/sidecar-auto/config"
  test "$SIDECAR_BIN" = "$HOME/.local/bin/sidecarctl"
  test "$DISPLAY_STATE_BIN" = "$HOME/.local/bin/display-state"
' bash "$ROOT"
printf 'config path compatibility test passed\n'
