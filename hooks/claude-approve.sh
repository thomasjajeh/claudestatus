#!/usr/bin/env bash
#
# claude-approve.sh — a blocking PreToolUse hook that routes Claude's tool
# permission decision to the ClaudeStatusBar menu bar.
#
# Flow:
#   1. If the approval queue is disabled (no `approve-enabled` sentinel), exit
#      immediately so Claude's normal permission flow is untouched.
#   2. Otherwise write a pending-request file the menu bar app displays, then
#      block, polling for a decision file the app writes when you click
#      Approve / Deny.
#   3. Emit the official PreToolUse permission decision (allow | deny), or on
#      timeout emit `ask` so it falls back to the normal terminal prompt.
#
# Configure with a matcher so it ONLY fires for tools you want to gate
# (e.g. Bash|Write|Edit|MultiEdit) and give it a `timeout` >= POLL_TIMEOUT.
#
# Requires python3 (ships with macOS). If absent, it no-ops (normal flow).

set +e

STATUS_DIR="${HOME}/.claude/console-status"
REQ_DIR="${STATUS_DIR}/requests"
DEC_DIR="${STATUS_DIR}/decisions"
ENABLE_FILE="${STATUS_DIR}/approve-enabled"

# How long to wait for a click before giving up and deferring to the terminal.
# Keep this <= the hook's configured `timeout` in settings.json.
POLL_TIMEOUT="${CLAUDE_APPROVE_TIMEOUT:-300}"

PAYLOAD="$(cat)"

# --- Opt-in gate: do nothing unless the queue is enabled ------------------
if [ ! -f "$ENABLE_FILE" ]; then
    exit 0
fi

command -v python3 >/dev/null 2>&1 || exit 0

mkdir -p "$REQ_DIR" "$DEC_DIR" 2>/dev/null

# --- Parse payload and write the pending request in one python pass -------
# Prints the session_id on success (empty on any failure / missing id).
SESSION_ID="$(printf '%s' "$PAYLOAD" | python3 -c '
import sys, json, os, time
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

sid = d.get("session_id") or ""
if not sid:
    sys.exit(0)

cwd = d.get("cwd") or os.getcwd()
tool = d.get("tool_name") or "tool"
ti = d.get("tool_input") or {}

# Build a short, human-readable summary of what the tool will do.
summary = ""
if isinstance(ti, dict):
    for k in ("command", "file_path", "path", "pattern", "url", "description"):
        if ti.get(k):
            summary = str(ti[k]); break
    if not summary:
        for v in ti.values():
            if isinstance(v, str) and v.strip():
                summary = v; break
summary = " ".join(summary.split())
if len(summary) > 120:
    summary = summary[:117] + "..."

req_dir = os.path.expanduser("~/.claude/console-status/requests")
os.makedirs(req_dir, exist_ok=True)
obj = {
    "session_id": sid,
    "cwd": cwd,
    "project": os.path.basename(cwd.rstrip("/")) or cwd,
    "tool_name": tool,
    "summary": summary,
    "created_at": int(time.time()),
}
tmp = os.path.join(req_dir, "." + sid + ".tmp")
with open(tmp, "w") as f:
    json.dump(obj, f)
os.replace(tmp, os.path.join(req_dir, sid + ".json"))
print(sid)
' 2>/dev/null)"

if [ -z "$SESSION_ID" ]; then
    exit 0
fi

REQ_FILE="${REQ_DIR}/${SESSION_ID}.json"
DEC_FILE="${DEC_DIR}/${SESSION_ID}.json"

# --- Block, polling for a decision from the menu bar ----------------------
DECISION=""
elapsed=0
while [ "$elapsed" -lt "$POLL_TIMEOUT" ]; do
    # If the queue is toggled off mid-wait, stop waiting and defer.
    [ -f "$ENABLE_FILE" ] || break

    if [ -f "$DEC_FILE" ]; then
        DECISION="$(python3 -c '
import sys, json
try:
    print((json.load(open(sys.argv[1])).get("decision") or "").strip())
except Exception:
    pass
' "$DEC_FILE" 2>/dev/null)"
        rm -f "$DEC_FILE" 2>/dev/null
        [ -n "$DECISION" ] && break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

# Clean up the pending request regardless of outcome.
rm -f "$REQ_FILE" 2>/dev/null

# --- Emit the official PreToolUse permission decision ---------------------
emit() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}' \
        "$1" "$2"
}

case "$DECISION" in
    allow) emit allow "Approved from ClaudeStatusBar" ;;
    deny)  emit deny  "Denied from ClaudeStatusBar" ;;
    *)     emit ask   "ClaudeStatusBar: no response, deferring to terminal" ;;
esac

exit 0
