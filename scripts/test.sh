#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./scripts/check-offline.sh
swift test
swift run codex-monitor --demo --format json > /dev/null
for file in Sources/CodexMonitorApp/*.swift; do
  swiftc -frontend -parse "$file"
done
