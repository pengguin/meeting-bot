#!/bin/bash
set -euo pipefail

APP_NAME="会议纪要助手"
EXECUTABLE_NAME="FeishuMeetingBot"
BUNDLE_ID="com.pgui.FeishuMeetingBotMenuBar"
APP_VERSION="0.3.0"
BUILD_NUMBER="21"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$SCRIPT_DIR/MeetingBotMenuBarApp"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="/private/tmp/meetingbot-swift-module-cache"
APP_ICON="$SOURCE_DIR/Resources/AppIcon.icns"
BOOTSTRAP_PAYLOAD_DIR="$RESOURCES_DIR/bootstrap/meeting-bot"
PAYLOAD_VERSION="$(date +%Y%m%d%H%M%S)"

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
    <key>LSUIElement</key>
    <true/>
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
    "$SOURCE_DIR/AppPaths.swift" \
    "$SOURCE_DIR/DesignSystem.swift" \
    "$SOURCE_DIR/Models.swift" \
    "$SOURCE_DIR/EnvironmentHealth.swift" \
    "$SOURCE_DIR/LaunchAgentManager.swift" \
    "$SOURCE_DIR/BotRuntimeStore.swift" \
    "$SOURCE_DIR/BootstrapInstaller.swift" \
    "$SOURCE_DIR/AppSettings.swift" \
    "$SOURCE_DIR/SetupWizard.swift" \
    "$SOURCE_DIR/MeetingLibraryStore.swift" \
    "$SOURCE_DIR/MeetingBotMenuView.swift" \
    "$SOURCE_DIR/MainWindowView.swift" \
    "$SOURCE_DIR/MeetingBotMenuBarAppApp.swift" \
    -o "$MACOS_DIR/$EXECUTABLE_NAME"

chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

if [[ -f "$APP_ICON" ]]; then
    cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"
fi

mkdir -p "$BOOTSTRAP_PAYLOAD_DIR"
rsync -a \
  --exclude ".env" \
  --exclude ".venv" \
  --exclude ".git" \
  --exclude ".pytest_cache" \
  --exclude "__pycache__" \
  --exclude ".DS_Store" \
  --exclude "downloads" \
  --exclude "sessions" \
  --exclude "logs" \
  --exclude "runtime" \
  --exclude "library" \
  --exclude "tmp" \
  --exclude "backups" \
  --exclude "latest_session.txt" \
  --exclude "*.bak" \
  --exclude "bot_backup_*.py" \
  --exclude "dist" \
  "$PROJECT_ROOT/" "$BOOTSTRAP_PAYLOAD_DIR/"
printf '%s\n' "$PAYLOAD_VERSION" > "$RESOURCES_DIR/payload-version.txt"

if command -v codesign >/dev/null 2>&1; then
codesign --force --sign - "$APP_BUNDLE"
fi

echo "$APP_BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
    INSTALL_PATH="/Applications/$APP_NAME.app"
    mkdir -p "$INSTALL_PATH"
    rsync -a --delete "$APP_BUNDLE/" "$INSTALL_PATH/"
    echo "$INSTALL_PATH"
fi
