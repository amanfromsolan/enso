import Foundation
import Testing
@testable import Enso

/// AgentSessionStore behavior: JSONL map compaction (incl. launch-context
/// decode), restore decisions per adapter (resume vs fresh-relaunch vs none,
/// quit-snapshot gating, 12h codex crash fallback, configDir-aware transcript
/// checks), orphan GC, and consumed-once restore semantics.
@MainActor
struct AgentSessionStoreTests {
    private let fm = FileManager.default

    /// Throwaway root per test; holds the sessions dir plus fake agent homes.
    private func makeRoot() throws -> URL {
        let root = fm.temporaryDirectory
            .appendingPathComponent("AgentSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Store rooted in <root>/agent-sessions with adapters pointed at fake
    /// claude/codex homes under the same root, and its own defaults suite.
    private func makeStore(root: URL) -> AgentSessionStore {
        let defaults = UserDefaults(suiteName: "AgentSessionStoreTests")!
        defaults.removePersistentDomain(forName: "AgentSessionStoreTests")
        return AgentSessionStore(
            directory: root.appendingPathComponent("agent-sessions", isDirectory: true),
            adapters: [
                ClaudeAdapter(configDirectory: root.appendingPathComponent(".claude", isDirectory: true)),
                CodexAdapter(codexHome: root.appendingPathComponent(".codex", isDirectory: true)),
            ],
            defaults: defaults
        )
    }

    private func writeMapFile(root: URL, tabID: UUID, lines: [String]) throws {
        let dir = root.appendingPathComponent("agent-sessions", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(tabID.uuidString.lowercased()).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// A transcript claude would consider resumable (has a user message).
    private func writeClaudeTranscript(configDirectory: URL, sessionID: String) throws {
        let dir = configDirectory.appendingPathComponent("projects/-tmp-proj", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"type":"user","message":"hi"}"#
            .write(to: dir.appendingPathComponent("\(sessionID).jsonl"), atomically: true, encoding: .utf8)
    }

    private func writeClaudeTranscript(root: URL, sessionID: String) throws {
        try writeClaudeTranscript(
            configDirectory: root.appendingPathComponent(".claude", isDirectory: true),
            sessionID: sessionID
        )
    }

    private func writeCodexRollout(codexHome: URL, sessionID: String) throws {
        let dir = codexHome.appendingPathComponent("sessions/2026/07/14", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(
            to: dir.appendingPathComponent("rollout-2026-07-14T09-00-00-\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeCodexRollout(root: URL, sessionID: String) throws {
        try writeCodexRollout(
            codexHome: root.appendingPathComponent(".codex", isDirectory: true),
            sessionID: sessionID
        )
    }

    private func writeQuitSnapshotFile(root: URL, tabs: [String: String], ts: TimeInterval = Date.now.timeIntervalSince1970) throws {
        let dir = root.appendingPathComponent("agent-sessions", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(QuitSnapshot(ts: ts, tabs: tabs))
        try data.write(to: dir.appendingPathComponent(".quit-snapshot.json"))
    }

    private func launchLine(agent: String, sessionID: String, cwd: String = "/tmp/proj", ts: TimeInterval) -> String {
        #"{"v":1,"event":"launch","agent":"\#(agent)","sessionId":"\#(sessionID)","cwd":"\#(cwd)","ts":\#(Int(ts))}"#
    }

    private func hookLine(agent: String, name: String, sessionID: String, extra: String = "", ts: TimeInterval) -> String {
        #"{"v":1,"event":"hook","agent":"\#(agent)","payload":{"hook_event_name":"\#(name)","session_id":"\#(sessionID)","cwd":"/tmp/proj"\#(extra)},"ts":\#(Int(ts))}"#
    }

    /// Encodes an argv exactly like the wrappers (`printf '%s\0' "$@"`).
    private func encodeArgv(_ argv: [String]) -> String {
        guard !argv.isEmpty else { return "" }
        return Data((argv.map { $0 + "\0" }.joined()).utf8).base64EncodedString()
    }

    private func record(
        agent: String,
        tabID: UUID = UUID(),
        sessionID: String,
        cwd: String = "/tmp/proj",
        lastEventDate: Date = .now,
        endReason: String? = nil,
        launchArgv: [String] = [],
        configDir: String? = nil
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            tabID: tabID,
            agent: agent,
            sessionID: sessionID,
            cwd: cwd,
            lastEventDate: lastEventDate,
            endReason: endReason,
            transcriptPath: nil,
            launchArgv: launchArgv,
            configDir: configDir
        )
    }

    private func snapshot(listing tabID: UUID, agent: String) -> QuitSnapshot {
        QuitSnapshot(ts: Date.now.timeIntervalSince1970, tabs: [tabID.uuidString.lowercased(): agent])
    }

    // MARK: - Compaction

    @Test func compactionHookSessionIDOverridesLaunch() {
        let tabID = UUID()
        // /clear mints a new id; the SessionStart hook is how we learn it.
        let record = AgentSessionStore.compactRecord(tabID: tabID, mapLines: [
            launchLine(agent: "claude", sessionID: "aaa", ts: 100),
            hookLine(agent: "claude", name: "SessionStart", sessionID: "bbb", extra: #","source":"clear","transcript_path":"/tmp/t.jsonl""#, ts: 200),
        ])
        #expect(record?.agent == "claude")
        #expect(record?.sessionID == "bbb")
        #expect(record?.cwd == "/tmp/proj")
        #expect(record?.transcriptPath == "/tmp/t.jsonl")
        #expect(record?.endReason == nil)
        #expect(record?.lastEventDate == Date(timeIntervalSince1970: 200))
    }

    @Test func compactionUserSessionResetsRecord() {
        let tabID = UUID()
        let record = AgentSessionStore.compactRecord(tabID: tabID, mapLines: [
            launchLine(agent: "claude", sessionID: "aaa", ts: 100),
            hookLine(agent: "claude", name: "SessionEnd", sessionID: "aaa", extra: #","reason":"prompt_input_exit""#, ts: 200),
            #"{"v":1,"event":"user-session","agent":"claude","sessionId":"ccc","cwd":"/elsewhere","ts":300}"#,
        ])
        #expect(record?.sessionID == "ccc")
        #expect(record?.cwd == "/elsewhere")
        // The reset wipes the previous session's clean end.
        #expect(record?.endReason == nil)
    }

    @Test func compactionRecordsCleanEndAndClearsOnRestart() {
        let tabID = UUID()
        var record = AgentSessionStore.compactRecord(tabID: tabID, mapLines: [
            launchLine(agent: "claude", sessionID: "aaa", ts: 100),
            hookLine(agent: "claude", name: "SessionEnd", sessionID: "aaa", extra: #","reason":"logout""#, ts: 200),
        ])
        #expect(record?.endReason == "logout")

        record = AgentSessionStore.compactRecord(tabID: tabID, mapLines: [
            launchLine(agent: "claude", sessionID: "aaa", ts: 100),
            hookLine(agent: "claude", name: "SessionEnd", sessionID: "aaa", extra: #","reason":"other""#, ts: 200),
            hookLine(agent: "claude", name: "SessionStart", sessionID: "aaa", ts: 300),
        ])
        #expect(record?.endReason == nil)
    }

    @Test func compactionSkipsGarbageLines() {
        let record = AgentSessionStore.compactRecord(tabID: UUID(), mapLines: [
            "not json at all",
            launchLine(agent: "codex", sessionID: "", ts: 100),
            #"{"v":1,"event":"hook","agent":"codex","payload":{"session_id":"ddd","cwd":"/tmp/proj"},"ts":150}"#,
        ])
        #expect(record?.agent == "codex")
        #expect(record?.sessionID == "ddd")
    }

    @Test func compactionDecodesLaunchContext() {
        let argvB64 = encodeArgv(["--model", "opus", "do the thing"])
        let record = AgentSessionStore.compactRecord(tabID: UUID(), mapLines: [
            #"{"v":1,"event":"launch","agent":"claude","sessionId":"aaa","cwd":"/tmp/proj","argvB64":"\#(argvB64)","configDir":"/tmp/claude home","ts":100}"#,
        ])
        #expect(record?.launchArgv == ["--model", "opus", "do the thing"])
        #expect(record?.configDir == "/tmp/claude home")
    }

    @Test func decodeArgvHandlesEmptyAndSpecialTokens() {
        #expect(AgentSessionStore.decodeArgv(nil) == [])
        #expect(AgentSessionStore.decodeArgv("") == [])
        let argv = ["hello world", "it's \"quoted\"", "line1\nline2", "émoji ✨"]
        #expect(AgentSessionStore.decodeArgv(encodeArgv(argv)) == argv)
        // A single empty argument survives too.
        #expect(AgentSessionStore.decodeArgv(encodeArgv([""])) == [""])
    }

    // MARK: - Claude restore policy

    @Test func claudeCleanSessionEndIsNotRestorable() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let tabID = UUID()
        let sessionID = "11111111-1111-1111-1111-111111111111"
        try writeClaudeTranscript(root: root, sessionID: sessionID)
        try writeMapFile(root: root, tabID: tabID, lines: [
            launchLine(agent: "claude", sessionID: sessionID, ts: Date.now.timeIntervalSince1970),
            hookLine(agent: "claude", name: "SessionEnd", sessionID: sessionID, extra: #","reason":"prompt_input_exit""#, ts: Date.now.timeIntervalSince1970),
        ])

        let store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [tabID])
        // No quit snapshot listing the tab either, so no fresh relaunch.
        #expect(store.consumeRestore(forTab: tabID) == nil)
    }

    @Test func claudeSessionEndReasonOtherIsRestorable() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let tabID = UUID()
        let sessionID = "22222222-2222-2222-2222-222222222222"
        try writeClaudeTranscript(root: root, sessionID: sessionID)
        try writeMapFile(root: root, tabID: tabID, lines: [
            launchLine(agent: "claude", sessionID: sessionID, ts: Date.now.timeIntervalSince1970),
            hookLine(agent: "claude", name: "SessionEnd", sessionID: sessionID, extra: #","reason":"other""#, ts: Date.now.timeIntervalSince1970),
        ])

        let store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [tabID])
        let restore = store.consumeRestore(forTab: tabID)
        #expect(restore?.record.sessionID == sessionID)
        #expect(restore?.command == "claude --resume \(sessionID)")
    }

    @Test func claudeMissingTranscriptIsNotRestorable() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let tabID = UUID()
        // No transcript on disk — cleanupPeriodDays pruned it — and no quit
        // snapshot (crash path), so not even a fresh relaunch.
        try writeMapFile(root: root, tabID: tabID, lines: [
            launchLine(agent: "claude", sessionID: "33333333-3333-3333-3333-333333333333", ts: Date.now.timeIntervalSince1970),
        ])

        let store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [tabID])
        #expect(store.consumeRestore(forTab: tabID) == nil)
    }

    @Test func claudeMissingTranscriptFallsBackToFreshRelaunchWhenSnapshotListsTab() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let tabID = UUID()
        try writeMapFile(root: root, tabID: tabID, lines: [
            launchLine(agent: "claude", sessionID: "33333333-3333-3333-3333-333333333333", ts: Date.now.timeIntervalSince1970),
        ])
        try writeQuitSnapshotFile(root: root, tabs: [tabID.uuidString.lowercased(): "claude"])

        let store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [tabID])
        #expect(store.consumeRestore(forTab: tabID)?.command == "claude")
    }

    // MARK: - Claude adapter decisions

    @Test func claudeResumePreservesSanitizedLaunchArgv() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let sessionID = "aaaa1111-1111-1111-1111-111111111111"
        let configDir = root.appendingPathComponent(".claude", isDirectory: true)
        try writeClaudeTranscript(configDirectory: configDir, sessionID: sessionID)

        let adapter = ClaudeAdapter(configDirectory: configDir)
        let rec = record(
            agent: "claude",
            sessionID: sessionID,
            launchArgv: ["--model", "opus", "--dangerously-skip-permissions", "write a haiku"]
        )
        #expect(
            adapter.restoreCommand(for: rec, quitSnapshot: nil, now: .now)
                == "claude --resume \(sessionID) --model opus --dangerously-skip-permissions"
        )
    }

    @Test func claudeFreshRelaunchRequiresQuitSnapshotEntry() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let adapter = ClaudeAdapter(configDirectory: root.appendingPathComponent(".claude", isDirectory: true))
        // No transcript exists, so never resumable.
        let rec = record(agent: "claude", sessionID: "", launchArgv: ["--model", "opus"])

        #expect(adapter.restoreCommand(for: rec, quitSnapshot: nil, now: .now) == nil)
        let otherTab = snapshot(listing: UUID(), agent: "claude")
        #expect(adapter.restoreCommand(for: rec, quitSnapshot: otherTab, now: .now) == nil)
        let listed = snapshot(listing: rec.tabID, agent: "claude")
        #expect(adapter.restoreCommand(for: rec, quitSnapshot: listed, now: .now) == "claude --model opus")
    }

    @Test func claudeSanitizerRejectionSuppressesRestoreEntirely() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let sessionID = "bbbb1111-1111-1111-1111-111111111111"
        let configDir = root.appendingPathComponent(".claude", isDirectory: true)
        try writeClaudeTranscript(configDirectory: configDir, sessionID: sessionID)

        let adapter = ClaudeAdapter(configDirectory: configDir)
        // -p means the launch was a one-shot print run, not a session: even
        // with a transcript AND a snapshot entry, nothing is restored.
        let rec = record(agent: "claude", sessionID: sessionID, launchArgv: ["-p", "one-shot"])
        let listed = snapshot(listing: rec.tabID, agent: "claude")
        #expect(adapter.restoreCommand(for: rec, quitSnapshot: listed, now: .now) == nil)
    }

    @Test func claudeConfigDirCarriesIntoCommandAndTranscriptCheck() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let sessionID = "cccc1111-1111-1111-1111-111111111111"
        // Transcript lives ONLY under the custom config dir.
        let customDir = root.appendingPathComponent("custom claude home", isDirectory: true)
        try writeClaudeTranscript(configDirectory: customDir, sessionID: sessionID)

        let adapter = ClaudeAdapter(configDirectory: root.appendingPathComponent(".claude", isDirectory: true))
        var rec = record(agent: "claude", sessionID: sessionID, configDir: customDir.path)
        #expect(
            adapter.restoreCommand(for: rec, quitSnapshot: nil, now: .now)
                == "CLAUDE_CONFIG_DIR='\(customDir.path)' claude --resume \(sessionID)"
        )
        // Without the recorded configDir the transcript is invisible.
        rec.configDir = nil
        #expect(adapter.restoreCommand(for: rec, quitSnapshot: nil, now: .now) == nil)
    }

    @Test func claudeRestoreOfRestoreIsIdempotent() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let sessionID = "dddd1111-1111-1111-1111-111111111111"
        let configDir = root.appendingPathComponent(".claude", isDirectory: true)
        try writeClaudeTranscript(configDirectory: configDir, sessionID: sessionID)

        let adapter = ClaudeAdapter(configDirectory: configDir)
        let first = adapter.restoreCommand(
            for: record(agent: "claude", sessionID: sessionID, launchArgv: ["--model", "opus"]),
            quitSnapshot: nil,
            now: .now
        )
        // The typed restore command re-enters the wrapper, which records the
        // NEW argv (--resume + preserved). Sanitizing that must converge.
        let replayed = record(
            agent: "claude",
            sessionID: sessionID,
            launchArgv: ["--resume", sessionID, "--model", "opus"]
        )
        let second = adapter.restoreCommand(for: replayed, quitSnapshot: nil, now: .now)
        #expect(first == "claude --resume \(sessionID) --model opus")
        #expect(second == first)
    }

    // MARK: - Codex restore policy

    @Test func codexQuitSnapshotGatesRestore() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let listedTab = UUID()
        let unlistedTab = UUID()
        let listedSession = "44444444-4444-4444-4444-444444444444"
        let unlistedSession = "55555555-5555-5555-5555-555555555555"
        try writeCodexRollout(root: root, sessionID: listedSession)
        try writeCodexRollout(root: root, sessionID: unlistedSession)
        for (tab, session) in [(listedTab, listedSession), (unlistedTab, unlistedSession)] {
            try writeMapFile(root: root, tabID: tab, lines: [
                launchLine(agent: "codex", sessionID: "", ts: Date.now.timeIntervalSince1970),
                hookLine(agent: "codex", name: "SessionStart", sessionID: session, ts: Date.now.timeIntervalSince1970),
            ])
        }
        // Only the listed tab was running codex when the user quit.
        try writeQuitSnapshotFile(root: root, tabs: [listedTab.uuidString.lowercased(): "codex"])

        let store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [listedTab, unlistedTab])
        let restore = store.consumeRestore(forTab: listedTab)
        #expect(restore?.record.sessionID == listedSession)
        #expect(restore?.command == "codex resume \(listedSession) -c check_for_update_on_startup=false")
        #expect(store.consumeRestore(forTab: unlistedTab) == nil)
    }

    @Test func codexCrashFallsBackToTwelveHourWindow() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let recentTab = UUID()
        let staleTab = UUID()
        let recentSession = "66666666-6666-6666-6666-666666666666"
        let staleSession = "77777777-7777-7777-7777-777777777777"
        try writeCodexRollout(root: root, sessionID: recentSession)
        try writeCodexRollout(root: root, sessionID: staleSession)
        try writeMapFile(root: root, tabID: recentTab, lines: [
            hookLine(agent: "codex", name: "SessionStart", sessionID: recentSession, ts: Date.now.timeIntervalSince1970 - 3600),
        ])
        try writeMapFile(root: root, tabID: staleTab, lines: [
            hookLine(agent: "codex", name: "SessionStart", sessionID: staleSession, ts: Date.now.timeIntervalSince1970 - 13 * 3600),
        ])
        // No quit snapshot: the app crashed. The stale tab gets neither a
        // resume (window expired) nor a fresh relaunch (snapshot required).

        let store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [recentTab, staleTab])
        #expect(store.consumeRestore(forTab: recentTab)?.record.sessionID == recentSession)
        #expect(store.consumeRestore(forTab: staleTab) == nil)
    }

    @Test func codexMissingRolloutFallsBackToFreshRelaunchOnlyWithSnapshot() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let tabID = UUID()
        // Session id known but its rollout is gone.
        try writeMapFile(root: root, tabID: tabID, lines: [
            hookLine(agent: "codex", name: "SessionStart", sessionID: "88888888-8888-8888-8888-888888888888", ts: Date.now.timeIntervalSince1970),
        ])

        var store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [tabID])
        #expect(store.consumeRestore(forTab: tabID) == nil)

        try writeQuitSnapshotFile(root: root, tabs: [tabID.uuidString.lowercased(): "codex"])
        store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [tabID])
        #expect(store.consumeRestore(forTab: tabID)?.command == "codex")
    }

    // MARK: - Codex adapter decisions

    @Test func codexResumeSuppressesUpdateCheckUnlessUserSetIt() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let sessionID = "99999999-1111-1111-1111-111111111111"
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        try writeCodexRollout(codexHome: home, sessionID: sessionID)
        let adapter = CodexAdapter(codexHome: home)

        let plain = record(agent: "codex", sessionID: sessionID, launchArgv: ["--model", "gpt-5.4"])
        #expect(
            adapter.restoreCommand(for: plain, quitSnapshot: nil, now: .now)
                == "codex resume \(sessionID) -c check_for_update_on_startup=false --model gpt-5.4"
        )

        // An explicit user choice stays authoritative (any -c/--config form).
        for argv in [
            ["-c", "check_for_update_on_startup=true"],
            ["--config", "check_for_update_on_startup=true"],
            ["-c=check_for_update_on_startup=true"],
            ["--config=check_for_update_on_startup=true"],
        ] {
            let rec = record(agent: "codex", sessionID: sessionID, launchArgv: argv)
            let command = adapter.restoreCommand(for: rec, quitSnapshot: nil, now: .now)
            #expect(command == "codex resume \(sessionID) " + argv.joined(separator: " "))
        }
    }

    @Test func codexRestoreOfRestoreIsIdempotent() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let sessionID = "99999999-2222-2222-2222-222222222222"
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        try writeCodexRollout(codexHome: home, sessionID: sessionID)
        let adapter = CodexAdapter(codexHome: home)

        let first = adapter.restoreCommand(
            for: record(agent: "codex", sessionID: sessionID, launchArgv: ["--model", "gpt-5.4"]),
            quitSnapshot: nil,
            now: .now
        )
        // The typed restore re-enters the wrapper; its recorded argv carries
        // resume + id + the injected -c override + preserved args.
        let replayed = record(
            agent: "codex",
            sessionID: sessionID,
            launchArgv: ["resume", sessionID, "-c", "check_for_update_on_startup=false", "--model", "gpt-5.4"]
        )
        let second = adapter.restoreCommand(for: replayed, quitSnapshot: nil, now: .now)
        #expect(first == "codex resume \(sessionID) -c check_for_update_on_startup=false --model gpt-5.4")
        #expect(second == first)
    }

    @Test func codexConfigDirCarriesIntoCommandAndRolloutCheck() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let sessionID = "99999999-3333-3333-3333-333333333333"
        // Rollout lives ONLY under the custom CODEX_HOME.
        let customHome = root.appendingPathComponent("custom codex home", isDirectory: true)
        try writeCodexRollout(codexHome: customHome, sessionID: sessionID)
        let adapter = CodexAdapter(codexHome: root.appendingPathComponent(".codex", isDirectory: true))

        var rec = record(agent: "codex", sessionID: sessionID, configDir: customHome.path)
        #expect(
            adapter.restoreCommand(for: rec, quitSnapshot: nil, now: .now)
                == "CODEX_HOME='\(customHome.path)' codex resume \(sessionID) -c check_for_update_on_startup=false"
        )
        rec.configDir = nil
        #expect(adapter.restoreCommand(for: rec, quitSnapshot: nil, now: .now) == nil)
    }

    // MARK: - Housekeeping

    @Test func bootstrapGarbageCollectsOrphanMapFiles() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let knownTab = UUID()
        let orphanTab = UUID()
        try writeMapFile(root: root, tabID: knownTab, lines: [launchLine(agent: "claude", sessionID: "x", ts: 100)])
        try writeMapFile(root: root, tabID: orphanTab, lines: [launchLine(agent: "claude", sessionID: "y", ts: 100)])

        let store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [knownTab])

        let dir = root.appendingPathComponent("agent-sessions", isDirectory: true)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("\(knownTab.uuidString.lowercased()).jsonl").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("\(orphanTab.uuidString.lowercased()).jsonl").path))
        #expect(store.records[knownTab] != nil)
        #expect(store.records[orphanTab] == nil)
    }

    @Test func bootstrapConsumesQuitSnapshot() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try writeQuitSnapshotFile(root: root, tabs: [:])

        let store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [])
        #expect(store.quitSnapshot != nil)

        let snapshotURL = root.appendingPathComponent("agent-sessions/.quit-snapshot.json")
        #expect(!fm.fileExists(atPath: snapshotURL.path))
    }

    @Test func restorableRecordIsConsumedOnce() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let tabID = UUID()
        let sessionID = "99999999-9999-9999-9999-999999999999"
        try writeClaudeTranscript(root: root, sessionID: sessionID)
        try writeMapFile(root: root, tabID: tabID, lines: [
            launchLine(agent: "claude", sessionID: sessionID, ts: Date.now.timeIntervalSince1970),
        ])

        let store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [tabID])
        #expect(store.consumeRestore(forTab: tabID) != nil)
        #expect(store.consumeRestore(forTab: tabID) == nil)
    }

    @Test func pendingRestorePreviewMatchesConsumeWithoutConsuming() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let restorableTab = UUID()
        let cleanTab = UUID()
        let sessionID = "88888888-8888-8888-8888-888888888888"
        try writeClaudeTranscript(root: root, sessionID: sessionID)
        try writeMapFile(root: root, tabID: restorableTab, lines: [
            launchLine(agent: "claude", sessionID: sessionID, ts: Date.now.timeIntervalSince1970),
        ])
        // Cleanly ended session (no quit snapshot either): nothing pending.
        try writeMapFile(root: root, tabID: cleanTab, lines: [
            launchLine(agent: "claude", sessionID: sessionID, ts: Date.now.timeIntervalSince1970),
            hookLine(agent: "claude", name: "SessionEnd", sessionID: sessionID, extra: #","reason":"logout""#, ts: Date.now.timeIntervalSince1970),
        ])

        let store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [restorableTab, cleanTab])
        #expect(store.hasPendingRestore(forTab: restorableTab))
        #expect(!store.hasPendingRestore(forTab: cleanTab))
        // The pending check consumed nothing…
        #expect(store.consumeRestore(forTab: restorableTab) != nil)
        // …and a consumed tab stops being pending.
        #expect(!store.hasPendingRestore(forTab: restorableTab))
    }

    @Test func mayRestoreTracksLaunchTimeRestorability() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let restorableTab = UUID()
        let untouchedTab = UUID()
        let cleanTab = UUID()
        let sessionID = "77777777-7777-7777-7777-777777777777"
        try writeClaudeTranscript(root: root, sessionID: sessionID)
        for tabID in [restorableTab, untouchedTab] {
            try writeMapFile(root: root, tabID: tabID, lines: [
                launchLine(agent: "claude", sessionID: sessionID, ts: Date.now.timeIntervalSince1970),
            ])
        }
        // Cleanly ended session: the record exists but adapter policy says
        // no restore — bootstrap's one-time policy pass rules it out, so it
        // never occupies a warm slot or wears the dormant badge.
        try writeMapFile(root: root, tabID: cleanTab, lines: [
            launchLine(agent: "claude", sessionID: sessionID, ts: Date.now.timeIntervalSince1970),
            hookLine(agent: "claude", name: "SessionEnd", sessionID: sessionID, extra: #","reason":"logout""#, ts: Date.now.timeIntervalSince1970),
        ])

        let store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [restorableTab, untouchedTab, cleanTab])
        #expect(store.mayRestore(forTab: restorableTab))
        #expect(!store.mayRestore(forTab: cleanTab))
        #expect(!store.mayRestore(forTab: UUID()))

        // The dormant badge follows the same gates and knows the agent.
        #expect(store.dormantAgent(forTab: restorableTab) == .claude)
        #expect(store.dormantAgent(forTab: cleanTab) == nil)

        // Consuming closes the gate (the tab is warming, badge hands over
        // to live process detection)…
        _ = store.consumeRestore(forTab: restorableTab)
        #expect(!store.mayRestore(forTab: restorableTab))
        #expect(store.dormantAgent(forTab: restorableTab) == nil)

        // …and so does the Settings toggle, for tabs never consumed.
        #expect(store.mayRestore(forTab: untouchedTab))
        UserDefaults(suiteName: "AgentSessionStoreTests")!
            .set(false, forKey: AgentSessionStore.restoreEnabledDefaultsKey)
        #expect(!store.mayRestore(forTab: untouchedTab))
    }

    @Test func closeRemovesMapFile() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let tabID = UUID()
        try writeMapFile(root: root, tabID: tabID, lines: [launchLine(agent: "claude", sessionID: "x", ts: 100)])

        let store = makeStore(root: root)
        store.bootstrap(knownTabIDs: [tabID])
        store.removeRecords(forTabs: [tabID])

        let file = root.appendingPathComponent("agent-sessions/\(tabID.uuidString.lowercased()).jsonl")
        #expect(!fm.fileExists(atPath: file.path))
        #expect(store.records[tabID] == nil)
    }

    // MARK: - Resume input

    @Test func resumeInputPrefixesCdWhenCwdDiffers() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let store = makeStore(root: root)
        let restore = AgentSessionStore.AgentRestore(
            record: record(agent: "claude", sessionID: "abc", cwd: "/tmp/it's here"),
            command: "claude --resume abc"
        )
        #expect(
            store.resumeInput(for: restore, currentWorkingDirectory: "/tmp/elsewhere")
                == "cd '/tmp/it'\\''s here' && claude --resume abc\n"
        )
        #expect(
            store.resumeInput(for: restore, currentWorkingDirectory: "/tmp/it's here")
                == "claude --resume abc\n"
        )
    }
}

/// AgentLaunchSanitizer: allowlist preservation, drop/reject tiers, variadic
/// and `=`-joined forms, prompt stripping, and shell quoting.
struct AgentLaunchSanitizerTests {
    private func claude(_ args: [String]) -> [String]? {
        AgentLaunchSanitizer.preservedArguments(args, policy: AgentLaunchSanitizer.claudePolicy)
    }

    private func codex(_ args: [String]) -> [String]? {
        AgentLaunchSanitizer.preservedArguments(args, policy: AgentLaunchSanitizer.codexPolicy)
    }

    @Test func claudeDropsSessionSelectionOptions() {
        #expect(claude(["--resume", "abc", "--model", "opus"]) == ["--model", "opus"])
        #expect(claude(["--resume=abc", "--model", "opus"]) == ["--model", "opus"])
        #expect(claude(["--continue", "--model", "opus"]) == ["--model", "opus"])
        #expect(claude(["-c", "--model", "opus"]) == ["--model", "opus"])
        #expect(claude(["--session-id", "abc", "--verbose"]) == ["--verbose"])
        #expect(claude(["--fork-session", "--model", "opus"]) == ["--model", "opus"])
    }

    @Test func claudeRejectsNonSessionShapes() {
        #expect(claude(["-p", "one shot"]) == nil)
        #expect(claude(["--print", "one shot"]) == nil)
        #expect(claude(["--no-session-persistence"]) == nil)
        #expect(claude(["--model", "opus", "-p"]) == nil)
        // Subcommands never restore.
        #expect(claude(["mcp", "list"]) == nil)
        #expect(claude(["doctor"]) == nil)
    }

    @Test func claudeStripsPositionalPromptAndEverythingAfter() {
        #expect(claude(["--model", "opus", "write a haiku"]) == ["--model", "opus"])
        // The scan ends at the prompt; a trailing option is prompt tail.
        #expect(claude(["write a haiku", "--model", "opus"]) == [])
        #expect(claude([]) == [])
    }

    @Test func claudeConsumesVariadicValues() {
        #expect(
            claude(["--add-dir", "/a", "/b", "--model", "opus", "prompt"])
                == ["--add-dir", "/a", "/b", "--model", "opus"]
        )
        // Variadic values never leak into the subcommand check.
        #expect(claude(["--add-dir", "mcp", "doctor", "--verbose"]) == ["--add-dir", "mcp", "doctor", "--verbose"])
    }

    @Test func claudePreservesEqualsJoinedValues() {
        #expect(claude(["--model=opus", "--permission-mode=plan"]) == ["--model=opus", "--permission-mode=plan"])
        #expect(claude(["--session-id=abc", "--model=opus"]) == ["--model=opus"])
    }

    @Test func codexStripsResumeSubcommandAndSessionID() {
        #expect(codex(["resume", "11111111-2222-3333-4444-555555555555", "--model", "gpt"]) == ["--model", "gpt"])
        #expect(codex(["resume", "--last", "--model", "gpt"]) == ["--model", "gpt"])
        #expect(codex(["--model", "gpt"]) == ["--model", "gpt"])
    }

    @Test func codexRejectsOneShotSubcommands() {
        #expect(codex(["exec", "do it"]) == nil)
        #expect(codex(["e", "do it"]) == nil)
        #expect(codex(["fork", "abc"]) == nil)
        #expect(codex(["login"]) == nil)
    }

    @Test func codexDropsOneShotOptionsAndPrompt() {
        #expect(codex(["--image", "a.png", "b.png", "-m", "gpt"]) == ["-m", "gpt"])
        #expect(codex(["-c", "key=value", "do the thing"]) == ["-c", "key=value"])
        #expect(codex(["do the thing"]) == [])
    }

    @Test func shellQuotedEscapesUnsafeTokens() {
        #expect(AgentLaunchSanitizer.shellQuoted("safe-token_1.0/@:%") == "safe-token_1.0/@:%")
        #expect(AgentLaunchSanitizer.shellQuoted("has space") == "'has space'")
        #expect(AgentLaunchSanitizer.shellQuoted("it's") == "'it'\\''s'")
        #expect(AgentLaunchSanitizer.shellQuoted("") == "''")
        #expect(AgentLaunchSanitizer.shellQuoted("a\nb") == "'a\nb'")
        #expect(AgentLaunchSanitizer.shellQuoted("$HOME`cmd`") == "'$HOME`cmd`'")
    }
}
