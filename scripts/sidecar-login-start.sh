#!/bin/bash
# Start Sidecar Auto after a user logs in.
#
# LaunchAgents can run before the Aqua session is ready, and a GUI app that
# exits during that short window otherwise leaves launchd with an exited job.
# This wrapper waits for WindowServer, starts the app silently, and retries a
# failed launch a few times. A clean app exit is treated as an intentional quit.

set -u

USER_HOME="${HOME:-$(/usr/bin/printf '%s' ~)}"
APP_EXECUTABLE="${1:-/Applications/Sidecar Auto Setup.app/Contents/MacOS/SidecarAutoSetup}"
LOG_FILE="${SIDECAR_AUTO_LOGIN_START_LOG:-$USER_HOME/Library/Logs/sidecar-auto-login-start.log}"
WAIT_SECONDS="${SIDECAR_AUTO_LOGIN_WAIT_SECONDS:-60}"
RETRY_DELAY_SECONDS="${SIDECAR_AUTO_LOGIN_RETRY_DELAY_SECONDS:-10}"
MAX_ATTEMPTS="${SIDECAR_AUTO_LOGIN_MAX_ATTEMPTS:-6}"

number_or_default() {
    local value="$1"
    local fallback="$2"
    case "$value" in
        ''|*[!0-9]*) printf '%s' "$fallback" ;;
        *) printf '%s' "$value" ;;
    esac
}

WAIT_SECONDS="$(number_or_default "$WAIT_SECONDS" 60)"
RETRY_DELAY_SECONDS="$(number_or_default "$RETRY_DELAY_SECONDS" 10)"
MAX_ATTEMPTS="$(number_or_default "$MAX_ATTEMPTS" 6)"
[ "$MAX_ATTEMPTS" -gt 0 ] || MAX_ATTEMPTS=6

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
}

if [ ! -x "$APP_EXECUTABLE" ]; then
    log "login startup failed: app executable is missing or not executable: $APP_EXECUTABLE"
    exit 127
fi

if [ "${SIDECAR_AUTO_LOGIN_SKIP_EXISTING_CHECK:-0}" != "1" ] && \
   /usr/bin/pgrep -x SidecarAutoSetup >/dev/null 2>&1; then
    log "login startup skipped: SidecarAutoSetup is already running"
    exit 0
fi

if [ "$WAIT_SECONDS" -gt 0 ]; then
    waited=0
    while [ "$waited" -lt "$WAIT_SECONDS" ]; do
        if /usr/bin/pgrep -x WindowServer >/dev/null 2>&1; then
            break
        fi
        /bin/sleep 1
        waited=$((waited + 1))
    done
    if ! /usr/bin/pgrep -x WindowServer >/dev/null 2>&1; then
        log "login startup continuing after waiting ${WAIT_SECONDS}s: WindowServer was not detected"
    else
        log "login startup session ready after ${waited}s"
    fi
fi

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    if [ "${SIDECAR_AUTO_LOGIN_SKIP_EXISTING_CHECK:-0}" != "1" ] && \
       /usr/bin/pgrep -x SidecarAutoSetup >/dev/null 2>&1; then
        log "login startup skipped: SidecarAutoSetup is already running"
        exit 0
    fi

    log "starting Sidecar Auto silently (attempt ${attempt}/${MAX_ATTEMPTS})"
    HOME="$USER_HOME" \
    SIDECAR_AUTO_LOGIN_START=1 \
        "$APP_EXECUTABLE" >> "$LOG_FILE" 2>&1
    status=$?
    if [ "$status" -eq 0 ]; then
        log "Sidecar Auto exited normally after login startup"
        exit 0
    fi

    log "Sidecar Auto exited during login startup (status=$status)"
    attempt=$((attempt + 1))
    if [ "$attempt" -le "$MAX_ATTEMPTS" ] && [ "$RETRY_DELAY_SECONDS" -gt 0 ]; then
        /bin/sleep "$RETRY_DELAY_SECONDS"
    fi
done

log "login startup exhausted ${MAX_ATTEMPTS} attempts"
exit 1
