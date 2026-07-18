import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Holds the settings window's nav selection so it survives close/reopen.
/// The window itself is a `Window` scene; open it via
/// `openWindow(id: SettingsPanel.windowID)`.
@MainActor
final class SettingsPanel: ObservableObject {
    static let shared = SettingsPanel()
    static let windowID = "settings"

    @Published var section: SettingsSection = .general
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case tabs
    case keyboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .tabs: "Tabs & Spaces"
        case .keyboard: "Keyboard"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .tabs: "rectangle.stack"
        case .keyboard: "keyboard"
        }
    }

}

/// Notion-Calendar-style settings: the app's own nav rail on the left,
/// native grouped-form panes on the right. Lives in a hidden-title-bar
/// window; fixed width, but the height is the user's (contentSize
/// resizability keeps the width pinned, System Settings style).
struct SettingsPanelView: View {
    @ObservedObject var panel: SettingsPanel
    @Environment(\.dismissWindow) private var dismissWindow

    /// Whether the pane's rows have scrolled up under the heading; drives
    /// the heading's large → compact collapse.
    @State private var isScrolled = false

    @Environment(\.controlActiveState) private var controlActiveState
    private var isWindowInactive: Bool { controlActiveState == .inactive }

    var body: some View {
        HStack(spacing: 0) {
            navRail
                // Hairline on the sidebar's own edge, over its frost — on
                // the content side the panel color washes it out to gray.
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Theme.ink.opacity(0.09))
                        .frame(width: 1)
                        .ignoresSafeArea(edges: .top)
                }

            contentPane
        }
        .frame(width: 780)
        .frame(minHeight: 470, idealHeight: 540, maxHeight: .infinity)
        // Content stays in the safe area (below the hidden title bar) so the
        // window sizes correctly; only the backgrounds extend into that strip.
        .background(Theme.panel.ignoresSafeArea())
        .background(
            // Settings windows traditionally close on ⎋ as well as ⌘W.
            Button("") { dismissWindow(id: SettingsPanel.windowID) }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        )
        .background(TrafficLightInset(offset: CGPoint(x: 8, y: 6)))
    }

    // MARK: - Nav rail

    private var navRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Traffic lights live in the title-bar strip above this content.
            ForEach(SettingsSection.allCases) { section in
                SettingsNavRow(
                    section: section,
                    isSelected: panel.section == section
                ) {
                    panel.section = section
                }
            }

            Spacer()

            // App identity: bundle name + version, so each channel signs
            // itself — "Enso Dev", "Enso Next", or plain "Enso". Version in
            // monospace so the digits sit steady.
            VStack(alignment: .leading, spacing: 1) {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Enso")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text(0.55))
                Text(UpdateController.shared.currentVersion)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.text(0.32))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 218)
        // Same fade the main sidebar wears when its window loses focus.
        .saturation(isWindowInactive ? 0 : 1)
        .opacity(isWindowInactive ? 0.6 : 1)
        .background(
            // Same frost as the main window's sidebar, but muted: the
            // heavier tint keeps just a hint of desktop glow — a settings
            // window shouldn't shimmer as much as the workspace.
            ZStack {
                SidebarFrost()
                Theme.inverseInk.opacity(0.55)
            }
            .ignoresSafeArea(edges: .top)
        )
    }

    // MARK: - Content

    private var contentPane: some View {
        // Native grouped form: sections render as inset rounded cards with
        // system row metrics, separators, and dark-mode handling for free.
        // The heading is a safe-area inset pinned over the scroll view on a
        // material wash, so rows blur through it as they pass beneath.
        Form {
            switch panel.section {
            case .general: GeneralSettings()
            case .appearance: AppearanceSettings()
            case .tabs: TabsSettings()
            case .keyboard: KeyboardSettings()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 4
        } action: { _, scrolled in
            isScrolled = scrolled
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Collapses once rows scroll beneath it: the title shrinks
            // (scaleEffect, not font, so the size animates smoothly), the
            // vertical padding tightens, and an edge-to-edge hairline
            // separates it from the passing content. Solid panel color —
            // the collapse is the scroll cue, no frost needed.
            Text(panel.section.title)
                .font(.system(size: 19, weight: .semibold))
                .scaleEffect(isScrolled ? 0.74 : 1, anchor: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, isScrolled ? 10 : 20)
                .background(Theme.panel)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Theme.ink.opacity(0.08))
                        .frame(height: 1)
                        .opacity(isScrolled ? 1 : 0)
                }
                .animation(.easeInOut(duration: 0.18), value: isScrolled)
        }
        // The heading owns the title-bar strip: 20pt from the window's true
        // top edge, not from the safe area below it.
        .ignoresSafeArea(edges: .top)
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsNavRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .symbolVariant(isSelected ? .fill : .none)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text(isSelected ? 0.9 : 0.55))
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Theme.text(isSelected ? 0.95 : 0.7))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.ink.opacity(isSelected ? 0.1 : (hovering ? 0.05 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Sections

private struct GeneralSettings: View {
    @AppStorage("restorePreviousSession") private var restoreSession = true
    @AppStorage("newTabWorkingDirectory") private var newTabDirectory = "home"
    @AppStorage("confirmCloseTabs") private var confirmClose = true
    @AppStorage("SUEnableAutomaticChecks") private var autoUpdateCheck = true

    var body: some View {
        Section("Startup") {
            Toggle(isOn: $restoreSession) {
                Text("Restore previous session")
                Text("Reopen your spaces and tabs where you left off.")
            }
        }

        Section("New tabs") {
            Picker(selection: $newTabDirectory) {
                Text("Home folder").tag("home")
                Text("Current tab's folder").tag("inherit")
            } label: {
                Text("New tabs open in")
                Text("Where a fresh terminal starts.")
            }
        }

        Section {
            Toggle(isOn: $confirmClose) {
                Text("Confirm before closing tabs")
                Text("Ask when a tab still has a process running.")
            }
        } header: {
            Text("Closing")
        } footer: {
            PreviewFootnote()
        }

        Section {
            // SUEnableAutomaticChecks is Sparkle's own backing store for
            // automaticallyChecksForUpdates, so the updater sees the flip
            // without any plumbing.
            Toggle("Automatically check for updates", isOn: $autoUpdateCheck)

            LabeledContent("Check for updates") {
                Button("Check Now") {
                    UpdateController.shared.checkForUpdates()
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Enso \(UpdateController.shared.currentVersion)")
        }
    }
}

private struct AppearanceSettings: View {
    @AppStorage("AppleFontSmoothing") private var fontSmoothing = 2
    @AppStorage(AppAppearance.defaultsKey) private var appearanceRaw = AppAppearance.system.rawValue

    private var smoothingOn: Binding<Bool> {
        Binding(
            get: { fontSmoothing != 0 },
            set: { fontSmoothing = $0 ? 2 : 0 }
        )
    }

    var body: some View {
        Section {
            AppearanceWells(selectedRaw: appearanceRaw)
                .frame(maxWidth: .infinity)
        } header: {
            Text("Theme")
        } footer: {
            Text("This affects your app. The terminal follows your Ghostty theme.")
        }

        Section("Text") {
            Toggle(isOn: smoothingOn) {
                Text("Font smoothing")
                Text("Thickens small light-on-dark text. Takes effect after relaunch.")
            }
        }

        Section("Terminal theme") {
            LabeledContent {
                Button("Edit config") {
                    editGhosttyConfig()
                }
            } label: {
                Text("Follows your Ghostty config")
                Text("Fonts, colors, and theme come from Ghostty's config file. Changes apply on relaunch.")
            }
        }
    }

    private func editGhosttyConfig() {
        let fm = FileManager.default
        let xdgDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty", isDirectory: true)
        let appSupportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let configDir = fm.fileExists(atPath: xdgDir.path) ? xdgDir : appSupportDir
        let configFile = configDir.appendingPathComponent("config", isDirectory: false)

        // Ghostty may not have run yet, so the file (and even its directory) can be
        // missing. Create it empty rather than dead-ending the button.
        if !fm.fileExists(atPath: configFile.path) {
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            fm.createFile(atPath: configFile.path, contents: nil)
        }

        // The config file has no extension, so a plain `open(configFile)` would
        // hand it to whatever app has claimed extensionless files. Resolve the
        // user's actual default text editor instead.
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText) {
            NSWorkspace.shared.open(
                [configFile], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(configFile)
        }
    }
}

private struct TabsSettings: View {
    @AppStorage(TerminalSessionStore.ephemeralTTLDefaultsKey) private var ephemeralTTLHours = 24
    @AppStorage(TabAutoNamer.enabledDefaultsKey) private var namingEnabled = true
    @AppStorage(TabAutoNamer.commandDefaultsKey) private var namingCommand = ""
    @AppStorage(AgentSessionStore.restoreEnabledDefaultsKey) private var resumeAgentSessions = true
    @AppStorage(TerminalSessionStore.agentWakePolicyDefaultsKey)
    private var agentWakePolicy = TerminalSessionStore.AgentWakePolicy.recent
    @AppStorage(TerminalSessionStore.agentWakeRecentCountDefaultsKey)
    private var agentWakeRecentCount = TerminalSessionStore.defaultAgentWakeRecentCount

    private static let customChoice = "Custom"
    @State private var namingChoice = TabAutoNamer.presetCommands[0].name

    var body: some View {
        Section {
            Toggle(isOn: $namingEnabled) {
                Text("Name tabs automatically")
                Text("Names each new tab from its first command. Renaming a tab yourself always wins.")
            }

            if namingEnabled {
                Picker(selection: $namingChoice) {
                    ForEach(TabAutoNamer.presetCommands, id: \.name) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                    Text(Self.customChoice).tag(Self.customChoice)
                } label: {
                    Text("Naming command")
                    Text("Runs in a login shell: prompt on stdin, tab name on stdout.")
                }
                .onChange(of: namingChoice) { _, choice in
                    if let preset = TabAutoNamer.presetCommands.first(where: { $0.name == choice }) {
                        namingCommand = preset.command
                    }
                }

                if namingChoice == Self.customChoice {
                    TextField("claude -p --model haiku", text: $namingCommand)
                        .font(.system(size: 12, design: .monospaced))
                }
            }
        } header: {
            Text("Tab naming")
        }
        .onAppear {
            let current = namingCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty {
                namingChoice = TabAutoNamer.presetCommands[0].name
            } else if let preset = TabAutoNamer.presetCommands.first(where: { $0.command == current }) {
                namingChoice = preset.name
            } else {
                namingChoice = Self.customChoice
            }
        }

        Section("Temporary tabs") {
            Picker(selection: $ephemeralTTLHours) {
                Text("12 hours").tag(12)
                Text("24 hours").tag(24)
                Text("48 hours").tag(48)
                Text("Never").tag(0)
            } label: {
                Text("Close unpinned tabs after")
                Text("Tabs below the sidebar divider are temporary. Pin a tab to keep it forever.")
            }
        }

        Section {
            Toggle(isOn: $resumeAgentSessions) {
                Text("Resume agent sessions on relaunch")
                Text("A tab that was running claude or codex when you quit picks its conversation back up.")
            }

            if resumeAgentSessions {
                Picker("When Enso opens…", selection: $agentWakePolicy) {
                    Text("Wake as I visit").tag(TerminalSessionStore.AgentWakePolicy.onVisit)
                    Text("Wake recent tabs first").tag(TerminalSessionStore.AgentWakePolicy.recent)
                    Text("Wake everything").tag(TerminalSessionStore.AgentWakePolicy.all)
                }

                if agentWakePolicy == .recent {
                    LabeledContent("Tabs to wake right away") {
                        HStack(spacing: 8) {
                            Text("\(agentWakeRecentCount)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Stepper("", value: $agentWakeRecentCount, in: 1...20)
                                .labelsHidden()
                        }
                    }
                }
            }
        } header: {
            Text("Agents")
        } footer: {
            if resumeAgentSessions {
                Text(wakeCaption)
            }
        }
    }

    /// The explainer under the wake picker doubles as the introduction to
    /// the sidebar's tinted "asleep" badge, so the setting and the badge
    /// teach each other.
    private var wakeCaption: String {
        switch agentWakePolicy {
        case .onVisit:
            "Sleeping agent tabs wear a tinted badge and wake the moment you click them."
        case .recent:
            "Your \(agentWakeRecentCount) most recent agent tabs pick up right away; the rest sleep with a tinted badge until you click."
        case .all:
            "Every agent restarts the moment Enso opens — heavier on memory while they all spin up."
        }
    }
}

private struct KeyboardSettings: View {
    var body: some View {
        Section("Navigation") {
            ShortcutRow("Command center", keys: ["⌘", "T"])
            ShortcutRow("Go to tab", keys: ["⌘", "P"])
            ShortcutRow("Switch to recent tab", keys: ["⌃", "⇥"])
            ShortcutRow("Previous / next tab", keys: ["⇧", "⌘", "[ ]"])
            ShortcutRow("Jump to tab 1–9", keys: ["⌘", "1–9"])
        }

        Section("Tabs") {
            ShortcutRow("New tab", keys: ["⇧", "⌘", "T"])
            ShortcutRow("New folder", keys: ["⇧", "⌘", "N"])
            ShortcutRow("Pin / unpin tab", keys: ["⇧", "⌘", "P"])
            ShortcutRow("Close tab", keys: ["⌘", "W"])
        }

        Section {
            ShortcutRow("Settings", keys: ["⌘", ","])
        } header: {
            Text("App")
        } footer: {
            Text("Custom key bindings are coming later.")
        }
    }
}

/// System-Settings-style appearance choice: three mini-window thumbnails
/// with a selection ring, centered in their card row. Applies immediately
/// via AppAppearance.
private struct AppearanceWells: View {
    let selectedRaw: String

    private static let options: [(AppAppearance, String, String)] = [
        (.light, "Light", "Always light"),
        (.dark, "Dark", "Always dark"),
        (.system, "Auto", "Match the system"),
    ]

    var body: some View {
        HStack(spacing: 28) {
            ForEach(Self.options, id: \.0) { option, label, help in
                let isSelected = selectedRaw == option.rawValue
                Button {
                    AppAppearance.set(option)
                } label: {
                    VStack(spacing: 6) {
                        AppearanceThumbnail(option: option)
                            .frame(width: 64, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? Color.accentColor : .primary.opacity(0.15),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            )
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .help(help)
            }
        }
        .padding(.vertical, 6)
    }
}

/// A mini app window: titlebar dots and a few lines of "text". Auto shows
/// the light and dark halves side by side, like the system's own well.
private struct AppearanceThumbnail: View {
    let option: AppAppearance

    var body: some View {
        switch option {
        case .light: pane(dark: false)
        case .dark: pane(dark: true)
        case .system:
            // Two half-width panes, each with its own full-size drawing
            // pinned to its own left edge; the bars bleed past the half and
            // each side clips its own overflow at the split.
            HStack(spacing: 0) {
                pane(dark: false, compact: true)
                pane(dark: true, compact: true)
            }
        }
    }

    private func pane(dark: Bool, compact: Bool = false) -> some View {
        // The color alone owns layout (each Auto half sizes purely from its
        // proposal); the drawing rides on top at fixed natural size, its
        // top-leading corner nailed to the pane's — so it can never be
        // re-centered by a narrow container. Compact bars fit a half's
        // 20pt of usable width.
        (dark ? Color(white: 0.14) : Color(white: 0.94))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2.5) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle()
                                .fill(dark ? Color(white: 0.5) : Color(white: 0.68))
                                .frame(width: 3.5, height: 3.5)
                        }
                    }

                    ForEach(0..<3, id: \.self) { line in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(dark ? Color(white: 0.55) : Color(white: 0.62))
                            .frame(
                                width: compact
                                    ? (line == 2 ? 13 : 20)
                                    : (line == 2 ? 22 : 34),
                                height: 3
                            )
                    }
                }
                .padding(6)
                .fixedSize()
            }
    }
}

/// Frosted backdrop blurring the desktop behind the window — the same
/// .sidebar/.behindWindow recipe as the main window's sidebar.
private struct SidebarFrost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        // Dims with the window, so the rail fades on focus loss along with
        // its content.
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Nudges the hosting window's traffic lights in from the corner they hug
/// in a hidden-title-bar window. AppKit re-seats the buttons on every
/// resize, so each button's target origin (first-seen origin + offset) is
/// captured once and re-applied — setting an already-correct origin is a
/// no-op, so the reapply is idempotent.
private struct TrafficLightInset: NSViewRepresentable {
    /// x moves the cluster right, y moves it down.
    let offset: CGPoint

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window, offset: offset)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The window can be nil during makeNSView; late attach is harmless.
        context.coordinator.attach(to: nsView.window, offset: offset)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        private var window: NSWindow?
        private var targets: [NSWindow.ButtonType: CGPoint] = [:]
        private var observer: NSObjectProtocol?

        func attach(to window: NSWindow?, offset: CGPoint) {
            guard let window, self.window == nil else { return }
            self.window = window
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                targets[type] = CGPoint(
                    x: button.frame.origin.x + offset.x,
                    // AppKit's y grows upward; down is minus.
                    y: button.frame.origin.y - offset.y
                )
            }
            apply()
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.apply() }
            }
        }

        private func apply() {
            guard let window else { return }
            for (type, origin) in targets {
                window.standardWindowButton(type)?.setFrameOrigin(origin)
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

// MARK: - Building blocks

/// A shortcut as native apps list them: plain right-aligned glyph text
/// (⇧⌘T), not keycap chips.
private struct ShortcutRow: View {
    let title: String
    let keys: [String]

    init(_ title: String, keys: [String]) {
        self.title = title
        self.keys = keys
    }

    var body: some View {
        LabeledContent(title) {
            Text(keys.joined())
                .foregroundStyle(.secondary)
        }
    }
}

/// Marks sections whose switches persist but aren't enforced yet.
private struct PreviewFootnote: View {
    var body: some View {
        Text("Preview — these preferences are saved but not wired up yet.")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.text(0.35))
    }
}

#Preview {
    SettingsPanelView(panel: SettingsPanel.shared)
        .padding(40)
        .background(.black)
}
