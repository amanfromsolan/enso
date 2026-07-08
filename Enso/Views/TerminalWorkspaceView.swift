import SwiftUI

struct TerminalWorkspaceView: View {
    @ObservedObject var store: TerminalSessionStore
    @State private var isRenaming = false
    @State private var draftTitle = ""

    var body: some View {
        Group {
            if let session = store.selectedSession {
                VStack(spacing: 0) {
                    TerminalHeaderView(
                        session: session,
                        onRename: {
                            draftTitle = session.title
                            isRenaming = true
                        }
                    )

                    GhosttyTerminalHostView(session: session, store: store)
                }
                .background(GhosttyRuntime.shared.themeBackground)
                .sheet(isPresented: $isRenaming, onDismiss: {
                    GhosttySurfaceManager.shared.restoreFocus(to: store.selection)
                }) {
                    RenameSessionSheet(
                        title: $draftTitle,
                        onCancel: {
                            isRenaming = false
                        },
                        onSave: {
                            store.rename(session, to: draftTitle)
                            isRenaming = false
                        }
                    )
                }
            } else {
                ContentUnavailableView(
                    "No Tabs",
                    systemImage: "terminal",
                    description: Text("Press ⌘T to open a new tab.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GhosttyRuntime.shared.themeBackground)
            }
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
