#!/usr/bin/env bash
# Safe integration tests for the one-shot controller.  Every external
# dependency is a deterministic fixture; no Sidecar request, display change,
# Bluetooth operation, or notification reaches the host running the test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-auto-connect-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
BIN="$TMP/bin"
mkdir -p "$HOME_DIR/.config/sidecar-auto" "$HOME_DIR/.local/bin" "$BIN"
STATE="$TMP/sidecar-state"
RADIO_LOG="$TMP/radio.log"
CONNECT="$ROOT/scripts/sidecar-connect-once.sh"
CONFIG="$HOME_DIR/.config/sidecar-auto/config"

cat > "$CONFIG" <<EOF
IPAD_NAME="iPad"
LOG_FILE="$TMP/sidecar.log"
DISPLAY_SETTLE_SECONDS=2
DISPLAY_SETTLE_MIN_SECONDS=0
DISPLAY_SETTLE_INTERVAL=0.05
DISPLAY_SETTLE_SAMPLES=2
DISPLAY_VERIFY_SECONDS=2
DISPLAY_VERIFY_INTERVAL=0.05
SIDECAR_STATUS_TIMEOUT_SECONDS=2
SIDECAR_CONNECT_TIMEOUT_SECONDS=2
SIDECAR_BLUETOOTH_PREPARE_TIMEOUT_SECONDS=2
SPEAK=0
SIDECAR_AUTO_TEST_MODE=1
EOF
chmod 600 "$CONFIG"

cat > "$BIN/sidecarctl" <<'EOF'
#!/usr/bin/env bash
set -u
state_file="${FAKE_SIDECAR_STATE:?}"
state="disconnected"
[ -r "$state_file" ] && state="$(cat "$state_file")"
case "${1:-}" in
  snapshot)
    if [ "$state" = connected ]; then
      printf '{"target":{"state":"connected","matches":1},"counts":{"devices":1,"connected":1,"disconnected":0,"unknown":0}}\n'
    else
      printf '{"target":{"state":"disconnected","matches":1},"counts":{"devices":1,"connected":0,"disconnected":1,"unknown":0}}\n'
    fi
    ;;
  status)
    if [ "$state" = connected ]; then printf 'connected\n'; exit 0; fi
    printf 'disconnected\n'; exit 1
    ;;
  connect)
    printf connected > "$state_file"
    printf 'fake connect accepted\n'
    ;;
  *) exit 64 ;;
esac
EOF

cat > "$BIN/display-state" <<'EOF'
#!/usr/bin/env bash
state="disconnected"
[ -r "${FAKE_SIDECAR_STATE:?}" ] && state="$(cat "$FAKE_SIDECAR_STATE")"
sidecar=0
[ "$state" = connected ] && sidecar=1
printf 'physical=1\nsidecar=%s\nvirtual=0\ndisplay id=100 kind=physical main=1 name=TestMonitor\n' "$sidecar"
if [ "$sidecar" -eq 1 ]; then
  printf 'display id=200 kind=sidecar main=0 name=iPad\n'
fi
EOF

cat > "$BIN/usb-detect" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_USB_MODE:-none}" in
  wired) printf 'USB_IPAD_MATCHED\tiPad\tSERIAL-ONE\n'; exit 0 ;;
  ambiguous) printf 'USB_IPAD_AMBIGUOUS\t2 iPads\n'; exit 3 ;;
  *) printf 'USB_IPAD_NOT_FOUND\tno device\n'; exit 1 ;;
esac
EOF

cat > "$BIN/networksetup" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -listallhardwareports) printf 'Hardware Port: Wi-Fi\nDevice: en0\n' ;;
  -getairportpower) printf 'Wi-Fi Power (en0): On\n' ;;
  -setairportpower) exit 0 ;;
  *) exit 1 ;;
esac
EOF

cat > "$BIN/bluetooth-radio" <<EOF
#!/usr/bin/env bash
printf 'prepare\n' >> "$RADIO_LOG"
exit 0
EOF

cat > "$BIN/defaults" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  read) printf '1\n' ;;
  write) exit 0 ;;
  *) exit 1 ;;
esac
EOF

chmod 755 "$BIN"/*

run_controller() {
  env HOME="$HOME_DIR" FAKE_SIDECAR_STATE="$STATE" FAKE_USB_MODE="$1" \
    SIDECAR_AUTO_CONFIG="$CONFIG" SIDECAR_BIN="$BIN/sidecarctl" \
    DISPLAY_STATE_BIN="$BIN/display-state" SIDECAR_USB_DETECT_BIN="$BIN/usb-detect" \
    NETWORKSETUP_BIN="$BIN/networksetup" SIDECAR_BLUETOOTH_RADIO_BIN="$BIN/bluetooth-radio" \
    DEFAULTS_BIN="$BIN/defaults" BLUETOOTH_PROFILER_BIN="$BIN/missing-profiler" \
    SOUND_START=/dev/null SOUND_SUCCESS=/dev/null SOUND_FAILURE=/dev/null \
    "$CONNECT" auto
}

: > "$STATE"
FAKE_USB_MODE=wired run_controller wired >/dev/null
[ "$(cat "$STATE")" = connected ] || { echo 'wired connect did not connect' >&2; exit 1; }
[ ! -d "$HOME_DIR/Library/Caches/sidecar-auto/explicit-action.lock" ] || { echo 'wired lock leaked' >&2; exit 1; }

printf disconnected > "$STATE"
rm -f "$RADIO_LOG"
FAKE_USB_MODE=none run_controller wireless >/dev/null
[ "$(cat "$STATE")" = connected ] || { echo 'wireless connect did not connect' >&2; exit 1; }
[ -s "$RADIO_LOG" ] || { echo 'wireless preflight did not prepare Bluetooth' >&2; exit 1; }

printf disconnected > "$STATE"
set +e
FAKE_USB_MODE=ambiguous run_controller ambiguous >/dev/null
status=$?
set -e
[ "$status" -eq 3 ] || { echo "ambiguous USB expected exit 3, got $status" >&2; exit 1; }
[ "$(cat "$STATE")" = disconnected ] || { echo 'ambiguous USB attempted a connection' >&2; exit 1; }

printf 'connect controller integration tests passed\n'
