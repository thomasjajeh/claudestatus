#!/usr/bin/env bash
#
# One-shot installer for ClaudeStatusBar.
#
# Auto-detects where the repo is checked out, then:
#   1. Builds the release binary.
#   2. Makes the hook script executable.
#   3. Merges the Claude Code hooks into ~/.claude/settings.json
#      (backing up any existing file first), with the correct absolute paths.
#   4. Installs a LaunchAgent so the app starts at login, and starts it now.
#
# Safe to re-run: it backs up settings.json and reloads the LaunchAgent.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HOOK="$REPO_DIR/hooks/claude-status.sh"
BINARY="$REPO_DIR/.build/release/ClaudeStatusBar"
SETTINGS="$HOME/.claude/settings.json"
LABEL="global.headfirst.claudestatusbar"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Repo detected at: $REPO_DIR"

echo "==> [1/4] Building release binary"
( cd "$REPO_DIR" && swift build -c release )

echo "==> [2/4] Making hook scripts executable"
chmod +x "$HOOK" "$REPO_DIR/hooks/claude-approve.sh"

echo "==> [3/4] Merging hooks into $SETTINGS"
mkdir -p "$HOME/.claude"
APPROVE_HOOK="$REPO_DIR/hooks/claude-approve.sh"
python3 - "$SETTINGS" "$HOOK" "$APPROVE_HOOK" <<'PY'
import json, os, sys, time, shutil

settings_path, hook, approve_hook = sys.argv[1], sys.argv[2], sys.argv[3]

def cmd(status):
    return {"type": "command", "command": f"{hook} {status}"}

hooks = {
    "SessionStart":     [{"hooks": [cmd("green")]}],
    "UserPromptSubmit": [{"hooks": [cmd("orange")]}],
    "PreToolUse":       [
        {"matcher": "*", "hooks": [cmd("orange")]},
        {"matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit",
         "hooks": [{"type": "command", "command": approve_hook, "timeout": 310}]},
    ],
    "PostToolUse":      [{"matcher": "*", "hooks": [cmd("orange")]}],
    "Notification":     [{"hooks": [cmd("red")]}],
    "Stop":             [{"hooks": [cmd("green")]}],
    "SessionEnd":       [{"hooks": [cmd("end")]}],
}

settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)
    backup = settings_path + ".bak." + str(int(time.time()))
    shutil.copy2(settings_path, backup)
    print(f"    backed up existing settings -> {backup}")

settings["hooks"] = hooks
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print("    wrote hooks for:", ", ".join(hooks))
PY

echo "==> [4/4] Installing LaunchAgent -> $PLIST_DST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/claudestatusbar.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claudestatusbar.err.log</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"

echo ""
echo "✅ Installed and running. Look at the top-right of your menu bar."
echo "   Hooks apply to NEW Claude Code sessions started from now on."
echo "   To remove everything later, run: scripts/uninstall.sh"
