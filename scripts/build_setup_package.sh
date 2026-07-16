#!/bin/bash
set -euo pipefail

APP_NAME="会议纪要助手"
VERSION="0.4.0"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_ROOT="$PROJECT_ROOT/dist/setup"
DMG_STAGING="$SETUP_ROOT/dmg"
DMG_PATH="$PROJECT_ROOT/dist/会议纪要助手 ${VERSION} 安装盘.dmg"
THREAD_HANDOFF_PATH="$PROJECT_ROOT/dist/线程交接汇总 ${VERSION}.md"
RW_DMG_PATH="$SETUP_ROOT/会议纪要助手 ${VERSION}.rw.dmg"
MOUNT_POINT="/Volumes/会议纪要助手 ${VERSION}"
DMG_RENDERER="$SETUP_ROOT/render_dmg_background"
SWIFT_MODULE_CACHE_DIR="/private/tmp/meetingbot-setup-swift-module-cache"

cd "$PROJECT_ROOT"

echo "[setup] 构建可拖拽安装的 App"
bash MeetingBotMenuBarApp/build_release_app.sh >/dev/null

echo "[setup] 构建 dmg"
rm -rf "$SETUP_ROOT"
mkdir -p "$DMG_STAGING/.background" "$DMG_STAGING/说明文档"
ditto "$PROJECT_ROOT/dist/$APP_NAME.app" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"
cp "$PROJECT_ROOT/docs/SETUP_GUIDE.html" "$DMG_STAGING/说明文档/安装与升级说明.html"
cp "$PROJECT_ROOT/docs/SOFTWARE_GUIDE.html" "$DMG_STAGING/说明文档/使用说明.html"
cp "$PROJECT_ROOT/docs/CHANGELOG.md" "$DMG_STAGING/说明文档/更新记录.md"
mkdir -p "$SWIFT_MODULE_CACHE_DIR"
xcrun swiftc \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$SWIFT_MODULE_CACHE_DIR" \
  "$PROJECT_ROOT/scripts/render_dmg_background.swift" \
  -o "$DMG_RENDERER"
"$DMG_RENDERER" "$DMG_STAGING/.background/background.png"

rm -f "$DMG_PATH" "$RW_DMG_PATH"
hdiutil create \
  -volname "会议纪要助手 ${VERSION}" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDRW \
  "$RW_DMG_PATH" >/dev/null

hdiutil attach "$RW_DMG_PATH" -readwrite -noverify -noautoopen >/dev/null

osascript <<EOF
tell application "Finder"
    tell disk "会议纪要助手 ${VERSION}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {120, 120, 760, 560}
        set arrangement of icon view options of container window to not arranged
        set icon size of icon view options of container window to 128
        set background picture of icon view options of container window to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {160, 210}
        set position of item "Applications" of container window to {480, 210}
        set position of item "说明文档" of container window to {320, 320}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
EOF

sync
hdiutil detach "$MOUNT_POINT" >/dev/null
hdiutil convert \
  "$RW_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" >/dev/null

cp "$PROJECT_ROOT/docs/THREAD_HANDOFF_SUMMARY.md" "$THREAD_HANDOFF_PATH"
echo "$DMG_PATH"
echo "$THREAD_HANDOFF_PATH"
