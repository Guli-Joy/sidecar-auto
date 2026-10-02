#!/bin/bash
# Prepare the built-in virtual display after Sidecar Auto starts.
# The app invokes this helper after the user's desktop session is ready. It is
# deliberately limited to the display helper; it never connects or disconnects
# Sidecar and it never changes the user's iPad session.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${SIDECAR_AUTO_BIN_DIR:-$HOME/.local/bin}"
CONFIG_FILE="${SIDECAR_AUTO_CONFIG:-$HOME/.config/sidecar-auto/config}"
LOG_FILE="${LOG_FILE:-$HOME/Library/Logs/sidecar-auto.log}"
DISPLAY_STATE_BIN="${DISPLAY_STATE_BIN:-$BIN_DIR/display-state}"
VIRTUAL_DISPLAY_HELPER="${VIRTUAL_DISPLAY_HELPER:-$BIN_DIR/sidecar-virtual-display}"

if [ ! -r "$SCRIPT_DIR/sidecar-runtime-common.sh" ]; then
    printf '缺少共享运行时文件：%s\n' "$SCRIPT_DIR/sidecar-runtime-common.sh" >&2
    exit 127
fi
. "$SCRIPT_DIR/sidecar-runtime-common.sh"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

run_with_timeout() {
    local seconds="$1"
    shift
    if [ ! -x /usr/bin/perl ]; then
        return 125
    fi
    /usr/bin/perl -e '
        use POSIX qw(setpgid);
        my $seconds = shift;
        my $child = fork();
        exit 127 unless defined $child;
        if ($child == 0) {
            setpgid(0, 0);
            exec @ARGV;
            exit 127;
        }
        my $grouped = setpgid($child, $child) == 0;
        $SIG{ALRM} = sub {
            kill "TERM", $grouped ? -$child : $child;
            select undef, undef, undef, 0.2;
            kill "KILL", $grouped ? -$child : $child;
            waitpid($child, 0);
            exit 124;
        };
        alarm $seconds;
        waitpid($child, 0);
        alarm 0;
        exit $? >> 8;
    ' "$seconds" "$@"
}

config_load "$CONFIG_FILE"
: "${AUTO_START_HEADLESS_DISPLAY:=1}"
: "${VIRTUAL_DISPLAY_BACKEND:=auto}"
: "${HEADLESS_DISPLAY_WAIT_SECONDS:=30}"
: "${DISPLAY_VERIFY_INTERVAL:=1}"

case "$HEADLESS_DISPLAY_WAIT_SECONDS" in
    ''|*[!0-9]*) HEADLESS_DISPLAY_WAIT_SECONDS=30 ;;
esac
[ "$HEADLESS_DISPLAY_WAIT_SECONDS" -gt 0 ] || HEADLESS_DISPLAY_WAIT_SECONDS=30
if ! /usr/bin/awk -v value="$DISPLAY_VERIFY_INTERVAL" \
    'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }'; then
    DISPLAY_VERIFY_INTERVAL=1
fi

if [ "$AUTO_START_HEADLESS_DISPLAY" != "1" ]; then
    log "headless startup disabled by configuration"
    exit 0
fi

case "$VIRTUAL_DISPLAY_BACKEND" in
    betterdisplay)
        log "headless startup skipped: BetterDisplay owns the selected backend"
        exit 0
        ;;
    auto|builtin)
        ;;
    *)
        log "headless startup skipped: invalid VIRTUAL_DISPLAY_BACKEND=$VIRTUAL_DISPLAY_BACKEND"
        exit 64
        ;;
esac

if [ ! -x "$VIRTUAL_DISPLAY_HELPER" ]; then
    log "headless startup failed: helper not installed at $VIRTUAL_DISPLAY_HELPER"
    exit 127
fi

# If a physical display is already present, leave the desktop unchanged. A
# missing or inconclusive probe is not treated as a reason to fail: the helper
# is the source of truth for whether the fallback is already online.
if [ -x "$DISPLAY_STATE_BIN" ]; then
    display_state="$(run_with_timeout 5 "$DISPLAY_STATE_BIN" 2>&1 || true)"
    if printf '%s\n' "$display_state" | /usr/bin/grep -Eq '(^|[[:space:]])physical=1([[:space:]]|$)'; then
        log "headless startup skipped: physical display is present"
        exit 0
    fi
fi

if run_with_timeout 5 "$VIRTUAL_DISPLAY_HELPER" status 2>&1 | /usr/bin/grep -Eq '(^|[[:space:]])online=1([[:space:]]|$)'; then
    log "headless startup found the built-in virtual display already online"
    run_with_timeout 5 "$VIRTUAL_DISPLAY_HELPER" set-main >/dev/null 2>&1 || true
    exit 0
fi

output="$(run_with_timeout 10 "$VIRTUAL_DISPLAY_HELPER" ensure --background 2>&1)"
code=$?
if [ "$code" -ne 0 ]; then
    log "headless startup failed to start helper (exit=$code): $output"
    exit "$code"
fi

end=$((SECONDS + HEADLESS_DISPLAY_WAIT_SECONDS))
while (( SECONDS <= end )); do
    state="$(run_with_timeout 5 "$VIRTUAL_DISPLAY_HELPER" status 2>&1 || true)"
    if printf '%s\n' "$state" | /usr/bin/grep -Eq '(^|[[:space:]])online=1([[:space:]]|$)'; then
        run_with_timeout 5 "$VIRTUAL_DISPLAY_HELPER" set-main >/dev/null 2>&1 || true
        log "headless startup completed: $state"
        exit 0
    fi
    sleep "$DISPLAY_VERIFY_INTERVAL"
done

state="$(run_with_timeout 5 "$VIRTUAL_DISPLAY_HELPER" status 2>&1 || true)"
log "headless startup timed out: $state"
exit 124
