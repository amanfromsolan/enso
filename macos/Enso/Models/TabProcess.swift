import SwiftUI

/// A recognized foreground process in a tab, detected from shell-integration
/// title events plus the pty's resolved foreground process. Agents get their
/// brand artwork, known tools a neutral-ink SF Symbol; an unrecognized live
/// process shows the running-blue dot, and idle shells the plain grey one.
/// Codable so a sleeping tab's "what was running" survives in state.json.
enum TabProcess: String, Hashable, Codable {
    // Agents with bundled brand icons.
    case claude
    case codex
    case gemini
    case ollama
    case opencode
    // Tool families with symbol glyphs.
    case editor
    case remote
    case git
    case runtime
    case container
    case monitor
    case build
    case reader
    // Something is in the foreground, but nothing we have artwork for —
    // the resolver saw a live non-shell process that missed the table.
    case unknown

    enum Badge: Equatable {
        /// Adaptive agent artwork. Carries the asset-catalog base name;
        /// views pick the concrete imageset — "<base>16" full-color with
        /// light/dark appearance variants, "<base>48" for the larger
        /// header rendition.
        case agent(String)
        /// SF Symbol, rendered in neutral ink by the row.
        case symbol(String)
        /// The plain dot, in its running-process (blue) treatment.
        case dot
    }

    var badge: Badge {
        switch self {
        case .claude: .agent("AgentClaude")
        case .codex: .agent("AgentCodex")
        case .gemini: .agent("AgentGemini")
        case .ollama: .agent("AgentOllama")
        case .opencode: .agent("AgentOpenCode")
        case .editor: .symbol("square.and.pencil")
        case .remote: .symbol("network")
        case .git: .symbol("arrow.triangle.branch")
        case .runtime: .symbol("chevron.left.forwardslash.chevron.right")
        case .container: .symbol("shippingbox")
        case .monitor: .symbol("speedometer")
        case .build: .symbol("hammer")
        case .reader: .symbol("doc.text")
        case .unknown: .dot
        }
    }

    private static let commands: [String: TabProcess] = [
        "claude": .claude,
        "codex": .codex,
        "gemini": .gemini,
        "ollama": .ollama,
        "opencode": .opencode,
        "vim": .editor, "nvim": .editor, "vi": .editor, "nano": .editor,
        "hx": .editor, "emacs": .editor, "micro": .editor,
        "ssh": .remote, "mosh": .remote, "et": .remote,
        "git": .git, "lazygit": .git, "tig": .git, "gh": .git,
        "node": .runtime, "bun": .runtime, "deno": .runtime,
        "python": .runtime, "python3": .runtime, "ipython": .runtime,
        "ruby": .runtime, "irb": .runtime,
        "docker": .container, "podman": .container, "kubectl": .container, "k9s": .container,
        "top": .monitor, "htop": .monitor, "btop": .monitor, "btm": .monitor,
        "make": .build, "cargo": .build, "npm": .build, "pnpm": .build,
        "yarn": .build, "xcodebuild": .build, "swift": .build, "go": .build,
        "less": .reader, "man": .reader, "bat": .reader, "tail": .reader,
    ]

    /// Shell names that mean "idle prompt" in a *title* event. Only the
    /// title path infers idleness from names; the foreground path gets an
    /// explicit identity-based `.idle` signal from the resolver instead
    /// (a wrapper script's bash would spoof a name check).
    private static let idleShells: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu", "login",
    ]

    /// Next detected process given a new title event. Titles come in three
    /// shapes: a command line from shell preexec ("claude --continue"), an
    /// idle prompt (shell name or the cwd), or a foreign title an app set
    /// itself (Claude Code retitles constantly). Commands match, idle
    /// clears, foreign titles keep the current detection — that stickiness
    /// is what survives an agent's own retitling while it is still running.
    static func detect(after current: TabProcess?, title: String) -> TabProcess? {
        guard let firstWord = title.split(separator: " ").first else { return current }
        let command = normalized((String(firstWord) as NSString).lastPathComponent)

        if let match = commands[command] {
            return match
        }
        if idleShells.contains(command) || isPathShaped(firstWord) {
            return nil
        }
        return current
    }

    /// Detection from the pty's resolved foreground — ground truth that
    /// title events can't offer, since preexec reports commands as typed
    /// and an alias like `c` never matches the table. The resolver decides
    /// idle vs running by process identity, so `.idle` (shell back at the
    /// prompt) and `.shellExited` (dead tab) both clear unconditionally.
    /// While something is running, the first table hit among the best-first
    /// candidates wins; a non-empty miss is authoritative — the foreground
    /// really is some process we have no artwork for, so it shows the
    /// `.unknown` running dot rather than keeping a stale table badge (the
    /// stickiness foreign titles get does not apply here). An empty
    /// candidate list carries no name evidence and keeps the current
    /// detection, as does `.unresolved`.
    static func detect(after current: TabProcess?, foreground resolution: ForegroundResolution) -> TabProcess? {
        switch resolution {
        case .unresolved:
            return current
        case .idle, .shellExited:
            return nil
        case .running(let candidates):
            for candidate in candidates {
                if let match = commands[normalized(candidate)] {
                    return match
                }
            }
            return candidates.isEmpty ? current : .unknown
        }
    }

    /// Login shells rewrite argv[0] with a leading dash ("-fish"); strip it
    /// before any table or idle-shell lookup.
    private static func normalized(_ name: String) -> String {
        let lowered = name.lowercased()
        return lowered.hasPrefix("-") ? String(lowered.dropFirst()) : lowered
    }

    /// Shell-integration prompts report the cwd as the title, in every
    /// shape the shell prints it: "~", "~/a/b", "/x/y", or ghostty's
    /// "…/a/b/c" shortening for deep paths. A path-shaped title that didn't
    /// match a known command means the shell is back at an idle prompt —
    /// this is what clears the badge when an agent or tool exits.
    private static func isPathShaped(_ word: Substring) -> Bool {
        word.hasPrefix("~") || word.hasPrefix("/") || word.hasPrefix("…")
    }
}
