#!/bin/bash
# Compatibility wrapper for users who already bound sidecar-hotkey.sh.
# `connect`/`auto` use the smart USB-versus-wireless decision. The explicit
# wireless entry remains useful for troubleshooting.

set -u

ACTION="${1:-status}"
case "$ACTION" in
    connect)
        exec "$HOME/.local/bin/sidecar-connect-once.sh" auto
        ;;
    auto)
        exec "$HOME/.local/bin/sidecar-connect-once.sh" auto
        ;;
    wireless)
        exec "$HOME/.local/bin/sidecar-connect-wireless-once.sh"
        ;;
    disconnect)
        exec "$HOME/.local/bin/sidecar-disconnect-once.sh"
        ;;
    status)
        exec "$HOME/.local/bin/sidecarctl" status "${IPAD_NAME:-iPad}"
        ;;
    *)
        printf 'usage: %s {connect|auto|wireless|disconnect|status}\n' "$0" >&2
        exit 64
        ;;
esac
