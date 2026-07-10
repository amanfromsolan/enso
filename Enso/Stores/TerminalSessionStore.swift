import Combine
import Foundation

@MainActor
final class TerminalSessionStore: ObservableObject {
    /// Swipeable sidebar spaces; always at least one.
    @Published private(set) var spaces: [SidebarSpace]
    @Published private(set) var activeSpaceID: SidebarSpace.ID

    @Published var selection: TerminalSession.ID? {
        didSet {
            touch(selection)
            recordRecency(selection)
        }
    }
    /// Rows highlighted for multi-select actions (folder creation, bulk close).
    @Published var multiSelection: Set<TerminalSession.ID> = []

    /// Most-recently-used selection order per space; drives the Ctrl-Tab
    /// switcher. Session-only — falls back to display order on launch.
    private var recency: [SidebarSpace.ID: [TerminalSession.ID]] = [:]
    /// While the Ctrl-Tab switcher previews tabs, selection changes must not
    /// reshuffle recency; the switcher records its final pick on commit.
    var isCyclingSelection = false

    /// Folders the user collapsed; session-only, shared by the docked
    /// sidebar and the edge-peek panel so state survives sidebar hiding.
    /// Inverted (collapsed, not expanded) so new folders start open.
    @Published var collapsedFolderIDs: Set<TerminalFolder.ID> = []

    /// Sidebar visibility (⌘B / titlebar button); remembered across launches.
    @Published var isSidebarVisible: Bool = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isSidebarVisible, forKey: "sidebarVisible") }
    }

    /// The one source of truth for the sidebar's width — every layout that
    /// once hardcoded 248 now follows this. The trailing-edge drag handle
    /// writes it live; the setter hard-clamps so no caller can push it out
    /// of range, and it survives launches.
    static let defaultSidebarWidth: CGFloat = 248
    static let minSidebarWidth: CGFloat = 200
    static let maxSidebarWidth: CGFloat = 360

    @Published private(set) var sidebarWidth: CGFloat = {
        let stored = UserDefaults.standard.object(forKey: "sidebarWidth") as? Double
        let value = stored.map { CGFloat($0) } ?? TerminalSessionStore.defaultSidebarWidth
        return min(TerminalSessionStore.maxSidebarWidth,
                   max(TerminalSessionStore.minSidebarWidth, value))
    }() {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "sidebarWidth") }
    }

    /// The one entry point for resizing (the trailing-edge drag handle),
    /// clamped so the width can never leave [min, max] no matter the caller.
    func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth = min(Self.maxSidebarWidth, max(Self.minSidebarWidth, width))
    }

    private var expiryTimer: Timer?
    private let persistToDisk: Bool

    init(spaces: [SidebarSpace]? = nil, persistToDisk: Bool = true) {
        self.persistToDisk = persistToDisk

        var loaded: [SidebarSpace]
        if let spaces {
            loaded = spaces
        } else if persistToDisk, let state = Self.loadState() {
            loaded = state.spaces
        } else {
            loaded = []
        }

        if loaded.isEmpty {
            loaded = [SidebarSpace(name: "Main", ephemeralSessions: [Self.makeSession()])]
        }

        self.spaces = loaded
        self.activeSpaceID = loaded[0].id

        pruneExpiredEphemeralSessions()

        if activeSpace.sessions.isEmpty, let first = self.spaces.first(where: { !$0.sessions.isEmpty }) {
            self.activeSpaceID = first.id
        }
        selection = activeSpace.lastSelection ?? activeSpace.sessions.first?.id

        if persistToDisk {
            let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.pruneExpiredEphemeralSessions()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            expiryTimer = timer
        }
    }

    // MARK: - Spaces

    var activeSpace: SidebarSpace {
        spaces.first { $0.id == activeSpaceID } ?? spaces[0]
    }

    func setActiveSpace(_ spaceID: SidebarSpace.ID) {
        guard spaceID != activeSpaceID, spaces.contains(where: { $0.id == spaceID }) else { return }
        withSpace(activeSpaceID) { $0.lastSelection = selection }
        activeSpaceID = spaceID
        selection = activeSpace.lastSelection.flatMap { last in
            activeSpace.sessions.contains { $0.id == last } ? last : nil
        } ?? activeSpace.sessions.first?.id
        multiSelection = selection.map { [$0] } ?? []
        save()
    }

    @discardableResult
    func createSpace(name: String, icon: SidebarSpace.Icon) -> SidebarSpace.ID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let space = SidebarSpace(
            name: trimmed.isEmpty ? "Space \(spaces.count + 1)" : trimmed,
            icon: icon,
            ephemeralSessions: [Self.makeSession()]
        )
        spaces.append(space)
        setActiveSpace(space.id)
        save()
        return space.id
    }

    func renameSpace(_ spaceID: SidebarSpace.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withSpace(spaceID) { $0.name = trimmed }
        save()
    }

    func updateSpace(_ spaceID: SidebarSpace.ID, name: String, icon: SidebarSpace.Icon) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        withSpace(spaceID) { space in
            if !trimmed.isEmpty {
                space.name = trimmed
            }
            space.icon = icon
        }
        save()
    }

    func deleteSpace(_ spaceID: SidebarSpace.ID) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        let removed = spaces[index]
        for session in removed.sessions {
            GhosttySurfaceManager.shared.closeSurface(for: session.id)
        }
        spaces.remove(at: index)
        if activeSpaceID == spaceID {
            let fallback = spaces[min(index, spaces.count - 1)]
            activeSpaceID = fallback.id
            selection = fallback.lastSelection ?? fallback.sessions.first?.id
        }
        save()
    }

    // MARK: - Derived collections

    /// Every session across all spaces (surface bookkeeping, title sync).
    var sessions: [TerminalSession] {
        spaces.flatMap(\.sessions)
    }

    var selectedSession: TerminalSession? {
        guard let selection else { return nil }
        return sessions.first { $0.id == selection }
    }

    func isPinned(_ sessionID: TerminalSession.ID) -> Bool {
        !spaces.contains { $0.ephemeralSessions.contains { $0.id == sessionID } }
    }

    // MARK: - Creation

    /// ⌘N and the command center default: new terminals continue in the
    /// selected tab's working directory rather than resetting to home.
    func createSessionInheritingWorkingDirectory() {
        createSession(workingDirectory: selectedSession?.workingDirectory)
    }

    func createSession(inSpace spaceID: SidebarSpace.ID? = nil, workingDirectory: String? = nil) {
        let targetID = spaceID ?? activeSpaceID
        let session = Self.makeSession(workingDirectory: workingDirectory, accentIndex: sessions.count)
        withSpace(targetID) { space in
            space.ephemeralSessions.append(session)
        }
        if targetID != activeSpaceID {
            setActiveSpace(targetID)
        }
        selection = session.id
        multiSelection = [session.id]
        save()
    }

    /// Palette "New Terminal in Current Folder": inherits the given working
    /// directory (the selected tab's cwd) and lands beside the selection —
    /// inside the same folder when the selected tab is filed under one,
    /// otherwise immediately after it in its container (loose pinned or
    /// ephemeral). Falls back to a loose append when nothing is selected.
    func createSession(besideSelectionWithWorkingDirectory workingDirectory: String?) {
        guard let selectedID = selection else {
            createSession(workingDirectory: workingDirectory)
            return
        }
        let session = Self.makeSession(workingDirectory: workingDirectory, accentIndex: sessions.count)

        for spaceIndex in spaces.indices {
            var inserted = false
            var revealFolderID: TerminalFolder.ID?

            if let index = spaces[spaceIndex].pinnedSessions.firstIndex(where: { $0.id == selectedID }) {
                spaces[spaceIndex].pinnedSessions.insert(session, at: index + 1)
                inserted = true
            } else {
                for folderIndex in spaces[spaceIndex].pinnedFolders.indices {
                    if let index = spaces[spaceIndex].pinnedFolders[folderIndex].sessions.firstIndex(where: { $0.id == selectedID }) {
                        spaces[spaceIndex].pinnedFolders[folderIndex].sessions.insert(session, at: index + 1)
                        revealFolderID = spaces[spaceIndex].pinnedFolders[folderIndex].id
                        inserted = true
                        break
                    }
                }
                if !inserted, let index = spaces[spaceIndex].ephemeralSessions.firstIndex(where: { $0.id == selectedID }) {
                    spaces[spaceIndex].ephemeralSessions.insert(session, at: index + 1)
                    inserted = true
                }
            }

            guard inserted else { continue }
            if spaces[spaceIndex].id != activeSpaceID {
                setActiveSpace(spaces[spaceIndex].id)
            }
            // Reveal the new tab even if its folder was collapsed.
            if let revealFolderID {
                collapsedFolderIDs.remove(revealFolderID)
            }
            selection = session.id
            multiSelection = [session.id]
            save()
            return
        }

        // Selection vanished mid-flight; don't drop the new tab.
        createSession(workingDirectory: workingDirectory)
    }

    /// New terminal inside a folder, continuing in the working directory of
    /// the folder's most recently active tab (home for an empty folder).
    func createSession(inFolder folderID: TerminalFolder.ID) {
        for spaceIndex in spaces.indices {
            guard let folderIndex = spaces[spaceIndex].pinnedFolders.firstIndex(where: { $0.id == folderID }) else {
                continue
            }
            let folder = spaces[spaceIndex].pinnedFolders[folderIndex]
            let cwd = folder.sessions.max(by: { $0.lastActivity < $1.lastActivity })?.workingDirectory
            let session = Self.makeSession(workingDirectory: cwd, accentIndex: sessions.count)
            spaces[spaceIndex].pinnedFolders[folderIndex].sessions.append(session)
            if spaces[spaceIndex].id != activeSpaceID {
                setActiveSpace(spaces[spaceIndex].id)
            }
            // Reveal the new tab even if the folder was collapsed.
            collapsedFolderIDs.remove(folderID)
            selection = session.id
            multiSelection = [session.id]
            save()
            return
        }
    }

    func createFolder(inSpace spaceID: SidebarSpace.ID? = nil) {
        withSpace(spaceID ?? activeSpaceID) { space in
            space.pinnedFolders.append(TerminalFolder(title: "Folder \(space.pinnedFolders.count + 1)"))
        }
        save()
    }

    /// Moves the given sessions into a new pinned folder in the given space.
    func createFolder(with sessionIDs: Set<TerminalSession.ID>, inSpace spaceID: SidebarSpace.ID) {
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        withSpace(spaceID) { space in
            space.pinnedFolders.append(
                TerminalFolder(title: "Folder \(space.pinnedFolders.count + 1)", sessions: moved)
            )
        }
        save()
    }

    /// Bulk collapse/expand of a space's folders from the space header menu.
    /// Session-only like every folder toggle (collapsedFolderIDs isn't
    /// persisted), so there's nothing to save.
    func collapseAllFolders(inSpace spaceID: SidebarSpace.ID) {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return }
        collapsedFolderIDs.formUnion(space.pinnedFolders.map(\.id))
    }

    func expandAllFolders(inSpace spaceID: SidebarSpace.ID) {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return }
        collapsedFolderIDs.subtract(space.pinnedFolders.map(\.id))
    }

    private static func makeSession(workingDirectory: String? = nil, accentIndex: Int = 0) -> TerminalSession {
        TerminalSession(
            title: "Terminal",
            workingDirectory: workingDirectory ?? NSHomeDirectory(),
            status: .running,
            accent: .cycling(index: accentIndex)
        )
    }

    // MARK: - Pinning / moving

    func pin(_ sessionIDs: Set<TerminalSession.ID>, inSpace spaceID: SidebarSpace.ID) {
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        withSpace(spaceID) { space in
            space.pinnedSessions.append(contentsOf: moved)
        }
        save()
    }

    func unpin(_ sessionIDs: Set<TerminalSession.ID>, inSpace spaceID: SidebarSpace.ID) {
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        withSpace(spaceID) { space in
            space.ephemeralSessions.append(contentsOf: moved)
        }
        save()
    }

    func move(_ sessionIDs: Set<TerminalSession.ID>, toFolder folderID: TerminalFolder.ID) {
        guard spaces.contains(where: { $0.pinnedFolders.contains { $0.id == folderID } }) else { return }
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        for spaceIndex in spaces.indices {
            if let folderIndex = spaces[spaceIndex].pinnedFolders.firstIndex(where: { $0.id == folderID }) {
                spaces[spaceIndex].pinnedFolders[folderIndex].sessions.append(contentsOf: moved)
                break
            }
        }
        save()
    }

    /// Reorders: moves sessions so they sit immediately before the target row,
    /// in whatever container (loose pinned, folder, ephemeral) the target lives.
    func insert(_ sessionIDs: Set<TerminalSession.ID>, before targetID: TerminalSession.ID) {
        guard !sessionIDs.contains(targetID) else { return }
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }

        for spaceIndex in spaces.indices {
            if let index = spaces[spaceIndex].pinnedSessions.firstIndex(where: { $0.id == targetID }) {
                spaces[spaceIndex].pinnedSessions.insert(contentsOf: moved, at: index)
                save()
                return
            }
            for folderIndex in spaces[spaceIndex].pinnedFolders.indices {
                if let index = spaces[spaceIndex].pinnedFolders[folderIndex].sessions.firstIndex(where: { $0.id == targetID }) {
                    spaces[spaceIndex].pinnedFolders[folderIndex].sessions.insert(contentsOf: moved, at: index)
                    save()
                    return
                }
            }
            if let index = spaces[spaceIndex].ephemeralSessions.firstIndex(where: { $0.id == targetID }) {
                spaces[spaceIndex].ephemeralSessions.insert(contentsOf: moved, at: index)
                save()
                return
            }
        }

        // Target vanished mid-drag; don't lose the sessions.
        withSpace(activeSpaceID) { space in
            space.ephemeralSessions.append(contentsOf: moved)
        }
        save()
    }

    /// Removes matching sessions from every space and returns them in display order.
    private func removeSessions(with sessionIDs: Set<TerminalSession.ID>) -> [TerminalSession] {
        var moved: [TerminalSession] = []
        for index in spaces.indices {
            moved += spaces[index].pinnedSessions.filter { sessionIDs.contains($0.id) }
            spaces[index].pinnedSessions.removeAll { sessionIDs.contains($0.id) }

            for folderIndex in spaces[index].pinnedFolders.indices {
                moved += spaces[index].pinnedFolders[folderIndex].sessions.filter { sessionIDs.contains($0.id) }
                spaces[index].pinnedFolders[folderIndex].sessions.removeAll { sessionIDs.contains($0.id) }
            }

            moved += spaces[index].ephemeralSessions.filter { sessionIDs.contains($0.id) }
            spaces[index].ephemeralSessions.removeAll { sessionIDs.contains($0.id) }
        }
        return moved
    }

    // MARK: - Closing

    func closeSelectedSession() {
        guard let selection else { return }
        close(sessionID: selection)
    }

    func close(sessionID: TerminalSession.ID) {
        close(sessionIDs: [sessionID])
    }

    func close(sessionIDs: Set<TerminalSession.ID>) {
        let orderedActive = activeSpace.sessions
        let anchorIndex = orderedActive.firstIndex { sessionIDs.contains($0.id) }

        for id in sessionIDs {
            GhosttySurfaceManager.shared.closeSurface(for: id)
        }
        _ = removeSessions(with: sessionIDs)
        multiSelection.subtract(sessionIDs)

        if let selection, sessionIDs.contains(selection) {
            let remaining = activeSpace.sessions
            if remaining.isEmpty {
                self.selection = nil
            } else {
                self.selection = remaining[min(anchorIndex ?? 0, remaining.count - 1)].id
            }
        }
        save()
    }

    /// Reorders: moves a folder so it sits immediately before the target
    /// folder, in whatever space the target lives.
    func insertFolder(_ folderID: TerminalFolder.ID, before targetID: TerminalFolder.ID) {
        guard folderID != targetID, let folder = removeFolder(folderID) else { return }
        for spaceIndex in spaces.indices {
            if let index = spaces[spaceIndex].pinnedFolders.firstIndex(where: { $0.id == targetID }) {
                spaces[spaceIndex].pinnedFolders.insert(folder, at: index)
                save()
                return
            }
        }
        // Target vanished mid-drag; don't lose the folder.
        withSpace(activeSpaceID) { $0.pinnedFolders.append(folder) }
        save()
    }

    func moveFolder(_ folderID: TerminalFolder.ID, toSpace spaceID: SidebarSpace.ID) {
        guard let folder = removeFolder(folderID) else { return }
        withSpace(spaceID) { $0.pinnedFolders.append(folder) }
        save()
    }

    private func removeFolder(_ folderID: TerminalFolder.ID) -> TerminalFolder? {
        for spaceIndex in spaces.indices {
            if let index = spaces[spaceIndex].pinnedFolders.firstIndex(where: { $0.id == folderID }) {
                return spaces[spaceIndex].pinnedFolders.remove(at: index)
            }
        }
        return nil
    }

    func deleteFolder(_ folderID: TerminalFolder.ID) {
        for spaceIndex in spaces.indices {
            guard let index = spaces[spaceIndex].pinnedFolders.firstIndex(where: { $0.id == folderID }) else {
                continue
            }
            // Folder rows disappear but their tabs survive as loose pinned tabs.
            spaces[spaceIndex].pinnedSessions.append(contentsOf: spaces[spaceIndex].pinnedFolders[index].sessions)
            spaces[spaceIndex].pinnedFolders.remove(at: index)
            break
        }
        save()
    }

    // MARK: - Renaming / status

    /// Inline-rename requests from menu shortcuts; the sidebar page owning
    /// the target picks it up and focuses the row's edit field.
    enum RenameRequest: Equatable {
        case session(TerminalSession.ID)
        case folder(TerminalFolder.ID)
    }

    @Published var renameRequest: RenameRequest?

    /// ⌘R: inline-rename the selected tab in the sidebar.
    func requestRenameOfSelection() {
        guard let selection else { return }
        renameRequest = .session(selection)
    }

    /// ⇧⌘R: inline-rename the selected tab's folder, or the tab when loose.
    func requestRenameOfSelectionContainer() {
        guard let selection else { return }
        let folder = spaces
            .flatMap(\.pinnedFolders)
            .first { $0.sessions.contains { $0.id == selection } }
        renameRequest = folder.map { .folder($0.id) } ?? .session(selection)
    }


    /// Manual rename; pins the title so shell and auto naming never touch it.
    func rename(_ session: TerminalSession, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(session.id) { item in
            item.title = trimmed
            item.titleOrigin = .user
        }
        save()
    }

    /// Live title from shell integration. The display title only lands while
    /// the tab still has its default naming — an auto or user name always
    /// wins — but process detection reads every event regardless, so the
    /// sidebar badge stays live on named tabs too.
    func applyShellTitle(_ sessionID: TerminalSession.ID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let display = Self.displayTitle(fromShellTitle: trimmed)
        update(sessionID) { item in
            // Process detection reads the raw title; only the display collapses.
            item.runningProcess = TabProcess.detect(after: item.runningProcess, title: trimmed)
            guard item.titleOrigin == .shell, item.title != display else { return }
            item.title = display
        }
        save()
    }

    /// Shells commonly report the cwd as the title — sometimes pre-shortened
    /// by ghostty to "…/a/b/c" — which makes tab names span the whole path.
    /// Collapse path-like titles to just the deepest folder name.
    private static func displayTitle(fromShellTitle title: String) -> String {
        guard title.hasPrefix("/") || title.hasPrefix("~") || title.hasPrefix("…") else { return title }
        let expanded = (title as NSString).expandingTildeInPath
        guard expanded != NSHomeDirectory(), expanded != "/" else { return "Terminal" }
        let folder = (expanded as NSString).lastPathComponent
        return folder.isEmpty || folder == "…" ? title : folder
    }

    /// One-shot LLM name; lands only on tabs the user hasn't renamed and
    /// that weren't already auto-named. `force` (explicit palette command)
    /// overwrites any name, including a user rename.
    func applyAutoName(_ sessionID: TerminalSession.ID, title: String, force: Bool = false) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(sessionID) { item in
            guard force || item.titleOrigin == .shell else { return }
            item.title = trimmed
            item.titleOrigin = .auto
        }
        save()
    }

    func rename(_ folder: TerminalFolder, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for spaceIndex in spaces.indices {
            if let index = spaces[spaceIndex].pinnedFolders.firstIndex(where: { $0.id == folder.id }) {
                spaces[spaceIndex].pinnedFolders[index].title = trimmed
                break
            }
        }
        save()
    }

    /// Live cwd reported by shell integration (OSC 7 → ghostty PWD action).
    /// Persisted, so a restored session's surface respawns where it left off.
    func updateWorkingDirectory(_ sessionID: TerminalSession.ID, to path: String) {
        guard !path.isEmpty else { return }
        update(sessionID) { item in
            guard item.workingDirectory != path else { return }
            item.workingDirectory = path
        }
        save()
    }

    func markSelectedNeedsAttention() {
        guard let selection else { return }
        update(selection) { item in
            item.status = .attention
            item.lastActivity = .now
        }
    }

    // MARK: - Focus navigation (within the active space)

    func focusNextSession() {
        let flattened = activeSpace.sessions
        guard !flattened.isEmpty else { return }
        guard let selection, let index = flattened.firstIndex(where: { $0.id == selection }) else {
            self.selection = flattened.first?.id
            return
        }
        self.selection = flattened[(index + 1) % flattened.count].id
    }

    func focusPreviousSession() {
        let flattened = activeSpace.sessions
        guard !flattened.isEmpty else { return }
        guard let selection, let index = flattened.firstIndex(where: { $0.id == selection }) else {
            self.selection = flattened.first?.id
            return
        }
        let nextIndex = index == 0 ? flattened.count - 1 : index - 1
        self.selection = flattened[nextIndex].id
    }

    func focusSession(atShortcutIndex shortcutIndex: Int) {
        let index = shortcutIndex - 1
        let flattened = activeSpace.sessions
        guard flattened.indices.contains(index) else { return }
        selection = flattened[index].id
    }

    // MARK: - Ephemeral expiry

    static let ephemeralTTLDefaultsKey = "ephemeralTTLHours"

    func pruneExpiredEphemeralSessions() {
        let hours = UserDefaults.standard.object(forKey: Self.ephemeralTTLDefaultsKey) as? Int ?? 24
        guard hours > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(-TimeInterval(hours) * 3600)
        let expired = spaces.flatMap(\.ephemeralSessions).filter {
            $0.lastActivity < cutoff && $0.id != selection
        }
        guard !expired.isEmpty else { return }
        close(sessionIDs: Set(expired.map(\.id)))
    }

    // MARK: - Selection recency

    /// The space's sessions in most-recently-used order; sessions never
    /// selected this launch keep their display order at the end.
    func recencyOrderedSessions(inSpace spaceID: SidebarSpace.ID) -> [TerminalSession] {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return [] }
        let all = space.sessions
        let order = recency[spaceID] ?? []
        let ranked = order.compactMap { id in all.first { $0.id == id } }
        let rest = all.filter { session in !order.contains(session.id) }
        return ranked + rest
    }

    /// Called by the switcher on commit, after cycling suppressed recording.
    func recordSelectionRecency() {
        recordRecency(selection)
    }

    /// Every session in recency order across spaces (active space first),
    /// paired with its containing space for display context.
    func recencyOrderedSessionsAcrossSpaces() -> [(session: TerminalSession, space: SidebarSpace)] {
        let orderedSpaces = [activeSpace] + spaces.filter { $0.id != activeSpaceID }
        return orderedSpaces.flatMap { space in
            recencyOrderedSessions(inSpace: space.id).map { ($0, space) }
        }
    }

    /// Selects a session wherever it lives, switching spaces when needed.
    func reveal(_ sessionID: TerminalSession.ID) {
        if !activeSpace.sessions.contains(where: { $0.id == sessionID }),
           let space = spaces.first(where: { $0.sessions.contains { $0.id == sessionID } }) {
            setActiveSpace(space.id)
        }
        selection = sessionID
        multiSelection = [sessionID]
    }

    private func recordRecency(_ sessionID: TerminalSession.ID?) {
        guard let sessionID, !isCyclingSelection else { return }
        var order = recency[activeSpaceID] ?? []
        order.removeAll { $0 == sessionID }
        order.insert(sessionID, at: 0)
        recency[activeSpaceID] = order
    }

    private func touch(_ sessionID: TerminalSession.ID?) {
        guard let sessionID else { return }
        update(sessionID) { item in
            item.lastActivity = .now
        }
    }

    // MARK: - Mutation helpers

    private func withSpace(_ id: SidebarSpace.ID, _ mutate: (inout SidebarSpace) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        mutate(&spaces[index])
    }

    private func update(_ id: TerminalSession.ID, mutate: (inout TerminalSession) -> Void) {
        for spaceIndex in spaces.indices {
            if let index = spaces[spaceIndex].pinnedSessions.firstIndex(where: { $0.id == id }) {
                mutate(&spaces[spaceIndex].pinnedSessions[index])
                return
            }
            for folderIndex in spaces[spaceIndex].pinnedFolders.indices {
                if let index = spaces[spaceIndex].pinnedFolders[folderIndex].sessions.firstIndex(where: { $0.id == id }) {
                    mutate(&spaces[spaceIndex].pinnedFolders[folderIndex].sessions[index])
                    return
                }
            }
            if let index = spaces[spaceIndex].ephemeralSessions.firstIndex(where: { $0.id == id }) {
                mutate(&spaces[spaceIndex].ephemeralSessions[index])
                return
            }
        }
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        var spaces: [SidebarSpace]
    }

    /// Pre-spaces state file layout, migrated on first load.
    private struct LegacyPersistedState: Codable {
        var pinnedFolders: [TerminalFolder]
        var pinnedSessions: [TerminalSession]
        var ephemeralSessions: [TerminalSession]
    }

    private static var stateURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = appSupport.appendingPathComponent("Enso", isDirectory: true)

        // One-time migration from a prior app identity, most recent first:
        // "Bloom" was the name before the Enso rename; "cmux-alternative"
        // was the identity before that. The app support folder is keyed on
        // this literal name, not the bundle id, so the rename would otherwise
        // orphan a user's saved sessions.
        if !FileManager.default.fileExists(atPath: base.path) {
            for legacyName in ["Bloom", "cmux-alternative"] {
                let legacy = appSupport.appendingPathComponent(legacyName, isDirectory: true)
                if FileManager.default.fileExists(atPath: legacy.path) {
                    try? FileManager.default.moveItem(at: legacy, to: base)
                    break
                }
            }
        }

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("state.json")
    }

    private static func loadState() -> PersistedState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        if let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            return state
        }
        if let legacy = try? JSONDecoder().decode(LegacyPersistedState.self, from: data) {
            return PersistedState(spaces: [
                SidebarSpace(
                    name: "Main",
                    pinnedFolders: legacy.pinnedFolders,
                    pinnedSessions: legacy.pinnedSessions,
                    ephemeralSessions: legacy.ephemeralSessions
                )
            ])
        }
        return nil
    }

    private func save() {
        guard persistToDisk else { return }
        withSpace(activeSpaceID) { $0.lastSelection = selection }
        guard let data = try? JSONEncoder().encode(PersistedState(spaces: spaces)) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}

extension TerminalSessionStore {
    static var preview: TerminalSessionStore {
        TerminalSessionStore(
            spaces: [
                SidebarSpace(
                    name: "Work",
                    icon: .symbol("hammer.fill"),
                    pinnedFolders: [
                        TerminalFolder(
                            title: "enso",
                            sessions: [
                                TerminalSession(title: "main", workingDirectory: "~", accent: .blue),
                                TerminalSession(title: "agent", workingDirectory: "~", accent: .green)
                            ]
                        )
                    ],
                    pinnedSessions: [
                        TerminalSession(title: "scratch", workingDirectory: "~", accent: .orange)
                    ],
                    ephemeralSessions: [
                        TerminalSession(title: "Terminal", workingDirectory: "~", accent: .pink)
                    ]
                ),
                SidebarSpace(
                    name: "Play",
                    icon: .emoji("🎮"),
                    ephemeralSessions: [
                        TerminalSession(title: "games", workingDirectory: "~", accent: .violet)
                    ]
                )
            ],
            persistToDisk: false
        )
    }
}
