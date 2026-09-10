#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# 静态回归门禁不是安全证明；添加系统调用时必须重新审查。
PATTERN='URLSession|URLRequest|NWConnection|WKWebView|import WebKit|NSAppleScript|Process\(|NSTask|execve\('
if grep -Enr "$PATTERN" Sources/CodexMonitorCore Sources/CodexMonitorCLI Sources/CodexMonitorApp; then
  echo "离线边界检查失败：新增网络或子进程 API 需要单独审查。" >&2
  exit 1
fi
if grep -Enr '(auth\.json|refresh_token|access_token|client_secret)' Sources; then
  # UI 提示允许提到 auth.json，但核心不能访问它。
  if grep -Enr '(auth\.json|refresh_token|access_token|client_secret)' Sources/CodexMonitorCore Sources/CodexMonitorCLI; then
    echo "核心出现凭据路径或字段，请人工检查。" >&2
    exit 1
  fi
fi
echo "离线边界静态检查通过。"
