#!/bin/bash
set -euo pipefail

INSTALL_FFMPEG=0
INSTALL_LIBREOFFICE=0
INSTALL_CODEX=0
BREW_BIN=""

info() {
  printf '[tools] %s\n' "$1"
}

warn() {
  printf '[tools][warn] %s\n' "$1" >&2
}

usage() {
  cat <<USAGE
用法：bash scripts/install_optional_tools.sh [选项]

选项：
  --ffmpeg        安装 ffmpeg
  --libreoffice   安装 LibreOffice
  --codex         安装 Codex CLI
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ffmpeg)
        INSTALL_FFMPEG=1
        shift
        ;;
      --libreoffice)
        INSTALL_LIBREOFFICE=1
        shift
        ;;
      --codex)
        INSTALL_CODEX=1
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

brew_bin() {
  if command -v brew >/dev/null 2>&1; then
    command -v brew
    return
  fi

  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$candidate" ]] && {
      printf '%s\n' "$candidate"
      return
    }
  done
}

find_executable() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return
  fi

  for candidate in \
    "$HOME/.local/bin/$name" \
    "$HOME/bin/$name" \
    "$HOME/.volta/bin/$name" \
    "$HOME/.bun/bin/$name" \
    "$HOME/Library/pnpm/$name" \
    "/opt/homebrew/bin/$name" \
    "/usr/local/bin/$name"; do
    [[ -x "$candidate" ]] && {
      printf '%s\n' "$candidate"
      return
    }
  done

  for candidate in \
    "$HOME"/.nvm/versions/node/*/bin/"$name" \
    "$HOME"/.npm/_npx/*/node_modules/.bin/"$name"; do
    [[ -x "$candidate" ]] && {
      printf '%s\n' "$candidate"
      return
    }
  done

  if [[ -x "/bin/zsh" ]]; then
    /bin/zsh -lic "command -v '$name' 2>/dev/null || true" 2>/dev/null || true
  fi
}

ensure_homebrew() {
  local brew
  brew="$(brew_bin || true)"
  if [[ -n "$brew" ]]; then
    BREW_BIN="$brew"
    return
  fi

  warn "未检测到 Homebrew。为避免自动执行未经用户确认的网络脚本，请先从 https://brew.sh 安装 Homebrew，再返回重试。"
  printf '[tools][error] code=HOMEBREW_REQUIRED\n' >&2
  exit 2
}

install_ffmpeg() {
  local brew="$1"
  if [[ -n "$(find_executable ffmpeg || true)" ]]; then
    info "ffmpeg 已存在"
    return
  fi
  info "安装 ffmpeg"
  "$brew" install ffmpeg
}

install_libreoffice() {
  local brew="$1"
  if [[ -n "$(find_executable soffice || true)" ]] ||
    [[ -x "/Applications/LibreOffice.app/Contents/MacOS/soffice" ]] ||
    [[ -x "$HOME/Applications/LibreOffice.app/Contents/MacOS/soffice" ]]; then
    info "LibreOffice 已存在"
    return
  fi
  info "安装 LibreOffice"
  "$brew" install --cask libreoffice
}

install_codex() {
  local brew="$1"
  local npm
  if [[ -n "$(find_executable codex || true)" ]]; then
    info "Codex CLI 已存在"
    return
  fi

  npm="$(find_executable npm || true)"
  if [[ -z "$npm" ]]; then
    [[ -n "$brew" ]] || {
      warn "未找到 npm；安装 Node.js 需要 Homebrew"
      exit 2
    }
    info "安装 Node.js"
    "$brew" install node
    npm="$(find_executable npm || true)"
  fi

  [[ -n "$npm" ]] || {
    warn "Node.js 安装完成后仍未找到 npm"
    exit 1
  }

  info "安装 Codex CLI"
  "$npm" install -g @openai/codex
}

main() {
  local npm
  parse_args "$@"
  if [[ "$INSTALL_FFMPEG" -eq 0 && "$INSTALL_LIBREOFFICE" -eq 0 && "$INSTALL_CODEX" -eq 0 ]]; then
    warn "未指定需要安装的工具"
    exit 1
  fi

  if [[ "$INSTALL_FFMPEG" -eq 1 || "$INSTALL_LIBREOFFICE" -eq 1 ]]; then
    ensure_homebrew
  fi
  if [[ "$INSTALL_CODEX" -eq 1 ]] &&
    [[ -z "$(find_executable codex || true)" ]]; then
    npm="$(find_executable npm || true)"
    [[ -n "$npm" ]] || ensure_homebrew
  fi

  [[ "$INSTALL_FFMPEG" -eq 1 ]] && install_ffmpeg "$BREW_BIN"
  [[ "$INSTALL_LIBREOFFICE" -eq 1 ]] && install_libreoffice "$BREW_BIN"
  [[ "$INSTALL_CODEX" -eq 1 ]] && install_codex "$BREW_BIN"

  info "工具安装流程完成"
}

main "$@"
