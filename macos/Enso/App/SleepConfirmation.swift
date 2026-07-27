import AppKit

/// The put-to-sleep confirmation, shared by every entry point — the
/// sidebar's −, the context menu (single or bulk), ⌘W, and the palette.
/// Because selecting a tab clears its attention dot, a focused agent almost
/// always "looks busy", so this fires on the default path, not the
/// exception: it is a gentle stray-click guard — Cancel keeps Return, the
/// sleep takes a deliberate click, and "Don't ask me again" turns it off
/// for good.
@MainActor
enum SleepConfirmation {
    static let suppressionDefaultsKey = "sleepBusyConfirmationSuppressed"

    /// True when the sleep may proceed. Instant when no agent in the group
    /// looks busy, or when the user opted out of the warning.
    static func consentsToSleep(
        _ store: TerminalSessionStore,
        sessionIDs: Set<TerminalSession.ID>
    ) -> Bool {
        guard let agent = sessionIDs.lazy.compactMap({ store.busyAgent(inTab: $0) }).first else {
            return true
        }
        guard !UserDefaults.standard.bool(forKey: suppressionDefaultsKey) else { return true }

        let plural = sessionIDs.count > 1
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = plural ? "Put these tabs to sleep?" : "Put this tab to sleep?"
        // Soft on purpose: "looks" — the busy signal can't tell a working
        // agent from one idling at its prompt, so the copy must not
        // overclaim.
        alert.informativeText = plural
            ? "\(displayName(agent)) looks busy. Your conversations are saved "
                + "and resume when you wake them."
            : "\(displayName(agent)) looks busy. Your conversation is saved "
                + "and resumes when you wake the tab."

        // Put to Sleep keeps the primary position but not the Return key:
        // a stray-click guard must not have a destructive default, so
        // Return cancels and the sleep takes a deliberate click — and Esc,
        // which Cancel's key equivalent displaced, comes back through the
        // modal-scoped monitor.
        let sleep = alert.addButton(withTitle: "Put to Sleep")
        sleep.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask me again"
        alert.centerOverAppWindow()

        guard alert.runModalCancellingOnEscape(with: cancel) == .alertFirstButtonReturn else {
            // Cancelled: hand focus back to the terminal the alert covered.
            GhosttySurfaceManager.shared.restoreFocus(to: store.selection)
            return false
        }
        // The opt-out only sticks when they went through with the sleep —
        // checking it and then cancelling must not silence future asks.
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressionDefaultsKey)
        }
        return true
    }

    /// Friendly names only — user-facing strings never say "process".
    static func displayName(_ agent: TabProcess) -> String {
        switch agent {
        case .claude: "Claude"
        case .codex: "Codex"
        default: "The agent"
        }
    }
}
