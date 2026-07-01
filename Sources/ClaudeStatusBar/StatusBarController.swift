import AppKit
import Foundation

/// Owns the `NSStatusItem` in the system menu bar and keeps it in sync with the
/// on-disk session status files.
///
/// Responsibilities:
/// - Render one colored dot per active session in the menu bar title.
/// - Poll the status directory on a repeating timer.
/// - Build the dropdown menu (per-session rows + Quit).
final class StatusBarController {

    /// Shown in the menu bar when there are zero active sessions. A dim,
    /// low-contrast dot reads as "nothing running" without being alarming.
    private static let idleTitle = "⚪️"

    /// How often the status directory is re-scanned.
    private static let pollInterval: TimeInterval = 1.5

    private let statusItem: NSStatusItem
    private let store: StatusStore
    private var pollTimer: Timer?

    /// - Parameter store: The status store to read sessions from.
    init(store: StatusStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    /// Performs first-run setup and begins polling. Call once at launch.
    func start() {
        store.ensureDirectoryExists()

        if let button = statusItem.button {
            button.title = Self.idleTitle
            button.setAccessibilityLabel("Claude Code session status")
        }

        // Render immediately so the bar is correct before the first timer tick.
        refresh()
        startPolling()
    }

    // MARK: - Polling

    private func startPolling() {
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Use .common so polling continues while the menu is open (tracking mode).
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Re-reads the sessions from disk and updates both the title and menu.
    private func refresh() {
        let sessions = store.loadActiveSessions()
        updateTitle(with: sessions)
        updateMenu(with: sessions)
    }

    // MARK: - Rendering

    /// Sets the menu bar title to one dot per session, or the idle dot if none.
    private func updateTitle(with sessions: [SessionStatus]) {
        guard let button = statusItem.button else { return }
        if sessions.isEmpty {
            button.title = Self.idleTitle
        } else {
            button.title = sessions.map { $0.status.dot }.joined()
        }
    }

    /// Rebuilds the dropdown menu: a header/rows section then a Quit item.
    private func updateMenu(with sessions: [SessionStatus]) {
        let menu = NSMenu()

        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No active Claude sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for session in sessions {
                let item = NSMenuItem(title: rowTitle(for: session), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Formats a single dropdown row, e.g. `🟠 macWidget  working  (updated 3s ago)`.
    private func rowTitle(for session: SessionStatus) -> String {
        let age = Self.formatAge(session.secondsSinceUpdate())
        return "\(session.status.dot) \(session.project)  \(session.status.label)  (updated \(age) ago)"
    }

    /// Renders an elapsed interval as a compact human-readable string.
    ///
    /// - `< 60s`  → `"12s"`
    /// - `< 60m`  → `"4m"`
    /// - else     → `"2h"`
    static func formatAge(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 {
            return "\(total)s"
        } else if total < 3600 {
            return "\(total / 60)m"
        } else {
            return "\(total / 3600)h"
        }
    }

    // MARK: - Actions

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
