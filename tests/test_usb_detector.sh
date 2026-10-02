#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTOR="$ROOT/scripts/sidecar-ipad-usb-detect.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-auto-usb-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAKE_IOREG="$TMP/fake-ioreg"
CONFIG="$TMP/config"
cat >"$FAKE_IOREG" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_IOREG_FIXTURE"
EOF
chmod 0755 "$FAKE_IOREG"

run_case() {
    local name="$1" expected_status="$2" expected_text="$3" fixture="$4"
    printf '%s\n' "$fixture" >"$TMP/fixture"
    set +e
    local output
    output="$(FAKE_IOREG_FIXTURE="$TMP/fixture" IOREG_BIN="$FAKE_IOREG" SIDECAR_AUTO_CONFIG="$CONFIG" \
        "$DETECTOR" 2>&1)"
    local status=$?
    set -e
    [ "$status" -eq "$expected_status" ] || {
        printf 'FAIL %s: expected status %s, got %s\n%s\n' "$name" "$expected_status" "$status" "$output" >&2
        exit 1
    }
    [[ "$output" == *"$expected_text"* ]] || {
        printf 'FAIL %s: output did not contain %s\n%s\n' "$name" "$expected_text" "$output" >&2
        exit 1
    }
}

ipad_fixture() {
    cat <<EOF
+-o $1 <class IOUSBHostDevice, id 0x123>
  |   |   "idVendor" = 1452
  |   |   "USB Product Name" = "$2"
  |   |   "USB Serial Number" = "$3"
EOF
}

: >"$CONFIG"
run_case "unique iPad" 0 "USB_IPAD_MATCHED" "$(ipad_fixture iPad "iPad Pro" SERIAL-ONE)"
run_case "no device" 1 "USB_IPAD_NOT_FOUND" ""
run_case "two iPads" 3 "USB_IPAD_AMBIGUOUS" "$(ipad_fixture iPad-1 "iPad Pro" SERIAL-ONE)
$(ipad_fixture iPad-2 "iPad mini" SERIAL-TWO)"

printf 'IPAD_USB_SERIAL_NUMBER="SERIAL-TWO"\n' >"$CONFIG"
run_case "configured serial" 0 "SERIAL-TWO" "$(ipad_fixture iPad-1 "iPad Pro" SERIAL-ONE)
$(ipad_fixture iPad-2 "iPad mini" SERIAL-TWO)"

# Configuration is data.  A shell statement must never be evaluated while
# loading it, while a supported allowlisted setting must still be honored.
MARKER="$TMP/config-was-executed"
cat >"$CONFIG" <<EOF
touch "$MARKER"
IPAD_USB_SERIAL_NUMBER="SERIAL-TWO"
EOF
run_case "config shell syntax is ignored" 0 "SERIAL-TWO" "$(ipad_fixture iPad-1 "iPad Pro" SERIAL-ONE)
$(ipad_fixture iPad-2 "iPad mini" SERIAL-TWO)"
[ ! -e "$MARKER" ] || {
    printf 'FAIL config shell syntax was executed\n' >&2
    exit 1
}

# A group/other-writable config is not trusted.  The detector must ignore its
# serial override instead of consuming values an unrelated account could edit.
printf 'IPAD_USB_SERIAL_NUMBER="SERIAL-TWO"\n' >"$CONFIG"
chmod 0666 "$CONFIG"
run_case "world-writable config is ignored" 3 "USB_IPAD_AMBIGUOUS" "$(ipad_fixture iPad-1 "iPad Pro" SERIAL-ONE)
$(ipad_fixture iPad-2 "iPad mini" SERIAL-TWO)"

chmod 0600 "$CONFIG"
cat >"$CONFIG" <<'EOF'
export IPAD_USB_SERIAL_NUMBER="SERIAL-TWO" # keep the selected device
EOF
run_case "export and inline comment are parsed as data" 0 "SERIAL-TWO" "$(ipad_fixture iPad-1 "iPad Pro" SERIAL-ONE)
$(ipad_fixture iPad-2 "iPad mini" SERIAL-TWO)"

printf 'USB detector tests passed\n'
