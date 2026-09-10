#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/dist/CodexMonitor.app"
INSTALL_DIR="${CODEX_NOTCH_INSTALL_DIR:-$HOME/Applications}"
TARGET_APP="$INSTALL_DIR/CodexMonitor.app"
[[ "${1:-}" == "" || "${1:-}" == "--replace" ]] || { echo "用法：$0 [--replace]" >&2; exit 2; }
[[ -d "$SOURCE_APP" ]] || { echo "请先运行 scripts/build-app.sh" >&2; exit 1; }
if [[ -d "$TARGET_APP" && "${1:-}" != "--replace" ]]; then echo "已安装；请先退出 Codex Monitor，再用 --replace。" >&2; exit 1; fi
if /bin/ps -axo command= | /usr/bin/grep -F "$TARGET_APP/Contents/MacOS/" | /usr/bin/grep -v grep >/dev/null; then echo "请先退出此项目的 Codex Monitor。" >&2; exit 1; fi
mkdir -p "$INSTALL_DIR"
if [[ -e "$TARGET_APP" ]]; then mv "$TARGET_APP" "$TARGET_APP.backup-$(date +%Y%m%d-%H%M%S)"; fi
ditto "$SOURCE_APP" "$TARGET_APP"
codesign --verify --deep --strict "$TARGET_APP"
open "$TARGET_APP"
echo "已安装：$TARGET_APP"
