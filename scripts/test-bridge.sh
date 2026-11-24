#!/usr/bin/env bash
# Run the TerminalBridge package tests; the root `swift test` does not see the nested package.
# Extra arguments go to `swift test` (for example `--filter LoopbackSession`). Exit status is swift test's.
# The real GNU screen tests stay skipped unless the caller exports TONAMOX_SCREEN_IT=1.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Sources/TonamoxExample/TerminalBridge"

swift test --package-path "$PACKAGE" "$@"
status=$?

if [ "$status" -eq 0 ]; then
  echo "test-bridge: TerminalBridge tests passed"
else
  echo "test-bridge: TerminalBridge tests FAILED (exit $status)" >&2
fi
exit "$status"
