# ClaudeStatusBar

A native macOS **menu bar app** that shows the live status of each running
Claude Code CLI session as a traffic light.

One colored dot per active session appears in the menu bar (top-right, next to
the clock):

| Dot | State | Meaning |
| --- | --- | --- |
| 🟢 GREEN  | idle / finished turn | Claude is **not** working — either idle or it just finished its turn. |
| 🟠 ORANGE | working              | Claude is actively running / using tools. **No input needed from you.** |
| 🔴 RED    | waiting for you       | Claude is **blocked** waiting on you (permission prompt or idle-input notification). |

> **GREEN vs RED:** GREEN covers *both* "idle" and "finished its turn" — nothing
> needs your attention. RED means Claude is actively blocked and waiting for you
> to respond or approve something.

The dots are drawn as crisp vector circles (not emoji), so they render in full
color and never flicker — the bar only redraws when a session's state actually
changes. Clicking the menu bar item opens a dropdown listing every active
session, labeled by its project folder, with its current state and how long ago
it updated, plus a **Quit** item. When there are no sessions, a dim outlined
ring is shown.

**Jump to a session:** click any row in the dropdown to bring that session's
terminal app to the front — handy when a 🔴 session is blocked and you want to
get to it fast. The hook records each session's terminal (`$TERM_PROGRAM`);
supported terminals include Terminal, iTerm2, VS Code, Ghostty, WezTerm, kitty,
Alacritty, Warp, Hyper and Tabby.

> **Note / limitation:** clicking raises the terminal *application*, not the
> exact tab/window. If you'd rather answer Claude's Yes/No **without** switching
> to the terminal at all, see the optional approval queue below.

---

## Approving tool calls from the menu bar (optional)

You can answer Claude's "may I run this?" permission decision **directly from the
dropdown**, without switching to the terminal. This is **off by default** — flip
it on via the **"Approve tool calls from here"** toggle in the dropdown.

When enabled, a blocking `PreToolUse` hook pauses the tool and the dropdown shows:

```
🔴 macWidget — approve Bash?  rm -rf build
     ✅ Approve
     🛑 Deny
```

Click **Approve** or **Deny** and the decision is returned to Claude through its
official permission API (`permissionDecision: allow | deny`). The dot turns 🔴
red for any session with a pending request.

**How it stays safe / unobtrusive:**

- **Off by default.** With the toggle off, the hook exits instantly and your
  normal permission flow (including `skipDangerousModePermissionPrompt` and your
  allow-list) is completely untouched.
- **Scoped to `Bash`, `Write`, `Edit`, `MultiEdit`, `NotebookEdit`** — read-only
  tools are never queued.
- **5-minute timeout.** If you don't click in time, the hook returns `ask` and
  Claude falls back to the normal terminal prompt — a session never hangs.

> The hook `timeout` in `settings.json` (310s) must stay **≥** the script's
> `CLAUDE_APPROVE_TIMEOUT` (default 300s), or Claude will kill the hook before
> your click lands.

**Caveat — when the queue is ON it intercepts *every* matching tool call**, so
tools you'd normally never be asked about will wait for a click. Turn it on when
you want a GUI approval queue; leave it off for hands-off sessions.

---

## How it works

```
Claude Code hooks ──> hooks/claude-status.sh ──> ~/.claude/console-status/<session_id>.json
                                                              │
                                                              ▼
                                             ClaudeStatusBar app polls every 1.5s
                                                              │
                                                              ▼
                                                   🟢🟠🔴  in the menu bar
```

- **Hook script** (`hooks/claude-status.sh`): fired by Claude Code on session
  events. It reads the hook JSON payload from stdin, extracts `session_id` and
  `cwd`, and writes/updates a small JSON status file — one per session. On
  session end it deletes that file. It uses `jq` if available and falls back to
  `python3`, so **`jq` is not required**.
- **Menu bar app** (`ClaudeStatusBar`): a dependency-free Swift Package Manager
  executable (Foundation + AppKit). It polls `~/.claude/console-status/` every
  1.5 s, renders one dot per session, and prunes **stale** sessions (older than
  30 minutes) so a missed terminal hook never leaves a dot lingering forever.

Status file shape:

```json
{
  "session_id": "abc123",
  "status": "green|orange|red",
  "cwd": "/abs/path/to/project",
  "project": "project",
  "updated_at": 1712345678
}
```

---

## Requirements

- macOS 13 (Ventura) or later.
- A Swift toolchain — install the Xcode Command Line Tools if you don't have
  one: `xcode-select --install`. Verify with `swift --version`.
- Claude Code (the `claude` CLI).
- `python3` (ships with macOS). `jq` is optional.

---

## Quick install (recommended)

Clone the repo anywhere, then run the installer. It auto-detects the checkout
location — **no path editing required** — builds the app, wires up the Claude
Code hooks, and installs the auto-start LaunchAgent:

```bash
git clone https://github.com/thomasjajeh/claudestatus.git
cd claudestatus
./scripts/install.sh
```

That single command:

1. Builds the release binary (`.build/release/ClaudeStatusBar`).
2. Makes `hooks/claude-status.sh` executable.
3. Merges the hooks into `~/.claude/settings.json` with the correct absolute
   paths (backing up any existing file to `settings.json.bak.<timestamp>`).
4. Writes `~/Library/LaunchAgents/global.headfirst.claudestatusbar.plist` and
   loads it, so the app runs now **and** starts automatically at every login.

Then **open a new Claude Code session** — hooks only apply to sessions started
after `settings.json` is updated — and a colored dot appears in your menu bar.

To remove everything (LaunchAgent, hooks, status files):

```bash
./scripts/uninstall.sh
```

> The installer is safe to re-run — e.g. after `git pull` + `swift build -c
> release`, just run `./scripts/install.sh` again to reload the new binary.

---

## Manual setup

If you'd rather do it by hand instead of running `scripts/install.sh`:

### 1. Build the app

```bash
cd /path/to/claudestatus     # wherever you cloned it
swift build -c release
```

The release binary is produced at `.build/release/ClaudeStatusBar`.
(For development you can also just use `swift build` / `swift run`.)

### 2. Make the hook script executable

```bash
chmod +x hooks/claude-status.sh
```

### 3. Configure Claude Code hooks

Merge the contents of [`hooks/settings-hooks.json`](hooks/settings-hooks.json)
into your `~/.claude/settings.json` under the top-level `"hooks"` key.

**Important:** the snippet uses a placeholder absolute path to the script:

```
/Users/thomasjajeh/Workspace/macWidget/hooks/claude-status.sh
```

Since you almost certainly cloned this repo elsewhere, replace that path
everywhere it appears with the absolute path to *your* `hooks/claude-status.sh`.
Get it with:

```bash
echo "$(pwd)/hooks/claude-status.sh"
```

The event → status mapping is:

| Event | Status | Effect |
| --- | --- | --- |
| `SessionStart`    | green  | Session begins, idle. |
| `UserPromptSubmit`| orange | You submitted a prompt; Claude starts working. |
| `PreToolUse` (`*`)  | orange | About to run a tool. |
| `PostToolUse` (`*`) | orange | Finished a tool, still in-turn. |
| `Notification`    | red    | Claude needs you (permission / idle input). |
| `Stop`            | green  | Turn finished. |
| `SessionEnd`      | end    | Status file deleted. |

> Hooks are read when a Claude Code session starts, so the traffic lights apply
> to **new** sessions you open after saving `settings.json`.

If you have no existing `"hooks"` block, you can copy the whole file's `hooks`
object in directly. If you already have hooks, merge event-by-event.

### 4. Run the app

**Option A — run it directly (foreground):**

```bash
./scripts/run.sh          # builds + runs
# or:
swift run ClaudeStatusBar
```

**Option B — auto-start at login (LaunchAgent):**

```bash
swift build -c release
cp launchagent/global.headfirst.claudestatusbar.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/global.headfirst.claudestatusbar.plist
```

The template plist points at `/Users/thomasjajeh/Workspace/macWidget/.build/release/ClaudeStatusBar`.
**Edit the `ProgramArguments` path** to your own absolute
`.build/release/ClaudeStatusBar` before copying it. The template uses
`RunAtLoad: true` + `KeepAlive: false` — it starts at login, and the dropdown's
**Quit** item works (with `KeepAlive: true`, launchd would relaunch the app the
instant you quit it).

After rebuilding (`swift build -c release`) you must reload the agent for the
new binary to take effect:

```bash
launchctl unload ~/Library/LaunchAgents/global.headfirst.claudestatusbar.plist
launchctl load   ~/Library/LaunchAgents/global.headfirst.claudestatusbar.plist
```

To stop / uninstall the LaunchAgent:

```bash
launchctl unload ~/Library/LaunchAgents/global.headfirst.claudestatusbar.plist
rm ~/Library/LaunchAgents/global.headfirst.claudestatusbar.plist
```

> **Logs** (for troubleshooting) go to `/tmp/claudestatusbar.out.log` and
> `/tmp/claudestatusbar.err.log`.

---

## Project layout

```
macWidget/
├── Package.swift
├── README.md
├── .gitignore
├── Sources/
│   └── ClaudeStatusBar/
│       ├── main.swift               # App entry point (accessory NSApplication)
│       ├── SessionStatus.swift      # Session state enum + status file model
│       ├── StatusStore.swift        # Reads/prunes status files from disk
│       └── StatusBarController.swift# NSStatusItem, polling timer, menu
├── hooks/
│   ├── claude-status.sh             # Status writer script (jq-optional)
│   ├── claude-approve.sh            # Blocking PreToolUse approval hook (optional queue)
│   └── settings-hooks.json          # Ready-to-merge Claude Code hooks config
├── scripts/
│   ├── install.sh                   # One-shot install (build + hooks + auto-start)
│   ├── uninstall.sh                 # Reverse the installer
│   └── run.sh                       # Build + run helper
└── launchagent/
    └── global.headfirst.claudestatusbar.plist  # Auto-start-at-login template
```

---

## Troubleshooting

- **No dots appear:** confirm hooks are configured (open a *new* Claude Code
  session after editing `settings.json`), and check that files appear in
  `~/.claude/console-status/`. Verify the script is executable (`chmod +x`).
- **A dot is stuck orange:** the app hides sessions not updated in 30 minutes.
  If a session genuinely ended without firing `SessionEnd`, its file may remain
  on disk but it will no longer be displayed once stale.
- **`jq` not installed:** not required — the script falls back to `python3`.
