#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="${HOME}/Library/Application Support/Superkeet/Grounder"
PYTHON="${PYTHON:-python3.12}"

"$PYTHON" -c 'import sys; assert sys.version_info[:2] == (3, 12), "The pinned grounder runtime requires Python 3.12"'
mkdir -p "$RUNTIME_DIR"
"$PYTHON" -m venv "$RUNTIME_DIR/venv"
"$RUNTIME_DIR/venv/bin/python3" -m pip install -r "$SCRIPT_DIR/gliner/requirements.txt"

# Only installation downloads weights; the app always starts its worker offline.
PYTHONPATH="$SCRIPT_DIR/gliner" "$RUNTIME_DIR/venv/bin/python3" -c \
    'from gliner_adapter import GROUNDING_MODEL, load_model; load_model(GROUNDING_MODEL, "cpu")'
printf 'Grounder installed. Enable Native UI grounder in Settings > Actions, then Check and Warm Runtime.\n'
