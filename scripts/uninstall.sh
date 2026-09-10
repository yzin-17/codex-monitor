#!/bin/bash
set -euo pipefail
TARGET="$HOME/Applications/CodexMonitor.app"
[[ "${1:-}" == "--confirm" ]] || { echo "运行 ./scripts/uninstall.sh --confirm 删除本应用。保留派生缓存与设置，不触及 Codex 数据。"; exit 0; }
if /usr/bin/pgrep -x CodexMonitor >/dev/null 2>&1; then echo "请先退出 Codex Monitor。" >&2; exit 1; fi
if [[ -d "$TARGET" ]]; then rm -rf "$TARGET"; echo "已移除：$TARGET"; fi
