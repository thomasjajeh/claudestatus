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

Clicking the menu bar item opens a dropdown listing every active session,
labeled by its project folder, with its current state and how long ago it
updated, plus a **Quit** item. When there are no sessions, a dim ⚪️ is shown.

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

## Setup

### 1. Build the app

```bash
cd /Users/thomasjajeh/Workspace/macWidget
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

**Important:** the snippet uses an absolute path to the script:

```
/Users/thomasjajeh/Workspace/macWidget/hooks/claude-status.sh
```

If you cloned this repo elsewhere, replace that path everywhere it appears in
the snippet with the absolute path to *your* `hooks/claude-status.sh`.

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

The plist points at `.build/release/ClaudeStatusBar`. If your project lives at a
different path, edit the `ProgramArguments` path in the plist before copying it.

To stop / uninstall the LaunchAgent:

```bash
launchctl unload ~/Library/LaunchAgents/global.headfirst.claudestatusbar.plist
```

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
│   ├── claude-status.sh             # Hook writer script (jq-optional)
│   └── settings-hooks.json          # Ready-to-merge Claude Code hooks config
├── scripts/
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
