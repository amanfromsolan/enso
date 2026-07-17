import Foundation

/// The live layer of agent attention (#30). AgentSessionStore reads the
/// per-tab map files once at launch for restore; this watcher tails the same
/// files while the app runs, surfacing the Notification and Stop hook events
/// the wrappers register — "the agent wants the user" — the moment the relay
/// appends them. Polling with a 1s stat-and-offset sweep instead of FSEvents
/// or per-file dispatch sources: the relay appends from short-lived shell
/// processes, the files are tiny and few, and never holding descriptors on
/// them keeps tab-close deletion (AgentSessionStore.removeRecords) trivial.
final class AgentAttentionWatcher {
    /// What a background agent wants, parsed from a map-file hook event.
    enum AttentionEvent: Equatable {
        /// Claude's Notification hook: waiting on a permission prompt or
        /// idle waiting for input.
        case needsInput(agent: String, message: String?)
        /// A Stop hook (claude and codex both wire one): the agent finished
        /// its response and is idle.
        case finishedResponding(agent: String)

        /// System-notification body. Claude's Notification hook ships its
        /// own human-readable message ("Claude needs your permission to use
        /// Bash"); Stop events and message-less notifications fall back to a
        /// generic line naming the agent.
        var notificationBody: String {
            switch self {
            case .needsInput(_, .some(let message)) where !message.isEmpty:
                return message
            case .needsInput(let agent, _):
                return "\(Self.displayName(agent)) is waiting for your input"
            case .finishedResponding(let agent):
                return "\(Self.displayName(agent)) finished responding"
            }
        }

        private static func displayName(_ agent: String) -> String {
            switch agent {
            case "claude": return "Claude"
            case "codex": return "Codex"
            default: return agent.isEmpty ? "Agent" : agent
            }
        }
    }

    nonisolated private let directory: URL
    nonisolated private let onEvent: @MainActor (UUID, AttentionEvent) -> Void

    /// All tailing state is confined to this queue; the main actor only
    /// touches the timer handle in start()/stop().
    nonisolated private let queue = DispatchQueue(label: "enso.agent-attention", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Byte offsets already consumed per map file, keyed by filename.
    /// Queue-confined — only tick() reads or writes after start().
    nonisolated(unsafe) private var offsets: [String: UInt64] = [:]
    nonisolated(unsafe) private var didInitialScan = false

    /// ~1s keeps the sidebar dot and the notification feeling immediate
    /// while the sweep stays far too cheap to measure.
    nonisolated private static let pollInterval: TimeInterval = 1.0

    init(directory: URL, onEvent: @escaping @MainActor (UUID, AttentionEvent) -> Void) {
        self.directory = directory
        self.onEvent = onEvent
    }

    /// Idempotent. The first tick baselines every existing file at EOF, so
    /// history recorded before this run never replays as fresh events.
    func start() {
        guard timer == nil else { return }
        // No tick can be in flight before resume, so seeding queue-owned
        // state from here is race-free.
        offsets = [:]
        didInitialScan = false
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Polling

    nonisolated private func tick() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return }
        var sizes: [String: UInt64] = [:]
        for url in urls where url.pathExtension == "jsonl" {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            sizes[url.lastPathComponent] = UInt64(size)
        }

        let plan = Self.readPlan(sizes: sizes, offsets: offsets, isInitialScan: !didInitialScan)
        didInitialScan = true
        var next = plan.offsets
        for (name, range) in plan.reads {
            let file = directory.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: range.lowerBound)) != nil,
                  let data = try? handle.read(upToCount: Int(range.upperBound - range.lowerBound)),
                  !data.isEmpty else { continue }
            let (lines, consumedBytes) = Self.completeLines(in: data)
            next[name] = range.lowerBound + UInt64(consumedBytes)
            // Map files are named <tab-uuid>.jsonl (see AgentSessionStore).
            guard let tabID = UUID(uuidString: (name as NSString).deletingPathExtension) else { continue }
            for line in lines {
                guard let event = Self.attentionEvent(fromLine: line) else { continue }
                let deliver = onEvent
                Task { @MainActor in
                    deliver(tabID, event)
                }
            }
        }
        offsets = next
    }

    // MARK: - Pure tailing logic (unit-tested without the timer)

    /// What one tick should read, given the directory's current file sizes
    /// and the offsets carried from the previous tick. The offset rules live
    /// here, pure, so they are testable without a timer or filesystem:
    /// the initial scan baselines every file at EOF without reading (events
    /// from before the watcher started are stale); a file born later starts
    /// at zero (its first events are fresh and must fire); a file smaller
    /// than its stored offset was rewritten, so skip to its new end rather
    /// than replay; files that disappeared drop their offsets.
    nonisolated static func readPlan(
        sizes: [String: UInt64],
        offsets: [String: UInt64],
        isInitialScan: Bool
    ) -> (reads: [String: Range<UInt64>], offsets: [String: UInt64]) {
        var reads: [String: Range<UInt64>] = [:]
        var next: [String: UInt64] = [:]
        for (name, size) in sizes {
            if isInitialScan {
                next[name] = size
                continue
            }
            let offset = offsets[name].map { min($0, size) } ?? 0
            if offset < size {
                reads[name] = offset..<size
            }
            // A failed read retries from here next tick; a successful one
            // overwrites this with the consumed-line position.
            next[name] = offset
        }
        return (reads, next)
    }

    /// Splits appended bytes into complete lines. Bytes after the last
    /// newline are a partial line the relay is still writing; they are not
    /// returned, and consumedBytes stops short of them so the next tick
    /// re-reads the line once its newline lands.
    nonisolated static func completeLines(in data: Data) -> (lines: [String], consumedBytes: Int) {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }
        let lines = data[data.startIndex...lastNewline]
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { String(data: Data($0), encoding: .utf8) }
        return (lines, data.distance(from: data.startIndex, to: lastNewline) + 1)
    }

    /// Parses one map line into an attention event: hook events only, and of
    /// those only Notification and Stop. Everything else — SessionStart and
    /// SessionEnd (restore's concern), launch/user-session records, garbage —
    /// is nil, never fatal, mirroring AgentSessionStore's tolerant compaction.
    nonisolated static func attentionEvent(fromLine line: String) -> AttentionEvent? {
        guard let data = line.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              event["event"] as? String == "hook",
              let payload = event["payload"] as? [String: Any]
        else { return nil }
        let agent = event["agent"] as? String ?? ""
        switch payload["hook_event_name"] as? String {
        case "Notification":
            return .needsInput(agent: agent, message: payload["message"] as? String)
        case "Stop":
            return .finishedResponding(agent: agent)
        default:
            return nil
        }
    }
}
