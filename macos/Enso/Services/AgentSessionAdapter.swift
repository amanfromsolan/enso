import Foundation

/// One compacted agent conversation for a tab — the latest session distilled
/// from the tab's JSONL map file in agent-sessions/. Sendable: restorability
/// resolution runs the adapters over these on a background task.
struct AgentSessionRecord: Equatable, Sendable {
    /// The tab (TerminalSession) UUID the map file is keyed on.
    let tabID: UUID
    /// Adapter id ("claude", "codex"); matches the wrapper name on PATH.
    var agent: String
    /// The agent CLI's own conversation id; empty until a hook reports one.
    var sessionID: String
    /// Where the agent was launched; resuming must happen there.
    var cwd: String
    var lastEventDate: Date
    /// SessionEnd reason from the agent's hooks; nil while live (or crashed).
    var endReason: String?
    /// Transcript path reported by hooks, when the agent provides one.
    var transcriptPath: String?
    /// The ORIGINAL user argv the wrapper saw (pre-injection); sanitized and
    /// replayed by the restore command so the launch shape survives.
    var launchArgv: [String] = []
    /// CLAUDE_CONFIG_DIR / CODEX_HOME at launch, when the user had one set:
    /// carried back into the restore command and used for transcript checks.
    var configDir: String?
}

/// Written beside the map files on every consented quit, so the next launch
/// can tell "was running at quit" (restore) from "crashed" (fall back to
/// per-agent policies). Consumed — deleted — after being read once.
struct QuitSnapshot: Codable, Equatable, Sendable {
    /// Epoch seconds; kept shell/JSON friendly on purpose.
    var ts: TimeInterval
    /// Lowercased tab UUID string → agent id.
    var tabs: [String: String]

    func lists(_ tabID: UUID, agent: String) -> Bool {
        tabs[tabID.uuidString.lowercased()] == agent
    }
}

/// An agent CLI plugged into session persistence. Adding an agent means one
/// adapter here, a sanitizer policy, and one wrapper script in
/// Resources/agent-shims. Sendable (adapters are stateless value types):
/// launch-time restorability resolution calls restoreCommand off the main
/// actor, where its transcript and rollout I/O belongs.
protocol AgentSessionAdapter: Sendable {
    /// "claude" / "codex" — the shim name on PATH and TabProcess raw value.
    var agentID: String { get }
    /// Bundled wrapper (Resources/agent-shims/<name>.sh) installed as agentID.
    var wrapperResourceName: String { get }
    /// The full command line the restored tab should run — a resume of the
    /// recorded conversation when it is still resumable, a fresh relaunch of
    /// the agent (preserved args, no conversation) when the quit snapshot
    /// says the agent was running at quit, or nil for no restore at all.
    /// Every token is shell-quoted; sanitizer rejection returns nil.
    func restoreCommand(for record: AgentSessionRecord, quitSnapshot: QuitSnapshot?, now: Date) -> String?
}

/// The one place agents are registered.
enum AgentSessionAdapterRegistry {
    static let all: [any AgentSessionAdapter] = [ClaudeAdapter(), CodexAdapter()]

    /// Shared hook relay installed alongside every wrapper.
    static let hookRelayResourceName = "enso-hook-relay"
}

private let sessionIDPattern = "^[0-9a-fA-F-]+$"

/// Claude Code (verified on 2.1.208): SessionEnd hooks report clean exits,
/// and transcripts under <config>/projects/ are pruned by cleanupPeriodDays,
/// so restore re-checks the transcript on disk rather than trusting the map.
struct ClaudeAdapter: AgentSessionAdapter {
    let agentID = "claude"
    let wrapperResourceName = "enso-claude-wrapper"

    /// Clean exits; a SIGHUP quit reports "other" and stays resumable.
    private static let cleanEndReasons: Set<String> = ["prompt_input_exit", "logout", "clear"]

    /// ~/.claude unless CLAUDE_CONFIG_DIR points elsewhere; a configDir
    /// recorded on the launch itself overrides both.
    let configDirectory: URL

    init(configDirectory: URL? = nil) {
        if let configDirectory {
            self.configDirectory = configDirectory
        } else if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            self.configDirectory = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            self.configDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
        }
    }

    func restoreCommand(for record: AgentSessionRecord, quitSnapshot: QuitSnapshot?, now: Date) -> String? {
        guard let preserved = AgentLaunchSanitizer.preservedArguments(
            record.launchArgv, policy: AgentLaunchSanitizer.claudePolicy
        ) else { return nil }

        let prefix = environmentPrefix(for: record)
        if isResumable(record) {
            let parts = ["claude", "--resume", record.sessionID] + preserved
            return prefix + parts.map(AgentLaunchSanitizer.shellQuoted).joined(separator: " ")
        }
        // Fresh relaunch restores the tab's shape (agent running, preserved
        // args, empty conversation). Snapshot-gated on purpose: a crash has
        // no snapshot and must never spuriously relaunch agents.
        guard let quitSnapshot, quitSnapshot.lists(record.tabID, agent: agentID) else { return nil }
        let parts = ["claude"] + preserved
        return prefix + parts.map(AgentLaunchSanitizer.shellQuoted).joined(separator: " ")
    }

    private func environmentPrefix(for record: AgentSessionRecord) -> String {
        guard let configDir = record.configDir, !configDir.isEmpty else { return "" }
        return "CLAUDE_CONFIG_DIR=\(AgentLaunchSanitizer.shellQuoted(configDir)) "
    }

    private func isResumable(_ record: AgentSessionRecord) -> Bool {
        guard !record.sessionID.isEmpty,
              record.sessionID.range(of: sessionIDPattern, options: .regularExpression) != nil
        else { return false }
        if let reason = record.endReason, Self.cleanEndReasons.contains(reason) { return false }
        guard let transcript = transcriptURL(for: record) else { return false }
        // An empty session (no prompt ever sent) has nothing to resume.
        guard let contents = try? String(contentsOf: transcript, encoding: .utf8),
              contents.contains("\"type\":\"user\"") else { return false }
        return true
    }

    /// Prefers the hook-reported path; otherwise a bounded search of
    /// projects/*/<id>.jsonl (avoids re-implementing claude's cwd encoding)
    /// under the launch-recorded config dir, falling back to the default.
    private func transcriptURL(for record: AgentSessionRecord) -> URL? {
        let fm = FileManager.default
        if let path = record.transcriptPath {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if fm.fileExists(atPath: url.path) { return url }
        }
        let root = record.configDir.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? configDirectory
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(record.sessionID).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// Codex (verified on 0.144.1): no SessionEnd hook exists, so a clean exit
/// is invisible — restore is gated on the quit snapshot ("was running at
/// quit"), with a 12-hour window as the crash fallback (no snapshot at all).
struct CodexAdapter: AgentSessionAdapter {
    let agentID = "codex"
    let wrapperResourceName = "enso-codex-wrapper"

    static let crashFallbackWindow: TimeInterval = 12 * 3600

    /// codex's TUI shows a blocking "Update available!" picker when launched
    /// without an initial prompt — exactly the shape of `codex resume <id>` —
    /// so restores suppress the startup check for that process only. Skipped
    /// when the preserved args already set it (any `-c`/`--config` form),
    /// which keeps an explicit user choice authoritative and makes a
    /// restore-of-a-restore idempotent.
    static let updateCheckSuppressionOverride = ["-c", "check_for_update_on_startup=false"]

    /// ~/.codex; rollouts live under sessions/YYYY/MM/DD/. A configDir
    /// (CODEX_HOME) recorded on the launch itself overrides it.
    let codexHome: URL

    init(codexHome: URL? = nil) {
        self.codexHome = codexHome
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    func restoreCommand(for record: AgentSessionRecord, quitSnapshot: QuitSnapshot?, now: Date) -> String? {
        guard let preserved = AgentLaunchSanitizer.preservedArguments(
            record.launchArgv, policy: AgentLaunchSanitizer.codexPolicy
        ) else { return nil }

        let prefix = environmentPrefix(for: record)
        let snapshotListsTab = quitSnapshot?.lists(record.tabID, agent: agentID) ?? false

        if isResumable(record) {
            // Snapshot present: it is authoritative. Absent (crash): the
            // 12-hour window stands in for "was probably still running".
            let gate = quitSnapshot != nil
                ? snapshotListsTab
                : now.timeIntervalSince(record.lastEventDate) < Self.crashFallbackWindow
            if gate {
                let parts = ["codex", "resume", record.sessionID]
                    + updateCheckOverrides(preserved: preserved) + preserved
                return prefix + parts.map(AgentLaunchSanitizer.shellQuoted).joined(separator: " ")
            }
        }
        // Fresh relaunch: no resumable session (id never learned, or the
        // rollout is gone), but the snapshot says codex was running here.
        guard snapshotListsTab else { return nil }
        let parts = ["codex"] + preserved
        return prefix + parts.map(AgentLaunchSanitizer.shellQuoted).joined(separator: " ")
    }

    private func environmentPrefix(for record: AgentSessionRecord) -> String {
        guard let configDir = record.configDir, !configDir.isEmpty else { return "" }
        return "CODEX_HOME=\(AgentLaunchSanitizer.shellQuoted(configDir)) "
    }

    private func isResumable(_ record: AgentSessionRecord) -> Bool {
        guard !record.sessionID.isEmpty,
              record.sessionID.range(of: sessionIDPattern, options: .regularExpression) != nil
        else { return false }
        return rolloutExists(for: record)
    }

    private func updateCheckOverrides(preserved: [String]) -> [String] {
        hasExplicitUpdateCheckOverride(in: preserved) ? [] : Self.updateCheckSuppressionOverride
    }

    /// Whether an argv already carries an explicit startup update-check
    /// setting, in any `-c`/`--config` spelling (split or `=`-joined).
    func hasExplicitUpdateCheckOverride(in arguments: [String]) -> Bool {
        for (index, argument) in arguments.enumerated() {
            if argument == "-c" || argument == "--config",
               index + 1 < arguments.count,
               arguments[index + 1].hasPrefix("check_for_update_on_startup=") {
                return true
            }
            if argument.hasPrefix("-c=check_for_update_on_startup=") {
                return true
            }
            if argument.hasPrefix("--config=check_for_update_on_startup=") {
                return true
            }
        }
        return false
    }

    /// Bounded glob for sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl under
    /// the launch-recorded CODEX_HOME (default ~/.codex); codex deletes
    /// rollouts too, so the map alone is never trusted.
    private func rolloutExists(for record: AgentSessionRecord) -> Bool {
        let suffix = "-\(record.sessionID.lowercased()).jsonl"
        let fm = FileManager.default
        let home = record.configDir.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? codexHome
        let root = home.appendingPathComponent("sessions", isDirectory: true)

        func children(of url: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }

        for year in children(of: root) {
            for month in children(of: year) {
                for day in children(of: month) {
                    for file in children(of: day)
                    where file.lastPathComponent.lowercased().hasSuffix(suffix) {
                        return true
                    }
                }
            }
        }
        return false
    }
}
