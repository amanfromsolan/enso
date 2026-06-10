import Combine
import Foundation

@MainActor
final class TerminalSessionStore: ObservableObject {
    @Published private(set) var folders: [TerminalFolder]
    @Published var selection: TerminalSession.ID?

    init(folders: [TerminalFolder]? = nil) {
        let initialFolders = folders ?? Self.defaultFolders
        self.folders = initialFolders
        self.selection = initialFolders.first { !$0.sessions.isEmpty }?.sessions.first?.id
    }

    var sessions: [TerminalSession] {
        folders.flatMap(\.sessions)
    }

    var selectedSession: TerminalSession? {
        guard let selection else {
            return sessions.first
        }

        return sessions.first { $0.id == selection }
    }

    func createFolder() {
        let folder = TerminalFolder(title: "Folder \(folders.count + 1)")
        folders.append(folder)
    }

    func createSession(in folderID: TerminalFolder.ID? = nil) {
        ensureAtLeastOneFolder()

        let targetFolderID = folderID ?? selectedFolderID ?? folders[0].id
        let count = sessions.count + 1
        let session = TerminalSession(
            title: "Session \(count)",
            workingDirectory: "~/Documents/dev-projects/cmux-alternative",
            branch: "main",
            accent: .cycling(index: count - 1)
        )

        updateFolder(targetFolderID) { folder in
            folder.sessions.append(session)
        }
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

        let folderID = folderID(containing: selectedSession.id) ?? folders.first?.id
        guard let folderID else {
            return
        }

        updateFolder(folderID) { folder in
            folder.sessions.append(copy)
        }
        selection = copy.id
    }

    func closeSelectedSession() {
        guard let selection, sessions.count > 1 else {
            return
        }

        let flattened = sessions
        guard let currentIndex = flattened.firstIndex(where: { $0.id == selection }) else {
            return
        }

        for folderIndex in folders.indices {
            if let sessionIndex = folders[folderIndex].sessions.firstIndex(where: { $0.id == selection }) {
                folders[folderIndex].sessions.remove(at: sessionIndex)
                break
            }
        }

        let remaining = sessions
        let nextIndex = min(currentIndex, remaining.count - 1)
        self.selection = remaining[nextIndex].id
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

    func rename(_ folder: TerminalFolder, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        updateFolder(folder.id) { item in
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
        let flattened = sessions
        guard let selection, let index = flattened.firstIndex(where: { $0.id == selection }) else {
            self.selection = flattened.first?.id
            return
        }

        self.selection = flattened[(index + 1) % flattened.count].id
    }

    func focusPreviousSession() {
        let flattened = sessions
        guard let selection, let index = flattened.firstIndex(where: { $0.id == selection }) else {
            self.selection = flattened.first?.id
            return
        }

        let nextIndex = index == 0 ? flattened.count - 1 : index - 1
        self.selection = flattened[nextIndex].id
    }

    func focusSession(atShortcutIndex shortcutIndex: Int) {
        let index = shortcutIndex - 1
        let flattened = sessions
        guard flattened.indices.contains(index) else {
            return
        }

        selection = flattened[index].id
    }

    private var selectedFolderID: TerminalFolder.ID? {
        guard let selection else {
            return folders.first?.id
        }

        return folderID(containing: selection)
    }

    private func folderID(containing sessionID: TerminalSession.ID) -> TerminalFolder.ID? {
        folders.first { folder in
            folder.sessions.contains { $0.id == sessionID }
        }?.id
    }

    private func ensureAtLeastOneFolder() {
        if folders.isEmpty {
            folders.append(TerminalFolder(title: "Folder 1"))
        }
    }

    private func updateFolder(_ id: TerminalFolder.ID, mutate: (inout TerminalFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            return
        }

        mutate(&folders[index])
    }

    private func update(_ id: TerminalSession.ID, mutate: (inout TerminalSession) -> Void) {
        for folderIndex in folders.indices {
            guard let sessionIndex = folders[folderIndex].sessions.firstIndex(where: { $0.id == id }) else {
                continue
            }

            mutate(&folders[folderIndex].sessions[sessionIndex])
            return
        }
    }
}

extension TerminalSessionStore {
    static let defaultFolders: [TerminalFolder] = [
        TerminalFolder(
            title: "cmux-alternative",
            sessions: [
                TerminalSession(
                    title: "main",
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
                )
            ]
        ),
        TerminalFolder(
            title: "Logs",
            sessions: [
                TerminalSession(
                    title: "agent logs",
                    workingDirectory: "~/Library/Logs",
                    status: .attention,
                    accent: .orange
                )
            ]
        )
    ]

    static var preview: TerminalSessionStore {
        TerminalSessionStore(folders: defaultFolders)
    }
}
