import SwiftUI

/// A recognized foreground process in a tab, detected from shell-integration
/// title events. Agents get their bundled brand logo, known tools an SF
/// Symbol glyph tinted with the tab accent; unknown or idle shells fall back
/// to the accent dot.
enum TabProcess: String, Hashable {
    // Agents with bundled brand icons.
    case claude
    case codex
    case gemini
    case ollama
    // Tool families with symbol glyphs.
    case editor
    case remote
    case git
    case runtime
    case container
    case monitor
    case build
    case reader

    enum Badge {
        /// Asset-catalog template image with its brand color.
        case asset(String, Color)
        /// SF Symbol, tinted with the tab's accent by the row.
        case symbol(String)
    }

    var badge: Badge {
        switch self {
        case .claude: .asset("AgentClaude", Color(hex: 0xD97757))
        case .codex: .asset("AgentCodex", Color.white.opacity(0.85))
        case .gemini: .asset("AgentGemini", Color(hex: 0x8E75B2))
        case .ollama: .asset("AgentOllama", Color.white.opacity(0.8))
        case .editor: .symbol("square.and.pencil")
        case .remote: .symbol("network")
        case .git: .symbol("arrow.triangle.branch")
        case .runtime: .symbol("chevron.left.forwardslash.chevron.right")
        case .container: .symbol("shippingbox")
        case .monitor: .symbol("speedometer")
        case .build: .symbol("hammer")
        case .reader: .symbol("doc.text")
        }
    }

    private static let commands: [String: TabProcess] = [
        "claude": .claude,
        "codex": .codex,
        "gemini": .gemini,
        "ollama": .ollama,
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

    private static let idleShells: Set<String> = [
        "zsh", "bash", "fish", "sh", "nu", "login", "-zsh", "-bash",
    ]

    /// Next detected process given a new title event. Titles come in three
    /// shapes: a command line from shell preexec ("claude --continue"), an
    /// idle prompt (shell name or a path), or a foreign title an app set
    /// itself (Claude Code retitles constantly). Commands match, idle
    /// clears, foreign titles keep the current detection — that stickiness
    /// is what survives an agent's own retitling.
    static func detect(after current: TabProcess?, title: String) -> TabProcess? {
        guard let firstWord = title.split(separator: " ").first else { return current }
        let command = (String(firstWord) as NSString).lastPathComponent.lowercased()

        if let match = commands[command] {
            return match
        }
        if idleShells.contains(command) || command.hasPrefix("~") || firstWord.hasPrefix("/") {
            return nil
        }
        return current
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
