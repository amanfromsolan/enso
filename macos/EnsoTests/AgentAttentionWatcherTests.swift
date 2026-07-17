import Foundation
import Testing
@testable import Enso

/// AgentAttentionWatcher's pure tailing logic — tick read planning (EOF
/// baseline on the initial scan, zero start for files born later, shrink
/// reset, dropped offsets for deleted files), complete-line splitting with a
/// partial trailing line, and hook-event filtering — plus the store side of
/// attention marking. The timer/queue plumbing is deliberately untested:
/// everything it does routes through these statics.
@MainActor
struct AgentAttentionWatcherTests {
    private func hookLine(agent: String, name: String, extra: String = "") -> String {
        #"{"v":1,"event":"hook","agent":"\#(agent)","payload":{"hook_event_name":"\#(name)","session_id":"abc","cwd":"/tmp/proj"\#(extra)},"ts":100}"#
    }

    // MARK: - Read planning

    @Test func initialScanBaselinesAtEOFWithoutReading() {
        let plan = AgentAttentionWatcher.readPlan(
            sizes: ["a.jsonl": 120, "b.jsonl": 0],
            offsets: [:],
            isInitialScan: true
        )
        // Events written before the watcher started are stale; never replay.
        #expect(plan.reads.isEmpty)
        #expect(plan.offsets == ["a.jsonl": 120, "b.jsonl": 0])
    }

    @Test func laterTicksReadOnlyAppendedBytes() {
        let plan = AgentAttentionWatcher.readPlan(
            sizes: ["a.jsonl": 150],
            offsets: ["a.jsonl": 100],
            isInitialScan: false
        )
        #expect(plan.reads == ["a.jsonl": 100..<150])
        // The planned offset stays put; the tick advances it only past the
        // lines it actually consumed.
        #expect(plan.offsets == ["a.jsonl": 100])
    }

    @Test func unchangedFileReadsNothing() {
        let plan = AgentAttentionWatcher.readPlan(
            sizes: ["a.jsonl": 100],
            offsets: ["a.jsonl": 100],
            isInitialScan: false
        )
        #expect(plan.reads.isEmpty)
        #expect(plan.offsets == ["a.jsonl": 100])
    }

    @Test func fileBornAfterStartReadsFromZero() {
        // A brand-new tab's first events are fresh and must fire.
        let plan = AgentAttentionWatcher.readPlan(
            sizes: ["new.jsonl": 40],
            offsets: [:],
            isInitialScan: false
        )
        #expect(plan.reads == ["new.jsonl": 0..<40])
    }

    @Test func shrunkenFileResetsWithoutReplay() {
        let plan = AgentAttentionWatcher.readPlan(
            sizes: ["a.jsonl": 80],
            offsets: ["a.jsonl": 200],
            isInitialScan: false
        )
        #expect(plan.reads.isEmpty)
        #expect(plan.offsets == ["a.jsonl": 80])
    }

    @Test func deletedFileDropsItsOffset() {
        let plan = AgentAttentionWatcher.readPlan(
            sizes: ["a.jsonl": 10],
            offsets: ["a.jsonl": 10, "gone.jsonl": 50],
            isInitialScan: false
        )
        #expect(plan.offsets == ["a.jsonl": 10])
    }

    // MARK: - Line splitting

    @Test func completeLinesLeavesPartialTrailingLineUnconsumed() {
        let (lines, consumed) = AgentAttentionWatcher.completeLines(in: Data("one\ntwo\npart".utf8))
        #expect(lines == ["one", "two"])
        #expect(consumed == 8)
    }

    @Test func completeLinesWithoutNewlineConsumesNothing() {
        let (lines, consumed) = AgentAttentionWatcher.completeLines(in: Data("partial".utf8))
        #expect(lines.isEmpty)
        #expect(consumed == 0)
    }

    @Test func completeLinesSkipsBlankLinesButConsumesThem() {
        let (lines, consumed) = AgentAttentionWatcher.completeLines(in: Data("one\n\ntwo\n".utf8))
        #expect(lines == ["one", "two"])
        #expect(consumed == 9)
    }

    // MARK: - Event filtering

    @Test func notificationHookBecomesNeedsInput() {
        let event = AgentAttentionWatcher.attentionEvent(fromLine: hookLine(
            agent: "claude",
            name: "Notification",
            extra: #","message":"Claude needs your permission to use Bash""#
        ))
        #expect(event == .needsInput(agent: "claude", message: "Claude needs your permission to use Bash"))
    }

    @Test func stopHookBecomesFinishedResponding() {
        let event = AgentAttentionWatcher.attentionEvent(fromLine: hookLine(agent: "codex", name: "Stop"))
        #expect(event == .finishedResponding(agent: "codex"))
    }

    @Test func lifecycleAndGarbageLinesAreIgnored() {
        for line in [
            hookLine(agent: "claude", name: "SessionStart"),
            hookLine(agent: "claude", name: "SessionEnd", extra: #","reason":"other""#),
            #"{"v":1,"event":"launch","agent":"claude","sessionId":"abc","cwd":"/tmp/proj","ts":100}"#,
            #"{"v":1,"event":"hook","agent":"claude","ts":100}"#,
            "not json at all",
            "",
        ] {
            #expect(AgentAttentionWatcher.attentionEvent(fromLine: line) == nil)
        }
    }

    @Test func notificationBodyPrefersHookMessage() {
        #expect(
            AgentAttentionWatcher.AttentionEvent
                .needsInput(agent: "claude", message: "Claude is waiting for your input")
                .notificationBody == "Claude is waiting for your input"
        )
        #expect(
            AgentAttentionWatcher.AttentionEvent.needsInput(agent: "claude", message: nil)
                .notificationBody == "Claude is waiting for your input"
        )
        #expect(
            AgentAttentionWatcher.AttentionEvent.finishedResponding(agent: "codex")
                .notificationBody == "Codex finished responding"
        )
    }

    // MARK: - Store handling

    private func makeStore(_ sessions: [TerminalSession]) -> TerminalSessionStore {
        TerminalSessionStore(
            spaces: [SidebarSpace(name: "Main", ephemeralSessions: sessions)],
            persistToDisk: false
        )
    }

    @Test func attentionMarksBackgroundTabAndSelectionClearsIt() {
        let front = TerminalSession(title: "front", workingDirectory: "~")
        let back = TerminalSession(title: "agent tab", workingDirectory: "~")
        let store = makeStore([front, back])
        store.selection = front.id

        #expect(store.handleAgentAttention(tabID: back.id, isAppActive: true) == "agent tab")
        #expect(store.sessions.first { $0.id == back.id }?.status == .attention)

        store.selection = back.id
        #expect(store.sessions.first { $0.id == back.id }?.status == .running)
    }

    @Test func selectedTabIsSuppressedWhileActiveButMarkedWhenInactive() {
        let session = TerminalSession(title: "front", workingDirectory: "~")
        let store = makeStore([session])
        store.selection = session.id

        // The user is already looking at it — no dot, no notification.
        #expect(store.handleAgentAttention(tabID: session.id, isAppActive: true) == nil)
        #expect(store.sessions.first { $0.id == session.id }?.status == .running)

        // App in the background: even the selected tab earns both.
        #expect(store.handleAgentAttention(tabID: session.id, isAppActive: false) == "front")
        #expect(store.sessions.first { $0.id == session.id }?.status == .attention)
    }

    @Test func repeatEventsKeepTheDotButSuppressRepeatNotifications() {
        let front = TerminalSession(title: "front", workingDirectory: "~")
        let back = TerminalSession(title: "back", workingDirectory: "~")
        let store = makeStore([front, back])
        store.selection = front.id

        #expect(store.handleAgentAttention(tabID: back.id, isAppActive: true) == "back")
        #expect(store.handleAgentAttention(tabID: back.id, isAppActive: true) == nil)
        #expect(store.sessions.first { $0.id == back.id }?.status == .attention)
    }

    @Test func unknownTabIsIgnored() {
        let store = makeStore([TerminalSession(title: "only", workingDirectory: "~")])
        #expect(store.handleAgentAttention(tabID: UUID(), isAppActive: false) == nil)
    }
}
