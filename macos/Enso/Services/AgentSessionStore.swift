import Combine
import Foundation

/// The restore layer of agent-session persistence (see
/// docs/agent-session-persistence.md). Wrappers and hook relays append JSONL
/// events to agent-sessions/<tab-uuid>.jsonl; at launch this store compacts
/// each map file to its latest session and decides — per agent adapter,
/// gated by the quit snapshot and the Settings toggle — whether the tab's
/// new surface should resume the conversation.
///
/// ObservableObject so the sidebar's dormant badges track the store live:
/// objectWillChange fires exactly when a mayRestore/dormantAgent answer can
/// flip — restorability resolution landing, a restore being consumed, a
/// tab's records being dropped, or the Settings toggle changing. Non-UI
/// callers keep using the plain accessors; nothing about the API changed.
@MainActor
final class AgentSessionStore: ObservableObject {
    static let shared = AgentSessionStore()

    static let restoreEnabledDefaultsKey = "agentSessionRestoreEnabled"

    private let directory: URL
    private let adapters: [String: any AgentSessionAdapter]
    private let defaults: UserDefaults

    private(set) var records: [UUID: AgentSessionRecord] = [:]
    private(set) var quitSnapshot: QuitSnapshot?
    /// Restore is offered at most once per tab per app run.
    private var consumedTabIDs: Set<UUID> = []
    /// Tabs whose adapter said "restorable" when bootstrap ran the full
    /// policy once, disk checks included. Resolved on a background task —
    /// the adapters' policies read transcripts and scan rollout trees, I/O
    /// that must not block the first render — so this stays EMPTY (and
    /// mayRestore answers false) until the resolution lands. Valid for the
    /// rest of the run once resolved: the transcript/rollout files and the
    /// quit snapshot don't change meaning mid-run — only consumption and
    /// the Settings toggle do, and the accessors layer those on top.
    private(set) var restorableAtLaunch: Set<UUID> = []
    /// Guards the async resolution against a bootstrap that re-ran while a
    /// previous resolution was still in flight: only the latest wins.
    private var resolutionGeneration = 0
    /// Fired on the main actor each time restorability resolution lands.
    /// EnsoApp points this at the tab store's eager sweep, so a launch
    /// whose first sweep ran before resolution isn't permanently starved of
    /// candidates. Wired from the app layer to keep the dependency
    /// direction clean — this store never imports the tab store.
    var onRestorabilityResolved: (() -> Void)?

    /// The Settings gate: off → no shim environment on new surfaces —
    /// ENSO_SESSIONS_DIR is what the wrappers key their recording on, so
    /// without it they pass through inertly — and no restore at launch.
    /// ENSO_TAB_ID is NOT gated here: it is the always-on tab-identity
    /// marker GhosttySurfaceManager injects on every surface regardless.
    var isEnabled: Bool {
        defaults.object(forKey: Self.restoreEnabledDefaultsKey) as? Bool ?? true
    }

    /// The Settings toggle writes its key through @AppStorage — straight to
    /// UserDefaults, never through this store — so watching defaults is the
    /// only way a flip can reach objectWillChange (and un-badge every
    /// dormant row at once). The notification fires for ANY defaults write;
    /// the cached value keeps unrelated writes from publishing.
    private var lastPublishedIsEnabled: Bool
    private var defaultsObserver: (any NSObjectProtocol)?

    init(
        directory: URL? = nil,
        adapters: [any AgentSessionAdapter]? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.adapters = Dictionary(
            uniqueKeysWithValues: (adapters ?? AgentSessionAdapterRegistry.all).map { ($0.agentID, $0) }
        )
        self.defaults = defaults
        self.lastPublishedIsEnabled = defaults.object(forKey: Self.restoreEnabledDefaultsKey) as? Bool ?? true
        // object nil, not `defaults`: the notification is posted by the
        // UserDefaults INSTANCE that wrote, and @AppStorage writes through
        // its own instance of the same domain — identity filtering would
        // miss every Settings flip. The cached-value guard above keeps the
        // broad subscription from publishing on unrelated writes. queue nil
        // = delivered synchronously on the writing thread; the Settings
        // toggle writes on the main thread, so its badge update is
        // synchronous, and a write from anywhere else hops first.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.publishIfEnabledFlipped() }
            } else {
                Task { @MainActor [weak self] in self?.publishIfEnabledFlipped() }
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private func publishIfEnabledFlipped() {
        let enabled = isEnabled
        guard enabled != lastPublishedIsEnabled else { return }
        lastPublishedIsEnabled = enabled
        objectWillChange.send()
    }

    /// agent-sessions/ beside state.json (per build identity). Deliberately
    /// not under TMPDIR — macOS purges /var/folders entries not accessed for
    /// a few days.
    static var defaultDirectory: URL {
        EnsoAppSupport.directory.appendingPathComponent("agent-sessions", isDirectory: true)
    }

    private var quitSnapshotURL: URL {
        directory.appendingPathComponent(".quit-snapshot.json")
    }

    // MARK: - Launch

    /// Called once at startup, after the tab store loaded state.json:
    /// consumes the quit snapshot, garbage-collects map files whose tab no
    /// longer exists, and compacts the survivors into in-memory records.
    func bootstrap(knownTabIDs: Set<UUID>) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        quitSnapshot = consumeQuitSnapshot()
        records = [:]
        consumedTabIDs = []
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "jsonl" {
            guard let tabID = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            guard knownTabIDs.contains(tabID) else {
                try? fm.removeItem(at: file)
                continue
            }
            if let record = Self.compactRecord(tabID: tabID, mapFileAt: file) {
                records[tabID] = record
            }
        }
        resolveRestorability()
    }

    /// Runs every adapter's full restore policy once — transcript reads,
    /// rollout scans — on a background task, because bootstrap happens on
    /// the main actor before the first render and that I/O scales with the
    /// number of agent tabs. Until the result lands, mayRestore answers
    /// false everywhere: the eager sweep sees no candidates and the sidebar
    /// shows no dormant badges, which is why the completion both publishes
    /// and pings onRestorabilityResolved to re-run the sweep. The per-tick
    /// gate chain (hasPendingRestore) never consults this snapshot, so the
    /// staggered fire-time checks work the same whichever side of the
    /// resolution they land on.
    private func resolveRestorability() {
        restorableAtLaunch = []
        resolutionGeneration += 1
        let generation = resolutionGeneration
        let records = records
        let quitSnapshot = quitSnapshot
        let adapters = adapters
        Task.detached(priority: .userInitiated) {
            let resolved = Set(records.compactMap { tabID, record -> UUID? in
                guard let adapter = adapters[record.agent],
                      adapter.restoreCommand(for: record, quitSnapshot: quitSnapshot, now: .now) != nil
                else { return nil }
                return tabID
            })
            await MainActor.run { [weak self] in
                guard let self, self.resolutionGeneration == generation else { return }
                self.objectWillChange.send()
                self.restorableAtLaunch = resolved
                self.onRestorabilityResolved?()
            }
        }
    }

    private func consumeQuitSnapshot() -> QuitSnapshot? {
        defer { try? FileManager.default.removeItem(at: quitSnapshotURL) }
        guard let data = try? Data(contentsOf: quitSnapshotURL),
              let snapshot = try? JSONDecoder().decode(QuitSnapshot.self, from: data) else { return nil }
        // A future or ancient timestamp means a corrupt or stale file; treat
        // it like a crash and let the per-agent fallbacks decide.
        let age = Date.now.timeIntervalSince1970 - snapshot.ts
        guard age >= 0, age < 30 * 24 * 3600 else { return nil }
        return snapshot
    }

    // MARK: - Spawn plumbing

    /// Environment for a new surface: identifies the tab to the wrappers and
    /// puts the shim dir on PATH (best-effort — path_helper demotes it; the
    /// shell-integration precmd hook is what re-asserts it).
    func spawnEnvironment(forTab tabID: UUID) -> [String: String] {
        guard isEnabled else { return [:] }
        let shimDir = AgentShimInstaller.shimBinDirectory.path
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return [
            ForegroundProcessResolver.sessionMarkerKey: ForegroundProcessResolver.marker(forTab: tabID),
            "ENSO_SHIM_DIR": shimDir,
            "ENSO_SESSIONS_DIR": directory.path,
            "PATH": "\(shimDir):\(inheritedPath)",
        ]
    }

    /// A restore decision: the compacted record plus the fully assembled
    /// command (env prefix + executable + sanitized replay args) the
    /// adapter chose — a resume or a fresh relaunch.
    struct AgentRestore: Equatable {
        let record: AgentSessionRecord
        let command: String
    }

    /// The gate chain every restore decision goes through: nil when restore
    /// is off, already consumed, the launch argv was rejected by the
    /// sanitizer, or the adapter's policy says there is nothing to bring
    /// back. Shared so the consuming path and the eager sweep's pending
    /// check can never drift apart.
    private func pendingRestore(forTab tabID: UUID) -> AgentRestore? {
        guard isEnabled, !consumedTabIDs.contains(tabID) else { return nil }
        guard let record = records[tabID],
              let adapter = adapters[record.agent],
              let command = adapter.restoreCommand(for: record, quitSnapshot: quitSnapshot, now: .now)
        else { return nil }
        return AgentRestore(record: record, command: command)
    }

    /// The restore the tab's new surface should run, at most once per tab
    /// per app run. Consumption flips mayRestore/dormantAgent for the tab,
    /// so it publishes: the sidebar's dormant badge hands over to live
    /// process detection the moment the tab starts warming.
    func consumeRestore(forTab tabID: UUID) -> AgentRestore? {
        guard let restore = pendingRestore(forTab: tabID) else { return nil }
        objectWillChange.send()
        consumedTabIDs.insert(tabID)
        return restore
    }

    /// Whether the tab's next surface would run a restore. The eager launch
    /// sweep (#45) checks this at each staggered tick — not once up front —
    /// so a restore that evaporates mid-sweep (toggled off, consumed) leaves
    /// its tab lazy instead of spawning a surface for nothing.
    func hasPendingRestore(forTab tabID: UUID) -> Bool {
        pendingRestore(forTab: tabID) != nil
    }

    /// hasPendingRestore without the per-call disk I/O: adapter policy is
    /// the bootstrap-time snapshot, the run-time gates (toggle, consumption)
    /// are live. The eager sweep uses this to pick and rank candidates —
    /// counting only tabs that will actually restore, so none of the capped
    /// warm slots is wasted on a cleanly-ended session — and the sidebar's
    /// dormant badge reads it per row. The full gate chain still runs at
    /// each staggered tick.
    func mayRestore(forTab tabID: UUID) -> Bool {
        isEnabled && !consumedTabIDs.contains(tabID) && restorableAtLaunch.contains(tabID)
    }

    /// The agent mark a dormant tab should wear in the sidebar — the tab
    /// holds a session that will resume on first visit (or when the eager
    /// sweep reaches it), but no process is running yet. Nil once the
    /// restore is consumed or when nothing would restore. Agent IDs are
    /// TabProcess raw values ("claude", "codex"), the same identity the
    /// quit snapshot uses.
    func dormantAgent(forTab tabID: UUID) -> TabProcess? {
        guard mayRestore(forTab: tabID) else { return nil }
        return records[tabID].flatMap { TabProcess(rawValue: $0.agent) }
    }

    /// The text typed into the fresh PTY (the trailing newline runs it).
    /// This is the single place the restore mechanism lives, so it can be
    /// swapped for a command-script launcher without touching callers.
    func resumeInput(for restore: AgentRestore, currentWorkingDirectory: String) -> String {
        var command = restore.command
        let current = (currentWorkingDirectory as NSString).expandingTildeInPath
        if !restore.record.cwd.isEmpty, restore.record.cwd != current {
            // codex refuses to resume from a different cwd; claude scopes
            // --resume to the project dir. Both need the recorded one.
            command = "cd '\(Self.singleQuoteEscaped(restore.record.cwd))' && \(command)"
        }
        return command + "\n"
    }

    private static func singleQuoteEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    // MARK: - Lifecycle hooks

    /// Closed tabs can never restore their conversation; drop the map files
    /// AND the launch-time restorability entries — a stale entry there would
    /// keep answering mayRestore for a tab that no longer exists, wasting a
    /// warm slot in the eager sweep's ranking. Publishes only when a badge
    /// or ranking answer could actually change; plain shell tabs close
    /// without touching observers.
    func removeRecords(forTabs tabIDs: Set<UUID>) {
        if tabIDs.contains(where: { records[$0] != nil || restorableAtLaunch.contains($0) }) {
            objectWillChange.send()
        }
        for tabID in tabIDs {
            records[tabID] = nil
            restorableAtLaunch.remove(tabID)
            let file = directory.appendingPathComponent("\(tabID.uuidString.lowercased()).jsonl")
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Written on every quit path that will actually terminate. Presence at
    /// next launch means clean quit; absence means crash or force-quit.
    func writeQuitSnapshot(agentsByTab: [UUID: String]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = QuitSnapshot(
            ts: Date.now.timeIntervalSince1970,
            tabs: Dictionary(uniqueKeysWithValues: agentsByTab.map { ($0.key.uuidString.lowercased(), $0.value) })
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: quitSnapshotURL, options: .atomic)
    }

    // MARK: - Map compaction

    static func compactRecord(tabID: UUID, mapFileAt url: URL) -> AgentSessionRecord? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return compactRecord(tabID: tabID, mapLines: contents.split(separator: "\n").map(String.init))
    }

    /// Folds a tab's JSONL map events into the latest session: launch and
    /// user-session events reset the record, hook events override the
    /// session id (which is how /clear's freshly minted id lands) and
    /// remember clean ends. Unparseable lines are skipped, never fatal.
    static func compactRecord(tabID: UUID, mapLines: [String]) -> AgentSessionRecord? {
        var record: AgentSessionRecord?
        for line in mapLines {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let kind = event["event"] as? String else { continue }
            let date = Date(timeIntervalSince1970: (event["ts"] as? Double) ?? 0)
            let agent = event["agent"] as? String ?? ""

            switch kind {
            case "launch", "user-session":
                record = AgentSessionRecord(
                    tabID: tabID,
                    agent: agent,
                    sessionID: event["sessionId"] as? String ?? "",
                    cwd: event["cwd"] as? String ?? "",
                    lastEventDate: date,
                    endReason: nil,
                    transcriptPath: nil,
                    launchArgv: Self.decodeArgv(event["argvB64"] as? String),
                    configDir: event["configDir"] as? String
                )
            case "hook":
                guard let payload = event["payload"] as? [String: Any] else { continue }
                var current = record ?? AgentSessionRecord(
                    tabID: tabID,
                    agent: agent,
                    sessionID: "",
                    cwd: "",
                    lastEventDate: date,
                    endReason: nil,
                    transcriptPath: nil
                )
                if !agent.isEmpty { current.agent = agent }
                if let sessionID = payload["session_id"] as? String, !sessionID.isEmpty {
                    current.sessionID = sessionID
                }
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                    current.cwd = cwd
                }
                if let transcript = payload["transcript_path"] as? String, !transcript.isEmpty {
                    current.transcriptPath = transcript
                }
                switch payload["hook_event_name"] as? String {
                case "SessionStart":
                    current.endReason = nil
                case "SessionEnd":
                    current.endReason = payload["reason"] as? String ?? "other"
                default:
                    break
                }
                current.lastEventDate = date
                record = current
            default:
                continue
            }
        }
        return record
    }

    /// Decodes a wrapper-recorded argv: base64 of NUL-delimited tokens with
    /// a trailing NUL (`printf '%s\0' "$@"`); empty means no arguments.
    static func decodeArgv(_ base64: String?) -> [String] {
        guard let base64, !base64.isEmpty, let data = Data(base64Encoded: base64) else { return [] }
        var tokens = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        if tokens.last == "" { tokens.removeLast() }
        return tokens
    }
}
