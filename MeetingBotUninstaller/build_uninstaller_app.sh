#!/bin/bash
set -euo pipefail

APP_NAME="会议纪要助手卸载器"
EXECUTABLE_NAME="MeetingBotUninstaller"
BUNDLE_ID="com.pgui.MeetingBotUninstaller"
APP_VERSION="0.2.14"
BUILD_NUMBER="1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="/private/tmp/meetingbot-uninstaller-swift-module-cache"
APP_ICON="$SCRIPT_DIR/Resources/AppIcon.icns"

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

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_BUNDLE"
fi

echo "$APP_BUNDLE"
