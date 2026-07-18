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

/// Notion-Calendar-style settings: nav rail on the left, one scrollable
/// content pane per section on the right. Lives in its own fixed-size
/// window (hidden title bar), so the window supplies all chrome.
struct SettingsPanelView: View {
    @ObservedObject var panel: SettingsPanel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(spacing: 0) {
            navRail

            Rectangle()
                .fill(Theme.ink.opacity(0.06))
                .frame(width: 1)
                .ignoresSafeArea(edges: .top)

            contentPane
        }
        .frame(width: 780, height: 520)
        // Content stays in the safe area (below the hidden title bar) so the
        // window sizes correctly; only the backgrounds extend into that strip.
        .background(Theme.panel.ignoresSafeArea())
        .background(
            // Settings windows traditionally close on ⎋ as well as ⌘W.
            Button("") { dismissWindow(id: SettingsPanel.windowID) }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        )
    }

    // MARK: - Nav rail

    private var navRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Traffic lights live in the title-bar strip above this content.
            Text("Settings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text(0.4))
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)

            ForEach(SettingsSection.allCases) { section in
                SettingsNavRow(
                    section: section,
                    isSelected: panel.section == section
                ) {
                    panel.section = section
                }
            }

            Spacer()

            Text(appVersionLine)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text(0.28))
                .padding(.horizontal, 10)
        }
        .padding(12)
        .frame(width: 196)
        .background(Theme.inverseInk.opacity(0.22).ignoresSafeArea(edges: .top))
    }

    private var appVersionLine: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Enso \(version)"
    }

    // MARK: - Content

    private var contentPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(panel.section.title)
                    .font(.system(size: 19, weight: .semibold))
                    .padding(.bottom, -4)

                switch panel.section {
                case .general: GeneralSettings()
                case .appearance: AppearanceSettings()
                case .tabs: TabsSettings()
                case .keyboard: KeyboardSettings()
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    var body: some View {
        SettingsGroup("Startup") {
            SettingsRow(
                "Restore previous session",
                caption: "Reopen your spaces and tabs where you left off."
            ) {
                Toggle("", isOn: $restoreSession)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }

        SettingsGroup("New tabs") {
            SettingsRow(
                "New tabs open in",
                caption: "Where a fresh terminal starts."
            ) {
                Picker("", selection: $newTabDirectory) {
                    Text("Home folder").tag("home")
                    Text("Current tab's folder").tag("inherit")
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        SettingsGroup("Closing") {
            SettingsRow(
                "Confirm before closing tabs",
                caption: "Ask when a tab still has a process running."
            ) {
                Toggle("", isOn: $confirmClose)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }

        PreviewFootnote()
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
        SettingsGroup("Theme") {
            SettingsRow(
                "Appearance",
                caption: "The app chrome follows this; the terminal keeps its Ghostty theme."
            ) {
                AppearanceSegments(selectedRaw: appearanceRaw)
            }
        }

        SettingsGroup("Text") {
            SettingsRow(
                "Font smoothing",
                caption: "Thickens small light-on-dark text. Takes effect after relaunch."
            ) {
                Toggle("", isOn: smoothingOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }

        SettingsGroup("Terminal theme") {
            SettingsRow(
                "Follows your Ghostty config",
                caption: "Fonts, colors, and theme come from Ghostty's config file. Changes apply on relaunch."
            ) {
                Button("Edit config") {
                    editGhosttyConfig()
                }
                .controlSize(.small)
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
        SettingsGroup("Tab naming") {
            SettingsRow(
                "Name tabs automatically",
                caption: "Names each new tab from its first command. Renaming a tab yourself always wins."
            ) {
                Toggle("", isOn: $namingEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if namingEnabled {
                SettingsRow(
                    "Naming command",
                    caption: "Runs in a login shell: prompt on stdin, tab name on stdout."
                ) {
                    Picker("", selection: $namingChoice) {
                        ForEach(TabAutoNamer.presetCommands, id: \.name) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                        Text(Self.customChoice).tag(Self.customChoice)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: namingChoice) { _, choice in
                        if let preset = TabAutoNamer.presetCommands.first(where: { $0.name == choice }) {
                            namingCommand = preset.command
                        }
                    }
                }

                if namingChoice == Self.customChoice {
                    TextField("claude -p --model haiku", text: $namingCommand)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.ink.opacity(0.06))
                        )
                }
            }
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

        SettingsGroup("Temporary tabs") {
            SettingsRow(
                "Close unpinned tabs after",
                caption: "Tabs below the sidebar divider are temporary. Pin a tab (drag it above the divider) to keep it forever."
            ) {
                Picker("", selection: $ephemeralTTLHours) {
                    Text("12 hours").tag(12)
                    Text("24 hours").tag(24)
                    Text("48 hours").tag(48)
                    Text("Never").tag(0)
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        SettingsGroup("Agents") {
            SettingsRow(
                "Resume agent sessions on relaunch",
                caption: "A tab that was running claude or codex when you quit picks its conversation back up. Takes effect for new tabs."
            ) {
                Toggle("", isOn: $resumeAgentSessions)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if resumeAgentSessions {
                SettingsRow("When Enso opens…", caption: wakeCaption) {
                    Picker("", selection: $agentWakePolicy) {
                        Text("Wake as I visit").tag(TerminalSessionStore.AgentWakePolicy.onVisit)
                        Text("Wake recent tabs").tag(TerminalSessionStore.AgentWakePolicy.recent)
                        Text("Wake everything").tag(TerminalSessionStore.AgentWakePolicy.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                if agentWakePolicy == .recent {
                    SettingsRow(
                        "Tabs to wake right away",
                        caption: "Most recent first, counted across the whole launch."
                    ) {
                        Stepper(value: $agentWakeRecentCount, in: 1...20) {
                            Text("\(agentWakeRecentCount)")
                                .font(.system(size: 13).monospacedDigit())
                                .frame(minWidth: 22, alignment: .trailing)
                        }
                        .fixedSize()
                    }
                }
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
            "Your \(agentWakeRecentCount) most recent agent tabs pick up right away. The rest sleep — a tinted badge marks them — and wake when you click."
        case .all:
            "Every agent restarts the moment Enso opens — heavier on memory while they all spin up."
        }
    }
}

private struct KeyboardSettings: View {
    var body: some View {
        SettingsGroup("Navigation") {
            ShortcutRow("Command center", keys: ["⌘", "T"])
            ShortcutRow("Go to tab", keys: ["⌘", "P"])
            ShortcutRow("Switch to recent tab", keys: ["⌃", "⇥"])
            ShortcutRow("Previous / next tab", keys: ["⇧", "⌘", "[ ]"])
            ShortcutRow("Jump to tab 1–9", keys: ["⌘", "1–9"])
        }

        SettingsGroup("Tabs") {
            ShortcutRow("New tab", keys: ["⇧", "⌘", "T"])
            ShortcutRow("New folder", keys: ["⇧", "⌘", "N"])
            ShortcutRow("Pin / unpin tab", keys: ["⇧", "⌘", "P"])
            ShortcutRow("Close tab", keys: ["⌘", "W"])
        }

        SettingsGroup("App") {
            ShortcutRow("Settings", keys: ["⌘", ","])
        }

        Text("Custom key bindings are coming later.")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.text(0.35))
    }
}

/// Icon segments for the appearance choice; selection is a neutral ink
/// well, not the accent, and applies immediately via AppAppearance.
private struct AppearanceSegments: View {
    let selectedRaw: String

    @Namespace private var selectionWell

    private static let options: [(AppAppearance, String, String)] = [
        (.system, "circle.lefthalf.filled", "Match the system"),
        (.light, "sun.max", "Always light"),
        (.dark, "moon", "Always dark"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.options, id: \.0) { option, symbol, help in
                let isSelected = selectedRaw == option.rawValue
                Button {
                    AppAppearance.set(option)
                } label: {
                    Image(systemName: symbol)
                        .symbolVariant(isSelected ? .fill : .none)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text(isSelected ? 1 : 0.45))
                        .frame(width: 34, height: 22)
                        .background {
                            // One shared well that slides between segments.
                            if isSelected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Theme.ink.opacity(0.12))
                                    .matchedGeometryEffect(id: "well", in: selectionWell)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(help)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.ink.opacity(0.05))
        )
        .animation(.spring(duration: 0.25, bounce: 0.15), value: selectedRaw)
    }
}

// MARK: - Building blocks

/// A titled group of rows separated by hairline dividers, Notion-Calendar
/// style: flat, no boxed background.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.text(0.92))
                .padding(.bottom, 8)

            content
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder let control: Control

    init(_ title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text(0.85))
                if let caption {
                    Text(caption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text(0.42))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 20)

            control
        }
        .padding(.vertical, 7)
    }
}

private struct ShortcutRow: View {
    let title: String
    let keys: [String]

    init(_ title: String, keys: [String]) {
        self.title = title
        self.keys = keys
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text(0.85))

            Spacer()

            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.text(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(Theme.ink.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                        .strokeBorder(Theme.ink.opacity(0.09), lineWidth: 1)
                                )
                        )
                }
            }
        }
        .padding(.vertical, 5)
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
