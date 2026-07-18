import Foundation
import Testing
@testable import Enso

/// Folder working-directory memory (#25): a folder is, in practice, a
/// project, so it must remember its last tab's cwd — surviving manual
/// closes, ephemeral expiry, and app relaunch — and hand it to the next
/// tab created inside it.
@MainActor
struct TerminalSessionStoreTests {
    /// A real directory on disk so the stale-path check passes.
    private func makeTempDirectory(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnsoStoreTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// `select` pins the store's initial selection; the store `touch`es the
    /// selected tab on launch, so tests about `lastActivity` ordering must
    /// control which tab that is.
    private func makeStore(folder: TerminalFolder, select: TerminalSession.ID? = nil) -> TerminalSessionStore {
        TerminalSessionStore(
            spaces: [SidebarSpace(name: "Main", pinnedFolders: [folder], lastSelection: select)],
            persistToDisk: false
        )
    }

    private func folder(_ id: TerminalFolder.ID, in store: TerminalSessionStore) -> TerminalFolder? {
        store.spaces.flatMap(\.pinnedFolders).first { $0.id == id }
    }

    @Test func emptiedFolderSpawnsNewTabInRememberedDirectory() throws {
        let projectDir = try makeTempDirectory("project")
        let session = TerminalSession(title: "main", workingDirectory: projectDir)
        let folderID = TerminalFolder.ID()
        let store = makeStore(folder: TerminalFolder(id: folderID, title: "enso", sessions: [session]))

        store.close(sessionID: session.id)
        #expect(folder(folderID, in: store)?.sessions.isEmpty == true)
        #expect(folder(folderID, in: store)?.lastWorkingDirectory == projectDir)

        store.createSession(inFolder: folderID)
        #expect(store.selectedSession?.workingDirectory == projectDir)
    }

    @Test func mostRecentlyActiveTabWinsWhenFolderEmpties() throws {
        let oldDir = try makeTempDirectory("old")
        let recentDir = try makeTempDirectory("recent")
        let older = TerminalSession(
            title: "old", workingDirectory: oldDir, lastActivity: .now.addingTimeInterval(-3600)
        )
        let recent = TerminalSession(title: "recent", workingDirectory: recentDir, lastActivity: .now)
        let folderID = TerminalFolder.ID()
        let store = makeStore(
            folder: TerminalFolder(id: folderID, title: "enso", sessions: [older, recent]),
            select: recent.id
        )

        store.close(sessionIDs: [older.id, recent.id])
        #expect(folder(folderID, in: store)?.lastWorkingDirectory == recentDir)
    }

    @Test func cwdChangeKeepsFolderMemoryLive() throws {
        let startDir = try makeTempDirectory("start")
        let nestedDir = try makeTempDirectory("nested")
        let session = TerminalSession(title: "main", workingDirectory: startDir)
        let folderID = TerminalFolder.ID()
        let store = makeStore(folder: TerminalFolder(id: folderID, title: "enso", sessions: [session]))

        // The breadcrumb cwd (OSC 7), not the spawn cwd, is what the folder
        // remembers — captured on every change, not only on removal.
        store.updateWorkingDirectory(session.id, to: nestedDir)
        #expect(folder(folderID, in: store)?.lastWorkingDirectory == nestedDir)

        store.close(sessionID: session.id)
        store.createSession(inFolder: folderID)
        #expect(store.selectedSession?.workingDirectory == nestedDir)
    }

    @Test func staleRememberedDirectoryFallsBackToDefault() {
        let folderID = TerminalFolder.ID()
        let store = makeStore(folder: TerminalFolder(
            id: folderID,
            title: "enso",
            lastWorkingDirectory: "/definitely/not/a/real/path-\(UUID().uuidString)"
        ))

        store.createSession(inFolder: folderID)
        #expect(store.selectedSession?.workingDirectory == NSHomeDirectory())
    }

    @Test func liveTabsStillWinOverRememberedDirectory() throws {
        let liveDir = try makeTempDirectory("live")
        let rememberedDir = try makeTempDirectory("remembered")
        let session = TerminalSession(title: "main", workingDirectory: liveDir)
        let folderID = TerminalFolder.ID()
        let store = makeStore(folder: TerminalFolder(
            id: folderID, title: "enso", sessions: [session], lastWorkingDirectory: rememberedDir
        ))

        store.createSession(inFolder: folderID)
        #expect(store.selectedSession?.workingDirectory == liveDir)
    }

    // MARK: - Eager restore candidates (#45 / #53)

    @Test func eagerRestoreCandidatesAreMostRecentFirstAndSkipSelectedAndFiltered() throws {
        let dir = try makeTempDirectory("candidates")
        let selected = TerminalSession(title: "selected", workingDirectory: dir, lastActivity: .now)
        let stale = TerminalSession(
            title: "stale", workingDirectory: dir, lastActivity: .now.addingTimeInterval(-7200)
        )
        let fresh = TerminalSession(
            title: "fresh", workingDirectory: dir, lastActivity: .now.addingTimeInterval(-60)
        )
        let plainShell = TerminalSession(
            title: "shell", workingDirectory: dir, lastActivity: .now.addingTimeInterval(-30)
        )
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [selected, stale, fresh, plainShell]),
            select: selected.id
        )

        let restorable: Set = [selected.id, stale.id, fresh.id]
        let candidates = store.eagerRestoreCandidates { restorable.contains($0) }
        // Selected is excluded even though restorable; the plain shell tab
        // never makes the list; the rest come most recently used first.
        #expect(candidates.map(\.id) == [fresh.id, stale.id])
    }

    @Test func eagerRestoreCandidatesFollowTheActiveSpace() throws {
        let dir = try makeTempDirectory("spaces")
        let homeSelected = TerminalSession(title: "home-a", workingDirectory: dir)
        let homeDormant = TerminalSession(title: "home-b", workingDirectory: dir)
        let workSelected = TerminalSession(title: "work-a", workingDirectory: dir)
        let workDormant = TerminalSession(title: "work-b", workingDirectory: dir)
        let work = SidebarSpace(
            name: "Work",
            pinnedFolders: [TerminalFolder(title: "w", sessions: [workSelected, workDormant])],
            lastSelection: workSelected.id
        )
        let store = TerminalSessionStore(
            spaces: [
                SidebarSpace(
                    name: "Home",
                    pinnedFolders: [TerminalFolder(title: "h", sessions: [homeSelected, homeDormant])],
                    lastSelection: homeSelected.id
                ),
                work,
            ],
            persistToDisk: false
        )

        // Only the active space's tabs are candidates.
        #expect(store.eagerRestoreCandidates { _ in true }.map(\.id) == [homeDormant.id])

        // Switching spaces re-aims the sweep: the new space's dormant tabs
        // become the candidates (its remembered selection is skipped).
        store.activateSpace(work.id)
        #expect(store.eagerRestoreCandidates { _ in true }.map(\.id) == [workDormant.id])
    }

    @Test func eagerRestoreCandidatesAreCapped() throws {
        let dir = try makeTempDirectory("capped")
        // tab-0 is selected (and skipped); tab-1 onward are candidates in
        // strictly decreasing recency.
        let sessions = (0..<(TerminalSessionStore.maxEagerRestores + 3)).map { index in
            TerminalSession(
                title: "tab-\(index)",
                workingDirectory: dir,
                lastActivity: .now.addingTimeInterval(-Double(index))
            )
        }
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: sessions),
            select: sessions[0].id
        )

        let candidates = store.eagerRestoreCandidates { _ in true }
        // The cap keeps the most recently used tabs; the least recent two
        // stay lazy.
        #expect(candidates.map(\.id)
            == sessions[1...TerminalSessionStore.maxEagerRestores].map(\.id))
    }

    @Test func equalLastActivityCandidatesRankByStableTieBreaker() throws {
        let dir = try makeTempDirectory("tiebreak")
        // tab-0 is selected (its lastActivity is touched on launch, and it
        // is skipped anyway); every other tab shares ONE lastActivity, so
        // which of them make the capped warm list is decided purely by the
        // secondary key — Swift's sort alone is unstable and would make the
        // cap boundary a coin flip.
        let stamp = Date.now.addingTimeInterval(-600)
        let sessions = (0..<(TerminalSessionStore.maxEagerRestores + 3)).map { index in
            TerminalSession(title: "tab-\(index)", workingDirectory: dir, lastActivity: stamp)
        }
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: sessions),
            select: sessions[0].id
        )

        let expected = Array(
            sessions.dropFirst()
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .prefix(TerminalSessionStore.maxEagerRestores)
                .map(\.id)
        )
        #expect(store.eagerRestoreCandidates { _ in true }.map(\.id) == expected)
        // Reproducible on every ask, not just the first.
        #expect(store.eagerRestoreCandidates { _ in true }.map(\.id) == expected)
    }

    // MARK: - Atomic space transitions (#53)

    /// Two spaces with remembered selections and one extra (dormant-able)
    /// tab each; Home is the launch-active space.
    private func makeTwoSpaceStore(dir: String) -> (
        store: TerminalSessionStore,
        home: SidebarSpace, homeSelected: TerminalSession, homeDormant: TerminalSession,
        work: SidebarSpace, workSelected: TerminalSession, workDormant: TerminalSession
    ) {
        let homeSelected = TerminalSession(title: "home-a", workingDirectory: dir)
        let homeDormant = TerminalSession(title: "home-b", workingDirectory: dir)
        let workSelected = TerminalSession(title: "work-a", workingDirectory: dir)
        let workDormant = TerminalSession(title: "work-b", workingDirectory: dir)
        let home = SidebarSpace(
            name: "Home",
            pinnedFolders: [TerminalFolder(title: "h", sessions: [homeSelected, homeDormant])],
            lastSelection: homeSelected.id
        )
        let work = SidebarSpace(
            name: "Work",
            pinnedFolders: [TerminalFolder(title: "w", sessions: [workSelected, workDormant])],
            lastSelection: workSelected.id
        )
        let store = TerminalSessionStore(spaces: [home, work], persistToDisk: false)
        return (store, home, homeSelected, homeDormant, work, workSelected, workDormant)
    }

    @Test func deleteActiveSpaceTransitionsToFallbackAndResweeps() throws {
        let dir = try makeTempDirectory("delete-space")
        let (store, home, homeSelected, homeDormant, work, _, _) = makeTwoSpaceStore(dir: dir)
        store.activateSpace(work.id)

        // Record every sweep the transition path schedules, with the
        // selection it fires against.
        var sweptSelections: [TerminalSession.ID?] = []
        store.eagerRestoreSweepOverride = { [weak store] in
            sweptSelections.append(store?.selection)
        }

        store.deleteSpace(work.id)
        // Deleting the active space is a full transition: the fallback
        // space is active with its remembered selection, and exactly one
        // sweep was scheduled — after that selection was final.
        #expect(store.activeSpaceID == home.id)
        #expect(store.selection == homeSelected.id)
        #expect(sweptSelections == [homeSelected.id])
        #expect(store.eagerRestoreCandidates { _ in true }.map(\.id) == [homeDormant.id])

        // Deleting a background space is not a transition; no re-sweep.
        let scratch = store.createSpace(name: "Scratch", icon: .dot)
        store.activateSpace(home.id)
        sweptSelections = []
        store.deleteSpace(scratch)
        #expect(store.activeSpaceID == home.id)
        #expect(sweptSelections.isEmpty)
    }

    @Test func revealAcrossSpacesAimsTheSweepAtTheFinalSelection() throws {
        let dir = try makeTempDirectory("reveal")
        let (store, _, _, _, work, workSelected, workDormant) = makeTwoSpaceStore(dir: dir)

        var sweptSelections: [TerminalSession.ID?] = []
        store.eagerRestoreSweepOverride = { [weak store] in
            sweptSelections.append(store?.selection)
        }

        store.reveal(workDormant.id)
        // One transition, selection already final when the sweep fires: no
        // warm slot spent on the tab being opened, and the space's
        // remembered selection is back in the candidate pool.
        #expect(store.activeSpaceID == work.id)
        #expect(store.selection == workDormant.id)
        #expect(store.multiSelection == [workDormant.id])
        #expect(sweptSelections == [workDormant.id])
        #expect(store.eagerRestoreCandidates { _ in true }.map(\.id) == [workSelected.id])

        // Same-space reveal is a selection landing, not a transition.
        store.reveal(workSelected.id)
        #expect(store.selection == workSelected.id)
        #expect(sweptSelections.count == 1)
    }

    @Test func crossSpaceCreationSelectsTheNewTabBeforeTheSweep() throws {
        let dir = try makeTempDirectory("cross-create")
        let (store, _, _, _, work, workSelected, workDormant) = makeTwoSpaceStore(dir: dir)

        var sweptSelections: [TerminalSession.ID?] = []
        store.eagerRestoreSweepOverride = { [weak store] in
            sweptSelections.append(store?.selection)
        }

        store.createSession(inSpace: work.id, workingDirectory: dir)
        // The new tab — not the target space's remembered selection — is
        // what the transition's sweep sees as selected.
        let newID = try #require(store.selection)
        #expect(store.activeSpaceID == work.id)
        #expect(newID != workSelected.id)
        #expect(store.activeSpace.sessions.contains { $0.id == newID })
        #expect(sweptSelections == [newID])
        #expect(Set(store.eagerRestoreCandidates { _ in true }.map(\.id))
            == [workSelected.id, workDormant.id])
    }

    // MARK: - Persistence compatibility

    /// State files written before the field existed must keep decoding.
    @Test func folderDecodesWithoutLastWorkingDirectoryKey() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"enso","sessions":[]}
        """
        let folder = try JSONDecoder().decode(TerminalFolder.self, from: Data(json.utf8))
        #expect(folder.title == "enso")
        #expect(folder.lastWorkingDirectory == nil)
    }

    @Test func folderRoundTripsLastWorkingDirectory() throws {
        let original = TerminalFolder(title: "enso", lastWorkingDirectory: "/tmp/project")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalFolder.self, from: data)
        #expect(decoded.lastWorkingDirectory == "/tmp/project")
    }
}
