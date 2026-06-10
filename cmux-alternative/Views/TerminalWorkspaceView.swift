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

                    Divider()

                    GhosttyTerminalHostView(session: session)
                        .id(session.id)
                }
                .sheet(isPresented: $isRenaming) {
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
                    "No Session",
                    systemImage: "terminal",
                    description: Text("Create a session to start a terminal workspace.")
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.focusPreviousSession()
                } label: {
                    Label("Previous Session", systemImage: "chevron.left")
                }
                .help("Previous Session")

                Button {
                    store.focusNextSession()
                } label: {
                    Label("Next Session", systemImage: "chevron.right")
                }
                .help("Next Session")

                Divider()

                Button {
                    store.duplicateSelectedSession()
                } label: {
                    Label("Duplicate Session", systemImage: "plus.square.on.square")
                }
                .help("Duplicate Session")

                Button {
                    store.closeSelectedSession()
                } label: {
                    Label("Close Session", systemImage: "xmark")
                }
                .disabled(store.sessions.count == 1)
                .help("Close Session")
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
            Text("Rename Session")
                .font(.headline)

            TextField("Session name", text: $title)
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
