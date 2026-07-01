import AppKit
import Foundation

/// Owns the `NSStatusItem` in the system menu bar and keeps it in sync with the
/// on-disk session status files.
///
/// Responsibilities:
/// - Render one colored dot per active session in the menu bar, drawn as a
///   vector image (not emoji) so the colors are crisp and never fall back to a
///   monochrome text glyph.
/// - Poll the status directory on a repeating timer, updating the bar only when
///   the rendered content actually changes (so it doesn't flicker every tick).
/// - Build the dropdown menu lazily, when it's opened, so per-row "updated Ns
///   ago" text is fresh and the menu is never rebuilt mid-poll.
final class StatusBarController: NSObject, NSMenuDelegate {

    /// How often the status directory is re-scanned.
    private static let pollInterval: TimeInterval = 1.5

    // Dot geometry (points). Vector-drawn, so these scale crisply on retina.
    private static let dotDiameter: CGFloat = 13
    private static let dotGap: CGFloat = 5
    private static let imageHeight: CGFloat = 18

    private let statusItem: NSStatusItem
    private let store: StatusStore
    private var pollTimer: Timer?

    /// The most recently loaded sessions; read by the menu delegate on open.
    private var latestSessions: [SessionStatus] = []

    /// Pending approval requests keyed by session id, from the blocking hook.
    private var latestRequests: [String: PendingRequest] = [:]

    /// Session ids the user chose to auto-approve for the rest of their run.
    private var latestAllowed: Set<String> = []

    /// Signature of what is currently drawn in the bar. Used to skip redundant
    /// redraws — reassigning the button image every tick is what caused the
    /// visible flicker.
    private var renderedSignature: String = ""

    /// - Parameter store: The status store to read sessions from.
    init(store: StatusStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    /// Performs first-run setup and begins polling. Call once at launch.
    func start() {
        store.ensureDirectoryExists()

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Claude Code session status")
        }

        // Attach the menu once and populate it on demand via the delegate.
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

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

    /// Re-reads the sessions from disk and updates the bar if anything changed.
    private func refresh() {
        latestSessions = store.loadActiveSessions()
        latestRequests = store.loadPendingRequests()
        latestAllowed = store.loadAllowedSessions()
        updateTitle()
    }

    /// The state to display for a session: a pending approval forces red,
    /// otherwise the session's own reported status.
    private func effectiveState(for session: SessionStatus) -> SessionState {
        latestRequests[session.sessionId] != nil ? .red : session.status
    }

    // MARK: - Menu bar dots

    /// Draws one colored dot per session (or a dim ring when idle), but only
    /// when the set of states has actually changed since the last render.
    private func updateTitle() {
        guard let button = statusItem.button else { return }

        let states = latestSessions.map { effectiveState(for: $0) }
        let signature = states.isEmpty
            ? "idle"
            : states.map { $0.rawValue }.joined(separator: ",")

        guard signature != renderedSignature else { return }
        renderedSignature = signature

        button.image = Self.dotsImage(for: states)
    }

    /// Renders a horizontal row of filled circles into an `NSImage`. When there
    /// are no sessions, draws a single dim outlined ring so the item stays
    /// visible and clickable.
    private static func dotsImage(for states: [SessionState]) -> NSImage {
        let count = max(states.count, 1)
        let width = CGFloat(count) * dotDiameter + CGFloat(count - 1) * dotGap
        let size = NSSize(width: width, height: imageHeight)

        let image = NSImage(size: size, flipped: false) { rect in
            let y = (rect.height - dotDiameter) / 2

            if states.isEmpty {
                let ring = NSBezierPath(ovalIn: NSRect(x: 0.75, y: y + 0.75,
                                                       width: dotDiameter - 1.5,
                                                       height: dotDiameter - 1.5))
                NSColor.tertiaryLabelColor.setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            } else {
                for (index, state) in states.enumerated() {
                    let x = CGFloat(index) * (dotDiameter + dotGap)
                    let circle = NSBezierPath(ovalIn: NSRect(x: x, y: y,
                                                             width: dotDiameter,
                                                             height: dotDiameter))
                    state.color.setFill()
                    circle.fill()
                }
            }
            return true
        }
        // Keep full color — a template image would be forced to monochrome.
        image.isTemplate = false
        return image
    }

    // MARK: - Dropdown menu (built lazily on open)

    /// Called by AppKit just before the menu is displayed. Rebuilding here (not
    /// on every poll) keeps the "updated Ns ago" text fresh without flicker.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if latestSessions.isEmpty {
            let empty = NSMenuItem(title: "No active Claude sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Click a session to jump to its terminal:",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for session in latestSessions {
                if let request = latestRequests[session.sessionId] {
                    addApprovalRows(for: session, request: request, to: menu)
                } else {
                    addSessionRow(for: session, to: menu)
                }
            }
        }

        menu.addItem(.separator())

        // Approval-queue toggle. Off by default; when on, gated tool calls wait
        // for an Approve/Deny click here instead of prompting in the terminal.
        let toggle = NSMenuItem(title: "Approve tool calls from here",
                                action: #selector(toggleApprovalQueue), keyEquivalent: "")
        toggle.target = self
        toggle.state = store.isApprovalEnabled() ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Adds a "needs approval" row plus indented Approve / Approve-all / Deny
    /// items for a session the blocking hook is currently waiting on.
    private func addApprovalRows(for session: SessionStatus, request: PendingRequest, to menu: NSMenu) {
        var title = "🔴 \(session.project) — approve \(request.toolName)?"
        if !request.summary.isEmpty {
            title += "  \(request.summary)"
        }
        let head = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)

        addIndented("✅ Approve", #selector(approveRequest(_:)), session.sessionId, to: menu)
        addIndented("✅ Approve — allow rest of this session",
                    #selector(approveSessionAll(_:)), session.sessionId, to: menu)
        addIndented("🛑 Deny", #selector(denyRequest(_:)), session.sessionId, to: menu)
    }

    /// Adds a normal (non-pending) session row: click to jump to its terminal.
    /// If the session is set to auto-approve, notes that and offers to stop.
    private func addSessionRow(for session: SessionStatus, to menu: NSMenu) {
        let autoApproving = latestAllowed.contains(session.sessionId)
        var title = rowTitle(for: session)
        if autoApproving {
            title += " · auto-approving"
        }

        let item = NSMenuItem(title: title, action: #selector(focusSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = session
        // Only clickable if we know which terminal to raise.
        item.isEnabled = Self.bundleIdentifier(for: session.termProgram) != nil
        menu.addItem(item)

        if autoApproving {
            addIndented("↩︎ Stop auto-approving this session",
                        #selector(stopAutoApprove(_:)), session.sessionId, to: menu)
        }
    }

    /// Convenience: append an indented, targeted menu item carrying a session id.
    private func addIndented(_ title: String, _ action: Selector, _ sessionId: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = sessionId
        item.indentationLevel = 1
        menu.addItem(item)
    }

    /// Formats a single dropdown row, e.g. `🟠 macWidget — working · updated 3s ago`.
    private func rowTitle(for session: SessionStatus) -> String {
        let age = Self.formatAge(session.secondsSinceUpdate())
        return "\(session.status.dot) \(session.project) — \(session.status.label) · updated \(age) ago"
    }

    // MARK: - Jump to terminal

    /// Brings the terminal app hosting the clicked session to the front so the
    /// user can respond to Claude. Note: this raises the terminal *application*;
    /// it can't focus the exact tab/window, nor answer the prompt for you.
    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionStatus,
              let bundleId = Self.bundleIdentifier(for: session.termProgram) else { return }

        let workspace = NSWorkspace.shared
        if let running = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            running.activate(options: [.activateIgnoringOtherApps])
        } else if let url = workspace.urlForApplication(withBundleIdentifier: bundleId) {
            workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Maps a `$TERM_PROGRAM` value to the terminal app's bundle identifier.
    /// Returns `nil` for unknown/empty values (row stays non-clickable).
    private static func bundleIdentifier(for termProgram: String?) -> String? {
        switch termProgram {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app":      return "com.googlecode.iterm2"
        case "vscode":         return "com.microsoft.VSCode"
        case "ghostty":        return "com.mitchellh.ghostty"
        case "WezTerm":        return "com.github.wez.wezterm"
        case "Hyper":          return "co.zeit.hyper"
        case "Warp":           return "dev.warp.Warp-Stable"
        case "Tabby":          return "org.tabby"
        case "kitty":          return "net.kovidgoyal.kitty"
        case "Alacritty":      return "org.alacritty"
        default:               return nil
        }
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

    // MARK: - Approval actions

    @objc private func approveRequest(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        store.writeDecision(sessionId: sessionId, allow: true)
        // Drop it from our local view immediately so the dot/menu update without
        // waiting for the next poll.
        latestRequests[sessionId] = nil
        updateTitle()
    }

    @objc private func denyRequest(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        store.writeDecision(sessionId: sessionId, allow: false)
        latestRequests[sessionId] = nil
        updateTitle()
    }

    /// Approve the pending call *and* auto-approve the rest of this session.
    @objc private func approveSessionAll(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        store.allowSessionForRest(sessionId: sessionId)
        store.writeDecision(sessionId: sessionId, allow: true)
        latestRequests[sessionId] = nil
        latestAllowed.insert(sessionId)
        updateTitle()
    }

    /// Cancel a session's auto-approval; future calls will queue again.
    @objc private func stopAutoApprove(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        store.revokeSessionAllow(sessionId: sessionId)
        latestAllowed.remove(sessionId)
    }

    @objc private func toggleApprovalQueue() {
        store.setApprovalEnabled(!store.isApprovalEnabled())
    }

    // MARK: - Actions

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

/// AppKit color mapping for each state. Kept out of `SessionState` so the model
/// file stays Foundation-only.
private extension SessionState {
    var color: NSColor {
        switch self {
        case .green:  return .systemGreen
        case .orange: return .systemOrange
        case .red:    return .systemRed
        }
    }
}
