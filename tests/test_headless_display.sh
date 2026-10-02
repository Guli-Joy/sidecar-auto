#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-auto-headless-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
mkdir -p "$BIN"
CONFIG="$TMP/config"
LOG="$TMP/sidecar-auto.log"
CALLS="$TMP/helper.calls"
STATE="$TMP/helper.online"

cat > "$BIN/fake-display-state" <<'SH'
#!/usr/bin/env bash
if [ "${FAKE_PHYSICAL:-0}" = "1" ]; then
    printf 'physical=1\n'
else
    printf 'physical=0\n'
fi
SH
chmod 755 "$BIN/fake-display-state"

cat > "$BIN/fake-virtual-display" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_CALLS:?}"
case "${1:-}" in
    status)
        if [ -f "${FAKE_STATE:?}" ]; then printf 'online=1\n'; else printf 'online=0\n'; fi
        ;;
    ensure)
        touch "$FAKE_STATE"
        ;;
    set-main)
        ;;
    *)
        exit 64
        ;;
esac
SH
chmod 755 "$BIN/fake-virtual-display"

cat > "$CONFIG" <<'EOF_CONFIG'
AUTO_START_HEADLESS_DISPLAY=1
VIRTUAL_DISPLAY_BACKEND="builtin"
HEADLESS_DISPLAY_WAIT_SECONDS=3
DISPLAY_VERIFY_INTERVAL=0.1
EOF_CONFIG
chmod 600 "$CONFIG"

run_headless() {
    env \
        SIDECAR_AUTO_CONFIG="$CONFIG" \
        SIDECAR_AUTO_BIN_DIR="$BIN" \
        DISPLAY_STATE_BIN="$BIN/fake-display-state" \
        VIRTUAL_DISPLAY_HELPER="$BIN/fake-virtual-display" \
        FAKE_CALLS="$CALLS" \
        FAKE_STATE="$STATE" \
        LOG_FILE="$LOG" \
        "$ROOT/scripts/sidecar-headless-display.sh"
}

run_headless

grep -Fxq 'status' "$CALLS"
grep -Fxq 'ensure --background' "$CALLS"
grep -Fxq 'set-main' "$CALLS"
grep -Fq 'headless startup completed' "$LOG"

: > "$CALLS"
rm -f "$STATE"
env \
    FAKE_PHYSICAL=1 \
    SIDECAR_AUTO_CONFIG="$CONFIG" \
    SIDECAR_AUTO_BIN_DIR="$BIN" \
    DISPLAY_STATE_BIN="$BIN/fake-display-state" \
    VIRTUAL_DISPLAY_HELPER="$BIN/fake-virtual-display" \
    FAKE_CALLS="$CALLS" \
    FAKE_STATE="$STATE" \
    LOG_FILE="$LOG" \
    "$ROOT/scripts/sidecar-headless-display.sh"
[ ! -s "$CALLS" ]
grep -Fq 'physical display is present' "$LOG"

cat > "$CONFIG" <<'EOF_DISABLED'
AUTO_START_HEADLESS_DISPLAY=0
VIRTUAL_DISPLAY_BACKEND="builtin"
EOF_DISABLED
chmod 600 "$CONFIG"
: > "$CALLS"
run_headless
[ ! -s "$CALLS" ]
grep -Fq 'disabled by configuration' "$LOG"

printf 'headless display test passed\n'
