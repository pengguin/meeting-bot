#!/bin/bash
set -euo pipefail

APP_NAME="会议纪要助手卸载器"
EXECUTABLE_NAME="MeetingBotUninstaller"
BUNDLE_ID="com.pgui.MeetingBotUninstaller"
APP_VERSION="0.7.2"
BUILD_NUMBER="38"
ACTION="${1:-}"
BUILD_SECURITY_MODE="${MEETINGBOT_BUILD_SECURITY_MODE:-distribution}"
CODESIGN_IDENTITY="${MEETINGBOT_CODESIGN_IDENTITY:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="/private/tmp/meetingbot-uninstaller-swift-module-cache"
APP_ICON="$SCRIPT_DIR/Resources/AppIcon.icns"

if [[ "$BUILD_SECURITY_MODE" != "development" && "$BUILD_SECURITY_MODE" != "distribution" ]]; then
    echo "MEETINGBOT_BUILD_SECURITY_MODE 必须是 development 或 distribution" >&2
    exit 1
fi
if [[ "$BUILD_SECURITY_MODE" == "distribution" && -z "$CODESIGN_IDENTITY" ]]; then
    echo "正式构建必须配置 MEETINGBOT_CODESIGN_IDENTITY" >&2
    exit 1
fi
if [[ "$ACTION" == "--security-preflight-only" ]]; then
    printf '%s\n' "$BUILD_SECURITY_MODE"
    exit 0
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

xcrun swiftc \
    -target arm64-apple-macosx14.0 \
    -O \
    -parse-as-library \
    -module-cache-path "$MODULE_CACHE_DIR" \
    "$SCRIPT_DIR/MeetingBotUninstaller.swift" \
    -o "$MACOS_DIR/$EXECUTABLE_NAME"

chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

if [[ ! -f "$APP_ICON" ]]; then
    python3 "$SCRIPT_DIR/generate_uninstaller_icon.py" >/dev/null
fi
cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"

if [[ "$BUILD_SECURITY_MODE" == "distribution" ]]; then
    codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "[build][warning] 正在生成仅供本机开发测试的 ad-hoc 签名卸载器" >&2
    codesign --force --sign - "$APP_BUNDLE"
fi

echo "$APP_BUNDLE"
