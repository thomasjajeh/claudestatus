#!/usr/bin/env bash
#
# run.sh — build (if needed) and launch the ClaudeStatusBar menu bar app.
#
# The app runs in the foreground; press Ctrl-C to stop it, or use the "Quit"
# item in its menu bar dropdown.

set -euo pipefail

# Resolve the project root (parent of this scripts/ directory) so the script
# works regardless of the caller's current directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$PROJECT_ROOT"

echo "Building ClaudeStatusBar..."
swift build

echo "Launching ClaudeStatusBar (look for the traffic-light dots in your menu bar)..."
exec swift run ClaudeStatusBar
