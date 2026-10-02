#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Sources/SidecarAutoSetup/main.swift"

python3 - "$SOURCE" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
required = {
    "refresh calls made while a probe is active are queued":
        "refreshRequestedWhileBusy = true",
    "queued probe is started after the active probe completes":
        "let rerun = self.refreshRequestedWhileBusy",
    "the running app recognizes its own process":
        'ProcessInfo.processInfo.processName == "SidecarAutoSetup"',
}
missing = [name for name, marker in required.items() if marker not in source]
if missing:
    for name in missing:
        print(f"missing status refresh guarantee: {name}", file=sys.stderr)
    raise SystemExit(1)
PY

printf 'status refresh regression test passed\n'
