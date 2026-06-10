import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: TerminalSessionStore

    var body: some View {
        List(selection: $store.selection) {
            Section("Sessions") {
                ForEach(store.sessions) { session in
                    SidebarSessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                store.selection = session.id
                                store.duplicateSelectedSession()
                            }

                            Button("Mark Needs Attention", systemImage: "bell.badge") {
                                store.selection = session.id
                                store.markSelectedNeedsAttention()
                            }

                            Divider()

                            Button("Close", systemImage: "xmark") {
                                store.selection = session.id
                                store.closeSelectedSession()
                            }
                            .disabled(store.sessions.count == 1)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                store.createSession()
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.createSession()
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("New Session")
            }
        }
    }
}

private struct SidebarSessionRow: View {
    let session: TerminalSession

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(session.accent.color.opacity(0.18))
                    .frame(width: 20, height: 20)

                Image(systemName: iconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(session.accent.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .lineLimit(1)

                    if session.status == .attention {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var iconName: String {
        switch session.status {
        case .running:
            "terminal"
        case .idle:
            "pause"
        case .attention:
            "exclamationmark"
        }
    }

    private var subtitle: String {
        if let branch = session.branch {
            "\(session.workingDirectory) - \(branch)"
        } else {
            session.workingDirectory
        }
    }
}

#Preview {
    SidebarView(store: .preview)
}
