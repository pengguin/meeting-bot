#!/bin/bash
set -euo pipefail

APP_NAME="会议纪要助手"
EXECUTABLE_NAME="FeishuMeetingBot"
BUNDLE_ID="com.pgui.FeishuMeetingBotMenuBar"
APP_VERSION="0.6.0"
BUILD_NUMBER="35"
ACTION="${1:-}"
BUILD_SECURITY_MODE="${MEETINGBOT_BUILD_SECURITY_MODE:-distribution}"
RELEASE_SIGNING_KEY="${MEETINGBOT_RELEASE_SIGNING_KEY:-}"
RELEASE_PUBLIC_KEY="${MEETINGBOT_RELEASE_PUBLIC_KEY:-}"
CODESIGN_IDENTITY="${MEETINGBOT_CODESIGN_IDENTITY:-}"
NOTARYTOOL_PROFILE="${MEETINGBOT_NOTARYTOOL_PROFILE:-}"

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
NOTARY_ARCHIVE="$DIST_DIR/$APP_NAME-notarization.zip"

validate_security_configuration() {
  [[ "$BUILD_SECURITY_MODE" == "development" || "$BUILD_SECURITY_MODE" == "distribution" ]] || {
    echo "MEETINGBOT_BUILD_SECURITY_MODE 必须是 development 或 distribution" >&2
    exit 1
  }
  [[ -z "$RELEASE_SIGNING_KEY" || -f "$RELEASE_SIGNING_KEY" ]] || {
    echo "发布私钥不存在：$RELEASE_SIGNING_KEY" >&2
    exit 1
  }
  [[ -z "$RELEASE_PUBLIC_KEY" || -f "$RELEASE_PUBLIC_KEY" ]] || {
    echo "发布公钥不存在：$RELEASE_PUBLIC_KEY" >&2
    exit 1
  }
  if [[ -n "$RELEASE_SIGNING_KEY" || -n "$RELEASE_PUBLIC_KEY" ]]; then
    [[ -n "$RELEASE_SIGNING_KEY" && -n "$RELEASE_PUBLIC_KEY" ]] || {
      echo "载荷签名必须同时配置发布私钥和公钥" >&2
      exit 1
    }
  fi
  if [[ "$BUILD_SECURITY_MODE" == "distribution" ]]; then
    [[ -n "$RELEASE_SIGNING_KEY" && -n "$RELEASE_PUBLIC_KEY" ]] || {
      echo "正式构建必须配置 MEETINGBOT_RELEASE_SIGNING_KEY 和 MEETINGBOT_RELEASE_PUBLIC_KEY" >&2
      exit 1
    }
    [[ -n "$CODESIGN_IDENTITY" && "$CODESIGN_IDENTITY" != "-" ]] || {
      echo "正式构建必须配置非 ad-hoc 的 MEETINGBOT_CODESIGN_IDENTITY" >&2
      exit 1
    }
    [[ -n "$NOTARYTOOL_PROFILE" ]] || {
      echo "正式构建必须配置 MEETINGBOT_NOTARYTOOL_PROFILE" >&2
      exit 1
    }
  fi
}

validate_security_configuration
if [[ "$ACTION" == "--security-preflight-only" ]]; then
  echo "$BUILD_SECURITY_MODE"
  exit 0
fi
[[ -z "$ACTION" || "$ACTION" == "--install" ]] || {
  echo "未知参数：$ACTION" >&2
  exit 1
}

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
    <key>MeetingBotBuildSecurityMode</key>
    <string>$BUILD_SECURITY_MODE</string>
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
    "$SOURCE_DIR/PayloadVerifier.swift" \
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
touch "$BOOTSTRAP_PAYLOAD_DIR/.meetingbot-packaged-payload"

if [[ -n "$RELEASE_PUBLIC_KEY" ]]; then
  cp "$RELEASE_PUBLIC_KEY" "$RESOURCES_DIR/release-public-key.pem"
fi

MEETINGBOT_RELEASE_SIGNING_KEY="$RELEASE_SIGNING_KEY" \
python3 "$PROJECT_ROOT/scripts/generate_release_manifest.py" payload \
  --root "$BOOTSTRAP_PAYLOAD_DIR" \
  --output "$BOOTSTRAP_PAYLOAD_DIR/release-manifest.json" \
  --checksums "$BOOTSTRAP_PAYLOAD_DIR/payload-files.sha256" \
  --signature "$BOOTSTRAP_PAYLOAD_DIR/release-manifest.sig" \
  --app-version "$APP_VERSION" \
  --build-number "$BUILD_NUMBER" \
  --payload-version "$PAYLOAD_VERSION" \
  --security-mode "$BUILD_SECURITY_MODE"

if [[ "$BUILD_SECURITY_MODE" == "distribution" ]]; then
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$CODESIGN_IDENTITY" \
    "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  rm -f "$NOTARY_ARCHIVE"
  ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_ARCHIVE"
  xcrun notarytool submit \
    "$NOTARY_ARCHIVE" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
  rm -f "$NOTARY_ARCHIVE"
else
  echo "[build][warning] 正在生成仅供本机开发测试的 ad-hoc 签名 App" >&2
  codesign --force --sign - "$APP_BUNDLE"
fi

echo "$APP_BUNDLE"

if [[ "$ACTION" == "--install" ]]; then
    INSTALL_PATH="/Applications/$APP_NAME.app"
    mkdir -p "$INSTALL_PATH"
    rsync -a --delete "$APP_BUNDLE/" "$INSTALL_PATH/"
    echo "$INSTALL_PATH"
fi
