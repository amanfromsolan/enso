import SwiftUI

struct TerminalWorkspaceView: View {
    @ObservedObject var store: TerminalSessionStore
    /// The single card's live corner radius (concentric with the window);
    /// split panes reuse it so each pane card matches the card exactly.
    let cardCornerRadius: CGFloat

    /// The selected UNSPLIT tab while it sleeps — the workspace then draws
    /// the full sleeping card in the single-card chrome. A sleeping pane
    /// of a split is the host's business instead: the split renders
    /// normally and that pane wears the in-pane moon.
    private var sleepingSelection: TerminalSession? {
        guard let session = store.selectedSession, session.isSleeping,
              store.splitContainer(containing: session.id) == nil else { return nil }
        return session
    }

    /// Split selection: panes render as individual cards on the window
    /// chrome, so the workspace itself must not paint the terminal
    /// background — the chrome shows through the gaps between cards.
    private var isSplitSelection: Bool {
        guard let selection = store.selection else { return false }
        return store.splitContainer(containing: selection) != nil
    }

    var body: some View {
        // Always mounted: the host container persists across session
        // and space switches so the Metal surface swap lands in the
        // same commit as SwiftUI's redraw (see GhosttyTerminalHostView).
        // Selecting any pane of a split shows the whole container. Each
        // pane draws its own in-pane header (the original strip when the
        // pane is wide, the stacked compact variant when its laid-out
        // width falls under the responsive threshold), so no chrome sits
        // above or across the splits — dividers run edge to edge through
        // the card.
        GhosttyTerminalHostView(
            session: store.selectedSession,
            container: store.selectedSession.flatMap { store.splitContainer(containing: $0.id) },
            store: store,
            paneCornerRadius: cardCornerRadius
        )
        .overlay {
            if store.selectedSession == nil {
                ContentUnavailableView(
                    "No Tabs",
                    systemImage: "terminal",
                    description: Text("Press ⌘T to open a new tab.")
                )
                // Sits on the terminal's theme background, which
                // stays dark regardless of app appearance — in
                // light mode the inherited dark-on-dark text would
                // vanish.
                .colorScheme(.dark)
            } else if let sleeping = sleepingSelection {
                // The sleeping card: no surface is mounted underneath (the
                // host skips the unsplit sleeping tab), just the summary on
                // the theme background. Clicking anywhere wakes — same
                // focus-to-wake contract as the sidebar rows.
                SleepingTabCard(session: sleeping) {
                    store.wake(sessionID: sleeping.id)
                }
            }
        }
        .background(isSplitSelection ? Color.clear : GhosttyRuntime.shared.themeBackground)
        // Space/tab switches run inside withAnimation; a cross-fade here
        // makes the SwiftUI pane headers and the Metal-backed terminal
        // (which can't fade) diverge, flashing the empty state through.
        // Commit those instantly — but only those: scoped to selection
        // changes so the sidebar show/hide spring still animates the
        // card's geometry.
        .transaction(value: store.selection) { $0.animation = nil }
    }

}

/// The card shown in place of an unsplit sleeping tab's terminal: the
/// moon, a plain summary of what was running (and where), and a click-
/// anywhere wake hint. No button — focusing the tab is what wakes it,
/// same as clicking its sidebar row.
private struct SleepingTabCard: View {
    let session: TerminalSession
    let wake: () -> Void

    /// Observed for the resume summary: whether a conversation picks back
    /// up is the wake marker's call, not detection's.
    @ObservedObject private var agentSessions = AgentSessionStore.shared

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            Text("This tab is sleeping")
                .font(.title3.weight(.semibold))

            Text(summary)
                .font(.system(size: 13))
                // Sentence-length copy that wraps: 1.6 line height
                // (13 pt type + 0.6× spacing) gives the lines air.
                .lineSpacing(13 * 0.6)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Text("Click anywhere to wake")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: wake)
        // Sits on the terminal's theme background, which stays dark
        // regardless of app appearance — same treatment as the No Tabs
        // state.
        .colorScheme(.dark)
    }

    // MARK: Summary copy

    private var summary: String {
        let place = Self.displayPath(session.workingDirectory)
        if let agent = agentSessions.sleepingAgent(forTab: session.id) {
            return "\(Self.processName(agent, capitalized: true)) was working in \(place). "
                + "Your conversation picks back up when you wake the tab."
        }
        if let process = session.sleepingProcess {
            // Honest: a non-agent process doesn't come back.
            return "\(Self.processName(process, capitalized: true)) was running in \(place). "
                + "The tab wakes to a fresh shell there."
        }
        return "It'll open fresh in \(place) when you wake it."
    }

    /// A friendly name for what was in the foreground. Agents keep their
    /// names; tool categories read as plain descriptions ("an editor"),
    /// capitalized only at sentence starts.
    private static func processName(_ process: TabProcess, capitalized: Bool) -> String {
        let name: String = switch process {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .ollama: "Ollama"
        case .opencode: "OpenCode"
        case .editor: "an editor"
        case .remote: "a remote session"
        case .git: "a Git command"
        case .runtime: "a program"
        case .container: "a container tool"
        case .monitor: "a system monitor"
        case .build: "a build"
        case .reader: "a viewer"
        case .unknown: "something"
        }
        guard capitalized, let first = name.first, first.isLowercase else { return name }
        return first.uppercased() + name.dropFirst()
    }

    /// Home-relative, and middle-truncated when a deep path would swallow
    /// the sentence.
    private static func displayPath(_ path: String) -> String {
        let abbreviated = (path as NSString).abbreviatingWithTildeInPath
        guard abbreviated.count > 44 else { return abbreviated }
        return "\(abbreviated.prefix(20))…\(abbreviated.suffix(20))"
    }
}

#Preview {
    TerminalWorkspaceView(store: .preview, cardCornerRadius: 10)
}
