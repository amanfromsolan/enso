import AppKit

/// ⌘Q safety net. Quitting Enso kills every live terminal, so a quit
/// request (⌘Q, app menu, or Dock) with sessions still running surfaces a
/// native confirmation alert instead of terminating outright — the user has
/// to say so. The alert runs modally, so consentsToTerminate blocks on the
/// answer and there is no async quit state to track: NSApp.terminate calls
/// applicationShouldTerminate on the same thread, and runModal doesn't
/// re-enter it.
@MainActor
final class QuitGuard {
    static let shared = QuitGuard()

    private weak var store: TerminalSessionStore?

    /// Held only so cancelling can restore focus to the live selection.
    func attach(store: TerminalSessionStore) {
        self.store = store
    }

    /// Called from applicationShouldTerminate for every quit path.
    /// Returns whether termination may proceed.
    func consentsToTerminate() -> Bool {
        // Nothing to lose, nothing to confirm.
        guard let store, !store.sessions.isEmpty else { return true }
        // No visible window means no place to anchor a confirmation — and it
        // covers logout/shutdown after windows close, where cancelling would
        // make macOS report that Enso interrupted shutdown.
        guard NSApp.windows.contains(where: \.isVisible) else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Enso?"
        alert.informativeText = store.sessions.count == 1
            ? "This will end your terminal session and anything running in it."
            : "This will end all \(store.sessions.count) terminal sessions and anything running in them."

        // Quit stays the first button so it keeps Return and the default
        // styling — assigning it another key equivalent would replace both.
        let quit = alert.addButton(withTitle: "Quit")
        // Cancel is second, so it inherits Esc automatically.
        alert.addButton(withTitle: "Cancel")

        // Center the alert over the app window, not the screen. The modal
        // session re-centers the panel when it orders it front, so an origin
        // set here alone can be overridden — but the main queue is drained by
        // the modal run loop (NSModalPanelRunLoopMode is a common mode), so
        // an async block re-asserting the origin runs right after the panel
        // shows, after that centering. Setting it up front too keeps the
        // panel from visibly jumping on the first frame.
        if let host = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: \.isVisible) {
            // The panel's frame is only meaningful once the alert has laid
            // out its content; layout() forces that before measuring.
            alert.layout()
            let size = alert.window.frame.size
            var origin = NSPoint(
                x: host.frame.midX - size.width / 2,
                y: host.frame.midY - size.height / 2
            )
            // Keep the dialog on the host's screen when the window hangs
            // near or off an edge.
            if let screen = (host.screen ?? NSScreen.main)?.visibleFrame {
                origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
                origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
            }
            alert.window.setFrameOrigin(origin)
            DispatchQueue.main.async { [window = alert.window] in
                window.setFrameOrigin(origin)
            }
        }

        // ⌘Q again should confirm, but the alert has no button bound to it,
        // so a monitor scoped to the modal session clicks Quit for the chord
        // (performClick ends runModal with that button's code). Everything
        // else passes through untouched — the modal loop already handles
        // Return and Esc.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let isQuitChord = event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "q"
            guard isQuitChord else { return event }
            quit.performClick(nil)
            return nil
        }
        let response = alert.runModal()
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }

        if response == .alertFirstButtonReturn {
            return true
        }
        // Cancelled: hand focus back to the terminal the alert covered.
        GhosttySurfaceManager.shared.restoreFocus(to: store.selection)
        return false
    }
}

/// AppKit lifecycle hook for EnsoApp; SwiftUI has no native quit intercept.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitGuard.shared.consentsToTerminate() ? .terminateNow : .terminateCancel
    }
}
