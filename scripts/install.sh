#!/bin/bash
set -Eeuo pipefail

APP_NAME="会议纪要助手"
SERVICE_LABEL="com.pgui.feishu-meeting-bot"
PROJECT_NAME="meeting-bot"

SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_INSTALL_DIR="$HOME/Library/Application Support/$PROJECT_NAME"
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
INSTALL_OWNERSHIP_MARKER=".meetingbot-install-root"
INSTALL_OWNERSHIP_VALUE="meeting-bot-exclusive-v1"
INSTALL_ROOT_EXCLUSIVE=0
LOG_DIR="${MEETINGBOT_LOG_DIR:-$HOME/Library/Logs/$PROJECT_NAME}"
LEGACY_MIGRATION_MARKER_RELATIVE="runtime/legacy_migration_completed.txt"
LEGACY_INSTALL_DIRS=(
  "$HOME/Library/Application Support/meetin-bot"
  "$HOME/Library/Application Support/feishu-meeting-bot"
  "$HOME/meetin-bot"
  "$HOME/meeting-bot"
  "$HOME/feishu-meeting-bot"
)
MIGRATE_FROM=""
NO_START=0
SKIP_APP_BUILD=0
SKIP_APP_INSTALL=0
DEPENDENCY_MODE="${DEPENDENCY_MODE:-auto}"
PYTHON_BIN="${PYTHON_BIN:-}"
MANAGED_RUNTIME_ROOT="${MANAGED_RUNTIME_ROOT:-$HOME/Library/Application Support/$PROJECT_NAME/runtime}"
MANAGED_PYTHON_BIN=""
UPGRADE_BACKUP_DIR=""
VENV_BACKUP_DIR=""
APP_BACKUP_DIR=""
APP_INSTALL_ATTEMPTED=0
ROLLBACK_READY=0
INSTALL_SUCCEEDED=0
CURRENT_STEP="准备安装"
VERIFY_PAYLOAD_ONLY=0

verify_payload_manifest() {
  local marker manifest checksum_file expected_checksum actual_checksum signature public_key
  local trust_mode manifest_mode embedded_key invalid_entry
  marker="$SOURCE_ROOT/.meetingbot-packaged-payload"
  manifest="$SOURCE_ROOT/release-manifest.json"
  checksum_file="$SOURCE_ROOT/payload-files.sha256"
  signature="$SOURCE_ROOT/release-manifest.sig"
  public_key="${MEETINGBOT_RELEASE_PUBLIC_KEY_PATH:-}"
  trust_mode="${MEETINGBOT_PAYLOAD_TRUST_MODE:-development}"
  embedded_key="$SOURCE_ROOT/release-public-key.pem"

  [[ -f "$marker" ]] || {
    info "源代码安装：未启用打包载荷校验"
    return 0
  }
  [[ "$trust_mode" == "development" || "$trust_mode" == "distribution" ]] || {
    printf '[install][error] code=PAYLOAD_INTEGRITY_FAILED reason=invalid_trust_mode\n' >&2
    return 1
  }
  [[ -f "$manifest" && -f "$checksum_file" ]] || {
    printf '[install][error] code=PAYLOAD_INTEGRITY_FAILED reason=missing_manifest\n' >&2
    return 1
  }
  [[ ! -e "$embedded_key" ]] || {
    printf '[install][error] code=PAYLOAD_INTEGRITY_FAILED reason=embedded_trust_anchor\n' >&2
    return 1
  }
  manifest_mode="$(sed -nE 's/.*"security_mode": "(development|distribution)".*/\1/p' "$manifest" | head -1)"
  [[ "$manifest_mode" == "$trust_mode" ]] || {
    printf '[install][error] code=PAYLOAD_INTEGRITY_FAILED reason=security_mode_mismatch\n' >&2
    return 1
  }
  expected_checksum="$(sed -nE 's/.*"checksum_file_sha256": "([0-9a-f]{64})".*/\1/p' "$manifest" | head -1)"
  actual_checksum="$(shasum -a 256 "$checksum_file" | awk '{print $1}')"
  [[ -n "$expected_checksum" && "$actual_checksum" == "$expected_checksum" ]] || {
    printf '[install][error] code=PAYLOAD_INTEGRITY_FAILED reason=checksum_manifest_mismatch\n' >&2
    return 1
  }

  if ! (cd "$SOURCE_ROOT" && shasum -a 256 -c "$(basename "$checksum_file")" >/dev/null); then
    printf '[install][error] code=PAYLOAD_INTEGRITY_FAILED reason=file_hash_mismatch\n' >&2
    return 1
  fi

  invalid_entry="$(find "$SOURCE_ROOT" -mindepth 1 ! -type f ! -type d -print -quit 2>/dev/null || true)"
  [[ -z "$invalid_entry" ]] || {
    printf '[install][error] code=PAYLOAD_INTEGRITY_FAILED reason=unsupported_file_type\n' >&2
    return 1
  }
  if ! diff -u \
    <(
      awk '
        /^[0-9a-f]{64}  / {
          path = substr($0, 67)
          if (path == "" || path ~ /^\// || path ~ /(^|\/)\.\.(\/|$)/ || path ~ /\\/) {
            exit 2
          }
          print path
          next
        }
        { exit 2 }
      ' "$checksum_file" | LC_ALL=C sort
    ) \
    <(
      cd "$SOURCE_ROOT"
      find . -type f \
        ! -path "./release-manifest.json" \
        ! -path "./payload-files.sha256" \
        ! -path "./release-manifest.sig" \
        -print |
        sed 's#^\./##' |
        LC_ALL=C sort
    ) >/dev/null; then
    printf '[install][error] code=PAYLOAD_INTEGRITY_FAILED reason=file_set_mismatch\n' >&2
    return 1
  fi

  if [[ "$trust_mode" == "distribution" || -f "$signature" || -n "$public_key" ]]; then
    [[ -f "$signature" && -n "$public_key" && -f "$public_key" ]] || {
      printf '[install][error] code=PAYLOAD_INTEGRITY_FAILED reason=incomplete_signature\n' >&2
      return 1
    }
    if ! /usr/bin/openssl dgst -sha256 -verify "$public_key" \
      -signature "$signature" "$manifest" >/dev/null 2>&1; then
      printf '[install][error] code=PAYLOAD_INTEGRITY_FAILED reason=signature_invalid\n' >&2
      return 1
    fi
    info "安装载荷签名与文件完整性校验通过"
  else
    info "开发构建载荷文件完整性校验通过（未附加发布签名）"
  fi
}

usage() {
  cat <<USAGE
用法：bash scripts/install.sh [选项]

选项：
  --install-dir PATH   指定安装目录
  --migrate-from PATH  从旧安装目录迁移用户数据
  --no-start           只安装，不尝试启动后台服务
  --skip-app-build     跳过菜单栏 App 构建
  --skip-app-install   跳过把菜单栏 App 复制到 /Applications
  --dependency-mode M  依赖安装策略：auto、reuse、offline、online、managed-online
  --python-bin PATH    指定 Python 3.12+ 可执行文件
  --verify-payload-only
                       只验证打包载荷，不执行安装
  -h, --help           显示帮助
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir)
        INSTALL_DIR="$2"
        shift 2
        ;;
      --migrate-from)
        MIGRATE_FROM="$2"
        shift 2
        ;;
      --no-start)
        NO_START=1
        shift
        ;;
      --skip-app-build)
        SKIP_APP_BUILD=1
        shift
        ;;
      --skip-app-install)
        SKIP_APP_INSTALL=1
        shift
        ;;
      --dependency-mode)
        DEPENDENCY_MODE="$2"
        shift 2
        ;;
      --python-bin)
        PYTHON_BIN="$2"
        shift 2
        ;;
      --verify-payload-only)
        VERIFY_PAYLOAD_ONLY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        warn "未知参数：$1"
        usage
        exit 1
        ;;
    esac
  done
}

info() {
  printf '[install] %s\n' "$1"
}

warn() {
  printf '[install][warn] %s\n' "$1" >&2
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  warn "安装在第 ${line_no} 行中止，退出码 ${exit_code}（阶段：${CURRENT_STEP}）"
  printf '[install][error] code=INSTALL_FAILED step=%s exit=%s\n' "$CURRENT_STEP" "$exit_code" >&2
  rollback_install || true
  restart_existing_service || true
}

trap 'on_error "$?" "$LINENO"' ERR

create_upgrade_backup() {
  [[ "$SOURCE_ROOT" != "$INSTALL_DIR" && -f "$INSTALL_DIR/bot.py" ]] || return 0
  local stamp
  stamp="$(date +%Y%m%d_%H%M%S)"
  UPGRADE_BACKUP_DIR="$INSTALL_DIR/runtime/upgrade-backups/$stamp"
  info "备份当前运行组件：$UPGRADE_BACKUP_DIR"
  mkdir -p "$UPGRADE_BACKUP_DIR"
  rsync -a \
    --exclude '.env' \
    --exclude '.venv' \
    --exclude 'downloads' \
    --exclude 'sessions' \
    --exclude 'logs' \
    --exclude 'runtime' \
    --exclude 'library' \
    --exclude 'tmp' \
    --exclude 'dist' \
    --exclude 'backups' \
    "$INSTALL_DIR/" "$UPGRADE_BACKUP_DIR/"
  ROLLBACK_READY=1
}

rollback_install() {
  [[ "$INSTALL_SUCCEEDED" -eq 0 ]] || return 0
  if [[ -n "$VENV_BACKUP_DIR" && -d "$VENV_BACKUP_DIR" ]]; then
    warn "正在恢复更新前的 Python 运行环境"
    rm -rf "$INSTALL_DIR/.venv"
    mv "$VENV_BACKUP_DIR" "$INSTALL_DIR/.venv"
  fi
  if [[ "$ROLLBACK_READY" -eq 1 && -d "$UPGRADE_BACKUP_DIR" ]]; then
    warn "正在恢复更新前的运行组件"
    rsync -a --delete \
      --exclude '.env' \
      --exclude '.venv' \
      --exclude 'downloads' \
      --exclude 'sessions' \
      --exclude 'logs' \
      --exclude 'runtime' \
      --exclude 'library' \
      --exclude 'tmp' \
      --exclude 'dist' \
      --exclude 'backups' \
      "$UPGRADE_BACKUP_DIR/" "$INSTALL_DIR/"
    warn "旧版本运行组件已恢复；会议、录音和配置未改动。"
    printf '[install][recovery] restored=%s\n' "$UPGRADE_BACKUP_DIR" >&2
  fi
  if [[ -n "$APP_BACKUP_DIR" && -d "$APP_BACKUP_DIR" ]]; then
    warn "正在恢复更新前的 App"
    rm -rf "$APP_INSTALL_PATH"
    ditto "$APP_BACKUP_DIR" "$APP_INSTALL_PATH"
  elif [[ "$APP_INSTALL_ATTEMPTED" -eq 1 ]]; then
    rm -rf "$APP_INSTALL_PATH"
  fi
}

cleanup_upgrade_backups() {
  [[ -z "$VENV_BACKUP_DIR" || ! -d "$VENV_BACKUP_DIR" ]] || rm -rf "$VENV_BACKUP_DIR"
  [[ -z "$APP_BACKUP_DIR" || ! -d "$APP_BACKUP_DIR" ]] || rm -rf "$APP_BACKUP_DIR"
}

simulate_failure_if_requested() {
  local point="$1"
  if [[ "${MEETINGBOT_INSTALL_TEST_MODE:-0}" == "1" \
    && "${MEETINGBOT_INSTALL_TEST_FAILURE_POINT:-}" == "$point" ]]; then
    warn "安装事务测试：在 ${point} 模拟失败"
    return 97
  fi
}

restart_existing_service() {
  [[ -n "${PLIST_PATH:-}" && -f "$PLIST_PATH" ]] || return 0
  launchctl enable "gui/$(id -u)/$SERVICE_LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$(id -u)/$SERVICE_LABEL" >/dev/null 2>&1 || true
}

require_command() {
  local command_name="$1"
  local message="$2"
  local configured_path="${3:-}"
  if [[ -z "$(resolve_tool_path "$command_name" "$configured_path" || true)" ]]; then
    warn "未找到 ${command_name}：${message}"
    return 1
  fi
  return 0
}

check_codex_cli() {
  local configured_path="${1:-}"
  local resolved
  resolved="$(resolve_tool_path codex "$configured_path" || true)"
  if [[ -z "$resolved" ]]; then
    warn "未找到 codex：请安装并登录 Codex CLI，或在 .env 中设置 CODEX_BIN 绝对路径。"
    return 1
  fi
  if "$resolved" login status >/dev/null 2>&1; then
    info "Codex CLI 已登录：$resolved"
    return 0
  fi
  if "$resolved" --version >/dev/null 2>&1; then
    warn "Codex CLI 已找到但登录状态未通过：${resolved}。请运行 codex login。"
  else
    warn "Codex CLI 无法正常执行：$resolved"
  fi
  return 1
}

check_llm_backend() {
  local provider api_key model
  provider="$(read_env_value LLM_PROVIDER || true)"
  provider="${provider:-codex}"
  provider="$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')"

  case "$provider" in
    codex)
      check_codex_cli "$(read_env_value CODEX_BIN)"
      ;;
    openai)
      api_key="$(read_env_value LLM_API_KEY || true)"
      model="$(read_env_value LLM_MODEL || true)"
      [[ -n "$api_key" ]] || warn "LLM 后端 openai 缺少 LLM_API_KEY"
      [[ -n "$model" ]] || warn "LLM 后端 openai 缺少 LLM_MODEL"
      if [[ -n "$api_key" && -n "$model" ]]; then
        info "LLM 后端配置：openai / $model"
      fi
      ;;
    anthropic)
      api_key="$(read_env_value LLM_API_KEY || true)"
      if [[ -n "$api_key" ]]; then
        info "LLM 后端配置：anthropic"
      else
        warn "LLM 后端 anthropic 缺少 LLM_API_KEY"
      fi
      ;;
    lm-studio|ollama)
      info "LLM 后端配置：${provider}（本地服务运行时检查模型）"
      ;;
    *)
      warn "不支持的 LLM_PROVIDER：$provider"
      return 1
      ;;
  esac
}

read_env_value() {
  local key="$1"
  local env_file="$INSTALL_DIR/.env"
  local value=""
  if [[ -f "$env_file" ]]; then
    value="$(grep -E "^${key}=" "$env_file" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  fi
  if [[ -z "$value" ]]; then
    case "$key" in
      FEISHU_APP_SECRET|HF_TOKEN|LLM_API_KEY)
        value="$(/usr/bin/security find-generic-password \
          -w -s "com.pgui.FeishuMeetingBotMenuBar.credentials" \
          -a "$key" 2>/dev/null || true)"
        ;;
    esac
  fi
  printf '%s\n' "$value"
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
    if [[ "$configured_path" != */* ]]; then
      command_name="$configured_path"
    fi
  fi

  if command -v "$command_name" >/dev/null 2>&1; then
    command -v "$command_name"
    return
  fi

  for candidate in \
    "$HOME/.local/bin/$command_name" \
    "$HOME/bin/$command_name" \
    "$HOME/.volta/bin/$command_name" \
    "$HOME/.bun/bin/$command_name" \
    "$HOME/Library/pnpm/$command_name" \
    "/opt/homebrew/bin/$command_name" \
    "/usr/local/bin/$command_name"; do
    [[ -x "$candidate" ]] && {
      printf '%s\n' "$candidate"
      return
    }
  done

  for candidate in \
    "$HOME"/.nvm/versions/node/*/bin/"$command_name" \
    "$HOME"/.npm/_npx/*/node_modules/.bin/"$command_name"; do
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

copy_project() {
  mkdir -p "$INSTALL_DIR"

  if [[ "$SOURCE_ROOT" == "$INSTALL_DIR" ]]; then
    info "当前目录已是安装目录：$INSTALL_DIR"
    return
  fi

  info "复制项目文件到 $INSTALL_DIR"
  rsync -a \
    --exclude ".env" \
    --exclude ".venv" \
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
    "$SOURCE_ROOT/" "$INSTALL_DIR/"
}

detect_install_root_ownership() {
  if [[ "$INSTALL_DIR" == "$DEFAULT_INSTALL_DIR" ]]; then
    INSTALL_ROOT_EXCLUSIVE=1
    return
  fi
  if [[ "$SOURCE_ROOT" == "$INSTALL_DIR" ]]; then
    INSTALL_ROOT_EXCLUSIVE=0
    return
  fi
  if [[ -f "$INSTALL_DIR/$INSTALL_OWNERSHIP_MARKER" ]] &&
     grep -qxF "$INSTALL_OWNERSHIP_VALUE" "$INSTALL_DIR/$INSTALL_OWNERSHIP_MARKER"; then
    INSTALL_ROOT_EXCLUSIVE=1
    return
  fi
  if [[ ! -e "$INSTALL_DIR" ]]; then
    INSTALL_ROOT_EXCLUSIVE=1
    return
  fi
  if [[ -d "$INSTALL_DIR" ]] && [[ -z "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    INSTALL_ROOT_EXCLUSIVE=1
  fi
}

migrate_legacy_install_if_needed() {
  local source item
  source="$MIGRATE_FROM"
  if [[ -z "$source" && "$INSTALL_DIR" == "$DEFAULT_INSTALL_DIR" && ! -f "$INSTALL_DIR/$LEGACY_MIGRATION_MARKER_RELATIVE" ]]; then
    for item in "${LEGACY_INSTALL_DIRS[@]}"; do
      if [[ -d "$item" && "$item" != "$INSTALL_DIR" ]]; then
        source="$item"
        break
      fi
    done
  fi
  [[ -n "$source" && -d "$source" && "$source" != "$INSTALL_DIR" ]] || return 0

  info "迁移旧安装数据：$source -> $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  for item in .env .venv downloads sessions runtime library tmp latest_session.txt; do
    [[ -e "$source/$item" ]] || continue
    info "迁移 $item"
    rsync -a "$source/$item" "$INSTALL_DIR/"
  done
  if [[ -d "$source/logs" ]]; then
    info "迁移 logs"
    mkdir -p "$LOG_DIR"
    rsync -a "$source/logs/" "$LOG_DIR/" || warn "日志迁移失败，已跳过；这不会影响安装和既有会议数据。"
  fi
  rewrite_legacy_storage_paths "$source"
  mkdir -p "$(dirname "$INSTALL_DIR/$LEGACY_MIGRATION_MARKER_RELATIVE")"
  printf '%s\n' "$source" > "$INSTALL_DIR/$LEGACY_MIGRATION_MARKER_RELATIVE"
}

rewrite_legacy_storage_paths() {
  local source="$1"
  local key value
  [[ -f "$INSTALL_DIR/.env" ]] || return

  for key in RECORDINGS_DIR MEETING_OUTPUT_DIR; do
    value="$(read_env_value "$key")"
    if [[ "$value" == "$source"* ]]; then
      write_env_value "$key" "${value/#$source/$INSTALL_DIR}"
    fi
  done
}

write_env_value() {
  local key="$1"
  local value="$2"
  local env_file="$INSTALL_DIR/.env"
  local tmp_file="$env_file.tmp.$$"
  [[ -f "$env_file" ]] || return

  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) {
        print key "=" value
      }
    }
  ' "$env_file" > "$tmp_file"
  mv "$tmp_file" "$env_file"
  chmod 600 "$env_file"
}

setup_python() {
  local requirements_hash marker_file installed_hash python
  info "准备 Python 运行环境（策略：${DEPENDENCY_MODE}）"
  cd "$INSTALL_DIR"
  requirements_hash="$(shasum -a 256 requirements.txt | awk '{print $1}')"
  marker_file="$INSTALL_DIR/runtime/requirements.sha256"
  installed_hash="$(cat "$marker_file" 2>/dev/null || true)"

  case "$DEPENDENCY_MODE" in
    auto|reuse|offline|online|managed-online)
      ;;
    *)
      warn "未知依赖安装策略：$DEPENDENCY_MODE"
      exit 1
      ;;
  esac

  if venv_is_usable && [[ -z "$installed_hash" || "$installed_hash" == "$requirements_hash" ]]; then
    info "复用现有 Python 虚拟环境：$INSTALL_DIR/.venv"
    mkdir -p "$(dirname "$marker_file")"
    printf '%s\n' "$requirements_hash" > "$marker_file"
    return
  fi

  if [[ ! -d ".venv" && "$DEPENDENCY_MODE" != "online" && "$DEPENDENCY_MODE" != "managed-online" ]]; then
    if reuse_historical_venv; then
      info "已复用历史虚拟环境，跳过依赖重新安装"
      mkdir -p "$(dirname "$marker_file")"
      printf '%s\n' "$requirements_hash" > "$marker_file"
      return
    fi
  fi

  if [[ "$DEPENDENCY_MODE" == "reuse" ]]; then
    warn "现有 Python 虚拟环境不可用，且当前策略要求只复用"
    exit 1
  fi

  if [[ "$DEPENDENCY_MODE" == "managed-online" ]]; then
    ensure_managed_python
    python="$MANAGED_PYTHON_BIN"
  else
    python="$(resolve_python_bin)"
  fi
  if [[ -z "$python" ]]; then
    warn "未找到 Python 3.12 或更高版本"
    exit 1
  fi
  info "已选择 Python 解释器：$python"

  if [[ -d ".venv" ]]; then
    VENV_BACKUP_DIR="$INSTALL_DIR/.venv.before-install.$$"
    info "暂存旧 Python 运行环境，安装失败时自动恢复"
    mv .venv "$VENV_BACKUP_DIR"
    simulate_failure_if_requested "after-venv-backup"
  fi
  "$python" -m venv .venv

  .venv/bin/python -m pip install --upgrade pip

  if [[ "$DEPENDENCY_MODE" == "offline" || ( "$DEPENDENCY_MODE" == "auto" && -d "wheelhouse" ) ]]; then
    if [[ ! -d "wheelhouse" ]]; then
      warn "未找到 wheelhouse，无法执行离线安装"
      exit 1
    fi

    info "使用 wheelhouse 离线安装依赖"
    .venv/bin/python -m pip install --no-index --find-links wheelhouse -r requirements.txt
  else
    info "在线安装依赖"
    .venv/bin/python -m pip install -r requirements.txt
  fi

  if ! venv_is_usable; then
    warn "Python 虚拟环境安装完成，但核心依赖校验未通过"
    exit 1
  fi
  mkdir -p "$(dirname "$marker_file")"
  printf '%s\n' "$requirements_hash" > "$marker_file"
}

resolve_python_bin() {
  local candidate version major minor best_python best_major best_minor
  if [[ -n "$PYTHON_BIN" ]]; then
    [[ -x "$PYTHON_BIN" ]] || {
      warn "指定的 Python 不可执行：$PYTHON_BIN"
      return
    }
    version="$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || {
      warn "无法读取指定 Python 的版本：$PYTHON_BIN"
      return
    }
    major="${version%%.*}"
    minor="${version##*.}"
    if (( major > 3 || (major == 3 && minor >= 12) )); then
      printf '%s\n' "$PYTHON_BIN"
      return
    fi
    warn "指定的 Python ${version} 不满足要求：$PYTHON_BIN"
    return
  fi

  best_python=""
  best_major=0
  best_minor=0

  while IFS= read -r candidate; do
    [[ -x "$candidate" ]] || continue
    version="$("$candidate" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || continue
    major="${version%%.*}"
    minor="${version##*.}"
    if (( major < 3 || (major == 3 && minor < 12) )); then
      continue
    fi
    if (( major > best_major || (major == best_major && minor > best_minor) )); then
      best_python="$candidate"
      best_major="$major"
      best_minor="$minor"
    fi
  done < <(python_candidates | awk '!seen[$0]++')

  [[ -n "$best_python" ]] && printf '%s\n' "$best_python"
}

ensure_managed_python() {
  local uv_root uv_bin uv_python_dir uv_cache_dir installer_script managed_python
  local uv_version uv_installer_sha256 actual_sha256 installed_uv_version
  uv_version="0.11.28"
  uv_installer_sha256="b7b3fe80cad1142a2a5794050b7db7b3291d1bac1423b0732571dd9366e8ca8b"
  uv_root="$MANAGED_RUNTIME_ROOT/uv"
  uv_bin="$uv_root/bin/uv"
  uv_python_dir="$MANAGED_RUNTIME_ROOT/python"
  uv_cache_dir="$MANAGED_RUNTIME_ROOT/cache"
  installer_script="$MANAGED_RUNTIME_ROOT/tmp/uv-install.sh"

  info "准备独立 Python 运行时"
  mkdir -p "$uv_root/bin" "$uv_python_dir" "$uv_cache_dir" "$MANAGED_RUNTIME_ROOT/tmp"

  installed_uv_version="$("$uv_bin" --version 2>/dev/null | awk '{print $2}' || true)"
  if [[ ! -x "$uv_bin" || "$installed_uv_version" != "$uv_version" ]]; then
    require_command curl "请联网后重试，安装程序需要下载独立 Python 运行时。"
    info "下载固定版本 uv ${uv_version} 运行时管理器"
    curl -fsSL --proto '=https' --tlsv1.2 \
      "https://astral.sh/uv/${uv_version}/install.sh" -o "$installer_script"
    actual_sha256="$(shasum -a 256 "$installer_script" | awk '{print $1}')"
    if [[ "$actual_sha256" != "$uv_installer_sha256" ]]; then
      rm -f "$installer_script"
      warn "uv 安装脚本校验失败，已停止安装；请检查网络或重新下载发行包。"
      exit 1
    fi
    UV_UNMANAGED_INSTALL="$uv_root/bin" \
      UV_NO_MODIFY_PATH=1 \
      sh "$installer_script"
    rm -f "$installer_script"
    installed_uv_version="$("$uv_bin" --version 2>/dev/null | awk '{print $2}' || true)"
    [[ "$installed_uv_version" == "$uv_version" ]] || {
      warn "uv 安装完成但版本校验失败：${installed_uv_version:-unknown}"
      exit 1
    }
  fi

  info "下载独立 Python 3.12 运行时"
  UV_PYTHON_INSTALL_DIR="$uv_python_dir" \
    UV_CACHE_DIR="$uv_cache_dir" \
    "$uv_bin" python install 3.12

  managed_python="$(
    UV_PYTHON_INSTALL_DIR="$uv_python_dir" \
      UV_CACHE_DIR="$uv_cache_dir" \
      "$uv_bin" python find 3.12
  )"
  [[ -x "$managed_python" ]] || {
    warn "独立 Python 运行时安装完成，但未能定位解释器"
    exit 1
  }

  MANAGED_PYTHON_BIN="$managed_python"
}

python_candidates() {
  local candidate resolved

  if [[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]]; then
    printf '%s\n' "$PYTHON_BIN"
  fi

  for candidate in \
    /opt/homebrew/bin/python3.13 \
    /opt/homebrew/bin/python3.12 \
    /opt/anaconda3/bin/python3.13 \
    /opt/anaconda3/bin/python3.12 \
    /usr/local/bin/python3.13 \
    /usr/local/bin/python3.12; do
    [[ -x "$candidate" ]] && printf '%s\n' "$candidate"
  done

  local venv_root
  for venv_root in "$INSTALL_DIR" "${LEGACY_INSTALL_DIRS[@]}"; do
    candidate="$venv_root/.venv/bin/python"
    [[ -x "$candidate" ]] && printf '%s\n' "$candidate"
  done

  local pyenv_root="${PYENV_ROOT:-$HOME/.pyenv}"
  if [[ -d "$pyenv_root/versions" ]]; then
    for candidate in "$pyenv_root"/versions/*/bin/python3; do
      [[ -x "$candidate" ]] && printf '%s\n' "$candidate"
    done
  fi

  for candidate in /Library/Frameworks/Python.framework/Versions/*/bin/python3; do
    [[ -x "$candidate" ]] && printf '%s\n' "$candidate"
  done

  if [[ -x "/bin/zsh" ]]; then
    while IFS= read -r resolved; do
      [[ "$resolved" == /* && -x "$resolved" ]] && printf '%s\n' "$resolved"
    done < <(
      /bin/zsh -lic '
        for candidate in python3.13 python3.12 python3; do
          command -v "$candidate" 2>/dev/null || true
        done
      ' 2>/dev/null || true
    )
  fi

  for candidate in python3.13 python3.12 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
    fi
  done
}

venv_python_is_usable() {
  local python_path="$1"
  [[ -x "$python_path" ]] || return 1
  "$python_path" - <<'PY' >/dev/null 2>&1
import sys
if sys.version_info < (3, 12):
    raise SystemExit(1)
import importlib
modules = [
    "faster_whisper",
    "lark_oapi",
    "opencc",
    "pyannote.audio",
    "docx",
    "dotenv",
    "requests",
    "soundfile",
    "torch",
]
for module in modules:
    importlib.import_module(module)
PY
}

venv_is_usable() {
  venv_python_is_usable ".venv/bin/python"
}

reuse_historical_venv() {
  local legacy source_venv
  for legacy in "${LEGACY_INSTALL_DIRS[@]}"; do
    source_venv="$legacy/.venv"
    [[ -d "$source_venv" && "$source_venv" != "$INSTALL_DIR/.venv" ]] || continue
    if venv_python_is_usable "$source_venv/bin/python"; then
      info "发现可复用的历史虚拟环境：$source_venv"
      rm -rf "$INSTALL_DIR/.venv"
      rsync -a "$source_venv/" "$INSTALL_DIR/.venv/"
      if venv_is_usable; then
        return 0
      fi
      warn "历史虚拟环境复制后核心依赖校验未通过，将改为重新安装依赖"
      rm -rf "$INSTALL_DIR/.venv"
      return 1
    fi
  done
  return 1
}

setup_env() {
  cd "$INSTALL_DIR"

  if [[ ! -f ".env" ]]; then
    cp .env.example .env
    warn "已生成基础配置。请打开 App 完成飞书、Hugging Face 和纪要后端设置；敏感凭据将保存在系统钥匙串。"
  else
    info ".env 已存在，保留现有配置"
  fi
  chmod 600 .env
}

prepare_runtime_dirs() {
  local recordings_dir meeting_output_dir
  recordings_dir="$(resolve_storage_dir "$(read_env_value RECORDINGS_DIR)" "$INSTALL_DIR/downloads")"
  meeting_output_dir="$(resolve_storage_dir "$(read_env_value MEETING_OUTPUT_DIR)" "$INSTALL_DIR/sessions")"

  mkdir -p "$recordings_dir" \
    "$meeting_output_dir" \
    "$LOG_DIR" \
    "$INSTALL_DIR/runtime/events" \
    "$INSTALL_DIR/library" \
    "$INSTALL_DIR/tmp"
}

mark_install_root_owned() {
  if [[ "$INSTALL_ROOT_EXCLUSIVE" -ne 1 ]]; then
    warn "安装目录原本包含其他内容，不标记为应用专用目录；卸载时将保留该目录。"
    return
  fi
  printf '%s\n' "$INSTALL_OWNERSHIP_VALUE" > "$INSTALL_DIR/$INSTALL_OWNERSHIP_MARKER"
  chmod 600 "$INSTALL_DIR/$INSTALL_OWNERSHIP_MARKER"
}

resolve_storage_dir() {
  local raw_value="$1"
  local default_value="$2"
  if [[ -z "$raw_value" ]]; then
    printf '%s\n' "$default_value"
  elif [[ "$raw_value" == "~"* ]]; then
    printf '%s\n' "${raw_value/#\~/$HOME}"
  elif [[ "$raw_value" == /* ]]; then
    printf '%s\n' "$raw_value"
  else
    printf '%s\n' "$INSTALL_DIR/$raw_value"
  fi
}

build_or_install_app() {
  cd "$INSTALL_DIR"

  if [[ "$SKIP_APP_BUILD" -eq 1 ]]; then
    info "已跳过菜单栏 App 构建"
  elif command -v xcrun >/dev/null 2>&1; then
    info "构建菜单栏 App"
    MEETINGBOT_BUILD_SECURITY_MODE="${MEETINGBOT_BUILD_SECURITY_MODE:-development}" \
      bash MeetingBotMenuBarApp/build_release_app.sh
  elif [[ ! -d "$APP_SOURCE" ]]; then
    warn "未找到 xcrun，且发行包中没有 ${APP_SOURCE}，菜单栏 App 暂不能安装。"
    return
  fi

  if [[ "$SKIP_APP_INSTALL" -eq 1 ]]; then
    info "已跳过菜单栏 App 安装"
  elif [[ -d "$APP_SOURCE" ]]; then
    info "安装菜单栏 App 到 $APP_INSTALL_PATH"
    if [[ -d "$APP_INSTALL_PATH" ]]; then
      APP_BACKUP_DIR="${TMPDIR:-/tmp}/meeting-bot-app-before-install.$$"
      ditto "$APP_INSTALL_PATH" "$APP_BACKUP_DIR"
      rm -rf "$APP_INSTALL_PATH"
    fi
    APP_INSTALL_ATTEMPTED=1
    if ditto "$APP_SOURCE" "$APP_INSTALL_PATH"; then
      info "菜单栏 App 已安装"
      if [[ -d "$LEGACY_APP_INSTALL_PATH" && "$LEGACY_APP_INSTALL_PATH" != "$APP_INSTALL_PATH" ]]; then
        rm -rf "$LEGACY_APP_INSTALL_PATH" 2>/dev/null ||
          warn "旧应用仍保留在 ${LEGACY_APP_INSTALL_PATH}，可手动删除。"
      fi
    else
      warn "无法写入 /Applications，正在恢复此前版本。"
      return 1
    fi
  fi
}

env_is_ready() {
  [[ -f "$INSTALL_DIR/.env" ]] || return 1

  local app_id app_secret hf_token
  app_id="$(read_env_value FEISHU_APP_ID)"
  app_secret="$(read_env_value FEISHU_APP_SECRET)"
  hf_token="$(read_env_value HF_TOKEN)"

  [[ -n "$app_id" && "$app_id" != cli_xxxxxxxxxxxxxxxx ]] &&
    [[ -n "$app_secret" && "$app_secret" != replace_with_* ]] &&
    [[ -n "$hf_token" && "$hf_token" != hf_replace_* ]]
}

write_launch_agent() {
  info "写入 LaunchAgent：$PLIST_PATH"
  mkdir -p "$LAUNCH_AGENTS_DIR"

  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$SERVICE_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$INSTALL_DIR/start_bot.sh</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$INSTALL_DIR</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$LOG_DIR/bot_stdout.log</string>

    <key>StandardErrorPath</key>
    <string>$LOG_DIR/bot_stderr.log</string>
</dict>
</plist>
PLIST

  plutil -lint "$PLIST_PATH" >/dev/null
}

load_launch_agent() {
  if [[ "$NO_START" -eq 1 ]]; then
    info "已按 --no-start 跳过后台服务启动"
    return
  fi

  if ! env_is_ready; then
    warn "核心配置尚未填完整，已跳过后台服务启动。"
    warn "在 App 中完成设置后，可点击“启动”继续。"
    return
  fi

  info "启用开机启动"
  launchctl enable "gui/$(id -u)/$SERVICE_LABEL" 2>/dev/null || true

  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/tmp/feishu-meeting-bot-bootstrap.err; then
    info "后台服务已加载"
  else
    warn "LaunchAgent 加载失败。错误如下："
    sed 's/^/[launchctl] /' /tmp/feishu-meeting-bot-bootstrap.err >&2 || true
    warn "可在填写 .env 后通过菜单栏 App 点击“启动”，或运行：launchctl bootstrap gui/$(id -u) $PLIST_PATH"
  fi
}

print_checks() {
  local allow_managed_python_install=0
  if [[ "$DEPENDENCY_MODE" == "managed-online" ]]; then
    allow_managed_python_install=1
  fi
  PYTHON_BIN="$PYTHON_BIN" \
    INSTALL_DIR="$INSTALL_DIR" \
    PROJECT_ROOT="$INSTALL_DIR" \
    ENV_FILE="$INSTALL_DIR/.env" \
    ALLOW_MANAGED_PYTHON_INSTALL="$allow_managed_python_install" \
    bash "$SOURCE_ROOT/scripts/preflight.sh" || exit 1
  require_command ffmpeg "请安装 ffmpeg，例如：brew install ffmpeg。" "$(read_env_value FFMPEG_BIN)" || true
  if [[ -z "$(resolve_tool_path soffice "" || true)" ]] &&
    [[ ! -x "/Applications/LibreOffice.app/Contents/MacOS/soffice" ]] &&
    [[ ! -x "$HOME/Applications/LibreOffice.app/Contents/MacOS/soffice" ]]; then
    warn "未找到 LibreOffice：请安装 LibreOffice，用于 DOCX 转 PDF。"
  fi
  check_llm_backend || true
}

main() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "当前安装脚本面向 macOS。"
  fi

  parse_args "$@"
  detect_install_root_ownership

  LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
  PLIST_PATH="$LAUNCH_AGENTS_DIR/$SERVICE_LABEL.plist"
  APP_SOURCE="$INSTALL_DIR/dist/$APP_NAME.app"
  APP_INSTALL_PATH="${MEETINGBOT_APP_INSTALL_PATH:-/Applications/$APP_NAME.app}"
  LEGACY_APP_INSTALL_PATH="${MEETINGBOT_LEGACY_APP_INSTALL_PATH:-/Applications/Feishu Meeting Bot.app}"

  CURRENT_STEP="校验安装载荷"
  verify_payload_manifest
  if [[ "$VERIFY_PAYLOAD_ONLY" -eq 1 ]]; then
    INSTALL_SUCCEEDED=1
    info "安装载荷验证完成"
    return 0
  fi
  CURRENT_STEP="安装前检查"
  print_checks
  CURRENT_STEP="备份当前版本"
  create_upgrade_backup
  CURRENT_STEP="迁移旧版数据"
  migrate_legacy_install_if_needed
  CURRENT_STEP="部署运行组件"
  copy_project
  simulate_failure_if_requested "after-project-copy"
  CURRENT_STEP="准备 Python 环境"
  setup_python
  CURRENT_STEP="保护本地配置"
  setup_env
  CURRENT_STEP="准备数据目录"
  prepare_runtime_dirs
  CURRENT_STEP="安装应用"
  build_or_install_app
  simulate_failure_if_requested "after-app-install"
  CURRENT_STEP="配置后台服务"
  write_launch_agent
  CURRENT_STEP="启动后台服务"
  load_launch_agent
  mark_install_root_owned
  INSTALL_SUCCEEDED=1
  cleanup_upgrade_backups

  info "安装流程完成。下一步："
  info "1. 打开 App 完成飞书和 Hugging Face 配置；敏感凭据会存入系统钥匙串。"
  info "2. 确认纪要生成后端可用；默认 Codex 后端需完成 Codex CLI 登录。"
  info "3. 运行 bash $INSTALL_DIR/scripts/doctor.sh，确认环境通过。"
  info "4. 打开 ${APP_INSTALL_PATH}，或直接运行 ${INSTALL_DIR}/dist/${APP_NAME}.app。"
}

if [[ "${MEETINGBOT_INSTALL_LIBRARY_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
