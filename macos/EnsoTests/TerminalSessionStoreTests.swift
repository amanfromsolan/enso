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
        let candidates = store.eagerRestoreCandidates(mayRestore: { restorable.contains($0) }, budget: .max)
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
        #expect(store.eagerRestoreCandidates(mayRestore: { _ in true }, budget: .max).map(\.id) == [homeDormant.id])

        // Switching spaces re-aims the sweep: the new space's dormant tabs
        // become the candidates (its remembered selection is skipped).
        store.activateSpace(work.id)
        #expect(store.eagerRestoreCandidates(mayRestore: { _ in true }, budget: .max).map(\.id) == [workDormant.id])
    }

    @Test func eagerRestoreCandidatesRespectTheWakeBudget() throws {
        let dir = try makeTempDirectory("capped")
        let budget = TerminalSessionStore.defaultAgentWakeRecentCount
        // tab-0 is selected (and skipped); tab-1 onward are candidates in
        // strictly decreasing recency.
        let sessions = (0..<(budget + 3)).map { index in
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

        // The budget keeps the most recently used tabs; the least recent
        // stay lazy. Zero budget ("wake as I visit") empties the sweep.
        let candidates = store.eagerRestoreCandidates(mayRestore: { _ in true }, budget: budget)
        #expect(candidates.map(\.id) == sessions[1...budget].map(\.id))
        #expect(store.eagerRestoreCandidates(mayRestore: { _ in true }, budget: 0).isEmpty)
    }

    @Test func agentWakeBudgetFollowsPolicyAndSpentWakes() {
        #expect(TerminalSessionStore.agentWakeBudget(policy: .onVisit, recentCount: 5, alreadyWoken: 0) == 0)
        #expect(TerminalSessionStore.agentWakeBudget(policy: .recent, recentCount: 5, alreadyWoken: 0) == 5)
        // The budget is per launch: re-sweeps continue it, never restart it.
        #expect(TerminalSessionStore.agentWakeBudget(policy: .recent, recentCount: 5, alreadyWoken: 3) == 2)
        // Lowering the count below what already woke must clamp, not trap.
        #expect(TerminalSessionStore.agentWakeBudget(policy: .recent, recentCount: 5, alreadyWoken: 7) == 0)
        #expect(TerminalSessionStore.agentWakeBudget(policy: .all, recentCount: 5, alreadyWoken: 100) == .max)
    }

    @Test func equalLastActivityCandidatesRankByStableTieBreaker() throws {
        let dir = try makeTempDirectory("tiebreak")
        // tab-0 is selected (its lastActivity is touched on launch, and it
        // is skipped anyway); every other tab shares ONE lastActivity, so
        // which of them make the capped warm list is decided purely by the
        // secondary key — Swift's sort alone is unstable and would make the
        // cap boundary a coin flip.
        let stamp = Date.now.addingTimeInterval(-600)
        let budget = TerminalSessionStore.defaultAgentWakeRecentCount
        let sessions = (0..<(budget + 3)).map { index in
            TerminalSession(title: "tab-\(index)", workingDirectory: dir, lastActivity: stamp)
        }
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: sessions),
            select: sessions[0].id
        )

        let expected = Array(
            sessions.dropFirst()
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .prefix(budget)
                .map(\.id)
        )
        #expect(store.eagerRestoreCandidates(mayRestore: { _ in true }, budget: budget).map(\.id) == expected)
        // Reproducible on every ask, not just the first.
        #expect(store.eagerRestoreCandidates(mayRestore: { _ in true }, budget: budget).map(\.id) == expected)
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
        #expect(store.eagerRestoreCandidates(mayRestore: { _ in true }, budget: .max).map(\.id) == [homeDormant.id])

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
        #expect(store.eagerRestoreCandidates(mayRestore: { _ in true }, budget: .max).map(\.id) == [workSelected.id])

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
        #expect(Set(store.eagerRestoreCandidates(mayRestore: { _ in true }, budget: .max).map(\.id))
            == [workSelected.id, workDormant.id])
    }

    // MARK: - Sleep / wake

    @Test func putToSleepCapturesWhatWasRunningAndHandsSelectionBack() throws {
        let dir = try makeTempDirectory("sleep")
        var sleeper = TerminalSession(title: "agent", workingDirectory: dir, status: .attention)
        sleeper.runningProcess = .claude
        let neighbor = TerminalSession(title: "shell", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [sleeper, neighbor]),
            select: sleeper.id
        )

        store.putToSleep(sessionID: sleeper.id)
        let slept = try #require(store.sessions.first { $0.id == sleeper.id })
        #expect(slept.isSleeping)
        // The process died with the surface, and the attention dot leads
        // nowhere anymore — but the sleeping card remembers what ran.
        #expect(slept.runningProcess == nil)
        #expect(slept.sleepingProcess == .claude)
        #expect(slept.status == .idle)
        // Sleeping the selected tab says "done here for now": the
        // workspace returns to the previously used tab instead of parking
        // on the sleeping card.
        #expect(store.selection == neighbor.id)

        // A background sleep never touches selection.
        store.wake(sessionID: sleeper.id)
        store.putToSleep(sessionID: sleeper.id)
        #expect(store.selection == neighbor.id)
    }

    @Test func selectingSleepingTabWakesIt() throws {
        let dir = try makeTempDirectory("wake")
        let awake = TerminalSession(title: "a", workingDirectory: dir)
        let sleeper = TerminalSession(title: "b", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [awake, sleeper]),
            select: awake.id
        )

        store.putToSleep(sessionID: sleeper.id)
        #expect(store.sessions.first { $0.id == sleeper.id }?.isSleeping == true)

        // Click to wake: a committed selection is all it takes.
        store.selection = sleeper.id
        #expect(store.sessions.first { $0.id == sleeper.id }?.isSleeping == false)
    }

    @Test func cyclingPreviewsDoNotWakeSleepingTabs() throws {
        let dir = try makeTempDirectory("cycle")
        let awake = TerminalSession(title: "a", workingDirectory: dir)
        let sleeper = TerminalSession(title: "b", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [awake, sleeper]),
            select: awake.id
        )
        store.putToSleep(sessionID: sleeper.id)

        // Ctrl-Tab previews pass through tabs the user never chose; only
        // the committed pick wakes.
        store.isCyclingSelection = true
        store.selection = sleeper.id
        #expect(store.sessions.first { $0.id == sleeper.id }?.isSleeping == true)

        store.isCyclingSelection = false
        store.recordSelectionRecency()
        #expect(store.sessions.first { $0.id == sleeper.id }?.isSleeping == false)
    }

    @Test func sleepingAPaneLeavesItsSplitSiblingsAwake() throws {
        let dir = try makeTempDirectory("split-sleep")
        let source = TerminalSession(title: "main", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [source]),
            select: source.id
        )
        store.splitSelection(direction: .horizontal)
        let pane = try #require(store.selection)
        #expect(pane != source.id)

        // Sleep is strictly per pane: the sibling keeps running and the
        // container stays intact — the slept pane's region shows the
        // in-pane moon, not a dissolved split.
        store.putToSleep(sessionID: source.id)
        #expect(store.sessions.first { $0.id == source.id }?.isSleeping == true)
        #expect(store.sessions.first { $0.id == pane }?.isSleeping == false)
        #expect(store.splitContainer(containing: source.id) != nil)

        // And the wake is just as scoped.
        store.wake(sessionID: source.id)
        #expect(store.sessions.first { $0.id == source.id }?.isSleeping == false)
    }

    @Test func sleepingTheFocusedPaneHandsSelectionToAnAwakeSibling() throws {
        let dir = try makeTempDirectory("split-sleep-handoff")
        let source = TerminalSession(title: "main", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [source]),
            select: source.id
        )
        store.splitSelection(direction: .horizontal)
        let pane = try #require(store.selection)
        #expect(pane != source.id)

        // The focused pane sleeps: with no live surface a selected moon
        // would strand the keyboard, so the nearest awake sibling takes
        // over — the same handoff close() makes. The split stays intact.
        store.putToSleep(sessionID: pane)
        #expect(store.selection == source.id)
        #expect(store.sessions.first { $0.id == pane }?.isSleeping == true)
        #expect(store.splitContainer(containing: pane) != nil)

        // With every sibling asleep — and nothing awake outside the split
        // either — there is nothing to hand over to: the selection parks
        // on the moon rather than jumping to another sleeping card.
        store.putToSleep(sessionID: source.id)
        #expect(store.selection == source.id)
    }

    @Test func sleepingTheSelectedTabHandsSelectionToThePreviousTab() throws {
        let dir = try makeTempDirectory("sleep-mru-handoff")
        let first = TerminalSession(title: "a", workingDirectory: dir)
        let second = TerminalSession(title: "b", workingDirectory: dir)
        let third = TerminalSession(title: "c", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [first, second, third]),
            select: second.id
        )
        // Recency: first (current), third, second.
        store.selection = third.id
        store.selection = first.id

        // The handoff follows recency, not row order: sleeping the
        // selected tab returns to the tab used just before it.
        store.putToSleep(sessionID: first.id)
        #expect(store.selection == third.id)

        // And it skips sleeping tabs while an awake candidate exists —
        // recency still ranks the just-slept FIRST ahead of SECOND, but a
        // handoff must never park on (or wake) a sleeping card.
        store.putToSleep(sessionID: third.id)
        #expect(store.selection == second.id)
        #expect(store.sessions.first { $0.id == first.id }?.isSleeping == true)
    }

    @Test func busyAgentRequiresARunningAgentWithoutTheAttentionDot() throws {
        let dir = try makeTempDirectory("busy")
        var working = TerminalSession(title: "working", workingDirectory: dir)
        working.runningProcess = .claude
        var waiting = TerminalSession(title: "waiting", workingDirectory: dir, status: .attention)
        waiting.runningProcess = .codex
        var tool = TerminalSession(title: "tool", workingDirectory: dir)
        tool.runningProcess = .editor
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [working, waiting, tool])
        )

        // Selecting clears attention, so pin the selection elsewhere first.
        store.selection = tool.id
        #expect(store.busyAgent(inTab: working.id) == .claude)
        // The attention dot means the agent is waiting on the user — idle,
        // safe to sleep without asking.
        #expect(store.busyAgent(inTab: waiting.id) == nil)
        // Non-agent tools never warrant the confirmation.
        #expect(store.busyAgent(inTab: tool.id) == nil)
    }

    @Test func closingASleepingTabRemovesItWithoutWakingOrSelecting() throws {
        let dir = try makeTempDirectory("close-sleeping")
        let selected = TerminalSession(title: "a", workingDirectory: dir)
        let sleeper = TerminalSession(title: "b", workingDirectory: dir)
        let bystander = TerminalSession(title: "c", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [selected, sleeper, bystander]),
            select: selected.id
        )
        store.putToSleep(sessionID: sleeper.id)

        // The sleeping row's × removes the tab for real: gone from the
        // sidebar, selection untouched — no wake, no reselect.
        store.close(sessionID: sleeper.id)
        #expect(!store.sessions.contains { $0.id == sleeper.id })
        #expect(store.selection == selected.id)
    }

    @Test func closingTheSelectedTabHandsSelectionToAnAwakeRow() throws {
        let dir = try makeTempDirectory("close-handoff")
        let selected = TerminalSession(title: "a", workingDirectory: dir)
        let sleeper = TerminalSession(title: "b", workingDirectory: dir)
        let awake = TerminalSession(title: "c", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [selected, sleeper, awake]),
            select: selected.id
        )
        store.putToSleep(sessionID: sleeper.id)

        // Selecting wakes, so the close handoff must skip the sleeping
        // neighbor — its shell must not spawn unasked.
        store.close(sessionID: selected.id)
        #expect(store.selection == awake.id)
        #expect(store.sessions.first { $0.id == sleeper.id }?.isSleeping == true)
    }

    @Test func launchKeepsASleepingLastSelectionAsleep() throws {
        let dir = try makeTempDirectory("launch-sleeping")
        let sleeper = TerminalSession(title: "a", workingDirectory: dir, isSleeping: true)
        let other = TerminalSession(title: "b", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [sleeper, other]),
            select: sleeper.id
        )

        // The relaunch shape: whatever was selected at quit is selected
        // again — and if it was asleep, it comes back asleep, showing its
        // sleeping card rather than spawning a shell nobody asked for.
        #expect(store.selection == sleeper.id)
        #expect(store.sessions.first { $0.id == sleeper.id }?.isSleeping == true)
    }

    @Test func activateSpaceLandsOnAnAwakeRowWhenTheRememberedOneSleeps() throws {
        let dir = try makeTempDirectory("space-landing")
        let homeTab = TerminalSession(title: "home", workingDirectory: dir)
        let workSleeper = TerminalSession(title: "w-sleeping", workingDirectory: dir, isSleeping: true)
        let workAwake = TerminalSession(title: "w-awake", workingDirectory: dir)
        let allSleeperA = TerminalSession(title: "p-a", workingDirectory: dir, isSleeping: true)
        let allSleeperB = TerminalSession(title: "p-b", workingDirectory: dir, isSleeping: true)
        let work = SidebarSpace(
            name: "Work",
            pinnedFolders: [TerminalFolder(title: "w", sessions: [workSleeper, workAwake])],
            lastSelection: workSleeper.id
        )
        let parked = SidebarSpace(
            name: "Parked",
            pinnedFolders: [TerminalFolder(title: "p", sessions: [allSleeperA, allSleeperB])],
            lastSelection: allSleeperA.id
        )
        let store = TerminalSessionStore(
            spaces: [
                SidebarSpace(name: "Home", ephemeralSessions: [homeTab], lastSelection: homeTab.id),
                work,
                parked,
            ],
            persistToDisk: false
        )

        // The user picked a space, not its sleeping remembered tab: land
        // on the first awake row instead, waking nothing.
        store.activateSpace(work.id)
        #expect(store.selection == workAwake.id)
        #expect(store.sessions.first { $0.id == workSleeper.id }?.isSleeping == true)

        // A space that is asleep wall to wall keeps its remembered card —
        // there is nothing awake to prefer, and nothing wakes.
        store.activateSpace(parked.id)
        #expect(store.selection == allSleeperA.id)
        #expect(store.sessions.first { $0.id == allSleeperA.id }?.isSleeping == true)
    }

    @Test func switcherCancelRestoresASleepingOriginWithoutWaking() throws {
        let dir = try makeTempDirectory("switcher-cancel")
        // Asleep from launch: the relaunch shape is how a sleeping tab
        // ends up selected (sleeping the selected tab now hands off).
        let sleeper = TerminalSession(title: "a", workingDirectory: dir, isSleeping: true)
        let other = TerminalSession(title: "b", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [sleeper, other]),
            select: sleeper.id
        )
        #expect(store.selection == sleeper.id)

        // Ctrl-Tab away from the sleeping card, then Esc back: the origin
        // must come back still asleep — a cancel is not a pick.
        let switcher = TabSwitcher()
        switcher.attach(to: store)
        switcher.begin(backwards: false)
        #expect(store.selection == other.id)
        switcher.cancel()
        #expect(store.selection == sleeper.id)
        #expect(store.sessions.first { $0.id == sleeper.id }?.isSleeping == true)
    }

    @Test func switcherTreatsASplitAsOneStop() throws {
        let dir = try makeTempDirectory("switcher-split")
        let source = TerminalSession(title: "main", workingDirectory: dir)
        let other = TerminalSession(title: "other", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [source, other]),
            select: source.id
        )
        store.splitSelection(direction: .horizontal)
        let pane = try #require(store.selection)
        #expect(pane != source.id)

        // Quick tap from a pane: the flip must reach the most recent tab
        // OUTSIDE the split — the sibling pane is part of the same stop,
        // even though it sits right below the pane in raw recency.
        let switcher = TabSwitcher()
        switcher.attach(to: store)
        switcher.begin(backwards: false)
        #expect(store.selection == other.id)
        // The HUD sees the collapsed stops too: one tile for the split
        // (its most recent member), one for the loose tab.
        #expect(switcher.sessions.map(\.id) == [pane, other.id])

        // Cycling on wraps back to the split as a whole — one stop, never
        // a walk through the sibling.
        switcher.advance(by: 1)
        #expect(store.selection == pane)
        switcher.commit()
    }

    /// The host grants pane focus when a cycle step renders a split, and
    /// the grant's onFocusGained sync can arrive LATE — after the walk
    /// moved on (SwiftUI update lag on the multi-surface re-attach), or
    /// after the session committed. A late grant must never yank the
    /// selection back into the split it came from.
    @Test func cyclingSurvivesLateFocusGrantsFromSplitPanes() throws {
        let dir = try makeTempDirectory("switcher-late-grants")
        let source = TerminalSession(title: "main", workingDirectory: dir)
        let c = TerminalSession(title: "c", workingDirectory: dir)
        let d = TerminalSession(title: "d", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [source, c, d]),
            select: source.id
        )
        store.splitSelection(direction: .horizontal)
        let pane = try #require(store.selection)
        let memberIDs = try #require(store.splitContainer(containing: pane)).memberIDs

        // The host model: landing on the split queues a focus regrant for
        // the landed pane (the surfaces re-attach); it is delivered one
        // step LATER, through the same sync onFocusGained runs.
        var lateGrants: [TerminalSession.ID] = []
        func step(_ switcher: TabSwitcher, by delta: Int = 1) {
            switcher.advance(by: delta)
            while !lateGrants.isEmpty {
                store.paneFocusDidGain(lateGrants.removeFirst())
            }
            if let landed = store.selection, memberIDs.contains(landed) {
                lateGrants.append(landed)
            }
        }

        // Hold-session walking TWO full wraps: stops are [pane, c, d].
        let switcher = TabSwitcher()
        switcher.attach(to: store)
        switcher.begin(backwards: false)
        if let landed = store.selection, memberIDs.contains(landed) {
            lateGrants.append(landed)
        }
        #expect(store.selection == c.id)

        step(switcher)
        #expect(store.selection == d.id)
        step(switcher)
        #expect(store.selection == pane) // split visit #1: passes
        // The step AFTER the split visit is where the regrant lands late:
        // the walk must stay on its new stop, not snap back to the pane.
        step(switcher)
        #expect(store.selection == c.id)
        step(switcher)
        #expect(store.selection == d.id)
        step(switcher)
        #expect(store.selection == pane) // split visit #2: still one stop
        step(switcher)
        #expect(store.selection == c.id)

        switcher.commit()
        #expect(store.selection == c.id)

        // Next session: quick-flip INTO the split; its landing regrant
        // drains after the commit and must be a no-op.
        switcher.begin(backwards: false)
        switcher.commit()
        if let landed = store.selection, memberIDs.contains(landed) {
            lateGrants.append(landed)
        }
        while !lateGrants.isEmpty {
            store.paneFocusDidGain(lateGrants.removeFirst())
        }
        #expect(store.selection == pane)

        // And a session AWAY from the split, with the split's stale
        // regrant arriving after the commit: the pick must stick — a
        // post-commit yank re-records the member and re-selects the
        // split, which is exactly the reported "stuck" loop.
        switcher.begin(backwards: false)
        switcher.commit()
        let committed = try #require(store.selection)
        #expect(!memberIDs.contains(committed))
        store.paneFocusDidGain(pane)
        #expect(store.selection == committed)
    }

    /// A late sibling grant accepted mid-cycle can leave a split member
    /// selected while raw recency ranks other tabs (and the sibling)
    /// above it. The walk's current-position lookup must find the
    /// container's stop by MEMBERSHIP, or the flip restarts at the top of
    /// the list and lands on the sibling — ping-pong inside the split.
    @Test func quickFlipFromADisplacedSplitMemberNeverLandsOnTheSibling() throws {
        let dir = try makeTempDirectory("switcher-displaced-member")
        let source = TerminalSession(title: "main", workingDirectory: dir)
        let c = TerminalSession(title: "c", workingDirectory: dir)
        let d = TerminalSession(title: "d", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [source, c, d]),
            select: source.id
        )
        store.splitSelection(direction: .horizontal)
        let pane = try #require(store.selection)
        let container = try #require(store.splitContainer(containing: pane))

        // c is genuinely recent; then a late grant (delivered inside a
        // cycling window, so nothing records) parks the user in SOURCE:
        // selection is a member, but recency reads [c, pane, source].
        store.selection = c.id
        store.isCyclingSelection = true
        store.selection = source.id
        store.isCyclingSelection = false

        // Quick flip from the displaced member: one stop past the
        // container — never the sibling pane.
        let switcher = TabSwitcher()
        switcher.attach(to: store)
        switcher.begin(backwards: false)
        let flipped = try #require(store.selection)
        #expect(!container.tree.contains(flipped))
        #expect(flipped == d.id)
        switcher.commit()
    }

    @Test func cyclingIntoASplitLandsOnItsMostRecentlyFocusedMember() throws {
        let dir = try makeTempDirectory("switcher-split-landing")
        let source = TerminalSession(title: "main", workingDirectory: dir)
        let other = TerminalSession(title: "other", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [source, other]),
            select: source.id
        )
        store.splitSelection(direction: .horizontal)

        // Focus back to the source pane (selection follows pane focus),
        // then leave the split for the loose tab.
        store.selection = source.id
        store.selection = other.id

        // Cycling into the split lands on SOURCE — the member focused
        // most recently — not on the sibling that was created later.
        let switcher = TabSwitcher()
        switcher.attach(to: store)
        switcher.begin(backwards: false)
        #expect(store.selection == source.id)
        switcher.commit()
    }

    @Test func closingOnePaneOfAFullySleepingSplitKeepsTheSurvivorAsleep() throws {
        let dir = try makeTempDirectory("split-close-sleeping")
        let source = TerminalSession(title: "main", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [source]),
            select: source.id
        )
        store.splitSelection(direction: .horizontal)
        let pane = try #require(store.selection)
        // Each pane slept on its own — sleep is per pane.
        store.putToSleep(sessionID: source.id)
        store.putToSleep(sessionID: pane)
        #expect(store.sessions.allSatisfy { $0.isSleeping })

        // Closing the selected sleeping pane hands over to the surviving
        // member — as its sleeping card, never as a freshly woken shell.
        store.close(sessionID: pane)
        #expect(store.selection == source.id)
        #expect(store.sessions.first { $0.id == source.id }?.isSleeping == true)
    }

    @Test func wakingABackgroundTabMountsItsSurfaces() throws {
        let dir = try makeTempDirectory("background-wake")
        let selected = TerminalSession(title: "a", workingDirectory: dir)
        let sleeper = TerminalSession(title: "b", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [selected, sleeper]),
            select: selected.id
        )
        store.putToSleep(sessionID: sleeper.id)

        var mounted: [TerminalSession.ID] = []
        store.wakeSurfaceMounter = { mounted.append($0.id) }

        // Context-menu Wake on a non-selected row: the workspace host only
        // renders the selection, so the wake itself must mount the surface
        // (which is what consumes the wake marker and spawns the resume).
        store.wake(sessionID: sleeper.id)
        #expect(mounted == [sleeper.id])
        #expect(store.sessions.first { $0.id == sleeper.id }?.isSleeping == false)
        #expect(store.selection == selected.id)
    }

    @Test func sleepingTabIsImmuneToEphemeralExpiry() throws {
        let dir = try makeTempDirectory("expiry")
        let defaults = UserDefaults.standard
        let previousTTL = defaults.object(forKey: TerminalSessionStore.ephemeralTTLDefaultsKey)
        defaults.set(24, forKey: TerminalSessionStore.ephemeralTTLDefaultsKey)
        defer {
            if let previousTTL {
                defaults.set(previousTTL, forKey: TerminalSessionStore.ephemeralTTLDefaultsKey)
            } else {
                defaults.removeObject(forKey: TerminalSessionStore.ephemeralTTLDefaultsKey)
            }
        }

        let stamp = Date.now.addingTimeInterval(-72 * 3600)
        let current = TerminalSession(title: "current", workingDirectory: dir)
        // An unpinned sleeper (slept, then unpinned or moved): parked on
        // purpose, so the expiry sweep must never close it.
        let sleeper = TerminalSession(
            title: "sleeper", workingDirectory: dir, lastActivity: stamp, isSleeping: true
        )
        let stale = TerminalSession(title: "stale", workingDirectory: dir, lastActivity: stamp)
        let store = TerminalSessionStore(
            spaces: [SidebarSpace(
                name: "Main",
                ephemeralSessions: [current, sleeper, stale],
                lastSelection: current.id
            )],
            persistToDisk: false
        )

        store.pruneExpiredEphemeralSessions()
        #expect(store.sessions.contains { $0.id == sleeper.id })
        #expect(!store.sessions.contains { $0.id == stale.id })
    }

    @Test func commandCloseIsTwoStepForPinnedTabs() throws {
        let dir = try makeTempDirectory("two-step")
        let pinned = TerminalSession(title: "pinned", workingDirectory: dir)
        let other = TerminalSession(title: "other", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [pinned, other]),
            select: pinned.id
        )

        // ⌘W on a pinned awake tab sleeps it — and the sleep hands the
        // workspace back to the previous tab, so a second ⌘W acts on THAT
        // tab, never blindly destroying the one just slept.
        #expect(store.selectedTabSleepsInsteadOfClosing)
        store.closeSelectedSession()
        #expect(store.sessions.first { $0.id == pinned.id }?.isSleeping == true)
        #expect(store.selection == other.id)

        // A sleeping tab holding the selection (the relaunch shape, here
        // via a non-waking restore) closes for real on ⌘W.
        store.setSelection(pinned.id, waking: false)
        #expect(!store.selectedTabSleepsInsteadOfClosing)
        store.closeSelectedSession()
        #expect(!store.sessions.contains { $0.id == pinned.id })

        // Unpinned tabs keep the one-step close.
        let ephemeral = TerminalSession(title: "temp", workingDirectory: dir)
        let ephemeralStore = TerminalSessionStore(
            spaces: [SidebarSpace(name: "Main", ephemeralSessions: [ephemeral])],
            persistToDisk: false
        )
        #expect(!ephemeralStore.selectedTabSleepsInsteadOfClosing)
        ephemeralStore.closeSelectedSession()
        #expect(!ephemeralStore.sessions.contains { $0.id == ephemeral.id })
    }

    @Test func splittingASleepingTabWakesItFirst() throws {
        let dir = try makeTempDirectory("split-wake")
        let sleeper = TerminalSession(title: "a", workingDirectory: dir)
        let other = TerminalSession(title: "b", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [sleeper, other]),
            select: other.id
        )
        store.putToSleep(sessionID: sleeper.id)
        store.setSelection(sleeper.id, waking: false)

        // ⌘D means "I want to work here": the sleeping source wakes, then
        // splits — no half-asleep container with an unreachable hole.
        store.splitSelection(direction: .horizontal)
        #expect(store.sessions.first { $0.id == sleeper.id }?.isSleeping == false)
        #expect(store.splitContainer(containing: sleeper.id) != nil)
    }

    @Test func eagerRestoreCandidatesSkipSleepingTabs() throws {
        let dir = try makeTempDirectory("sleeping-candidates")
        let selected = TerminalSession(title: "selected", workingDirectory: dir)
        let dormant = TerminalSession(title: "dormant", workingDirectory: dir)
        let sleeper = TerminalSession(title: "sleeper", workingDirectory: dir)
        let store = makeStore(
            folder: TerminalFolder(title: "enso", sessions: [selected, dormant, sleeper]),
            select: selected.id
        )

        store.putToSleep(sessionID: sleeper.id)
        // A background warm-up spawning a sleeping tab's agent would defeat
        // the sleep — it waits for its click.
        #expect(store.eagerRestoreCandidates(mayRestore: { _ in true }, budget: .max).map(\.id) == [dormant.id])
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

    @Test func sessionDecodesWithoutIsSleepingKey() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"main","workingDirectory":"/tmp",\
        "status":"Running","accent":"blue","lastActivity":774059000.0}
        """
        let session = try JSONDecoder().decode(TerminalSession.self, from: Data(json.utf8))
        #expect(!session.isSleeping)
    }

    @Test func sessionRoundTripsSleepState() throws {
        let original = TerminalSession(
            title: "main", workingDirectory: "/tmp", isSleeping: true, sleepingProcess: .claude
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalSession.self, from: data)
        #expect(decoded.isSleeping)
        // The sleeping card's "what was running" summary survives relaunch.
        #expect(decoded.sleepingProcess == .claude)
    }

    /// A future build's process kind must degrade to the plain-shell
    /// summary, never fail the whole tab's decode.
    @Test func sessionToleratesAnUnknownSleepingProcess() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"main","workingDirectory":"/tmp",\
        "status":"Running","accent":"blue","lastActivity":774059000.0,\
        "isSleeping":true,"sleepingProcess":"hal9000"}
        """
        let session = try JSONDecoder().decode(TerminalSession.self, from: Data(json.utf8))
        #expect(session.isSleeping)
        #expect(session.sleepingProcess == nil)
    }
}
