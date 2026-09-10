#!/usr/bin/env bash
set -euo pipefail
# 仅在临时 GitHub Mac 运行器使用原版合成数据预览，不在用户桌面截图。
[[ "${GITHUB_ACTIONS:-}" == true && "$(uname -s)" == Darwin ]] || { echo '仅允许在 GitHub macOS CI 中运行。' >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${RUNNER_TEMP:?}/ui-preview.png"
DOMAIN=dev.yzin.codexmonitor.alight
for key in remoteMonitorEnabled newAPIMonitorEnabled subAPIMonitorEnabled codexRadarEnabled; do
  /usr/bin/defaults write "$DOMAIN" "$key" -bool false
done
"$ROOT/dist/CodexMonitor.app/Contents/MacOS/CodexMonitor" --qa-static-preview --qa-expanded > "$RUNNER_TEMP/ui-smoke.log" 2>&1 &
monitor_pid=$!
trap 'kill "$monitor_pid" 2>/dev/null || true' EXIT
sleep 4
kill -0 "$monitor_pid"
/usr/sbin/screencapture -x "$OUTPUT"
test -s "$OUTPUT"
/usr/bin/sips -g pixelWidth -g pixelHeight "$OUTPUT"
echo '已捕获临时运行器的原版静态测试数据预览；不是用户真实对话，不代表人工视觉验收。'
