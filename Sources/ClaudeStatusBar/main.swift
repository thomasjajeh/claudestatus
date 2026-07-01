import AppKit
import Foundation

/// Entry point for the Claude Status Bar menu bar app.
///
/// The app runs as an accessory (menu-bar-only, no Dock icon) and displays the
/// live traffic-light status of each running Claude Code CLI session.

/// Retains the app-lifetime objects and hosts the status bar controller.
///
/// Kept alive for the duration of the process by the strong reference held in
/// `main.swift`'s top level and by being the app delegate.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = StatusStore()
        let controller = StatusBarController(store: store)
        controller.start()
        self.controller = controller
    }
}

let app = NSApplication.shared

// Menu-bar-only: no Dock icon, no main window.
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
