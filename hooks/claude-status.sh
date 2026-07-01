#!/usr/bin/env bash
#
# claude-status.sh — writes/deletes a per-session status file that the
# ClaudeStatusBar menu bar app reads.
#
# Usage (invoked by Claude Code hooks, receives the hook JSON payload on stdin):
#   claude-status.sh green|orange|red|end
#
# Behavior:
#   green|orange|red  -> write ~/.claude/console-status/<session_id>.json
#   end               -> delete ~/.claude/console-status/<session_id>.json
#
# Design constraints:
#   - Must never block Claude Code and must exit 0 quickly.
#   - Must NOT print anything to stdout (that could interfere with hooks).
#   - jq-optional: uses jq if present, otherwise a portable python3 fallback.

# Never let an error abort the calling hook; we always want to exit 0.
set +e

STATUS="$1"

# The status directory the menu bar app polls.
STATUS_DIR="${HOME}/.claude/console-status"

# --- Read the hook payload from stdin -------------------------------------
# Claude Code passes a JSON object on stdin containing at least session_id and cwd.
PAYLOAD="$(cat)"

# --- Extract a field from the payload, jq-first with python3 fallback ------
# Prints the value (or empty string) to stdout of the *function*, captured by caller.
extract_field() {
    local key="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$PAYLOAD" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$PAYLOAD" | python3 -c '
import sys, json
key = sys.argv[1]
try:
    data = json.load(sys.stdin)
    val = data.get(key, "")
    sys.stdout.write("" if val is None else str(val))
except Exception:
    pass
' "$key" 2>/dev/null
    fi
}

SESSION_ID="$(extract_field session_id)"
CWD="$(extract_field cwd)"

# Without a session id we cannot key the file; nothing to do. Exit cleanly.
if [ -z "$SESSION_ID" ]; then
    exit 0
fi

STATUS_FILE="${STATUS_DIR}/${SESSION_ID}.json"

# --- Handle the terminal 'end' event: remove the session file -------------
if [ "$STATUS" = "end" ]; then
    rm -f "$STATUS_FILE" 2>/dev/null
    exit 0
fi

# --- Validate the requested status ----------------------------------------
case "$STATUS" in
    green|orange|red) ;;
    *)
        # Unknown status argument — do nothing rather than write garbage.
        exit 0
        ;;
esac

# --- Derive fields --------------------------------------------------------
# Fall back to $PWD if cwd was somehow absent from the payload.
if [ -z "$CWD" ]; then
    CWD="$PWD"
fi
PROJECT="$(basename "$CWD")"
UPDATED_AT="$(date +%s)"

# Which terminal app this session runs in, so the menu bar app can bring it to
# the front when clicked. $TERM_PROGRAM is set by the terminal and inherited by
# this hook subprocess (e.g. "iTerm.app", "Apple_Terminal", "vscode", "ghostty").
TERM_PROG="${TERM_PROGRAM:-}"

# Ensure the status directory exists.
mkdir -p "$STATUS_DIR" 2>/dev/null

# --- Write the status file atomically -------------------------------------
# Build JSON safely (escaping strings) via jq or python3; write to a temp file
# and mv into place so the menu bar app never reads a half-written file.
TMP_FILE="$(mktemp "${STATUS_DIR}/.${SESSION_ID}.XXXXXX" 2>/dev/null)"
if [ -z "$TMP_FILE" ]; then
    # mktemp failed (e.g. dir issue); nothing more we can safely do.
    exit 0
fi

if command -v jq >/dev/null 2>&1; then
    jq -n \
        --arg sid "$SESSION_ID" \
        --arg status "$STATUS" \
        --arg cwd "$CWD" \
        --arg project "$PROJECT" \
        --arg term "$TERM_PROG" \
        --argjson updated "$UPDATED_AT" \
        '{session_id: $sid, status: $status, cwd: $cwd, project: $project, term_program: $term, updated_at: $updated}' \
        > "$TMP_FILE" 2>/dev/null
elif command -v python3 >/dev/null 2>&1; then
    SESSION_ID="$SESSION_ID" STATUS="$STATUS" CWD="$CWD" PROJECT="$PROJECT" TERM_PROG="$TERM_PROG" UPDATED_AT="$UPDATED_AT" \
    python3 -c '
import os, json
obj = {
    "session_id": os.environ["SESSION_ID"],
    "status": os.environ["STATUS"],
    "cwd": os.environ["CWD"],
    "project": os.environ["PROJECT"],
    "term_program": os.environ.get("TERM_PROG", ""),
    "updated_at": int(os.environ["UPDATED_AT"]),
}
print(json.dumps(obj))
' > "$TMP_FILE" 2>/dev/null
else
    # Last-resort fallback with no JSON tooling. Values here are machine-derived
    # (session_id, epoch) or paths; adequate for this local-only status file.
    printf '{"session_id":"%s","status":"%s","cwd":"%s","project":"%s","term_program":"%s","updated_at":%s}\n' \
        "$SESSION_ID" "$STATUS" "$CWD" "$PROJECT" "$TERM_PROG" "$UPDATED_AT" > "$TMP_FILE" 2>/dev/null
fi

mv -f "$TMP_FILE" "$STATUS_FILE" 2>/dev/null

exit 0
