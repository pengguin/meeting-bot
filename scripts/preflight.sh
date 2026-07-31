#!/bin/bash
set -euo pipefail

MIN_MACOS_MAJOR=14
MIN_MEMORY_GB=8
RECOMMENDED_MEMORY_GB=16
MIN_DISK_GB=8
RECOMMENDED_DISK_GB=12
ALLOW_MANAGED_PYTHON_INSTALL="${ALLOW_MANAGED_PYTHON_INSTALL:-0}"

FAILURES=0
WARNINGS=0
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"
LEGACY_INSTALL_DIRS=(
  "$HOME/Library/Application Support/meetin-bot"
  "$HOME/Library/Application Support/feishu-meeting-bot"
  "$HOME/meetin-bot"
  "$HOME/meeting-bot"
  "$HOME/feishu-meeting-bot"
)

pass() {
  printf '[通过] %s\n' "$1"
}

warn() {
  printf '[警告] %s\n' "$1"
  WARNINGS=$((WARNINGS + 1))
}

fail() {
  printf '[失败] %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

read_env_value() {
  local key="$1"
  local value=""
  if [[ -f "$ENV_FILE" ]]; then
    value="$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
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

python_candidates() {
  local candidate resolved

  if [[ -n "${PYTHON_BIN:-}" && -x "${PYTHON_BIN:-}" ]]; then
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
  for venv_root in "${INSTALL_DIR:-$PROJECT_ROOT}" "$PROJECT_ROOT" "${LEGACY_INSTALL_DIRS[@]}"; do
    candidate="$venv_root/.venv/bin/python"
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

best_python_candidate() {
  local candidate version major minor best_python best_major best_minor
  if [[ -n "${PYTHON_BIN:-}" ]]; then
    [[ -x "$PYTHON_BIN" ]] || return
    version="$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || return
    major="${version%%.*}"
    minor="${version##*.}"
    if (( major > 3 || (major == 3 && minor >= 12) )); then
      printf '%s\n' "$PYTHON_BIN"
    fi
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
    if (( major > best_major || (major == best_major && minor > best_minor) )); then
      best_python="$candidate"
      best_major="$major"
      best_minor="$minor"
    fi
  done < <(python_candidates | awk '!seen[$0]++')

  [[ -n "$best_python" ]] && printf '%s\n' "$best_python"
}

check_macos() {
  local version major
  version="$(sw_vers -productVersion)"
  major="${version%%.*}"
  if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= MIN_MACOS_MAJOR )); then
    pass "macOS $version"
  else
    fail "macOS ${version}；需要 macOS ${MIN_MACOS_MAJOR} 或更高版本"
  fi
}

check_architecture() {
  local arch arm64_capable
  arch="$(uname -m)"
  arm64_capable="$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)"
  if [[ "$arch" == "arm64" || "$arm64_capable" == "1" ]]; then
    pass "Apple Silicon 芯片"
  else
    fail "当前芯片架构为 ${arch}；当前发行包仅支持 Apple Silicon"
  fi
}

check_memory() {
  local bytes gb hostinfo_gb
  bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
  if [[ -z "$bytes" ]]; then
    hostinfo_gb="$(
      /usr/bin/hostinfo 2>/dev/null |
        awk '/Primary memory available:/ {printf "%d", $4; exit}' || true
    )"
    if [[ "$hostinfo_gb" =~ ^[0-9]+$ ]]; then
      gb="$hostinfo_gb"
    else
      warn "无法读取物理内存；建议至少 ${RECOMMENDED_MEMORY_GB}GB"
      return
    fi
  else
    gb=$(( bytes / 1024 / 1024 / 1024 ))
  fi
  if (( gb < MIN_MEMORY_GB )); then
    fail "物理内存约 ${gb}GB；至少需要 ${MIN_MEMORY_GB}GB"
  elif (( gb < RECOMMENDED_MEMORY_GB )); then
    warn "物理内存约 ${gb}GB；可安装，但建议 ${RECOMMENDED_MEMORY_GB}GB 或更高"
  else
    pass "物理内存约 ${gb}GB"
  fi
}

check_disk() {
  local target available_kb available_gb
  target="${INSTALL_DIR:-$HOME}"
  while [[ ! -e "$target" && "$target" != "/" ]]; do
    target="$(dirname "$target")"
  done
  available_kb="$(df -Pk "$target" | awk 'NR==2 {print $4}')"
  if [[ -z "$available_kb" ]]; then
    warn "无法读取剩余磁盘空间"
    return
  fi

  available_gb=$(( available_kb / 1024 / 1024 ))
  if (( available_gb < MIN_DISK_GB )); then
    fail "可用磁盘空间约 ${available_gb}GB；至少需要 ${MIN_DISK_GB}GB"
  elif (( available_gb < RECOMMENDED_DISK_GB )); then
    warn "可用磁盘空间约 ${available_gb}GB；建议预留 ${RECOMMENDED_DISK_GB}GB 或更高"
  else
    pass "可用磁盘空间约 ${available_gb}GB"
  fi
}

check_python() {
  local python version major minor
  if [[ -n "${PYTHON_BIN:-}" ]]; then
    if [[ ! -x "$PYTHON_BIN" ]]; then
      fail "指定的 Python 不可执行：$PYTHON_BIN"
      return
    fi

    version="$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")' 2>/dev/null || true)"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      fail "无法读取指定 Python 的版本：$PYTHON_BIN"
      return
    fi

    major="${version%%.*}"
    minor="$(printf '%s' "$version" | cut -d. -f2)"
    if (( major > 3 || (major == 3 && minor >= 12) )); then
      pass "Python ${version}：$PYTHON_BIN"
    else
      fail "指定的 Python ${version} 不满足要求：$PYTHON_BIN"
    fi
    return
  fi

  python="$(best_python_candidate || true)"
  if [[ -z "$python" ]]; then
    if [[ "$ALLOW_MANAGED_PYTHON_INSTALL" == "1" ]]; then
      warn "未找到 Python 3.12 或更高版本；将自动安装独立 Python 运行时"
    else
      fail "未找到 Python 3.12 或更高版本"
    fi
    return
  fi

  version="$("$python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')"
  major="${version%%.*}"
  minor="$(printf '%s' "$version" | cut -d. -f2)"
  if (( major > 3 || (major == 3 && minor >= 12) )); then
    pass "Python ${version}：$python"
  elif [[ "$ALLOW_MANAGED_PYTHON_INSTALL" == "1" ]]; then
    warn "Python ${version} 已检测到；将自动安装独立 Python 3.12 运行时"
  else
    fail "Python ${version}；需要 Python 3.12 或更高版本"
  fi
}

check_optional_tool() {
  local command_name="$1"
  local label="$2"
  local configured_path="${3:-}"
  local fallback_path="${4:-}"
  local resolved

  resolved="$(resolve_tool_path "$command_name" "$configured_path" || true)"
  if [[ -n "$resolved" || ( -n "$fallback_path" && -x "$fallback_path" ) ]]; then
    pass "$label 可用"
  else
    warn "$label 未找到；安装可继续，但对应功能暂不可用"
  fi
}

check_codex_cli() {
  local configured_path="${1:-}"
  local resolved
  resolved="$(resolve_tool_path codex "$configured_path" || true)"
  if [[ -z "$resolved" ]]; then
    warn "Codex CLI 未找到；安装可继续，但纪要生成前需要安装并登录"
    return
  fi
  if "$resolved" login status >/dev/null 2>&1; then
    pass "Codex CLI 已登录"
  elif "$resolved" --version >/dev/null 2>&1; then
    warn "Codex CLI 已找到但未确认登录；请运行 codex login"
  else
    warn "Codex CLI 无法正常执行：$resolved"
  fi
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
        pass "LLM 后端配置：openai / $model"
      fi
      ;;
    anthropic)
      api_key="$(read_env_value LLM_API_KEY || true)"
      if [[ -n "$api_key" ]]; then
        pass "LLM 后端配置：anthropic"
      else
        warn "LLM 后端 anthropic 缺少 LLM_API_KEY"
      fi
      ;;
    lm-studio|ollama)
      pass "LLM 后端配置：${provider}（本地服务运行时检查模型）"
      ;;
    *)
      warn "不支持的 LLM_PROVIDER：$provider"
      ;;
  esac
}

main() {
  local libreoffice_fallback="/Applications/LibreOffice.app/Contents/MacOS/soffice"
  if [[ ! -x "$libreoffice_fallback" ]] &&
    [[ -x "$HOME/Applications/LibreOffice.app/Contents/MacOS/soffice" ]]; then
    libreoffice_fallback="$HOME/Applications/LibreOffice.app/Contents/MacOS/soffice"
  fi
  printf '会议纪要助手 安装前检查\n\n'
  check_macos
  check_architecture
  check_memory
  check_disk
  check_python
  check_optional_tool ffmpeg "ffmpeg" "$(read_env_value FFMPEG_BIN)"
  check_optional_tool soffice "LibreOffice" "" "$libreoffice_fallback"
  check_llm_backend

  printf '\n'
  if (( FAILURES > 0 )); then
    fail "安装前检查未通过；存在 $FAILURES 项硬性条件不满足"
    exit 1
  fi

  if (( WARNINGS > 0 )); then
    warn "安装前检查完成；有 $WARNINGS 项需要后续处理"
  else
    pass "安装前检查完成"
  fi
}

main "$@"
