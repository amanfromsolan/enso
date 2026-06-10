import SwiftUI

struct TerminalHeaderView: View {
    let session: TerminalSession
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(session.accent.color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(session.title)
                        .font(.headline)
                        .lineLimit(1)

                    StatusPill(status: session.status)
                }

                HStack(spacing: 8) {
                    Label(session.workingDirectory, systemImage: "folder")

                    if let branch = session.branch {
                        Label(branch, systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .labelStyle(.iconOnly)
            .help("Rename Session")

            Button {
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .help("Find in Terminal")

            Button {
            } label: {
                Label("Split", systemImage: "rectangle.split.2x1")
            }
            .labelStyle(.iconOnly)
            .help("Split Terminal")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(red: 0.035, green: 0.037, blue: 0.044))
    }
}

private struct StatusPill: View {
    let status: TerminalSession.Status

    var body: some View {
        Text(status.rawValue)
            .font(.caption2)
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(backgroundStyle, in: Capsule())
    }

    private var foregroundStyle: Color {
        switch status {
        case .running:
            .green
        case .idle:
            Color.secondary
        case .attention:
            .orange
        }
    }

    private var backgroundStyle: Color {
        switch status {
        case .running:
            .green.opacity(0.14)
        case .idle:
            Color.secondary.opacity(0.12)
        case .attention:
            .orange.opacity(0.16)
        }
    }
}

#Preview {
    TerminalHeaderView(session: TerminalSessionStore.defaultFolders[0].sessions[0], onRename: {})
}
