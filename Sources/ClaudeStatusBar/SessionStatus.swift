import Foundation

/// The traffic-light state of a single Claude Code session.
///
/// - green:  Not working. The session is idle or has finished its turn.
/// - orange: Working, no user input required (actively running / using tools).
/// - red:    Waiting for the user (permission prompt or idle-input notification).
enum SessionState: String, Codable {
    case green
    case orange
    case red

    /// The colored emoji dot used to represent this state in the menu bar.
    var dot: String {
        switch self {
        case .green:  return "🟢"
        case .orange: return "🟠"
        case .red:    return "🔴"
        }
    }

    /// A short human-readable label used in the dropdown menu rows.
    var label: String {
        switch self {
        case .green:  return "idle"
        case .orange: return "working"
        case .red:    return "waiting for you"
        }
    }
}

/// A decoded representation of a single `<session_id>.json` status file written
/// by the `claude-status.sh` hook script.
///
/// The JSON on disk has the shape:
/// ```
/// { "session_id": "...", "status": "green|orange|red",
///   "cwd": "/abs/path", "project": "folder-name", "updated_at": 1712345678 }
/// ```
struct SessionStatus: Codable {
    let sessionId: String
    let status: SessionState
    let cwd: String
    let project: String
    /// The terminal app the session runs in (from `$TERM_PROGRAM`), used to
    /// bring that terminal to the front when the row is clicked. May be empty
    /// or absent for older status files.
    let termProgram: String?
    /// Unix epoch (seconds) recording when the hook last updated this session.
    let updatedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case sessionId  = "session_id"
        case status
        case cwd
        case project
        case termProgram = "term_program"
        case updatedAt  = "updated_at"
    }

    /// The time interval, in seconds, since this session was last updated.
    /// A negative or zero value is clamped to 0 (clock skew safety).
    func secondsSinceUpdate(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince1970 - updatedAt)
    }

    /// Whether this session is considered stale and should be pruned from the
    /// display. A stale session is one whose hook likely failed to fire a
    /// terminal event, leaving the status file behind.
    ///
    /// - Parameter staleThreshold: Age in seconds beyond which the session is stale.
    func isStale(now: Date = Date(), staleThreshold: TimeInterval) -> Bool {
        secondsSinceUpdate(now: now) > staleThreshold
    }
}

/// A pending tool-approval request written by the blocking `PreToolUse` hook
/// (`claude-approve.sh`) while it waits for the user to Approve or Deny from the
/// menu bar. One file per waiting session in `console-status/requests/`.
struct PendingRequest: Codable {
    let sessionId: String
    let cwd: String
    let project: String
    /// The tool Claude wants to run, e.g. `Bash`, `Write`, `Edit`.
    let toolName: String
    /// A short human summary of what the tool will do (command, file path, …).
    let summary: String
    /// Unix epoch (seconds) when the hook created this request.
    let createdAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case project
        case toolName  = "tool_name"
        case summary
        case createdAt = "created_at"
    }

    func secondsSinceCreated(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince1970 - createdAt)
    }
}
