#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-auto-login-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAKE_APP="$TMP/fake app.sh"
ATTEMPTS_FILE="$TMP/attempts"
MARKER_FILE="$TMP/marker"
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR"

cat > "$FAKE_APP" <<'SH'
#!/usr/bin/env bash
set -u
attempts=0
if [ -f "${SIDECAR_AUTO_TEST_ATTEMPTS:?}" ]; then
    attempts="$(cat "$SIDECAR_AUTO_TEST_ATTEMPTS")"
fi
attempts=$((attempts + 1))
printf '%s\n' "$attempts" > "$SIDECAR_AUTO_TEST_ATTEMPTS"
printf 'login=%s\nhome=%s\n' "${SIDECAR_AUTO_LOGIN_START:-}" "${HOME:-}" > "${SIDECAR_AUTO_TEST_MARKER:?}"
if [ "$attempts" -lt 3 ]; then
    exit 75
fi
exit 0
SH
chmod 755 "$FAKE_APP"

SIDECAR_AUTO_LOGIN_SKIP_EXISTING_CHECK=1 \
SIDECAR_AUTO_LOGIN_WAIT_SECONDS=0 \
SIDECAR_AUTO_LOGIN_RETRY_DELAY_SECONDS=0 \
SIDECAR_AUTO_LOGIN_MAX_ATTEMPTS=4 \
SIDECAR_AUTO_TEST_ATTEMPTS="$ATTEMPTS_FILE" \
SIDECAR_AUTO_TEST_MARKER="$MARKER_FILE" \
HOME="$HOME_DIR" \
    "$ROOT/scripts/sidecar-login-start.sh" "$FAKE_APP"

test "$(cat "$ATTEMPTS_FILE")" = "3"
grep -Fxq 'login=1' "$MARKER_FILE"
grep -Fxq "home=$HOME_DIR" "$MARKER_FILE"

printf 'login start retry test passed\n'
