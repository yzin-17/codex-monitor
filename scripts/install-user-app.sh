#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/dist/CodexMonitor.app"
INSTALL_DIR="${CODEX_NOTCH_INSTALL_DIR:-$HOME/Applications}"
TARGET_APP="$INSTALL_DIR/CodexMonitor.app"
replace=0
case "${1:-}" in
  '') ;;
  --replace) replace=1 ;;
  *) echo "用法：$0 [--replace]" >&2; exit 2 ;;
esac
[[ -d "$SOURCE_APP" ]] || { echo '请先运行 ./scripts/build-app.sh' >&2; exit 1; }
if pgrep -x CodexMonitor >/dev/null; then
  echo '请先正常退出 Codex Monitor，再安装。不会强制结束任何应用。' >&2
  exit 1
fi
codesign --verify --deep --strict "$SOURCE_APP"
mkdir -p "$INSTALL_DIR"
if [[ -e "$TARGET_APP" ]]; then
  [[ "$replace" == 1 ]] || { echo '应用已存在，请显式传入 --replace。' >&2; exit 1; }
  BACKUP_DIR="$(mktemp -d "$INSTALL_DIR/CodexMonitor-backup-$(date +%Y%m%d-%H%M%S).XXXXXX")"
  mv "$TARGET_APP" "$BACKUP_DIR/CodexMonitor.app"
  echo "旧版已备份：$BACKUP_DIR"
fi
ditto "$SOURCE_APP" "$TARGET_APP"
codesign --verify --deep --strict "$TARGET_APP"
open "$TARGET_APP"
echo "已安装：$TARGET_APP"
