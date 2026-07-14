import Testing
@testable import Enso

/// TabProcess.detect turns shell-integration title events into the sidebar's
/// per-tab process badge. Titles come in three shapes — a preexec command
/// line, an idle prompt (shell name or cwd), and a foreign title an app set
/// itself — and the badge is only trustworthy if commands match, every idle
/// prompt shape clears, and an agent's own retitling keeps its icon alive.
@MainActor
struct TabProcessTests {
    // MARK: - Command lines (shell preexec)

    @Test func commandLineDetectsAgent() {
        #expect(TabProcess.detect(after: nil, title: "claude --continue") == .claude)
        #expect(TabProcess.detect(after: nil, title: "codex resume abc123") == .codex)
    }

    @Test func commandPathsResolveToTheirBasename() {
        #expect(TabProcess.detect(after: nil, title: "/opt/homebrew/bin/claude") == .claude)
        #expect(TabProcess.detect(after: nil, title: "~/bin/nvim notes.md") == .editor)
    }

    @Test func newCommandReplacesPreviousDetection() {
        #expect(TabProcess.detect(after: .claude, title: "htop") == .monitor)
    }

    @Test func unknownCommandKeepsCurrentDetection() {
        // An unrecognized non-path word is indistinguishable from a foreign
        // title, so the current detection survives.
        #expect(TabProcess.detect(after: .editor, title: "frobnicate --all") == .editor)
    }

    // MARK: - Idle prompts (issue #34: the badge used to latch here)

    /// Shell integration reports the cwd as the idle title: zsh prints "~",
    /// "~/a/b", "/x/y", or "…/a/b/c" for deep paths; bash uses \w. Every
    /// shape must clear the badge — before #34 only bare "~" and absolute
    /// paths did, so any tab whose cwd lived under home kept a stale icon.
    @Test(arguments: [
        "~",
        "~/dev/enso",
        "/etc",
        "/Users/dev/project",
        "…/dev-projects/enso/macos",
        "…",
    ])
    func idlePromptClearsDetection(title: String) {
        #expect(TabProcess.detect(after: .claude, title: title) == nil)
    }

    @Test func idleShellNameClearsDetection() {
        #expect(TabProcess.detect(after: .codex, title: "zsh") == nil)
        #expect(TabProcess.detect(after: .codex, title: "-zsh") == nil)
        #expect(TabProcess.detect(after: .git, title: "fish") == nil)
    }

    // MARK: - Foreign titles (apps retitling themselves)

    /// Claude Code retitles constantly while running; those foreign titles
    /// must keep the badge alive until the shell prompts again.
    @Test func foreignTitleKeepsCurrentDetection() {
        #expect(TabProcess.detect(after: .claude, title: "✳ Fixing the sidebar badge") == .claude)
    }

    @Test func foreignTitleAloneDetectsNothing() {
        #expect(TabProcess.detect(after: nil, title: "✳ Some agent status") == nil)
    }

    // MARK: - Lifecycle

    /// The whole point of the badge: launch, retitle, exit, next command —
    /// the icon follows the foreground process the entire way.
    @Test func badgeTracksTheForegroundProcessAcrossALifecycle() {
        var process: TabProcess?
        process = TabProcess.detect(after: process, title: "~/dev/enso") // fresh prompt
        #expect(process == nil)
        process = TabProcess.detect(after: process, title: "claude") // preexec
        #expect(process == .claude)
        process = TabProcess.detect(after: process, title: "✳ Reticulating splines") // agent retitle
        #expect(process == .claude)
        process = TabProcess.detect(after: process, title: "~/dev/enso") // agent exited
        #expect(process == nil)
        process = TabProcess.detect(after: process, title: "htop") // next command
        #expect(process == .monitor)
    }
}
