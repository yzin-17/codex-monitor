#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${1:-}" == "" || "${1:-}" == "--replace" ]] || { echo "用法：$0 [--replace]" >&2; exit 2; }
./scripts/build.sh
exec ./scripts/install-user-app.sh "${1:-}"
