import AppKit

/// The close confirmation, shared by every entry point that closes on a
/// user's gesture — the pane header's ×, the sidebar row's ×, the context
/// menu (single or bulk), ⌘W, the palette, and Delete Space. Sleep's twin,
/// with the stakes reversed: a sleep parks the conversation, a close
/// destroys it, so the copy names what is lost. Opt-in rather than
/// always-on — closing a tab is the ordinary gesture and most tabs have
/// nothing left to lose — so it fires only while "Confirm before closing
/// tabs" is on.
@MainActor
enum CloseConfirmation {
    /// The Settings toggle's own @AppStorage key. The alert's "Don't ask
    /// me again" clears it and the toggle sets it again, so the checkbox
    /// is a round trip instead of a one-way door. Unset means on.
    static let enabledDefaultsKey = "confirmCloseTabs"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// What the gesture destroys. Only the copy differs between the two —
    /// a space's tabs are closed by exactly the same path.
    enum Subject {
        case tabs
        case space
    }

    /// What the group has left to lose, in the order the copy names it.
    /// Nil means nothing worth stopping the user for. Kept separate from
    /// the alert so the decision — which is where the bugs live — can be
    /// tested without a modal session.
    enum Stake: Equatable {
        /// An agent is at work in the group right now.
        case busyAgent(TabProcess)
        /// No live agent, but a saved conversation the close would throw
        /// away: a sleeping tab, or a dormant one after relaunch. These
        /// are the tabs with the MOST to lose and the least to show for
        /// it — no process, no output, just a moon — so they must prompt.
        case savedConversation(TabProcess)
        /// Something the app can't name is still running.
        case runningSomething
    }

    /// The pure decision behind the alert. `savedConversation` is
    /// injectable because the real answer lives in the shared
    /// AgentSessionStore, which unit tests don't drive.
    static func stake(
        _ store: TerminalSessionStore,
        sessionIDs: Set<TerminalSession.ID>,
        savedConversation: ((TerminalSession.ID) -> TabProcess?)? = nil
    ) -> Stake? {
        // An agent names itself in the copy; anything else is described
        // generically, so the agent lookups run first and the plain
        // "something is running" check only backstops them.
        if let agent = sessionIDs.lazy.compactMap({ store.busyAgent(inTab: $0) }).first {
            return .busyAgent(agent)
        }
        let savedConversation = savedConversation ?? Self.savedConversationAgent
        if let agent = sessionIDs.lazy.compactMap({ savedConversation($0) }).first {
            return .savedConversation(agent)
        }
        return sessionIDs.contains { isRunningSomething(store, $0) } ? .runningSomething : nil
    }

    /// A conversation the tab is holding for later with no process to show
    /// for it: parked by an explicit sleep, or dormant since relaunch —
    /// after which every agent tab comes back with `runningProcess` nil, so
    /// this is the only signal that ⌘W is about to destroy something.
    private static func savedConversationAgent(_ sessionID: TerminalSession.ID) -> TabProcess? {
        AgentSessionStore.shared.sleepingAgent(forTab: sessionID)
            ?? AgentSessionStore.shared.dormantAgent(forTab: sessionID)
    }

    /// True when the close may proceed. Instant when the preference is
    /// off, or when the group has nothing left to lose.
    static func consentsToClose(
        _ store: TerminalSessionStore,
        sessionIDs: Set<TerminalSession.ID>,
        subject: Subject = .tabs
    ) -> Bool {
        guard isEnabled else { return true }
        guard let stake = stake(store, sessionIDs: sessionIDs) else { return true }

        let plural = sessionIDs.count > 1
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = switch subject {
        case .space: "Delete this space?"
        case .tabs: plural ? "Close these tabs?" : "Close this tab?"
        }
        alert.informativeText = informativeText(for: stake, subject: subject, plural: plural)

        // The destructive button keeps the primary position but not the
        // Return key: a guard in front of a destructive action must not
        // have a destructive default, so Return cancels…
        let proceed = alert.addButton(withTitle: subject == .space ? "Delete" : "Close")
        proceed.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask me again"
        alert.centerOverAppWindow()

        // …and Esc, which Cancel's own key equivalent displaced, comes
        // back through the modal-scoped monitor.
        guard alert.runModalCancellingOnEscape(with: cancel) == .alertFirstButtonReturn else {
            // Cancelled: hand focus back to the terminal the alert covered.
            GhosttySurfaceManager.shared.restoreFocus(to: store.selection)
            return false
        }
        // The opt-out only sticks when they went through with the close —
        // checking it and then cancelling must not silence future asks.
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(false, forKey: enabledDefaultsKey)
        }
        return true
    }

    /// Delete Space — the one gesture that closes a whole space's worth of
    /// tabs at once. Both menu items route through here so the ask happens
    /// once, for the space rather than per tab, and the teardown goes
    /// through `close` like every other exit.
    static func deleteSpace(_ store: TerminalSessionStore, _ spaceID: SidebarSpace.ID) {
        guard let space = store.spaces.first(where: { $0.id == spaceID }) else { return }
        guard consentsToClose(
            store, sessionIDs: Set(space.sessions.map(\.id)), subject: .space
        ) else { return }
        store.deleteSpace(spaceID)
    }

    /// "looks busy" for the same reason sleep hedges: the busy signal
    /// can't tell a working agent from one idling at its prompt.
    private static func informativeText(for stake: Stake, subject: Subject, plural: Bool) -> String {
        switch (stake, subject) {
        case (.busyAgent(let agent), .space):
            "\(SleepConfirmation.displayName(agent)) looks busy. "
                + "Deleting this space ends it and discards the conversation."
        case (.busyAgent(let agent), .tabs):
            plural
                ? "\(SleepConfirmation.displayName(agent)) looks busy. "
                    + "Closing ends it and discards the conversations."
                : "\(SleepConfirmation.displayName(agent)) looks busy. "
                    + "Closing ends it and discards the conversation."
        case (.savedConversation(let agent), .space):
            "\(SleepConfirmation.displayName(agent))'s conversation is saved here. "
                + "Deleting this space discards it."
        case (.savedConversation(let agent), .tabs):
            plural
                ? "\(SleepConfirmation.displayName(agent))'s conversation is saved here. "
                    + "Closing these tabs discards it."
                : "\(SleepConfirmation.displayName(agent))'s conversation is saved here. "
                    + "Closing discards it."
        case (.runningSomething, .space):
            "Something's still running. Deleting this space ends it."
        case (.runningSomething, .tabs):
            plural
                ? "Something's still running. Closing these tabs ends it."
                : "Something's still running. Closing ends it."
        }
    }

    /// Whether the tab has anything live to end. `runningProcess` is nil
    /// exactly when the shell is back at an idle prompt, and a sleeping
    /// tab has no shell at all — so this is the same "still running"
    /// signal the sidebar's badge draws from.
    private static func isRunningSomething(
        _ store: TerminalSessionStore,
        _ sessionID: TerminalSession.ID
    ) -> Bool {
        guard let session = store.sessions.first(where: { $0.id == sessionID }) else { return false }
        return !session.isSleeping && session.runningProcess != nil
    }
}
