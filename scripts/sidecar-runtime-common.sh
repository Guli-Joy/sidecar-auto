#!/bin/bash
# Shared functions for the standalone runtime entry points.
# This file is sourced from the same directory as the installed scripts.

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
