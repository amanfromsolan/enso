import SwiftUI

struct TerminalWorkspaceView: View {
    @ObservedObject var store: TerminalSessionStore
    // Live theme switches change GhosttyRuntime.themeBackground; observing
    // the manager re-evaluates the body so the backing color tracks it.
    @ObservedObject private var themeManager = TerminalThemeManager.shared
    @State private var isRenaming = false
    @State private var draftTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            if let session = store.selectedSession {
                TerminalHeaderView(
                    session: session,
                    onRename: {
                        draftTitle = session.title
                        isRenaming = true
                    }
                )
            }

            // Always mounted: the host container persists across session
            // and space switches so the Metal surface swap lands in the
            // same commit as SwiftUI's redraw (see GhosttyTerminalHostView).
            GhosttyTerminalHostView(session: store.selectedSession, store: store)
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
        }
        .background(GhosttyRuntime.shared.themeBackground)
        // Space/tab switches run inside withAnimation; a cross-fade here
        // makes the SwiftUI header and the Metal-backed terminal (which
        // can't fade) diverge, flashing the empty state through. Commit
        // those instantly — but only those: scoped to selection changes so
        // the sidebar show/hide spring still animates the card's geometry.
        .transaction(value: store.selection) { $0.animation = nil }
        .sheet(isPresented: $isRenaming, onDismiss: {
            GhosttySurfaceManager.shared.restoreFocus(to: store.selection)
        }) {
            RenameSessionSheet(
                title: $draftTitle,
                onCancel: {
                    isRenaming = false
                },
                onSave: {
                    if let session = store.selectedSession {
                        store.rename(session, to: draftTitle)
                    }
                    isRenaming = false
                }
            )
        }
    }
}

private struct RenameSessionSheet: View {
    @Binding var title: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Tab")
                .font(.headline)

            TextField("Tab name", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

#Preview {
    TerminalWorkspaceView(store: .preview)
}
