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
            wakeIfSleeping(selection)
        }
    }

    /// While set, a selection assignment skips only the wake side effect;
    /// touch, recency, and attention behave like any assignment. Shaped
    /// like isCyclingSelection, but scoped to one setSelection call.
    private var suppressWakeOnSelection = false

    /// THE programmatic selection assignment. Only genuine user picks may
    /// wake a sleeping tab — a row tap, the switcher's committed pick, a
    /// palette row, the sleeping card's wake — so every transition that
    /// lands on a tab the user didn't aim at (space switches, close
    /// fallbacks, scene restoration, the switcher's Esc) passes
    /// `waking: false` and, at worst, parks the workspace on the sleeping
    /// card instead of spawning a shell unasked.
    func setSelection(_ sessionID: TerminalSession.ID?, waking: Bool) {
        guard !waking else {
            selection = sessionID
            return
        }
        suppressWakeOnSelection = true
        selection = sessionID
        suppressWakeOnSelection = false
    }
    /// Rows highlighted for multi-select actions (folder creation, bulk close).
    @Published var multiSelection: Set<TerminalSession.ID> = []

    /// Split containers: each groups the tabs participating in one split
    /// layout (every pane is a real tab; the container only records the
    /// grouping and geometry). Persisted with the sidebar structure so a
    /// split survives relaunch.
    @Published private(set) var splitContainers: [SplitContainer] = []

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
        var loadedContainers: [SplitContainer] = []
        if let spaces {
            loaded = spaces
        } else if persistToDisk, let state = Self.loadState() {
            loaded = state.spaces
            loadedContainers = state.splitContainers ?? []
        } else {
            loaded = []
        }

        if loaded.isEmpty {
            loaded = [SidebarSpace(name: "Main", ephemeralSessions: [Self.makeSession()])]
        }

        self.spaces = loaded
        self.activeSpaceID = loaded[0].id
        self.splitContainers = loadedContainers
        // A stale state file may reference tabs that no longer exist;
        // membership must only ever cover live sessions.
        pruneSplitContainerMembership()

        pruneExpiredEphemeralSessions()

        if activeSpace.sessions.isEmpty, let first = self.spaces.first(where: { !$0.sessions.isEmpty }) {
            self.activeSpaceID = first.id
        }
        // Non-waking on purpose: launch restores the exact shape the app
        // quit in, and a selection that was asleep then comes back asleep,
        // showing its sleeping card.
        setSelection(activeSpace.lastSelection ?? activeSpace.sessions.first?.id, waking: false)

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
            // Non-waking: callers passing an explicit id (reveal, tab
            // creation) decide themselves whether the landing is a pick
            // that wakes.
            setSelection(sessionID, waking: false)
            multiSelection = [sessionID]
            save()
            return
        }
        // The departing space remembers its selection for the next visit.
        // After deleteSpace the departing space is already gone and this is
        // a harmless no-op.
        withSpace(activeSpaceID) { $0.lastSelection = selection }
        activeSpaceID = spaceID
        setSelection(sessionID ?? landingSelection(in: activeSpace), waking: false)
        multiSelection = selection.map { [$0] } ?? []
        save()
        // Warm-up follows the user: drop the old space's unfired restore
        // ticks and sweep the space now in front of them.
        scheduleEagerRestoreSweep()
    }

    /// The space's landing selection when a transition names none: the
    /// remembered one while it is still present AND awake. A sleeping
    /// remembered tab is skipped for the first awake row — the user picked
    /// a space, not that tab, and parking them on a sleeping card they
    /// never chose reads wrong — unless the whole space is asleep, where
    /// the remembered card is the most honest thing to show.
    private func landingSelection(in space: SidebarSpace) -> TerminalSession.ID? {
        let sessions = space.sessions
        if let remembered = space.lastSelection.flatMap({ last in sessions.first { $0.id == last } }) {
            if !remembered.isSleeping || sessions.allSatisfy({ $0.isSleeping }) {
                return remembered.id
            }
        }
        return (sessions.first { !$0.isSleeping } ?? sessions.first)?.id
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
        // Containers whose members lived in the deleted space are gone too.
        pruneSplitContainerMembership()
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
    /// ephemeral). A selected split pane counts as its whole group: the new
    /// tab lands after the container's LAST member, because inserting
    /// between members would break the adjacent run the sidebar (and the
    /// drop projection) renders the group as. Falls back to a loose append
    /// when nothing is selected.
    func createSession(besideSelectionWithWorkingDirectory workingDirectory: String?) {
        guard let selectedID = selection else {
            createSession(workingDirectory: workingDirectory)
            return
        }
        let session = Self.makeSession(workingDirectory: workingDirectory, accentIndex: sessions.count)
        let anchorID = splitRunEnd(after: selectedID)

        for spaceIndex in spaces.indices {
            var inserted = false
            var revealFolderID: TerminalFolder.ID?

            if let itemIndex = spaces[spaceIndex].pinnedItems.firstIndex(where: { $0.id == anchorID }) {
                spaces[spaceIndex].pinnedItems.insert(.tab(session), at: itemIndex + 1)
                inserted = true
            } else {
                spaces[spaceIndex].modifyFolders { folder in
                    guard !inserted,
                          let index = folder.items.firstIndex(where: { $0.id == anchorID }) else {
                        return
                    }
                    folder.items.insert(.tab(session), at: index + 1)
                    revealFolderID = folder.id
                    inserted = true
                }
                if !inserted, let index = spaces[spaceIndex].ephemeralSessions.firstIndex(where: { $0.id == anchorID }) {
                    spaces[spaceIndex].ephemeralSessions.insert(session, at: index + 1)
                    inserted = true
                }
            }

            guard inserted else { continue }
            // Reveal the new tab even if its folder (or any ancestor of
            // it) was collapsed.
            if let revealFolderID {
                expandFolderPath(to: revealFolderID)
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
            guard let folder = spaces[spaceIndex].allFolders.first(where: { $0.id == folderID }) else {
                continue
            }
            let cwd = workingDirectory
                ?? folder.allSessions.max(by: { $0.lastActivity < $1.lastActivity })?.workingDirectory
                ?? Self.existingDirectory(folder.lastWorkingDirectory)
            let session = Self.makeSession(workingDirectory: cwd, accentIndex: sessions.count)
            spaces[spaceIndex].modifyFolder(folderID) { $0.items.append(.tab(session)) }
            // Reveal the new tab even if the folder (or any ancestor) was
            // collapsed.
            expandFolderPath(to: folderID)
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
        collapsedFolderIDs.formUnion(space.allFolders.map(\.id))
    }

    func expandAllFolders(inSpace spaceID: SidebarSpace.ID) {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return }
        collapsedFolderIDs.subtract(space.allFolders.map(\.id))
    }

    /// Expands the folder and every ancestor above it, so a row revealed
    /// inside a nested folder is actually visible — clearing only the
    /// folder's own flag would leave it hidden under a collapsed parent.
    private func expandFolderPath(to folderID: TerminalFolder.ID) {
        for space in spaces {
            guard let path = space.pinnedItems.folderPath(to: folderID) else { continue }
            collapsedFolderIDs.subtract(path)
            return
        }
    }

    private static func makeSession(workingDirectory: String? = nil, accentIndex: Int = 0) -> TerminalSession {
        TerminalSession(
            title: "Terminal",
            workingDirectory: workingDirectory ?? NSHomeDirectory(),
            status: .running,
            accent: .cycling(index: accentIndex)
        )
    }

    // MARK: - Splits

    /// The container the given tab is a pane of, if any.
    func splitContainer(containing sessionID: TerminalSession.ID) -> SplitContainer? {
        splitContainers.first { $0.tree.contains(sessionID) }
    }

    // A split group's members render as ONE adjacent run in the sidebar, so
    // insertions near a member must aim at the run's edges, never between
    // members. These resolve a member to its run's first/last row (in the
    // containing space's display order); a tab outside any container is its
    // own boundary.

    /// The first member of the target's split run — where "insert before
    /// this member" lands when the inserted tabs aren't part of the group.
    private func splitRunStart(before targetID: TerminalSession.ID) -> TerminalSession.ID {
        guard let container = splitContainer(containing: targetID),
              let space = spaces.first(where: { $0.sessions.contains { $0.id == targetID } }),
              let first = space.sessions.first(where: { container.tree.contains($0.id) })
        else { return targetID }
        return first.id
    }

    /// The last member of the target's split run — where "insert after this
    /// member" (split siblings, new-tab-beside-selection) lands.
    private func splitRunEnd(after targetID: TerminalSession.ID) -> TerminalSession.ID {
        guard let container = splitContainer(containing: targetID),
              let space = spaces.first(where: { $0.sessions.contains { $0.id == targetID } }),
              let last = space.sessions.last(where: { container.tree.contains($0.id) })
        else { return targetID }
        return last.id
    }

    /// ⌘D / ⇧⌘D: splits the focused pane. A split creates a NEW real tab —
    /// its own sidebar row, session, and shell (spawned in the split pane's
    /// working directory) — and groups it with the source tab in a split
    /// container. Splitting an unsplit tab starts a container; splitting a
    /// pane of an existing container grows its tree in place.
    ///
    /// The new row is inserted right after the container's last member (or
    /// after the source tab when unsplit), so members always sit adjacent
    /// in the sidebar in creation order — the flat stack the container
    /// renders, regardless of split geometry.
    func splitSelection(direction: SplitDirection) {
        guard let selection, let source = selectedSession else { return }
        // ⌘D on a sleeping tab means "I want to work here": wake it first,
        // so the split opens with both panes live instead of one card
        // still asleep beside the fresh shell.
        if source.isSleeping {
            wake(sessionID: selection)
        }
        let session = Self.makeSession(
            workingDirectory: source.workingDirectory,
            accentIndex: sessions.count
        )

        let existing = splitContainer(containing: selection)
        let anchorID = splitRunEnd(after: selection)

        insertSession(session, after: anchorID)

        if let existing,
           let index = splitContainers.firstIndex(where: { $0.id == existing.id }),
           let grown = existing.tree.inserting(session.id, splitting: selection, direction: direction) {
            splitContainers[index].tree = grown
        } else {
            splitContainers.append(SplitContainer(tree: .split(SplitBranch(
                direction: direction,
                ratio: 0.5,
                first: .leaf(selection),
                second: .leaf(session.id)
            ))))
        }

        // Focus follows the new pane, like every terminal's split behavior.
        activateSpace(activeSpaceID, selecting: session.id)
    }

    /// Divider drag ended: rewrites one split's ratio. Called ONCE per
    /// drag, on mouse-up — the drag itself is laid out locally by the
    /// AppKit host (see SplitLayoutHostView), so the store's @Published
    /// containers (and every sidebar row observing them) never hear about
    /// individual mouse events. Persistence follows via `commitSplitLayout`.
    func updateSplitRatio(containerID: SplitContainer.ID, path: SplitPath, ratio: Double) {
        guard let index = splitContainers.firstIndex(where: { $0.id == containerID }) else { return }
        splitContainers[index].tree = splitContainers[index].tree.updatingRatio(at: path, to: ratio)
    }

    /// Divider drag ended: persist the final ratios.
    func commitSplitLayout() {
        save()
    }

    /// Inserts a session immediately after the anchor row, in whatever
    /// collection (loose pinned, folder, ephemeral) the anchor lives — the
    /// split sibling lands beside its source wherever that is. Falls back
    /// to a loose ephemeral append if the anchor vanished mid-flight.
    private func insertSession(_ session: TerminalSession, after anchorID: TerminalSession.ID) {
        for spaceIndex in spaces.indices {
            if let itemIndex = spaces[spaceIndex].pinnedItems.firstIndex(where: { $0.id == anchorID }) {
                spaces[spaceIndex].pinnedItems.insert(.tab(session), at: itemIndex + 1)
                return
            }
            var inserted = false
            var revealFolderID: TerminalFolder.ID?
            spaces[spaceIndex].modifyFolders { folder in
                guard !inserted,
                      let index = folder.items.firstIndex(where: { $0.id == anchorID }) else {
                    return
                }
                folder.items.insert(.tab(session), at: index + 1)
                revealFolderID = folder.id
                inserted = true
            }
            if inserted {
                // A pane born into a collapsed folder must be visible.
                if let revealFolderID {
                    expandFolderPath(to: revealFolderID)
                }
                return
            }
            if let index = spaces[spaceIndex].ephemeralSessions.firstIndex(where: { $0.id == anchorID }) {
                spaces[spaceIndex].ephemeralSessions.insert(session, at: index + 1)
                return
            }
        }
        withSpace(activeSpaceID) { $0.ephemeralSessions.append(session) }
    }

    /// Removes the given tabs from any split trees they are panes of;
    /// neighbors absorb the space, and a container down to one member
    /// dissolves — its last tab returns to being a plain sidebar row.
    /// Called for closes AND for moves (pin/unpin, drag, move-to-space,
    /// into-folder): a tab relocated away from its group leaves the split,
    /// which keeps every container's members co-located and adjacent.
    private func removeFromSplitContainers(_ sessionIDs: Set<TerminalSession.ID>) {
        guard !sessionIDs.isEmpty else { return }
        var changed = false
        for index in splitContainers.indices {
            var tree: SplitNode? = splitContainers[index].tree
            for id in sessionIDs where tree?.contains(id) == true {
                tree = tree?.removing(id)
                changed = true
            }
            // A fully emptied tree collapses to a dead single leaf, which
            // the dissolve pass below removes along with every other
            // container left under two members.
            splitContainers[index].tree = tree ?? .leaf(UUID())
        }
        guard changed else { return }
        splitContainers.removeAll { $0.memberIDs.count < 2 }
    }

    /// Drops membership for tabs that no longer exist anywhere (stale state
    /// files, whole-space deletion) and dissolves containers left with a
    /// single member.
    private func pruneSplitContainerMembership() {
        let live = Set(sessions.map(\.id))
        let stale = splitContainers
            .flatMap(\.memberIDs)
            .filter { !live.contains($0) }
        removeFromSplitContainers(Set(stale))
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
        guard spaces.contains(where: { $0.allFolders.contains { $0.id == folderID } }) else { return }
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        for spaceIndex in spaces.indices {
            if spaces[spaceIndex].modifyFolder(folderID, {
                $0.items.append(contentsOf: moved.map(SidebarPinnedItem.tab))
            }) {
                break
            }
        }
        save()
    }

    /// Reorders: moves sessions so they sit immediately before the target row,
    /// in whatever container (loose pinned, folder, ephemeral) the target lives.
    func insert(_ sessionIDs: Set<TerminalSession.ID>, before targetID: TerminalSession.ID) {
        guard !sessionIDs.contains(targetID) else { return }
        // A drag that starts and ends inside one split group — the anchor
        // AND every dragged tab are members of the same container — is a
        // pure reorder of the group's rows, and the split must survive it.
        // Anything anchored outside the group stays a real relocation and
        // ejects as usual.
        let withinOwnSplitGroup = splitContainer(containing: targetID).map { container in
            sessionIDs.allSatisfy { container.tree.contains($0) }
        } ?? false
        let moved = removeSessions(with: sessionIDs, leavingSplits: !withinOwnSplitGroup)
        guard !moved.isEmpty else { return }

        // Outsiders must never land BETWEEN two members of a split group —
        // the sidebar renders members as one adjacent run. A drop anchored
        // on a mid-run member snaps to the front of the run (the resolver
        // proposes run boundaries already; this is the structural backstop
        // for any other caller).
        let anchorID = withinOwnSplitGroup ? targetID : splitRunStart(before: targetID)

        for spaceIndex in spaces.indices {
            if let itemIndex = spaces[spaceIndex].pinnedItems.firstIndex(where: { $0.id == anchorID }) {
                spaces[spaceIndex].pinnedItems.insert(
                    contentsOf: moved.map(SidebarPinnedItem.tab), at: itemIndex
                )
                save()
                return
            }
            var insertedInFolder = false
            spaces[spaceIndex].modifyFolders { folder in
                guard !insertedInFolder,
                      let index = folder.items.firstIndex(where: { $0.id == anchorID }) else {
                    return
                }
                folder.items.insert(contentsOf: moved.map(SidebarPinnedItem.tab), at: index)
                insertedInFolder = true
            }
            if insertedInFolder {
                save()
                return
            }
            if let index = spaces[spaceIndex].ephemeralSessions.firstIndex(where: { $0.id == anchorID }) {
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

    /// Reorders: moves sessions so they sit immediately before the given
    /// folder row, as its siblings — in the space's top level or, for a
    /// nested folder, in its parent folder — wherever that folder lives.
    func insertLoosePinned(_ sessionIDs: Set<TerminalSession.ID>, beforeFolder folderID: TerminalFolder.ID) {
        let moved = removeSessions(with: sessionIDs)
        guard !moved.isEmpty else { return }
        for spaceIndex in spaces.indices {
            if spaces[spaceIndex].pinnedItems.insert(
                moved.map(SidebarPinnedItem.tab), beforeItem: folderID
            ) {
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
    /// `leavingSplits` controls the split side effect: true (every close and
    /// real relocation) ejects the removed tabs from their containers; false
    /// is reserved for the intra-group reorder (see `insert(_:before:)`),
    /// where the rows only swap places inside their own split group and the
    /// container must survive the round trip.
    private func removeSessions(
        with sessionIDs: Set<TerminalSession.ID>, leavingSplits: Bool = true
    ) -> [TerminalSession] {
        var moved: [TerminalSession] = []
        for index in spaces.indices {
            // One depth-first pass over the pinned tree keeps display order.
            moved += Self.extractSessions(sessionIDs, from: &spaces[index].pinnedItems)
            moved += spaces[index].ephemeralSessions.filter { sessionIDs.contains($0.id) }
            spaces[index].ephemeralSessions.removeAll { sessionIDs.contains($0.id) }
        }
        // Leaving one's spot usually means leaving one's split: closes and
        // relocations (pin/unpin, drag to a new home, move to folder/space)
        // exit the container so members always stay adjacent. The exception
        // is the intra-group reorder, which shuffles rows WITHIN their own
        // group and passes leavingSplits: false. Splits never re-home a
        // session through this path (they insert directly), so this can't
        // misfire.
        if leavingSplits {
            removeFromSplitContainers(sessionIDs)
        }
        return moved
    }

    /// Detaches matching tabs from one item tree, at every depth, returning
    /// them in display order. Each folder losing direct tabs remembers its
    /// most recently active tab's cwd first, so even the last tab leaving
    /// (close, expiry, move-out) keeps the folder's project directory.
    private static func extractSessions(
        _ sessionIDs: Set<TerminalSession.ID>,
        from items: inout [SidebarPinnedItem]
    ) -> [TerminalSession] {
        var moved: [TerminalSession] = []
        for index in items.indices {
            switch items[index] {
            case .tab(let session):
                if sessionIDs.contains(session.id) {
                    moved.append(session)
                }
            case .folder(var folder):
                let losesDirectTab = folder.sessions.contains { sessionIDs.contains($0.id) }
                if losesDirectTab,
                   let lastActive = folder.sessions.max(by: { $0.lastActivity < $1.lastActivity }) {
                    folder.lastWorkingDirectory = lastActive.workingDirectory
                }
                moved += extractSessions(sessionIDs, from: &folder.items)
                items[index] = .folder(folder)
            }
        }
        items.removeAll { item in
            if case .tab(let session) = item { return sessionIDs.contains(session.id) }
            return false
        }
        return moved
    }

    // MARK: - Closing

    /// Whether ⌘W (and the palette's close command) would put the selected
    /// tab to sleep instead of closing it: pinned awake tabs get the
    /// two-step exit — sleep first (which hands the workspace back to the
    /// previous tab), close the sleeping tab second, from its row's × or
    /// context menu, or with another ⌘W when a sleeping tab holds the
    /// selection (the relaunch shape) — so one keystroke can never
    /// silently destroy a pinned tab or the saved conversation a sleep
    /// promised to keep. The menu and palette read this to title the
    /// command and run the busy confirmation to match.
    var selectedTabSleepsInsteadOfClosing: Bool {
        guard let selection,
              let session = sessions.first(where: { $0.id == selection }) else { return false }
        return isPinned(selection) && !session.isSleeping
    }

    /// ⌘W. The caller runs the busy confirmation first when
    /// selectedTabSleepsInsteadOfClosing says the close is really a sleep;
    /// this just performs.
    func closeSelectedSession() {
        guard let selection else { return }
        if selectedTabSleepsInsteadOfClosing {
            putToSleep(sessionID: selection)
        } else {
            close(sessionID: selection)
        }
    }

    func close(sessionID: TerminalSession.ID) {
        close(sessionIDs: [sessionID])
    }

    func close(sessionIDs: Set<TerminalSession.ID>) {
        let orderedActive = activeSpace.sessions
        let anchorIndex = orderedActive.firstIndex { sessionIDs.contains($0.id) }

        // Closing the focused pane of a split keeps focus inside the split:
        // the nearest surviving member (by sidebar order) takes over,
        // instead of the generic next-row fallback jumping outside the
        // container. Resolved before removal — membership is gone after.
        var splitFallback: TerminalSession.ID?
        if let selection, sessionIDs.contains(selection),
           let container = splitContainer(containing: selection),
           let selectionIndex = orderedActive.firstIndex(where: { $0.id == selection }) {
            let survivors = orderedActive.enumerated()
                .filter { container.tree.contains($0.element.id) && !sessionIDs.contains($0.element.id) }
            // Prefer an awake survivor: the handoff must not park the user
            // on a sleeping pane while awake ones exist. A fully sleeping
            // container still hands over to its nearest member — shown as
            // the sleeping card, never woken by the handoff.
            let awake = survivors.filter { !$0.element.isSleeping }
            splitFallback = (awake.isEmpty ? survivors : awake)
                .min { abs($0.offset - selectionIndex) < abs($1.offset - selectionIndex) }?
                .element.id
        }

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
                setSelection(nil, waking: false)
            } else if let splitFallback {
                setSelection(splitFallback, waking: false)
            } else {
                // Prefer an awake row for the handoff; a close is not a
                // pick, so even the only-sleeping-rows-left case lands
                // non-waking and shows the sleeping card.
                let awake = remaining.filter { !$0.isSleeping }
                let pool = awake.isEmpty ? remaining : awake
                setSelection(pool[min(anchorIndex ?? 0, pool.count - 1)].id, waking: false)
            }
        }
        save()
    }

    // MARK: - Sleep / wake

    /// Pinned tabs never die from their row affordance — they go to sleep:
    /// the shell (and anything running in it) ends to free resources, but
    /// the tab keeps its row, its working directory, and — via
    /// AgentSessionStore — the agent conversation to resume on wake.
    /// Sleep is strictly per tab: a pane of a split sleeps alone, its
    /// siblings keep running and its region shows the in-pane sleeping
    /// card. Sleeping the selected tab hands the workspace to the
    /// previously used tab (per-space MRU, non-waking): sleeping a tab
    /// says "done here for now", so the workspace returns to what the
    /// user was doing instead of parking on the sleeping card. The
    /// focused pane of a split hands over inside the split instead — the
    /// nearest awake sibling, same handoff as close() — since its region
    /// keeps showing the in-pane card and a selected pane with no surface
    /// would leave the keyboard pointing at nothing while the focus ring
    /// crowned the moon. With nothing awake to hand to anywhere, the
    /// selection stays put on the moon: a jump to some other sleeping
    /// card would read as waking it. Background sleeps (a non-selected
    /// tab's context menu) never touch selection. One
    /// plain entry point on purpose, so a future auto-sleep (idle timeout,
    /// sleep-on-quit) can call it too. The set form exists for bulk
    /// context-menu sleeps — one marker write for the whole batch.
    func putToSleep(sessionIDs: Set<TerminalSession.ID>) {
        let targets = sessionIDs.filter { id in
            sessions.first { $0.id == id }?.isSleeping == false
        }
        guard !targets.isEmpty else { return }

        // Resolved before the targets are marked sleeping — the fallback
        // must only consider siblings that stay awake.
        var splitFallback: TerminalSession.ID?
        if let selection, targets.contains(selection),
           let container = splitContainer(containing: selection) {
            let orderedActive = activeSpace.sessions
            if let selectionIndex = orderedActive.firstIndex(where: { $0.id == selection }) {
                splitFallback = orderedActive.enumerated()
                    .filter {
                        container.tree.contains($0.element.id)
                            && !targets.contains($0.element.id)
                            && !$0.element.isSleeping
                    }
                    .min { abs($0.offset - selectionIndex) < abs($1.offset - selectionIndex) }?
                    .element.id
            }
        }

        // The general handoff, also resolved before marking: sleeping the
        // selected tab returns the workspace to the previously used tab
        // (per-space MRU). Awake non-targets only — the handoff must not
        // park the user on some other sleeping card (or wake it); with
        // nothing awake left the selection stays put and the slept tab's
        // own card is the feedback. A split member prefers its sibling
        // handoff above and only falls through here when the whole
        // container is going dark.
        var recencyFallback: TerminalSession.ID?
        if let selection, targets.contains(selection) {
            recencyFallback = recencyOrderedSessions(inSpace: activeSpaceID)
                .first { !targets.contains($0.id) && !$0.isSleeping }?.id
        }

        if persistToDisk {
            // One store call for the whole group (one marker write).
            // Remember which agent to resume before the shells die; only
            // adapter-backed agents (claude, codex) can come back, and the
            // dormant fallback for a never-woken tab lives in recordSleep.
            let agentsByTab = targets.reduce(into: [UUID: TabProcess?]()) { result, id in
                let running = sessions.first(where: { $0.id == id })?.runningProcess
                result[id] = running.flatMap { process in
                    AgentSessionAdapterRegistry.all.contains { $0.agentID == process.rawValue }
                        ? process : nil
                }
            }
            AgentSessionStore.shared.recordSleep(forTabs: agentsByTab)
        }
        for id in targets {
            // The ⌘+/⌘- zoom lives in the surface; read it before the
            // shell dies so the wake can respawn at the same size.
            let fontSize = GhosttySurfaceManager.shared.fontSize(for: id)
            GhosttySurfaceManager.shared.closeSurface(for: id)
            // A sleeping tab's attention banner leads nowhere; drop it with
            // the dot.
            onAttentionCleared?(id)
            update(id) { item in
                item.isSleeping = true
                // The sleeping card's "what was running" summary, captured
                // before detection is cleared with the shell.
                item.sleepingProcess = item.runningProcess
                item.runningProcess = nil
                item.sleepingFontSize = fontSize
                item.status = .idle
                // A sleeping tab is deliberately parked; the expiry clock
                // (should it ever be unpinned) starts fresh, not pre-aged.
                item.lastActivity = .now
            }
        }
        multiSelection.subtract(targets)
        if let handoff = splitFallback ?? recencyFallback {
            setSelection(handoff, waking: false)
        }
        save()
    }

    func putToSleep(sessionID: TerminalSession.ID) {
        putToSleep(sessionIDs: [sessionID])
    }

    /// Wakes a sleeping tab: clears the flags, then mounts its surface
    /// itself — a fresh shell in the saved working directory, consuming
    /// the wake restore so a saved agent conversation resumes in place.
    /// Per tab like sleep: a pane of a split wakes alone. The mount can't
    /// be left to the workspace host: it only renders the selection, so a
    /// background wake (context menu, palette) would otherwise clear the
    /// flag while the marker sat unconsumed and no shell ever spawned.
    func wake(sessionID: TerminalSession.ID) {
        guard let sleeping = sessions.first(where: { $0.id == sessionID }),
              sleeping.isSleeping else { return }
        // Consumed by this wake's mount; cleared so a later fresh spawn
        // (quit restore of the awake tab) uses the config default again.
        let fontSize = sleeping.sleepingFontSize
        update(sessionID) { item in
            item.isSleeping = false
            item.sleepingProcess = nil
            item.sleepingFontSize = nil
            item.lastActivity = .now
        }
        save()
        // Idempotent for the visible tab: the host's next render asks for
        // the same surface this mount created.
        if let live = sessions.first(where: { $0.id == sessionID }) {
            mountWokenSurface(for: live, fontSize: fontSize)
        }
    }

    /// Injectable stand-in for the surface mount a wake performs — the
    /// real mount drives GhosttyRuntime, which unit tests can't host (see
    /// eagerRestoreSweepOverride for the pattern). nil in production.
    var wakeSurfaceMounter: ((TerminalSession) -> Void)?

    private func mountWokenSurface(for session: TerminalSession, fontSize: Float?) {
        if let wakeSurfaceMounter {
            wakeSurfaceMounter(session)
            return
        }
        // Unit stores drive no real surfaces, mirroring how they skip the
        // shared AgentSessionStore.
        guard persistToDisk else { return }
        wireSurfaceCallbacks(
            GhosttySurfaceManager.shared.view(for: session, fontSize: fontSize),
            for: session.id
        )
    }

    /// Committed selection of a sleeping tab wakes it — "click to wake"
    /// needs no extra plumbing anywhere tabs get picked. Guarded like
    /// recency and attention: Ctrl-Tab previews and setSelection's
    /// non-waking transitions pass through tabs the user never chose, and
    /// neither must spawn shells.
    private func wakeIfSleeping(_ sessionID: TerminalSession.ID?) {
        guard let sessionID, !isCyclingSelection, !suppressWakeOnSelection else { return }
        guard sessions.first(where: { $0.id == sessionID })?.isSleeping == true else { return }
        wake(sessionID: sessionID)
    }

    /// The agent still working in the tab, if one is — the gate for the
    /// put-to-sleep confirmation, per tab like sleep itself. "Working" is
    /// the best signal already live in the app: the agent CLI is the tab's
    /// foreground process and the attention dot hasn't marked it as waiting
    /// for the user. An agent sitting at its prompt in the focused tab
    /// reads as working too — over-warning beats killing a response
    /// mid-stream.
    func busyAgent(inTab sessionID: TerminalSession.ID) -> TabProcess? {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              !session.isSleeping,
              session.status != .attention,
              let process = session.runningProcess,
              AgentSessionAdapterRegistry.all.contains(where: { $0.agentID == process.rawValue })
        else { return nil }
        return process
    }

    /// Reorders: moves a folder so it sits immediately before the given
    /// item (a tab or another folder), in whatever container — the space's
    /// top level or any folder at any depth — that item lives. An anchor
    /// inside the dragged folder's own subtree is refused: the resolver
    /// never proposes one, and the mutation must not create a cycle even
    /// for a stale/foreign target.
    func insertFolder(_ folderID: TerminalFolder.ID, beforeItem itemID: UUID) {
        guard folderID != itemID else { return }
        if let dragged = findFolder(folderID),
           dragged.contains(folderID: itemID)
               || dragged.allSessions.contains(where: { $0.id == itemID }) {
            return
        }
        guard let folder = removeFolder(folderID) else { return }
        for spaceIndex in spaces.indices {
            if spaces[spaceIndex].pinnedItems.insert([.folder(folder)], beforeItem: itemID) {
                save()
                return
            }
        }
        // Anchor vanished mid-drag; don't lose the folder.
        withSpace(activeSpaceID) { $0.pinnedItems.append(.folder(folder)) }
        save()
    }

    /// Nests a folder inside another, appended at the end of the target's
    /// children — the "drop a folder onto a folder row" mutation. Refused
    /// when the target is the folder itself or anywhere in its subtree:
    /// the mutation-level backstop for the resolver's cycle prevention.
    func nestFolder(_ folderID: TerminalFolder.ID, insideFolder targetID: TerminalFolder.ID) {
        guard folderID != targetID else { return }
        guard let dragged = findFolder(folderID), !dragged.contains(folderID: targetID),
              findFolder(targetID) != nil else { return }
        guard let folder = removeFolder(folderID) else { return }
        for spaceIndex in spaces.indices {
            if spaces[spaceIndex].modifyFolder(targetID, { $0.items.append(.folder(folder)) }) {
                save()
                return
            }
        }
        // Target vanished mid-drag; don't lose the folder.
        withSpace(activeSpaceID) { $0.pinnedItems.append(.folder(folder)) }
        save()
    }

    func moveFolder(_ folderID: TerminalFolder.ID, toSpace spaceID: SidebarSpace.ID) {
        guard let folder = removeFolder(folderID) else { return }
        withSpace(spaceID) { $0.pinnedItems.append(.folder(folder)) }
        save()
    }

    /// The folder with the given ID, wherever it nests, across all spaces.
    private func findFolder(_ folderID: TerminalFolder.ID) -> TerminalFolder? {
        for space in spaces {
            if let folder = space.pinnedItems.firstFolder(folderID) { return folder }
        }
        return nil
    }

    private func removeFolder(_ folderID: TerminalFolder.ID) -> TerminalFolder? {
        for spaceIndex in spaces.indices {
            if let folder = spaces[spaceIndex].pinnedItems.removeFolder(folderID) {
                return folder
            }
        }
        return nil
    }

    func deleteFolder(_ folderID: TerminalFolder.ID) {
        // The folder row disappears but its children survive, in place —
        // tabs and subfolders splice into the containing list.
        for spaceIndex in spaces.indices {
            if spaces[spaceIndex].pinnedItems.dissolveFolder(folderID) { break }
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
        case (.folder(let folderID), .intoFolder(let targetID)),
             (.folder(let folderID), .appendToFolder(let targetID)):
            // A folder dropped onto (or into the trailing gap of) another
            // folder nests inside it, appended at the end of its children.
            nestFolder(folderID, insideFolder: targetID)
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
        surfaceView.onFocusGained = { [weak self] in
            self?.paneFocusDidGain(sessionID)
        }
    }

    /// Clicking a pane focuses its surface; the sidebar selection must
    /// follow so the highlighted row is always the focused pane. The
    /// first guard keeps programmatic focus (the host focusing the
    /// already-selected pane) from re-publishing selection during a view
    /// update. The second scopes the sync to SIBLINGS of the current
    /// selection: only panes of the rendered layout can be clicked, so a
    /// grant for any other tab is stale — the host's focus regrant for a
    /// Ctrl-Tab preview arriving after the cycle moved on (or committed
    /// elsewhere) — and following it would yank the workspace back into
    /// a split the user just left, re-ranking a pane nobody picked.
    func paneFocusDidGain(_ sessionID: TerminalSession.ID) {
        guard selection != sessionID else { return }
        guard let selection,
              splitContainer(containing: selection)?.tree.contains(sessionID) == true
        else { return }
        self.selection = sessionID
        multiSelection = [sessionID]
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
                // Sleeping tabs wait for their click — a background warm-up
                // spawning their agent would defeat the sleep.
                .filter { $0.id != selection && !$0.isSleeping && mayRestore($0.id) }
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
                // the stagger (its surface must not come back), gone to
                // sleep (waking it is the user's call), its restore may
                // have evaporated (toggled off or consumed — the tab must
                // stay lazy), and its cwd may have changed. view(for:) is
                // idempotent, so a tab the user already switched to is a
                // no-op.
                guard let live = self.sessions.first(where: { $0.id == sessionID }),
                      !live.isSleeping,
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
            // Sleeping tabs are deliberately parked, never expired: an
            // unpinned sleeper quietly closing would delete the very
            // conversation the sleep promised to keep.
            !$0.isSleeping && $0.lastActivity < cutoff && $0.id != selection
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

    /// The Ctrl-Tab switcher's stops: recency order with each split
    /// container collapsed to its most recently used member. A split is
    /// ONE tab in the sidebar, so it is ONE stop in the cycle — pane
    /// focus records recency per member, and without the collapse an
    /// actively-used split's panes occupy the top TWO stops and Ctrl-Tab
    /// ping-pongs between siblings instead of reaching other tabs.
    /// Landing on the stop selects the surviving entry: the member
    /// focused most recently inside the container.
    func switcherOrderedSessions(inSpace spaceID: SidebarSpace.ID) -> [TerminalSession] {
        var seenContainers: Set<SplitContainer.ID> = []
        return recencyOrderedSessions(inSpace: spaceID).filter { session in
            guard let container = splitContainer(containing: session.id) else { return true }
            return seenContainers.insert(container.id).inserted
        }
    }

    /// Called by the switcher on commit, after cycling suppressed recording
    /// (and attention clearing — the committed pick is the acknowledgment;
    /// likewise waking, since a preview must not spawn shells).
    func recordSelectionRecency() {
        recordRecency(selection)
        clearAttention(selection)
        wakeIfSleeping(selection)
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
        // A reveal is a genuine pick (palette row, notification click):
        // activateSpace lands the selection non-waking, so a sleeping
        // target wakes here, exactly like clicking its sidebar row.
        wakeIfSleeping(sessionID)
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
            if Self.updateSession(id, in: &spaces[spaceIndex].pinnedItems, mutate: mutate) {
                return
            }
            if let index = spaces[spaceIndex].ephemeralSessions.firstIndex(where: { $0.id == id }) {
                mutate(&spaces[spaceIndex].ephemeralSessions[index])
                return
            }
        }
    }

    /// Mutates one session in place wherever it nests in the item tree;
    /// returns whether it was found.
    private static func updateSession(
        _ id: TerminalSession.ID,
        in items: inout [SidebarPinnedItem],
        mutate: (inout TerminalSession) -> Void
    ) -> Bool {
        for index in items.indices {
            switch items[index] {
            case .tab(var session) where session.id == id:
                mutate(&session)
                items[index] = .tab(session)
                return true
            case .folder(var folder):
                if updateSession(id, in: &folder.items, mutate: mutate) {
                    items[index] = .folder(folder)
                    return true
                }
            default:
                break
            }
        }
        return false
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        var spaces: [SidebarSpace]
        /// Absent in state files written before splits shipped.
        var splitContainers: [SplitContainer]?
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
        guard let data = try? JSONEncoder().encode(
            PersistedState(spaces: spaces, splitContainers: splitContainers)
        ) else { return }
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
