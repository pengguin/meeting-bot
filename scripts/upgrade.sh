#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Library/Application Support/meeting-bot}"
LEGACY_INSTALL_DIRS=(
  "$HOME/Library/Application Support/meetin-bot"
  "$HOME/Library/Application Support/feishu-meeting-bot"
  "$HOME/meetin-bot"
  "$HOME/meeting-bot"
  "$HOME/feishu-meeting-bot"
)
SERVICE_LABEL="com.pgui.feishu-meeting-bot"
PLIST_PATH="$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist"
TARGET_VERSION="0.6.0"

installed_version() {
  local version_file guide
  version_file="$SOURCE_INSTALL_DIR/runtime/installed_app_version.txt"
  if [[ -f "$version_file" ]]; then
    head -n 1 "$version_file"
    return
  fi

  guide="$SOURCE_INSTALL_DIR/docs/SOFTWARE_GUIDE.md"
  if [[ -f "$guide" ]]; then
    sed -n '1s/.* \([0-9][0-9.]*\) 使用说明$/\1/p' "$guide"
  fi
}

SOURCE_INSTALL_DIR="$INSTALL_DIR"
MIGRATE_ARGS=()
if [[ ! -d "$INSTALL_DIR" ]]; then
  for legacy_install_dir in "${LEGACY_INSTALL_DIRS[@]}"; do
    if [[ -d "$legacy_install_dir" ]]; then
      SOURCE_INSTALL_DIR="$legacy_install_dir"
      MIGRATE_ARGS=(--migrate-from "$legacy_install_dir")
      break
    fi
  done
fi

echo "[upgrade] 使用新版文件更新：$INSTALL_DIR"
echo "[upgrade] 保留 .env、已配置保存位置、sessions、downloads、runtime、library、本地模板和独立日志目录。"

if [[ ! -d "$SOURCE_INSTALL_DIR" ]]; then
  echo "[upgrade][error] 未检测到现有安装目录：$SOURCE_INSTALL_DIR" >&2
  echo "[upgrade][error] 若这是首次安装，请改用完整安装包。" >&2
  exit 1
fi

CURRENT_VERSION="$(installed_version || true)"
if [[ -n "$CURRENT_VERSION" ]]; then
  echo "[upgrade] 检测到当前版本：$CURRENT_VERSION"
else
  echo "[upgrade] 未能识别当前版本，将继续执行更新。"
fi
echo "[upgrade] 目标版本：$TARGET_VERSION"

if [[ -f "$PLIST_PATH" ]]; then
  echo "[upgrade] 暂停后台服务，避免更新过程中读取旧文件。"
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
fi

bash "$PROJECT_ROOT/scripts/install.sh" --install-dir "$INSTALL_DIR" "${MIGRATE_ARGS[@]}"

echo "[upgrade] 升级完成。"
