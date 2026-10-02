#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-auto-recovery-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/harness.swift" <<'SWIFT'
import Foundation

@main
struct RecoveryTimeoutHarness {
    static func main() {
        let started = Date()
        let marker = CommandLine.arguments[1]
        let result = shell("/bin/sh", ["-c", "sleep 10 & echo $! > '\(marker)' ; wait"], timeout: 0.2)
        let elapsed = Date().timeIntervalSince(started)
        print("status=\(result.status)")
        print(String(format: "elapsed=%.2f", elapsed))
        let noisy = shell("/bin/sh", ["-c", "awk 'BEGIN { for (i = 0; i < 2000000; i++) printf \"x\" }'"], timeout: 2)
        print("noisy-bytes=\(noisy.output.utf8.count)")
        let detached = shell("/bin/sh", ["-c", "sleep 2 & exit 0"], timeout: 1)
        print("detached-status=\(detached.status)")
    }
}
SWIFT

swiftc -O \
  "$ROOT/vendor/sidecarctl/Sources/Shared"/*.swift \
  "$TMP/harness.swift" \
  -o "$TMP/harness"

output="$($TMP/harness "$TMP/child.pid")"
printf '%s\n' "$output"
status="$(printf '%s\n' "$output" | sed -n 's/^status=//p')"
elapsed="$(printf '%s\n' "$output" | sed -n 's/^elapsed=//p')"
noisy_bytes="$(printf '%s\n' "$output" | sed -n 's/^noisy-bytes=//p')"
detached_status="$(printf '%s\n' "$output" | sed -n 's/^detached-status=//p')"

[ "$status" = "124" ] || {
    printf 'expected timeout status 124, got %s\n' "$status" >&2
    exit 1
}

awk -v elapsed="$elapsed" 'BEGIN { exit !(elapsed < 1.5) }' || {
    printf 'timeout took too long: %ss\n' "$elapsed" >&2
    exit 1
}

awk -v bytes="$noisy_bytes" 'BEGIN { exit !(bytes <= 1048576) }' || {
    printf 'captured output exceeded the 1 MiB cap: %s bytes\n' "$noisy_bytes" >&2
    exit 1
}
[ "$detached_status" = "0" ] || {
    printf 'detached child scenario returned status %s\n' "$detached_status" >&2
    exit 1
}

child_pid="$(cat "$TMP/child.pid" 2>/dev/null || true)"
if [[ "$child_pid" =~ ^[0-9]+$ ]]; then
    # A killed child may briefly remain as a zombie while launchd reaps it.
    sleep 0.1
    if kill -0 "$child_pid" 2>/dev/null; then
        state="$(ps -o state= -p "$child_pid" 2>/dev/null | tr -d ' ' || true)"
        if [ "$state" != "Z" ]; then
            printf 'timed-out child process leaked: %s\n' "$child_pid" >&2
            exit 1
        fi
    fi
fi

printf 'recovery timeout test passed\n'
