#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
APP_NAME="CodexMonitor"
PACKAGE_NAME="codex-monitor"
APP_VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
BUNDLE_ID="dev.yzin.codexmonitor"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_STAGE_DIR="$DIST_DIR/dmg-stage"
PACKAGE_STAGE_DIR="$DIST_DIR/package-stage"

if [[ -z "$APP_VERSION" ]]; then
  echo "VERSION is empty" >&2
  exit 1
fi

prepare_swiftpm_module_cache() {
  local build_root="$ROOT_DIR/.build"
  local marker="$build_root/.codex-monitor-root"
  local previous_root=""

  if [[ -f "$marker" ]]; then
    previous_root="$(cat "$marker" 2>/dev/null || true)"
  fi

  # Swift PCM 文件会记录绝对 ModuleCache 路径。仓库移动后复用旧 .build 会触发
  # "precompiled file ... was compiled with module cache path ..." / SwiftShims 缺失。
  if [[ -d "$build_root" && "$previous_root" != "$ROOT_DIR" ]]; then
    echo "SwiftPM build path changed; clearing stale module caches..."
    find "$build_root" -type d \( -name ModuleCache -o -name ModuleCache.noindex \) -prune -exec rm -rf {} +
  fi

  mkdir -p "$build_root"
  printf '%s\n' "$ROOT_DIR" > "$marker"
}

cd "$ROOT_DIR"
prepare_swiftpm_module_cache
if [[ "${CODEX_NOTCH_SKIP_TESTS:-0}" != "1" ]]; then
  "$ROOT_DIR/scripts/run-regression-tests.sh"
fi
mkdir -p "$DIST_DIR"
if [[ ! -s "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  swift "$ROOT_DIR/scripts/generate-app-icon.swift"
fi
find "$DIST_DIR" -maxdepth 1 -type f \( -name "$APP_NAME.dmg" -o -name "$APP_NAME-*.dmg" -o -name "$PACKAGE_NAME-*.dmg" \) -delete
rm -rf "$DMG_STAGE_DIR" "$PACKAGE_STAGE_DIR"

create_app_bundle() {
  local binary_path="$1"
  local app_dir="$2"
  local contents_dir="$app_dir/Contents"
  local macos_dir="$contents_dir/MacOS"
  local resources_dir="$contents_dir/Resources"

  rm -rf "$app_dir"
  mkdir -p "$macos_dir" "$resources_dir"
  cp "$binary_path" "$macos_dir/CodexNotch"
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$resources_dir/AppIcon.icns"

  cat > "$contents_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>CodexNotch</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

  codesign --force --deep --sign - "$app_dir"
  codesign --verify --deep --strict "$app_dir"
}

build_arch() {
  local swift_arch="$1"
  local dmg_arch="$2"
  local build_dir="$ROOT_DIR/.build/$swift_arch-apple-macosx/release"
  local staged_app="$PACKAGE_STAGE_DIR/$dmg_arch/$APP_NAME.app"
  local dmg_path="$DIST_DIR/$PACKAGE_NAME-$APP_VERSION-$dmg_arch.dmg"

  swift build -c release --arch "$swift_arch"
  create_app_bundle "$build_dir/CodexNotch" "$staged_app"

  rm -rf "$DMG_STAGE_DIR"
  mkdir -p "$DMG_STAGE_DIR"
  ditto "$staged_app" "$DMG_STAGE_DIR/$APP_NAME.app"
  hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE_DIR" -ov -format UDZO "$dmg_path"
  echo "Built $dmg_path"
}

build_arch "arm64" "arm64"
build_arch "x86_64" "amd64"

case "$(uname -m)" in
  x86_64) create_app_bundle "$ROOT_DIR/.build/x86_64-apple-macosx/release/CodexNotch" "$APP_DIR" ;;
  *) create_app_bundle "$ROOT_DIR/.build/arm64-apple-macosx/release/CodexNotch" "$APP_DIR" ;;
esac

rm -rf "$DMG_STAGE_DIR" "$PACKAGE_STAGE_DIR"
echo "Built $APP_DIR"