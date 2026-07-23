import SwiftUI

struct TerminalWorkspaceView: View {
    @ObservedObject var store: TerminalSessionStore

    var body: some View {
        // Always mounted: the host container persists across session
        // and space switches so the Metal surface swap lands in the
        // same commit as SwiftUI's redraw (see GhosttyTerminalHostView).
        // Selecting any pane of a split shows the whole container. Each
        // pane draws its own in-pane header (the original strip for
        // unsplit tabs and full-width panes, the stacked compact variant
        // only for horizontally narrowed ones), so no chrome sits above
        // or across the splits — dividers run edge to edge through the
        // card.
        GhosttyTerminalHostView(
            session: store.selectedSession,
            container: store.selectedSession.flatMap { store.splitContainer(containing: $0.id) },
            store: store
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
            }
        }
        .background(GhosttyRuntime.shared.themeBackground)
        // Space/tab switches run inside withAnimation; a cross-fade here
        // makes the SwiftUI pane headers and the Metal-backed terminal
        // (which can't fade) diverge, flashing the empty state through.
        // Commit those instantly — but only those: scoped to selection
        // changes so the sidebar show/hide spring still animates the
        // card's geometry.
        .transaction(value: store.selection) { $0.animation = nil }
    }
}

#Preview {
    TerminalWorkspaceView(store: .preview)
}
