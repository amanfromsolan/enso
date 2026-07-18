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
            clearAttention(selection)
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

    /// Wake-setting changes take effect live: a raised count or a switch to
    /// "wake everything" starts a fresh sweep instead of waiting for the
    /// next space switch. UserDefaults.didChangeNotification fires on every
    /// defaults write (sidebar width, tab naming…), so the observer keeps a
    /// snapshot and only re-sweeps on an actual wake-setting change.
    private var wakeSettingsObserver: NSObjectProtocol?
    private var lastWakeSettings: (policy: String?, count: Int?) = (nil, nil)

    private static func wakeSettingsSnapshot() -> (policy: String?, count: Int?) {
        let defaults = UserDefaults.standard
        return (
            defaults.string(forKey: agentWakePolicyDefaultsKey),
            defaults.object(forKey: agentWakeRecentCountDefaultsKey) as? Int
        )
    }

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

            lastWakeSettings = Self.wakeSettingsSnapshot()
            wakeSettingsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let snapshot = Self.wakeSettingsSnapshot()
                    guard snapshot != self.lastWakeSettings else { return }
                    self.lastWakeSettings = snapshot
                    self.eagerlyRestoreAgentSessions()
                }
            }
        }
    }

    // MARK: - Spaces

    var activeSpace: SidebarSpace {
        spaces.first { $0.id == activeSpaceID } ?? spaces[0]
    }

    /// THE space-transition path — every caller that changes activeSpaceID
    /// (space switch, cross-space tab creation, reveal, delete-space
    /// fallback) goes through here, because the transition's invariants
    /// only hold when applied as one unit: space and FINAL selection land
    /// together, the state is saved once, and the eager sweep is scheduled
    /// last. The sweep ranks and excludes against `selection`, so a caller
    /// that switched first and selected afterwards would aim it at a
    /// selection about to change — spending a warm slot on the tab the
    /// user is about to open anyway, and excluding the wrong one.
    ///
    /// `selecting:` nil means "the space's remembered selection", validated
    /// against its live sessions and falling back to the first tab.
    /// Activating the already-active space just lands the selection: no
    /// transition happened, so the sweep isn't re-aimed.
    func activateSpace(_ spaceID: SidebarSpace.ID, selecting sessionID: TerminalSession.ID? = nil) {
        guard spaces.contains(where: { $0.id == spaceID }) else { return }
        if spaceID == activeSpaceID {
            guard let sessionID else { return }
            selection = sessionID
            multiSelection = [sessionID]
            save()
            return
        }
        // The departing space remembers its selection for the next visit.
        // After deleteSpace the departing space is already gone and this is
        // a harmless no-op.
        withSpace(activeSpaceID) { $0.lastSelection = selection }
        activeSpaceID = spaceID
        selection = sessionID ?? activeSpace.lastSelection.flatMap { last in
            activeSpace.sessions.contains { $0.id == last } ? last : nil
        } ?? activeSpace.sessions.first?.id
        multiSelection = selection.map { [$0] } ?? []
        save()
        // Warm-up follows the user: drop the old space's unfired restore
        // ticks and sweep the space now in front of them.
        scheduleEagerRestoreSweep()
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
        activateSpace(space.id)
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
            // Deleting the active space is a real transition: route it
            // through activateSpace so the fallback space gets everything a
            // switch gets — validated remembered selection, one save, and a
            // fresh eager sweep (which also cancels the deleted space's
            // unfired restore ticks, whose tabs no longer exist).
            activateSpace(spaces[min(index, spaces.count - 1)].id)
        } else {
            save()
        }
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

    /// The folder the selected tab is filed under, if any. New tabs inherit
    /// it (#28), so "another terminal for this project" is one keystroke.
    var selectionFolder: TerminalFolder? {
        guard let selection else { return nil }
        return spaces.lazy.compactMap { $0.folder(containing: selection) }.first
    }

    // MARK: - Creation

    /// ⌘N and the command center default: new terminals join the active
    /// tab's folder (#28) and continue in its working directory rather than
    /// resetting to home. A loose tab keeps today's behavior — a new
    /// top-level tab. The deliberate top-level door stays open via ⌥⌘N and
    /// the sidebar's root-level "New Terminal".
    func createSessionInheritingWorkingDirectory() {
        if let folder = selectionFolder {
            createSession(inFolder: folder.id, workingDirectory: selectedSession?.workingDirectory)
        } else {
            createSession(workingDirectory: selectedSession?.workingDirectory)
        }
    }

    func createSession(inSpace spaceID: SidebarSpace.ID? = nil, workingDirectory: String? = nil) {
        let targetID = spaceID ?? activeSpaceID
        let session = Self.makeSession(workingDirectory: workingDirectory, accentIndex: sessions.count)
        withSpace(targetID) { space in
            space.ephemeralSessions.append(session)
        }
        // One atomic transition (or same-space selection landing): the new
        // tab is the final selection when the sweep is aimed.
        activateSpace(targetID, selecting: session.id)
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

            if let itemIndex = spaces[spaceIndex].pinnedItems.firstIndex(where: { $0.id == selectedID }) {
                spaces[spaceIndex].pinnedItems.insert(.tab(session), at: itemIndex + 1)
                inserted = true
            } else {
                spaces[spaceIndex].modifyFolders { folder in
                    guard !inserted,
                          let index = folder.sessions.firstIndex(where: { $0.id == selectedID }) else {
                        return
                    }
                    folder.sessions.insert(session, at: index + 1)
                    revealFolderID = folder.id
                    inserted = true
                }
                if !inserted, let index = spaces[spaceIndex].ephemeralSessions.firstIndex(where: { $0.id == selectedID }) {
                    spaces[spaceIndex].ephemeralSessions.insert(session, at: index + 1)
                    inserted = true
                }
            }

            guard inserted else { continue }
            // Reveal the new tab even if its folder was collapsed.
            if let revealFolderID {
                collapsedFolderIDs.remove(revealFolderID)
            }
            activateSpace(spaces[spaceIndex].id, selecting: session.id)
            return
        }

        // Selection vanished mid-flight; don't drop the new tab.
        createSession(workingDirectory: workingDirectory)
    }

    /// New terminal inside a folder. Continues in the given working
    /// directory when one is passed (⌘N inheriting the active tab's cwd);
    /// otherwise in the working directory of the folder's most recently
    /// active tab. An empty folder falls back to the directory remembered
    /// from its last departed tab (see `rememberWorkingDirectory`), and
    /// only then to home — a folder is a project, and losing every tab
    /// shouldn't lose the project.
    func createSession(inFolder folderID: TerminalFolder.ID, workingDirectory: String? = nil) {
        for spaceIndex in spaces.indices {
            guard let folder = spaces[spaceIndex].pinnedFolders.first(where: { $0.id == folderID }) else {
                continue
            }
            let cwd = workingDirectory
                ?? folder.sessions.max(by: { $0.lastActivity < $1.lastActivity })?.workingDirectory
                ?? Self.existingDirectory(folder.lastWorkingDirectory)
            let session = Self.makeSession(workingDirectory: cwd, accentIndex: sessions.count)
            spaces[spaceIndex].modifyFolder(folderID) { $0.sessions.append(session) }
            // Reveal the new tab even if the folder was collapsed.
            collapsedFolderIDs.remove(folderID)
            activateSpace(spaces[spaceIndex].id, selecting: session.id)
            return
        }
    }

    func createFolder(inSpace spaceID: SidebarSpace.ID? = nil) {
        withSpace(spaceID ?? activeSpaceID) { space in
            space.pinnedItems.append(
                .folder(TerminalFolder(title: "Folder \(space.pinnedFolders.count + 1)"))
            )
        }
        save()
    }

    /// Moves the given sessions into a new pinned folder in the given space.
    func createFolder(with sessionIDs: Set<TerminalSession.ID>, inSpace spaceID: SidebarSpace.ID) {
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        withSpace(spaceID) { space in
            space.pinnedItems.append(
                .folder(TerminalFolder(title: "Folder \(space.pinnedFolders.count + 1)", sessions: moved))
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
            space.pinnedItems.append(contentsOf: moved.map(SidebarPinnedItem.tab))
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
            if spaces[spaceIndex].modifyFolder(folderID, { $0.sessions.append(contentsOf: moved) }) {
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
            if let itemIndex = spaces[spaceIndex].pinnedItems.firstIndex(where: { $0.id == targetID }) {
                spaces[spaceIndex].pinnedItems.insert(
                    contentsOf: moved.map(SidebarPinnedItem.tab), at: itemIndex
                )
                save()
                return
            }
            var insertedInFolder = false
            spaces[spaceIndex].modifyFolders { folder in
                guard !insertedInFolder,
                      let index = folder.sessions.firstIndex(where: { $0.id == targetID }) else {
                    return
                }
                folder.sessions.insert(contentsOf: moved, at: index)
                insertedInFolder = true
            }
            if insertedInFolder {
                save()
                return
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

    /// Reorders: moves sessions so they sit as loose pinned tabs immediately
    /// before the given folder, in whatever space that folder lives.
    func insertLoosePinned(_ sessionIDs: Set<TerminalSession.ID>, beforeFolder folderID: TerminalFolder.ID) {
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        for spaceIndex in spaces.indices {
            if let itemIndex = spaces[spaceIndex].pinnedItems.firstIndex(where: { $0.id == folderID }) {
                spaces[spaceIndex].pinnedItems.insert(
                    contentsOf: moved.map(SidebarPinnedItem.tab), at: itemIndex
                )
                save()
                return
            }
        }
        // Anchor vanished mid-drag; don't lose the sessions.
        withSpace(activeSpaceID) { space in
            space.ephemeralSessions.append(contentsOf: moved)
        }
        save()
    }

    /// Removes matching sessions from every space and returns them in display order.
    private func removeSessions(with sessionIDs: Set<TerminalSession.ID>) -> [TerminalSession] {
        var moved: [TerminalSession] = []
        for index in spaces.indices {
            // One pass over the interleaved pinned list keeps display order.
            for itemIndex in spaces[index].pinnedItems.indices {
                switch spaces[index].pinnedItems[itemIndex] {
                case .tab(let session):
                    if sessionIDs.contains(session.id) {
                        moved.append(session)
                    }
                case .folder(var folder):
                    let leaving = folder.sessions.filter { sessionIDs.contains($0.id) }
                    guard !leaving.isEmpty else { continue }
                    // A folder losing tabs remembers its most recently active
                    // tab's cwd, so even the last tab leaving (close, expiry,
                    // move-out) keeps the folder's project directory.
                    if let lastActive = folder.sessions.max(by: { $0.lastActivity < $1.lastActivity }) {
                        folder.lastWorkingDirectory = lastActive.workingDirectory
                    }
                    moved += leaving
                    folder.sessions.removeAll { sessionIDs.contains($0.id) }
                    spaces[index].pinnedItems[itemIndex] = .folder(folder)
                }
            }
            spaces[index].pinnedItems.removeAll { item in
                if case .tab(let session) = item { return sessionIDs.contains(session.id) }
                return false
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
        if persistToDisk {
            // A closed tab can never resume its agent conversation.
            AgentSessionStore.shared.removeRecords(forTabs: sessionIDs)
        }
        // Nor can its attention notification lead anywhere; drop any
        // delivered banner along with the tab.
        for id in sessionIDs {
            onAttentionCleared?(id)
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

    /// Reorders: moves a folder so it sits immediately before the given
    /// pinned item (a loose tab or another folder), in whatever space that
    /// item lives.
    func insertFolder(_ folderID: TerminalFolder.ID, beforeItem itemID: UUID) {
        guard folderID != itemID, let folder = removeFolder(folderID) else { return }
        for spaceIndex in spaces.indices {
            if let index = spaces[spaceIndex].pinnedItems.firstIndex(where: { $0.id == itemID }) {
                spaces[spaceIndex].pinnedItems.insert(.folder(folder), at: index)
                save()
                return
            }
        }
        // Anchor vanished mid-drag; don't lose the folder.
        withSpace(activeSpaceID) { $0.pinnedItems.append(.folder(folder)) }
        save()
    }

    func moveFolder(_ folderID: TerminalFolder.ID, toSpace spaceID: SidebarSpace.ID) {
        guard let folder = removeFolder(folderID) else { return }
        withSpace(spaceID) { $0.pinnedItems.append(.folder(folder)) }
        save()
    }

    private func removeFolder(_ folderID: TerminalFolder.ID) -> TerminalFolder? {
        for spaceIndex in spaces.indices {
            if let index = spaces[spaceIndex].pinnedItems.firstIndex(where: { $0.id == folderID }),
               case .folder(let folder) = spaces[spaceIndex].pinnedItems[index] {
                spaces[spaceIndex].pinnedItems.remove(at: index)
                return folder
            }
        }
        return nil
    }

    func deleteFolder(_ folderID: TerminalFolder.ID) {
        for spaceIndex in spaces.indices {
            guard let index = spaces[spaceIndex].pinnedItems.firstIndex(where: { $0.id == folderID }),
                  case .folder(let folder) = spaces[spaceIndex].pinnedItems[index] else {
                continue
            }
            // The folder row disappears but its tabs survive, in place, as
            // loose pinned tabs.
            spaces[spaceIndex].pinnedItems.replaceSubrange(
                index...index, with: folder.sessions.map(SidebarPinnedItem.tab)
            )
            break
        }
        save()
    }

    // MARK: - Sidebar drag and drop

    /// The payload of the sidebar drag currently in flight, recorded at drag
    /// start. Hover-time drop projection needs to know what's being dragged,
    /// but AppKit only hands over item providers at drop time. Store-level so
    /// it survives space switches mid-drag. A cancelled drag leaves it stale
    /// (there's no end-of-drag hook); the next drag start overwrites it.
    var activeSidebarDrag: SidebarDragPayload?
    /// Whether the folder in flight was expanded before its drag collapsed it.
    var sidebarDragFolderWasExpanded = false

    /// The single commit point for sidebar drops: maps a resolved drop target
    /// onto the store's mutations. Every target is anchor-based, so nothing
    /// here depends on the dragged rows' old positions.
    func applySidebarDrop(
        _ payload: SidebarDragPayload,
        target: SidebarDropTarget,
        inSpace spaceID: SidebarSpace.ID
    ) {
        switch (payload, target) {
        case (.tabs(let ids), .insertBefore(let anchor)):
            insert(Set(ids), before: anchor)
        case (.tabs(let ids), .insertLooseBefore(let folderID)):
            insertLoosePinned(Set(ids), beforeFolder: folderID)
        case (.tabs(let ids), .appendToPinned):
            pin(Set(ids), inSpace: spaceID)
        case (.tabs(let ids), .appendToFolder(let folderID)),
             (.tabs(let ids), .intoFolder(let folderID)):
            move(Set(ids), toFolder: folderID)
        case (.tabs(let ids), .appendToEphemeral):
            unpin(Set(ids), inSpace: spaceID)
        case (.folder(let folderID), .insertFolderBefore(let anchor)):
            insertFolder(folderID, beforeItem: anchor)
        case (.folder(let folderID), .appendFolder):
            moveFolder(folderID, toSpace: spaceID)
        default:
            // The resolver never pairs a folder payload with a tab target or
            // vice versa; a mismatch means a stale/foreign drop. Ignore it.
            break
        }
    }

    // MARK: - Surface plumbing

    /// Wires a surface's event callbacks into the store. Called by the
    /// workspace host on every display pass and by the eager restore sweep,
    /// so a background-restored tab reports titles, cwd, and process
    /// detection — and closes on exit — exactly like a visible one.
    func wireSurfaceCallbacks(_ surfaceView: GhosttySurfaceView, for sessionID: TerminalSession.ID) {
        surfaceView.onTitleChange = { [weak self] title in
            self?.applyShellTitle(sessionID, title: title)
            TabAutoNamer.shared.noteActivity(sessionID)
        }
        surfaceView.onPwdChange = { [weak self] pwd in
            self?.updateWorkingDirectory(sessionID, to: pwd)
            TabAutoNamer.shared.noteActivity(sessionID)
        }
        surfaceView.onSurfaceClose = { [weak self] in
            self?.close(sessionID: sessionID)
        }
    }

    /// Delay between background restores so a launch with many agent tabs
    /// doesn't spawn every PTY and agent process in the same instant.
    private static let eagerRestoreStagger: TimeInterval = 1.0

    /// How eagerly sleeping agent tabs wake in the background — the
    /// "When Enso opens…" setting. The budget is global per launch, not per
    /// sweep: "wake my 5 most recent" promises at most five agent processes
    /// spawned unasked, and the cost being bounded (a resumed claude is a
    /// full Node process) is global, so space-hopping must not multiply it.
    /// Tabs past the budget stay asleep wearing the sidebar's dormant badge
    /// and wake on first visit.
    enum AgentWakePolicy: String {
        /// Nothing wakes unasked; every sleeping tab waits for its click.
        case onVisit
        /// The most recently used tabs wake right away, up to the count
        /// setting (the default).
        case recent
        /// Every restorable tab wakes, staggered.
        case all
    }

    static let agentWakePolicyDefaultsKey = "agentWakePolicy"
    static let agentWakeRecentCountDefaultsKey = "agentWakeRecentCount"
    static let defaultAgentWakeRecentCount = 5

    /// Background wakes already spent this launch. Only a tick that really
    /// wakes a tab counts — no-op ticks (tab closed, restore consumed) and
    /// click-driven restores spend nothing.
    private var agentWakesThisLaunch = 0

    /// Pure policy → budget mapping, separated so it is testable without
    /// touching UserDefaults.
    static func agentWakeBudget(policy: AgentWakePolicy, recentCount: Int, alreadyWoken: Int) -> Int {
        switch policy {
        case .onVisit: return 0
        case .recent: return max(0, recentCount - alreadyWoken)
        case .all: return .max
        }
    }

    /// The live remaining budget: settings are read on every ask so a
    /// mid-run change applies to the very next sweep.
    private var remainingAgentWakeBudget: Int {
        let defaults = UserDefaults.standard
        let policy = defaults.string(forKey: Self.agentWakePolicyDefaultsKey)
            .flatMap(AgentWakePolicy.init(rawValue:)) ?? .recent
        let count = defaults.object(forKey: Self.agentWakeRecentCountDefaultsKey) as? Int
            ?? Self.defaultAgentWakeRecentCount
        return Self.agentWakeBudget(policy: policy, recentCount: count, alreadyWoken: agentWakesThisLaunch)
    }

    /// Pending ticks of the sweep in flight; cancelled wholesale when a new
    /// sweep starts so warm-up effort always chases the active space.
    private var eagerRestoreTicks: [DispatchWorkItem] = []

    /// Injectable stand-in for the sweep the transition path schedules.
    /// The real sweep drives shared singletons (surface manager, agent
    /// session store) a unit test can't observe, so tests inject a recorder
    /// here to verify the transition invariant: exactly one sweep per space
    /// switch, scheduled after the final selection landed. nil in
    /// production.
    var eagerRestoreSweepOverride: (() -> Void)?

    private func scheduleEagerRestoreSweep() {
        if let eagerRestoreSweepOverride {
            eagerRestoreSweepOverride()
        } else {
            eagerlyRestoreAgentSessions()
        }
    }

    /// The active space's tabs the sweep will warm, most recently used
    /// first. lastActivity persists across launches, so the ordering favors
    /// the tabs the user is most likely to switch to right after the
    /// selected one. Scoped to the active space: that's where the user is
    /// looking, and other spaces' tabs get their sweep when their space
    /// becomes active. The pre-filter (injectable for tests) is cheap and
    /// precise — restorability was resolved once at bootstrap, so no
    /// transcript I/O happens here and no warm slot is spent on a tab that
    /// wouldn't actually resume.
    func eagerRestoreCandidates(
        mayRestore: ((TerminalSession.ID) -> Bool)? = nil,
        budget: Int? = nil
    ) -> [TerminalSession] {
        // Resolved here, not as default arguments: the fallbacks read the
        // main-actor AgentSessionStore and this store's launch budget, and
        // only the method body carries that isolation.
        let mayRestore = mayRestore ?? { AgentSessionStore.shared.mayRestore(forTab: $0) }
        let budget = budget ?? remainingAgentWakeBudget
        return Array(
            activeSpace.sessions
                .filter { $0.id != selection && mayRestore($0.id) }
                .sorted {
                    // Swift's sort is unstable, so equal lastActivity (bulk
                    // state imports, freshly seeded spaces) needs a stable
                    // secondary key — otherwise which tabs make the capped
                    // warm list could differ run to run.
                    $0.lastActivity != $1.lastActivity
                        ? $0.lastActivity > $1.lastActivity
                        : $0.id.uuidString < $1.id.uuidString
                }
                .prefix(budget)
        )
    }

    /// The eager sweep (#45): creates surfaces in the background for the
    /// active space's tabs with a pending agent restore, staggered, so
    /// switching to one lands on an already-resumed session instead of
    /// watching the resume command get typed. The selected tab is skipped —
    /// the workspace host creates it on first render — and tabs without a
    /// pending restore stay lazy. Runs at launch and again on every space
    /// switch: restarting cancels the previous sweep's unfired ticks, and
    /// tabs it already warmed were consumed, so a re-sweep only picks up
    /// what's still dormant. The full gate chain (including the adapters'
    /// on-disk checks) runs at fire time, not here, so that I/O stays off
    /// the first render.
    func eagerlyRestoreAgentSessions() {
        eagerRestoreTicks.forEach { $0.cancel() }
        eagerRestoreTicks = []
        for (index, session) in eagerRestoreCandidates().enumerated() {
            let sessionID = session.id
            let tick = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Re-resolved at fire time: the tab may have closed during
                // the stagger (its surface must not come back), its restore
                // may have evaporated (toggled off or consumed — the tab
                // must stay lazy), and its cwd may have changed. view(for:)
                // is idempotent, so a tab the user already switched to is a
                // no-op.
                guard let live = self.sessions.first(where: { $0.id == sessionID }),
                      AgentSessionStore.shared.hasPendingRestore(forTab: sessionID)
                else { return }
                self.wireSurfaceCallbacks(GhosttySurfaceManager.shared.view(for: live), for: sessionID)
                // A real background wake spends one slot of the launch-wide
                // budget; the guards above ensure no-ops never do.
                self.agentWakesThisLaunch += 1
            }
            eagerRestoreTicks.append(tick)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.eagerRestoreStagger * Double(index + 1),
                execute: tick
            )
        }
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
        renameRequest = selectionFolder.map { .folder($0.id) } ?? .session(selection)
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
        // Alias-proof detection needs every event, even ones that change
        // nothing here, so schedule it before the no-op bail.
        scheduleForegroundProcessCheck(for: sessionID)
        // Compute first, publish only on change: agents retitle every few
        // seconds, and a repeat event must not touch @Published state or
        // re-encode the state file.
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        // Process detection reads the raw title; only the display collapses.
        let detected = TabProcess.detect(after: session.runningProcess, title: trimmed)
        let displayLands = session.titleOrigin == .shell && session.title != display
        guard detected != session.runningProcess || displayLands else { return }
        update(sessionID) { item in
            item.runningProcess = detected
            guard item.titleOrigin == .shell, item.title != display else { return }
            item.title = display
        }
        save()
    }

    /// Delay before asking the pty what's actually running: long enough for
    /// the command to exec (preexec titles arrive before the shell forks),
    /// short enough that the badge still feels live.
    private static let foregroundCheckDelay: TimeInterval = 0.5

    /// Sessions with a foreground check already queued; coalesces bursts of
    /// title events (agents retitle constantly) into one walk per window.
    private var pendingForegroundChecks: Set<TerminalSession.ID> = []

    /// Title-based detection can't see through shell aliases — preexec
    /// reports the command *as typed*, so `alias c="claude"` never matches
    /// the table. Shortly after each title event, re-run detection on the
    /// pty's actual foreground process, which is alias-proof and also
    /// catches agents launched from scripts.
    private func scheduleForegroundProcessCheck(for sessionID: TerminalSession.ID) {
        guard !pendingForegroundChecks.contains(sessionID) else { return }
        pendingForegroundChecks.insert(sessionID)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.foregroundCheckDelay) { [weak self] in
            guard let self else { return }
            self.pendingForegroundChecks.remove(sessionID)
            let resolution = ForegroundProcessResolver.shared
                .resolveForeground(forSessionMarker: ForegroundProcessResolver.marker(forTab: sessionID))
            // Compute first, publish only on change: update() mutates
            // @Published state and re-renders the sidebar and header, so a
            // no-op detection — the steady state for a long-running agent
            // retitling every few seconds — must not touch it.
            guard let session = self.sessions.first(where: { $0.id == sessionID }) else { return }
            let detected = TabProcess.detect(after: session.runningProcess, foreground: resolution)
            guard detected != session.runningProcess else { return }
            self.update(sessionID) { $0.runningProcess = detected }
        }
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
            if spaces[spaceIndex].modifyFolder(folder.id, { $0.title = trimmed }) {
                break
            }
        }
        save()
    }

    /// Live cwd reported by shell integration (OSC 7 → ghostty PWD action).
    /// Persisted, so a restored session's surface respawns where it left off.
    func updateWorkingDirectory(_ sessionID: TerminalSession.ID, to path: String) {
        guard !path.isEmpty else { return }
        // Shells re-report the cwd on every prompt; only an actual move gets
        // published and persisted.
        guard let session = sessions.first(where: { $0.id == sessionID }),
              session.workingDirectory != path else { return }
        update(sessionID) { item in
            item.workingDirectory = path
        }
        rememberWorkingDirectory(path, forFolderContaining: sessionID)
        save()
    }

    /// Writes the folder's remembered directory on every member cwd change,
    /// so it always tracks the live cwd of the tab that most recently moved —
    /// captured continuously rather than only on tab removal, which would
    /// lose the value if the app quits uncleanly.
    private func rememberWorkingDirectory(_ path: String, forFolderContaining sessionID: TerminalSession.ID) {
        for spaceIndex in spaces.indices {
            var found = false
            spaces[spaceIndex].modifyFolders { folder in
                guard !found, folder.sessions.contains(where: { $0.id == sessionID }) else { return }
                folder.lastWorkingDirectory = path
                found = true
            }
            if found { return }
        }
    }

    /// A remembered directory is only worth spawning into while it still
    /// exists; stale paths fall back to the default instead of failing.
    private static func existingDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return path
    }

    func markSelectedNeedsAttention() {
        guard let selection else { return }
        update(selection) { item in
            item.status = .attention
            item.lastActivity = .now
        }
    }

    /// The escalation distinction attention policy needs, and nothing more —
    /// the watcher's payload-carrying event type stays out of the store so
    /// the store never grows a dependency on the tailing layer.
    enum AgentAttentionKind {
        /// The agent is blocked on the user (permission prompt, idle input).
        case needsInput
        /// The agent finished a response and went idle.
        case finishedResponding
    }

    /// EnsoApp points this at AgentNotificationCenter so an acknowledged (or
    /// closed) tab's banner leaves Notification Center with the dot. A
    /// callback, not a direct call: every UN* symbol stays out of this store,
    /// which must remain testable without a signed bundle.
    var onAttentionCleared: ((TerminalSession.ID) -> Void)?

    /// An agent in the tab asked for the user (Notification hook) or
    /// finished a response (Stop hook). Marks the tab's row with the
    /// attention dot and returns its title when the caller should also post
    /// a system notification — nil means stay silent: the tab is unknown, or
    /// the user is already looking at it (selected while the app is active).
    /// A repeated finishedResponding while the dot is already lit stays
    /// silent (one notification per attention episode), but needsInput posts
    /// even then: a blocking permission prompt must escalate past an earlier
    /// "finished responding" mark, and the notification request id is the
    /// tab UUID, so the newer banner replaces the older one instead of
    /// stacking. AppKit-free on purpose: the caller passes app activity, and
    /// EnsoApp owns the UserNotifications side, so this stays testable
    /// without a signed bundle.
    func handleAgentAttention(
        tabID: TerminalSession.ID, kind: AgentAttentionKind, isAppActive: Bool
    ) -> String? {
        guard let session = sessions.first(where: { $0.id == tabID }) else { return nil }
        if tabID == selection, isAppActive { return nil }
        let alreadyMarked = session.status == .attention
        update(tabID) { item in
            item.status = .attention
            item.lastActivity = .now
        }
        if kind == .finishedResponding, alreadyMarked { return nil }
        return session.title
    }

    /// App activation acknowledges the selected tab's dot. An event that
    /// marks the SELECTED tab while the app is inactive can never be cleared
    /// by a selection change — selection is already there — so EnsoApp calls
    /// this from its didBecomeActive observer; the store never watches
    /// NSApplication itself (AppKit-free).
    func acknowledgeSelectedAttention() {
        clearAttention(selection)
    }

    /// Selecting a tab acknowledges its attention dot. Guarded like recency
    /// recording: Ctrl-Tab previews pass through tabs the user never chose,
    /// so only the committed pick (via recordSelectionRecency) clears.
    private func clearAttention(_ sessionID: TerminalSession.ID?) {
        guard let sessionID, !isCyclingSelection else { return }
        guard sessions.first(where: { $0.id == sessionID })?.status == .attention else { return }
        update(sessionID) { $0.status = .running }
        onAttentionCleared?(sessionID)
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

    /// Called by the switcher on commit, after cycling suppressed recording
    /// (and attention clearing — the committed pick is the acknowledgment).
    func recordSelectionRecency() {
        recordRecency(selection)
        clearAttention(selection)
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
    /// One activateSpace call with the selection included, so a cross-space
    /// reveal's sweep is aimed at the revealed tab — not at the space's
    /// remembered selection it would otherwise warm for nothing.
    /// False when no space contains it: a notification click can outlive its
    /// tab, and assigning selection to a ghost id would point the workspace
    /// at nothing.
    @discardableResult
    func reveal(_ sessionID: TerminalSession.ID) -> Bool {
        guard let space = spaces.first(where: { $0.sessions.contains { $0.id == sessionID } })
        else { return false }
        activateSpace(space.id, selecting: sessionID)
        return true
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
            for itemIndex in spaces[spaceIndex].pinnedItems.indices {
                if case .tab(var session) = spaces[spaceIndex].pinnedItems[itemIndex], session.id == id {
                    mutate(&session)
                    spaces[spaceIndex].pinnedItems[itemIndex] = .tab(session)
                    return
                }
                if case .folder(var folder) = spaces[spaceIndex].pinnedItems[itemIndex],
                   let index = folder.sessions.firstIndex(where: { $0.id == id }) {
                    mutate(&folder.sessions[index])
                    spaces[spaceIndex].pinnedItems[itemIndex] = .folder(folder)
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

    private static let stateURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Per-build-identity folder (debug builds get "Enso Dev", the Next
        // channel gets "Enso Next") so a dev or Next build running alongside
        // the installed Enso can't clobber its state.json — two live writers
        // is last-writer-wins data loss.
        let base = EnsoAppSupport.directory

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
    }()

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
