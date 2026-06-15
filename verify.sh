#!/usr/bin/env bash
# Headless verification: regenerate SFX, import assets, then run the game
# headless for a few hundred frames and fail on any script/load error.
set -euo pipefail

cd "$(dirname "$0")"

# Locate the Godot 4 binary.
GODOT="${GODOT:-}"
if [[ -z "$GODOT" ]]; then
  for c in \
    "/Applications/Godot.app/Contents/MacOS/Godot" \
    "$(command -v godot || true)" \
    "$(command -v godot4 || true)"; do
    if [[ -n "$c" && -x "$c" ]]; then GODOT="$c"; break; fi
  done
fi
if [[ -z "$GODOT" || ! -x "$GODOT" ]]; then
  echo "ERROR: Godot 4 binary not found. Set GODOT=/path/to/Godot" >&2
  exit 1
fi
echo "Using Godot: $GODOT"
"$GODOT" --version

echo "== Regenerating SFX =="
python3 gen_sfx.py

echo "== Importing assets =="
"$GODOT" --headless --import --path . 2>&1 | tee /tmp/nd_import.log || true

echo "== Headless smoke run (300 frames) =="
LOG=/tmp/nd_run.log
"$GODOT" --headless --path . --quit-after 300 2>&1 | tee "$LOG" || true

echo "== Scanning logs for errors =="
if grep -E "SCRIPT ERROR|Parse Error|SCRIPT error|Failed to load|Can't open|Condition .* is true|still in use at exit|instances leaked" "$LOG" /tmp/nd_import.log; then
  echo "VERIFY: FAILED — errors found above." >&2
  exit 1
fi
echo "VERIFY: PASSED — project loaded and ran headless with no script/load errors or leaks."
