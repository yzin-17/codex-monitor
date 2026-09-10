#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == "Darwin" ]] || { echo "安装需要 macOS。" >&2; exit 1; }
TARGET="$HOME/Applications/CodexMonitor.app"
if [[ -e "$TARGET" && "${1:-}" != "--replace" ]]; then
  echo "已有 $TARGET。先退出 Codex Monitor，再用 ./scripts/install.sh --replace 明确替换。" >&2
  exit 1
fi
# 只检查本应用；从不退出、重启或注入 Codex / ChatGPT。
if /usr/bin/pgrep -x CodexMonitor >/dev/null 2>&1; then
  echo "请先从菜单栏退出 Codex Monitor，再安装。不会自动结束进程。" >&2
  exit 1
fi
"$ROOT/scripts/build.sh"
mkdir -p "$HOME/Applications"
STAGING="$(mktemp -d "$HOME/Applications/.codex-monitor-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$ROOT/dist/CodexMonitor.app" "$STAGING/CodexMonitor.app"
if [[ -e "$TARGET" ]]; then
  BACKUP="$HOME/Applications/CodexMonitor-backup-$(date +%Y%m%d%H%M%S).app"
  mv "$TARGET" "$BACKUP"
  echo "旧版备份：$BACKUP"
fi
mv "$STAGING/CodexMonitor.app" "$TARGET"
echo "已安装：$TARGET"
/usr/bin/open "$TARGET" || { echo "自动打开失败，请在 Finder 双击应用；不重试或重启 Codex。" >&2; exit 1; }
