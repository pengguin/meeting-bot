#!/bin/bash

PROJECT_DIR="${MEETINGBOT_INSTALL_DIR:-$HOME/Library/Application Support/meeting-bot}"
for LEGACY_PROJECT_DIR in \
  "$HOME/meetin-bot" \
  "$HOME/meeting-bot" \
  "$HOME/feishu-meeting-bot"; do
  if [[ ! -d "$PROJECT_DIR" && -d "$LEGACY_PROJECT_DIR" ]]; then
    PROJECT_DIR="$LEGACY_PROJECT_DIR"
    break
  fi
done
PYTHON_BIN="$PROJECT_DIR/.venv/bin/python"

cd "$PROJECT_DIR" || exit 1

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export PYTHONWARNINGS="${PYTHONWARNINGS:-ignore:pkg_resources is deprecated as an API:UserWarning,ignore:resource_tracker:UserWarning}"
export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
export PYANNOTE_METRICS_ENABLED="${PYANNOTE_METRICS_ENABLED:-false}"
export OTEL_SDK_DISABLED="${OTEL_SDK_DISABLED:-true}"
export MPLCONFIGDIR="${MPLCONFIGDIR:-$PROJECT_DIR/runtime/matplotlib}"

mkdir -p "$MPLCONFIGDIR"

exec "$PYTHON_BIN" "$PROJECT_DIR/bot.py" 2> >(
  grep -v "Class AVFFrameReceiver is implemented in both" |
  grep -v "Class AVFAudioReceiver is implemented in both" >&2
)
