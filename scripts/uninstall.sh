#!/usr/bin/env bash
#
# Uninstaller for ClaudeStatusBar. Reverses scripts/install.sh:
#   1. Stops and removes the LaunchAgent.
#   2. Removes the "hooks" key from ~/.claude/settings.json (backing it up).
#   3. Cleans up leftover per-session status files.
#
# It does NOT delete the checked-out repo or the built binary.
#
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
LABEL="global.headfirst.claudestatusbar"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> [1/3] Removing LaunchAgent"
if [ -f "$PLIST_DST" ]; then
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    rm -f "$PLIST_DST"
    echo "    removed $PLIST_DST"
else
    echo "    no LaunchAgent found"
fi
# Belt-and-braces: stop any still-running instance.
pkill -f 'ClaudeStatusBar' 2>/dev/null || true

echo "==> [2/3] Removing hooks from $SETTINGS"
if [ -f "$SETTINGS" ]; then
    python3 - "$SETTINGS" <<'PY'
import json, os, sys, time, shutil
p = sys.argv[1]
with open(p) as f:
    s = json.load(f)
if "hooks" in s:
    backup = p + ".bak." + str(int(time.time()))
    shutil.copy2(p, backup)
    del s["hooks"]
    with open(p, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    print(f"    removed 'hooks' (backup -> {backup})")
else:
    print("    no 'hooks' key present")
PY
else
    echo "    no settings.json found"
fi

echo "==> [3/3] Cleaning up status files"
rm -rf "$HOME/.claude/console-status"
echo "    removed ~/.claude/console-status"

echo ""
echo "✅ Uninstalled. (The repo and built binary are left in place.)"
