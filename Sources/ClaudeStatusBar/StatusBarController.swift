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
        updateTitle(with: latestSessions)
    }

    // MARK: - Menu bar dots

    /// Draws one colored dot per session (or a dim ring when idle), but only
    /// when the set of states has actually changed since the last render.
    private func updateTitle(with sessions: [SessionStatus]) {
        guard let button = statusItem.button else { return }

        let signature = sessions.isEmpty
            ? "idle"
            : sessions.map { $0.status.rawValue }.joined(separator: ",")

        guard signature != renderedSignature else { return }
        renderedSignature = signature

        button.image = Self.dotsImage(for: sessions.map { $0.status })
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
                let item = NSMenuItem(title: rowTitle(for: session),
                                      action: #selector(focusSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = session
                // Only clickable if we know which terminal to raise.
                item.isEnabled = Self.bundleIdentifier(for: session.termProgram) != nil
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
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
