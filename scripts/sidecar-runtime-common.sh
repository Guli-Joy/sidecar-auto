#!/bin/bash
# Shared functions for the standalone runtime entry points.
# This file is sourced from the same directory as the installed scripts.

# Read configuration as data.  The config file is intentionally a small
# allowlist of KEY=value records; it is never sourced as shell code.  Keep the
# validation here so every runtime entry point applies the same ownership and
# permission checks before consuming a setting.
config_file_is_safe() {
    local config="${1:-}" owner current mode
    [ -n "$config" ] || return 1
    [ -f "$config" ] || return 1
    # A symlink can be swapped after a check and is not a user-owned config
    # record, even when its target happens to be a regular file.
    [ ! -L "$config" ] || return 1
    [ -r "$config" ] || return 1

    current="$(id -un 2>/dev/null || true)"
    if [ -x /usr/bin/stat ]; then
        owner="$(/usr/bin/stat -f%Su "$config" 2>/dev/null || true)"
        mode="$(/usr/bin/stat -f%Lp "$config" 2>/dev/null || true)"
    else
        owner="$(stat -c%U "$config" 2>/dev/null || true)"
        mode="$(stat -c%a "$config" 2>/dev/null || true)"
    fi
    [ -n "$current" ] && [ -n "$owner" ] && [ "$owner" = "$current" ] || return 1
    case "$mode" in
        ''|*[!0-7]*) return 1 ;;
    esac
    # Group/other write bits would let another account alter executable paths
    # or values between invocations.  Owner write/read bits are acceptable.
    (( (8#$mode & 022) == 0 )) || return 1
    return 0
}

config_load() {
    local config="${1:-}" key value
    config_file_is_safe "$config" || return 0

    # These are the only settings consumed by the runtime scripts.  Unknown
    # names and malformed records are ignored before they can affect shell
    # state.  Values are assigned with printf -v; no eval or source is used.
    local allowed_keys='IPAD_USB_SERIAL_NUMBER,IOREG_BIN,IPAD_NAME,SIDECAR_BIN,SIDECAR_USB_DETECT_BIN,SIDECAR_BLUETOOTH_RADIO_BIN,BLUETOOTH_PROFILER_BIN,NETWORKSETUP_BIN,AUTO_ENABLE_HANDOFF,AUTO_START_HEADLESS_DISPLAY,DEFAULTS_BIN,DISPLAY_STATE_BIN,DISPLAY_VERIFY_SECONDS,DISPLAY_VERIFY_INTERVAL,DISPLAY_SETTLE_SECONDS,DISPLAY_SETTLE_INTERVAL,DISPLAY_SETTLE_SAMPLES,DISPLAY_SETTLE_MIN_SECONDS,SIDECAR_STATUS_TIMEOUT_SECONDS,SIDECAR_BLUETOOTH_PREPARE_TIMEOUT_SECONDS,SIDECAR_CONNECT_TIMEOUT_SECONDS,BETTERDISPLAY_CLI,BETTERDISPLAY_APP,VIRTUAL_DISPLAY_BACKEND,VIRTUAL_DISPLAY_HELPER,BUILTIN_VIRTUAL_DISPLAY_NAME,VIRTUAL_DISPLAY_NAME,BETTERDISPLAY_TIMEOUT_SECONDS,HEADLESS_DISPLAY_WAIT_SECONDS,BETTERDISPLAY_SIDECAR_SPECIFIER,LOG_FILE,AUTO_CREATE_VIRTUAL_DISPLAY,SOUND_START,SOUND_SUCCESS,SOUND_FAILURE,VOICE,SPEAK,SIDECAR_AUTO_TEST_MODE,LOG_MAX_BYTES,SIDECAR_DISCONNECT_TIMEOUT_SECONDS,DISABLE_FALLBACK_WITH_PHYSICAL'
    while IFS=$'\t' read -r key value; do
        [ -n "$key" ] || continue
        # The awk allowlist already constrains names; retain this shell-side
        # guard so a future parser change cannot turn arbitrary names into
        # variable assignments.
        case ",$allowed_keys," in
            *,"$key",*) printf -v "$key" '%s' "$value" ;;
        esac
    done < <(/usr/bin/awk -v keys="$allowed_keys" '
        BEGIN {
            count = split(keys, names, ",")
            for (i = 1; i <= count; i++) allowed[names[i]] = 1
        }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line == "" || line ~ /^#/) next
            # Accept the common shell spelling for existing user configs, but
            # keep parsing declarative: the optional export keyword is removed
            # as text and no shell is evaluated.
            sub(/^export[[:space:]]+/, "", line)
            if (line !~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) next
            name = line
            sub(/[[:space:]]*=.*/, "", name)
            if (!(name in allowed)) next
            value = substr(line, index(line, "=") + 1)
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            if (value ~ /[\r\n\t]/) next
            if (value ~ /^"/) {
                if (value !~ /^"[^"]*"[[:space:]]*(#.*)?$/ || length(value) < 2) next
                end = index(substr(value, 2), "\"")
                value = substr(value, 2, end - 1)
            } else if (value ~ /^\047/) {
                if (value !~ /^\047[^\047]*\047[[:space:]]*(#.*)?$/ || length(value) < 2) next
                end = index(substr(value, 2), "\047")
                value = substr(value, 2, end - 1)
            } else {
                # Inline comments are recognized only after at least one
                # whitespace character, so paths and URLs containing '#' stay
                # intact.
                sub(/[[:space:]]+#.*$/, "", value)
                sub(/[[:space:]]*$/, "", value)
            }
            print name "\t" value
        }
    ' "$config")
}

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

rotate_log_if_needed() {
    local limit="${LOG_MAX_BYTES:-1048576}" size=""
    case "$limit" in
        ''|*[!0-9]*) limit=1048576 ;;
    esac
    [ "$limit" -gt 0 ] || limit=1048576
    [ -f "${LOG_FILE:-}" ] || return 0
    if [ -x /usr/bin/stat ]; then
        size="$(/usr/bin/stat -f%z "$LOG_FILE" 2>/dev/null || true)"
    else
        size="$(/usr/bin/stat -c%s "$LOG_FILE" 2>/dev/null || true)"
    fi
    case "$size" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$size" -lt "$limit" ] || mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
}

log() {
    rotate_log_if_needed
    printf '%s %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"
}

mark_shortcut_invocation() {
    # New templates set an explicit marker. Keep a bounded parent-process
    # fallback so shortcuts imported before this release still record their
    # first-run consent when launched from Shortcuts.app.
    local slug="${1:-${SLUG:-}}" launched_by_shortcuts=0 parent="" grandparent=""
    [ -n "$slug" ] || return 0
    if [ "${SIDECAR_SHORTCUT_INVOCATION:-0}" = "1" ]; then
        launched_by_shortcuts=1
    elif [ -n "${PPID:-}" ]; then
        parent="$(/bin/ps -o command= -p "$PPID" 2>/dev/null || true)"
        grandparent="$(/bin/ps -o command= -p "$(/bin/ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')" 2>/dev/null || true)"
        case "$parent $grandparent" in
            *Shortcuts*|*shortcuts*) launched_by_shortcuts=1 ;;
        esac
    fi
    [ "$launched_by_shortcuts" = "1" ] || return 0
    local state_dir="$HOME/Library/Application Support/Sidecar Auto/Shortcuts"
    local marker="$state_dir/${slug}.shell-status"
    mkdir -p "$state_dir" 2>/dev/null || return 0
    {
        printf 'authorized=1\n'
        printf 'timestamp=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    } >"$marker.tmp.$$" 2>/dev/null || return 0
    chmod 600 "$marker.tmp.$$" 2>/dev/null || true
    mv -f "$marker.tmp.$$" "$marker" 2>/dev/null || rm -f "$marker.tmp.$$"
}
