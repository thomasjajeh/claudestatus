import Foundation

/// Reads and interprets the per-session status files written by the hook script.
///
/// The store is deliberately stateless between reads: every poll re-reads the
/// directory from scratch so the menu bar always reflects the current contents
/// of `~/.claude/console-status/`.
final class StatusStore {

    /// The directory that holds one `<session_id>.json` file per active session.
    let statusDirectory: URL

    /// Sessions older than this (in seconds) are treated as stale and hidden.
    /// A missed terminal hook should not leave a colored dot lingering forever.
    let staleThreshold: TimeInterval

    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - statusDirectory: Directory containing the status files. Defaults to
    ///     `~/.claude/console-status/` with `$HOME` expanded.
    ///   - staleThreshold: Age in seconds beyond which a session is pruned from
    ///     the display. Defaults to 30 minutes.
    init(statusDirectory: URL? = nil, staleThreshold: TimeInterval = 30 * 60) {
        self.statusDirectory = statusDirectory ?? StatusStore.defaultDirectory()
        self.staleThreshold = staleThreshold
        self.decoder = JSONDecoder()
    }

    /// The default status directory: `~/.claude/console-status/`.
    ///
    /// Uses the real home directory rather than a sandbox container path so it
    /// matches where the shell hook writes files.
    static func defaultDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("console-status", isDirectory: true)
    }

    /// Ensures the status directory exists. Safe to call repeatedly.
    ///
    /// The app does not require the directory to exist to function — a missing
    /// directory simply yields zero sessions — but creating it up front avoids
    /// noisy first-run behavior.
    func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: statusDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Reads all current, non-stale sessions from disk.
    ///
    /// Behavior:
    /// - A missing directory returns an empty array (never throws).
    /// - Files that fail to decode are skipped rather than aborting the poll,
    ///   so a single malformed/partially-written file cannot blank the UI.
    /// - Stale sessions (see `staleThreshold`) are excluded.
    /// - Results are sorted by project name, then session id, for a stable order.
    ///
    /// - Returns: The active sessions to display, in stable sorted order.
    func loadActiveSessions(now: Date = Date()) -> [SessionStatus] {
        let fileManager = FileManager.default

        guard let entries = try? fileManager.contentsOfDirectory(
            at: statusDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            // Directory does not exist yet or is unreadable — treat as no sessions.
            return []
        }

        let sessions = entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { decodeSession(at: $0) }
            .filter { !$0.isStale(now: now, staleThreshold: staleThreshold) }

        return sessions.sorted { lhs, rhs in
            if lhs.project != rhs.project {
                return lhs.project.localizedCaseInsensitiveCompare(rhs.project) == .orderedAscending
            }
            return lhs.sessionId < rhs.sessionId
        }
    }

    /// Decodes a single status file, returning `nil` on any read/parse failure.
    ///
    /// A `nil` result is expected and non-fatal: the hook may be mid-write, or
    /// the file may be from an incompatible/old format.
    private func decodeSession(at url: URL) -> SessionStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SessionStatus.self, from: data)
    }
}
