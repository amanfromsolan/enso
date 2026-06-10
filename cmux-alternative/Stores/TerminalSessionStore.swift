import Combine
import Foundation

@MainActor
final class TerminalSessionStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession]
    @Published var selection: TerminalSession.ID?

    init(sessions: [TerminalSession]? = nil) {
        let initialSessions = sessions ?? Self.defaultSessions
        self.sessions = initialSessions
        self.selection = initialSessions.first?.id
    }

    var selectedSession: TerminalSession? {
        guard let selection else {
            return sessions.first
        }

        return sessions.first { $0.id == selection }
    }

    func createSession() {
        let count = sessions.count + 1
        let session = TerminalSession(
            title: "Session \(count)",
            workingDirectory: "~/Documents/dev-projects/cmux-alternative",
            branch: "main",
            accent: .cycling(index: count - 1)
        )
        sessions.append(session)
        selection = session.id
    }

    func duplicateSelectedSession() {
        guard let selectedSession else {
            createSession()
            return
        }

        let copy = TerminalSession(
            title: "\(selectedSession.title) Copy",
            workingDirectory: selectedSession.workingDirectory,
            branch: selectedSession.branch,
            status: .running,
            accent: .cycling(index: sessions.count),
            lastActivity: .now
        )
        sessions.append(copy)
        selection = copy.id
    }

    func closeSelectedSession() {
        guard let selection, sessions.count > 1 else {
            return
        }

        guard let index = sessions.firstIndex(where: { $0.id == selection }) else {
            return
        }

        sessions.remove(at: index)
        let nextIndex = min(index, sessions.count - 1)
        self.selection = sessions[nextIndex].id
    }

    func rename(_ session: TerminalSession, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        update(session.id) { item in
            item.title = trimmed
        }
    }

    func markSelectedNeedsAttention() {
        guard let selection else {
            return
        }

        update(selection) { item in
            item.status = .attention
            item.lastActivity = .now
        }
    }

    func focusNextSession() {
        guard let selection, let index = sessions.firstIndex(where: { $0.id == selection }) else {
            self.selection = sessions.first?.id
            return
        }

        self.selection = sessions[(index + 1) % sessions.count].id
    }

    func focusPreviousSession() {
        guard let selection, let index = sessions.firstIndex(where: { $0.id == selection }) else {
            self.selection = sessions.first?.id
            return
        }

        let nextIndex = index == 0 ? sessions.count - 1 : index - 1
        self.selection = sessions[nextIndex].id
    }

    func focusSession(atShortcutIndex shortcutIndex: Int) {
        let index = shortcutIndex - 1
        guard sessions.indices.contains(index) else {
            return
        }

        selection = sessions[index].id
    }

    private func update(_ id: TerminalSession.ID, mutate: (inout TerminalSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }

        mutate(&sessions[index])
    }
}

extension TerminalSessionStore {
    static let defaultSessions: [TerminalSession] = [
        TerminalSession(
            title: "cmux-alternative",
            workingDirectory: "~/Documents/dev-projects/cmux-alternative",
            branch: "main",
            status: .running,
            accent: .blue
        ),
        TerminalSession(
            title: "scratch",
            workingDirectory: "~/Desktop",
            status: .idle,
            accent: .green
        ),
        TerminalSession(
            title: "agent logs",
            workingDirectory: "~/Library/Logs",
            status: .attention,
            accent: .orange
        )
    ]

    static var preview: TerminalSessionStore {
        TerminalSessionStore(sessions: defaultSessions)
    }
}
