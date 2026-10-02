#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-auto-config-validation.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/.config/sidecar-auto"

expect_invalid_timeout() {
  local value="$1" output status
  cat > "$HOME_DIR/.config/sidecar-auto/config" <<EOF
IPAD_NAME="iPad"
SIDECAR_CONNECT_TIMEOUT_SECONDS=$value
EOF
  chmod 600 "$HOME_DIR/.config/sidecar-auto/config"
  set +e
  output="$(env HOME="$HOME_DIR" \
    SIDECAR_AUTO_CONFIG="$HOME_DIR/.config/sidecar-auto/config" \
    SIDECAR_AUTO_TEST_MODE=1 SPEAK=0 \
    SOUND_START=/dev/null SOUND_SUCCESS=/dev/null SOUND_FAILURE=/dev/null \
    "$ROOT/scripts/sidecar-connect-once.sh" wired 2>&1)"
  status=$?
  set -e
  printf '%s\n' "$output"
  [ "$status" -eq 64 ] || {
      printf 'expected invalid timeout %s to exit 64, got %s\n' "$value" "$status" >&2
      exit 1
  }
  printf '%s\n' "$output" | grep -Fq '超时' || {
      printf 'invalid timeout message missing for %s\n' "$value" >&2
      exit 1
  }
}

expect_invalid_timeout 0
expect_invalid_timeout 0.5
expect_invalid_timeout 999

printf 'connect config validation test passed\n'
