#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHEELHOUSE_DIR="${WHEELHOUSE_DIR:-$PROJECT_ROOT/wheelhouse}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"

mkdir -p "$WHEELHOUSE_DIR"

"$PYTHON_BIN" -m pip download \
  --dest "$WHEELHOUSE_DIR" \
  -r "$PROJECT_ROOT/requirements.txt"

echo "$WHEELHOUSE_DIR"
