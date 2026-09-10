#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS .app 需要在 Mac 构建；本环境可运行 swift test 或 swift run codex-monitor --demo。" >&2
  exit 1
fi
command -v swift >/dev/null || { echo "未找到 Swift，请安装 Xcode 或包含 Swift 6 的 Command Line Tools。" >&2; exit 1; }
./scripts/test.sh
swift build -c release --product CodexMonitor
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/CodexMonitor.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CodexMonitor" "$APP/Contents/MacOS/CodexMonitor"
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION 无效" >&2; exit 1; }
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.yzin.codexmonitor</string>
<key>CFBundleName</key><string>Codex Monitor</string>
<key>CFBundleDisplayName</key><string>Codex Monitor</string>
<key>CFBundleExecutable</key><string>CodexMonitor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ROOT/dist/CodexMonitor-$VERSION-macos-$(uname -m).zip"
echo "已构建：$APP"
echo "本地产物使用 ad-hoc 签名，未经过 Apple 公证。"
