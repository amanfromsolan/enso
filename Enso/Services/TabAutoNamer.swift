import Combine
import Foundation

/// Names each tab once, shortly after its shell shows real activity, by
/// asking an agent CLI (claude by default) to summarize what the terminal is
/// doing. Shell-integration titles stay the live baseline: the tab is only
/// touched when the model returns a valid name, never after a user rename,
/// and every failure is silent — the tab just keeps its shell title.
@MainActor
final class TabAutoNamer: ObservableObject {
    static let shared = TabAutoNamer()

    /// Sessions with a naming command in flight; drives the sidebar's
    /// per-tab activity indicator.
    @Published private(set) var namingSessions: Set<TerminalSession.ID> = []

    // Settings UI (later) toggles/edits these; until then they're the API.
    static let enabledDefaultsKey = "tabNamingEnabled"
    static let commandDefaultsKey = "tabNamingCommand"

    /// Ready-made commands for the settings UI. Contract for custom commands:
    /// runs in a login shell, prompt arrives on stdin, tab name goes to
    /// stdout, exit 0 on success.
    static let presetCommands: [(name: String, command: String)] = [
        ("Claude", "claude -p --model haiku"),
        ("Codex", "codex exec --skip-git-repo-check -"),
        ("Gemini", "gemini"),
    ]

    private enum JobState {
        case scheduled(Task<Void, Never>)
        case running
        /// Terminal states: named, gave up, or user/auto title already present.
        case finished
    }

    private var jobs: [TerminalSession.ID: JobState] = [:]
    private var runningCount = 0
    /// Consecutive command failures across sessions; a broken custom command
    /// shouldn't burn a spawn attempt on every new tab.
    private var consecutiveFailures = 0

    private let debounceSeconds: Double = 6
    private let commandTimeoutSeconds: Double = 30
    private let attemptsPerSession = 2
    private let maxConcurrentJobs = 2
    private let breakerLimit = 3

    private weak var store: TerminalSessionStore?

    private init() {}

    func configure(store: TerminalSessionStore) {
        self.store = store
    }

    /// Called on every shell-integration signal (title or pwd change). Each
    /// signal pushes the debounce out, so naming runs once the tab settles.
    func noteActivity(_ sessionID: TerminalSession.ID) {
        guard UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false,
              consecutiveFailures < breakerLimit
        else { return }

        switch jobs[sessionID] {
        case .running, .finished:
            return
        case .scheduled(let task):
            task.cancel()
        case nil:
            break
        }

        schedule(sessionID, after: debounceSeconds)
    }

    /// Explicit palette command: runs regardless of the enabled toggle, the
    /// breaker, and any previous name — including a user rename.
    func forceName(_ sessionID: TerminalSession.ID) {
        if case .scheduled(let task)? = jobs[sessionID] {
            task.cancel()
        }
        jobs[sessionID] = .scheduled(Task { [weak self] in
            await self?.attempt(sessionID, force: true)
        })
    }

    private func schedule(_ sessionID: TerminalSession.ID, after seconds: Double) {
        jobs[sessionID] = .scheduled(Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.attempt(sessionID)
        })
    }

    private func attempt(_ sessionID: TerminalSession.ID, force: Bool = false) async {
        guard let store, let session = store.sessions.first(where: { $0.id == sessionID }) else {
            jobs[sessionID] = nil
            return
        }
        guard force || session.titleOrigin == .shell else {
            jobs[sessionID] = .finished
            return
        }
        if !force, runningCount >= maxConcurrentJobs {
            schedule(sessionID, after: 10)
            return
        }

        // A tab that's only ever shown a prompt has nothing to name yet;
        // stay armed and wait for the next activity signal.
        guard let context = namingContext(for: session, relaxed: force) else {
            jobs[sessionID] = force ? .finished : nil
            return
        }

        jobs[sessionID] = .running
        runningCount += 1
        namingSessions.insert(sessionID)
        defer {
            runningCount -= 1
            namingSessions.remove(sessionID)
        }

        let prompt = Self.buildPrompt(workingDirectory: session.workingDirectory, screenText: context)

        for _ in 1...attemptsPerSession {
            if let raw = await runNamingCommand(prompt: prompt),
               let name = Self.sanitizeName(raw) {
                consecutiveFailures = 0
                jobs[sessionID] = .finished
                store.applyAutoName(sessionID, title: name, force: force)
                return
            }
        }

        // Give up on this tab; its live shell title is the fallback name.
        consecutiveFailures += 1
        jobs[sessionID] = .finished
    }

    // MARK: - Context

    /// Recent screen text, capped and redacted; nil when too thin to name.
    /// `relaxed` (explicit command) accepts any non-empty screen.
    private func namingContext(for session: TerminalSession, relaxed: Bool = false) -> String? {
        guard let raw = GhosttySurfaceManager.shared.existingView(for: session.id)?.screenContents()
        else { return nil }

        var lines = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        lines = Array(lines.suffix(60))

        let meaningful = lines.filter { !$0.isEmpty }
        if relaxed {
            guard !meaningful.isEmpty else { return nil }
        } else {
            guard meaningful.count >= 4, meaningful.joined().count >= 80 else { return nil }
        }

        let joined = lines.joined(separator: "\n")
        return Self.redactSecrets(String(joined.suffix(4000)))
    }

    /// Scrollback can contain printed tokens (env dumps, auth output); strip
    /// the obvious shapes before the text leaves the app.
    static func redactSecrets(_ text: String) -> String {
        let patterns = [
            "sk-[A-Za-z0-9_-]{16,}",            // OpenAI/Anthropic-style keys
            "(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}", // GitHub tokens
            "github_pat_[A-Za-z0-9_]{20,}",
            "AKIA[0-9A-Z]{16}",                  // AWS access key IDs
            "xox[baprs]-[A-Za-z0-9-]{10,}",      // Slack tokens
            "eyJ[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}", // JWTs
            "(?i)(bearer|authorization:)\\s+[A-Za-z0-9._~+/-]{16,}",
        ]
        var result = text
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: .regularExpression
            )
        }
        return result
    }

    static func buildPrompt(workingDirectory: String, screenText: String) -> String {
        """
        You name terminal tabs. Based on the working directory and recent \
        terminal output below, reply with ONLY the tab name: 2-4 lowercase \
        words, at most 30 characters, no punctuation, no quotes, no explanation.

        Working directory: \(workingDirectory)

        Recent terminal output:
        \(screenText)
        """
    }

    // MARK: - Command execution

    /// The configured naming command, or the claude preset when unset.
    private var configuredCommand: String {
        let custom = UserDefaults.standard.string(forKey: Self.commandDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty {
            return custom
        }
        return Self.presetCommands[0].command
    }

    /// Runs the naming command in a login shell (GUI apps get a bare PATH;
    /// the login shell finds claude/codex wherever the user installed them),
    /// feeding the prompt on stdin. Nil on non-zero exit, timeout, or spawn
    /// failure.
    private func runNamingCommand(prompt: String) async -> String? {
        let command = configuredCommand
        let timeout = commandTimeoutSeconds

        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]

            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return nil
            }

            let killer = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

            stdin.fileHandleForWriting.write(Data(prompt.utf8))
            stdin.fileHandleForWriting.closeFile()

            let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            killer.cancel()

            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }

    /// Extracts a usable tab name from possibly chatty CLI output: last
    /// non-empty line, stripped of quoting, rejected when it doesn't look
    /// like a name. Nil means the attempt failed.
    static func sanitizeName(_ raw: String) -> String? {
        let lines = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var name = lines.last else { return nil }

        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*_.,;:!"))
        name = name.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")

        guard (2...40).contains(name.count),
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              !name.contains("[redacted]")
        else { return nil }
        return name
    }
}
