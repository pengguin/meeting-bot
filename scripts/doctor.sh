#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
PLIST_PATH="$HOME/Library/LaunchAgents/com.pgui.feishu-meeting-bot.plist"
FAILURES=0

pass() {
  printf '[通过] %s\n' "$1"
}

fail() {
  printf '[失败] %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

check_command() {
  local command_name="$1"
  local label="$2"
  local configured_path="${3:-}"

  if [[ -n "$(resolve_tool_path "$command_name" "$configured_path" || true)" ]]; then
    pass "$label"
  else
    fail "$label 未找到"
  fi
}

check_codex_cli() {
  local configured_path="${1:-}"
  local resolved
  resolved="$(resolve_tool_path codex "$configured_path" || true)"
  if [[ -z "$resolved" ]]; then
    fail "Codex CLI 未找到"
    return
  fi
  if "$resolved" login status >/dev/null 2>&1; then
    pass "Codex CLI 已登录"
  else
    fail "Codex CLI 未登录或校验失败：$resolved"
  fi
}

resolve_tool_path() {
  local command_name="$1"
  local configured_path="${2:-}"
  local candidate resolved

  if [[ -n "$configured_path" ]]; then
    if [[ "$configured_path" == */* && -x "$configured_path" ]]; then
      printf '%s\n' "$configured_path"
      return
    fi
    command_name="$configured_path"
  fi

  if command -v "$command_name" >/dev/null 2>&1; then
    command -v "$command_name"
    return
  fi

  for candidate in "/opt/homebrew/bin/$command_name" "/usr/local/bin/$command_name"; do
    [[ -x "$candidate" ]] && {
      printf '%s\n' "$candidate"
      return
    }
  done

  if [[ -x "/bin/zsh" ]]; then
    resolved="$(
      /bin/zsh -lic "command -v '$command_name' 2>/dev/null || true" 2>/dev/null || true
    )"
    if [[ "$resolved" == /* && -x "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return
    fi
  fi
}

read_env_value() {
  local key="$1"
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

check_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    fail ".env 不存在"
    return
  fi

  local app_id app_secret hf_token
  app_id="$(read_env_value FEISHU_APP_ID)"
  app_secret="$(read_env_value FEISHU_APP_SECRET)"
  hf_token="$(read_env_value HF_TOKEN)"

  if [[ -n "$app_id" && "$app_id" != cli_xxxxxxxxxxxxxxxx ]]; then
    pass "FEISHU_APP_ID 已配置"
  else
    fail "FEISHU_APP_ID 未配置"
  fi

  if [[ -n "$app_secret" && "$app_secret" != replace_with_* ]]; then
    pass "FEISHU_APP_SECRET 已配置"
  else
    fail "FEISHU_APP_SECRET 未配置"
  fi

  if [[ -n "$hf_token" && "$hf_token" != hf_replace_* ]]; then
    pass "HF_TOKEN 已配置"
  else
    fail "HF_TOKEN 未配置"
  fi
}

check_paths() {
  [[ -x "$PROJECT_ROOT/.venv/bin/python" ]] &&
    pass "Python 虚拟环境存在" ||
    fail "Python 虚拟环境不存在"

  [[ -f "$PROJECT_ROOT/start_bot.sh" ]] &&
    pass "启动脚本存在" ||
    fail "启动脚本不存在"

  [[ -f "$PLIST_PATH" ]] &&
    pass "LaunchAgent 配置存在" ||
    fail "LaunchAgent 配置不存在"
}

check_libo() {
  if [[ -n "$(resolve_tool_path soffice || true)" ]] ||
    [[ -x "/Applications/LibreOffice.app/Contents/MacOS/soffice" ]]; then
    pass "LibreOffice 可用"
  else
    fail "LibreOffice 未找到"
  fi
}

main() {
  printf '会议纪要助手 自检\n'
  printf '项目目录：%s\n\n' "$PROJECT_ROOT"

  INSTALL_DIR="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" ENV_FILE="$ENV_FILE" bash "$PROJECT_ROOT/scripts/preflight.sh" || true
  printf '\n'
  check_paths
  check_command ffmpeg "ffmpeg 可用" "$(read_env_value FFMPEG_BIN)"
  check_codex_cli "$(read_env_value CODEX_BIN)"
  check_libo
  check_env

  printf '\n'
  if [[ "$FAILURES" -eq 0 ]]; then
    pass "自检完成"
  else
    fail "自检完成，仍有 $FAILURES 项需要处理"
    exit 1
  fi
}

main "$@"
