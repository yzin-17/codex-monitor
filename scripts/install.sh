#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in ''|--replace) ;; *) echo '用法：./scripts/install.sh [--replace]' >&2; exit 2;; esac
if pgrep -x CodexMonitor >/dev/null; then echo '请先正常退出 Codex Monitor。' >&2; exit 1; fi
python3 "$ROOT/scripts/verify-alight-baseline.py"
"$ROOT/scripts/build-app.sh"
exec "$ROOT/scripts/install-user-app.sh" "$@"
