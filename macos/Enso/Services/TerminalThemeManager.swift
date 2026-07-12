import AppKit
import Combine
import SwiftUI

/// Enso's terminal-theme layer on top of the user's own Ghostty config.
///
/// The user's ghostty config files are never touched. Enso keeps its choice in
/// its own places instead:
///   - UserDefaults for the durable preference (an all-spaces theme plus
///     per-space overrides, and the "recent themes" list), and
///   - a small override config file under Application Support that is loaded
///     *after* the user's config whenever a `ghostty_config_t` is built, so
///     Enso's `theme` key wins while everything else (fonts, keybinds, any
///     explicitly set colors) stays the user's.
///
/// Live application is real: changing the theme rebuilds the config and pushes
/// it through `ghostty_app_update_config` / `ghostty_surface_update_config`
/// (see GhosttyRuntime.reloadConfig), which recolors running terminals
/// immediately — the same mechanism Ghostty itself uses for config reload.
@MainActor
final class TerminalThemeManager: ObservableObject {
    static let shared = TerminalThemeManager()

    enum Scope {
        case thisSpace(SidebarSpace.ID)
        case allSpaces
    }

    static let allSpacesDefaultsKey = "terminalThemeAllSpaces"
    static let bySpaceDefaultsKey = "terminalThemeBySpace"
    static let recentsDefaultsKey = "terminalThemeRecents"
    /// The last theme name pushed live (preview or commit). Persisted so the
    /// chrome background can seed itself at launch without re-parsing the
    /// on-disk override file — that file is still the source of truth for the
    /// running config (GhosttyRuntime.loadConfig reads it), this key only
    /// mirrors the applied *name* for the UI.
    static let appliedDefaultsKey = "terminalThemeApplied"

    /// Every bundled Ghostty theme name (Enso ships Ghostty's theme set under
    /// Resources/ghostty/themes, the location libghostty resolves `theme`
    /// names from), sorted for the "All Themes" section.
    let themes: [String]

    /// Recently applied themes, most recent first. Seeded with a few
    /// well-known ones so the picker's "Recent" section reads believably
    /// before the user has committed anything.
    @Published private(set) var recentThemeNames: [String]

    /// Bumped on every live apply (preview or commit) so chrome that blends
    /// with the terminal background can re-read GhosttyRuntime.themeBackground.
    @Published private(set) var appliedThemeName: String?

    /// True between the palette starting a live preview and either a commit
    /// or a cancel. While previewing, space switches don't reapply.
    private(set) var isPreviewing = false

    private weak var store: TerminalSessionStore?
    private var accentCache: [String: Color] = [:]
    private var previewWorkItem: DispatchWorkItem?

    private init() {
        themes = Self.enumerateBundledThemes()
        let storedRecents = UserDefaults.standard.stringArray(forKey: Self.recentsDefaultsKey)
        recentThemeNames = storedRecents
            ?? ["Catppuccin Mocha", "TokyoNight", "Nord", "Gruvbox Dark"]
        // Seed the applied name from the durable mirror. The running config
        // was built from the override file at startup (GhosttyRuntime.loadConfig
        // loads it), and this key was written alongside it on the last apply.
        appliedThemeName = UserDefaults.standard.string(forKey: Self.appliedDefaultsKey)
    }

    /// Called once from the root view. Reconciles the on-disk override (which
    /// tracks the *applied* theme, possibly a stale preview from a crash) with
    /// the committed preference for the active space.
    func attach(to store: TerminalSessionStore) {
        self.store = store
        apply(effectiveThemeName(forSpace: store.activeSpaceID))
    }

    // MARK: - Preference

    /// The committed theme for a space: its own override, else the all-spaces
    /// choice, else nil (the user's ghostty config as-is).
    func effectiveThemeName(forSpace spaceID: SidebarSpace.ID) -> String? {
        themeBySpace[spaceID.uuidString] ?? allSpacesTheme
    }

    private var allSpacesTheme: String? {
        UserDefaults.standard.string(forKey: Self.allSpacesDefaultsKey)
    }

    private var themeBySpace: [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.bySpaceDefaultsKey) as? [String: String] ?? [:]
    }

    // MARK: - Live preview / commit

    /// Recolors the running terminals to `name` without persisting anything.
    /// Debounced a beat so held arrow keys don't rebuild the config per row.
    func preview(_ name: String) {
        isPreviewing = true
        previewWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.apply(name)
        }
        previewWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Reverts an uncommitted preview to the committed theme.
    func cancelPreview() {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        guard isPreviewing else { return }
        isPreviewing = false
        let spaceID = store?.activeSpaceID
        apply(spaceID.flatMap { effectiveThemeName(forSpace: $0) } ?? allSpacesTheme)
    }

    /// Persists the choice into Enso's own config (UserDefaults) and leaves
    /// the previewed colors applied.
    func commit(_ name: String, scope: Scope) {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        isPreviewing = false

        let defaults = UserDefaults.standard
        switch scope {
        case .allSpaces:
            defaults.set(name, forKey: Self.allSpacesDefaultsKey)
            // "All Spaces" means all: older per-space overrides give way.
            defaults.removeObject(forKey: Self.bySpaceDefaultsKey)
        case .thisSpace(let spaceID):
            var map = themeBySpace
            map[spaceID.uuidString] = name
            defaults.set(map, forKey: Self.bySpaceDefaultsKey)
        }

        var recents = recentThemeNames.filter { $0 != name }
        recents.insert(name, at: 0)
        recentThemeNames = Array(recents.prefix(5))
        defaults.set(recentThemeNames, forKey: Self.recentsDefaultsKey)

        apply(name)
    }

    /// Per-space themes follow the active space; called from the store on
    /// space switches.
    func activeSpaceDidChange(_ spaceID: SidebarSpace.ID) {
        guard !isPreviewing else { return }
        apply(effectiveThemeName(forSpace: spaceID))
    }

    /// Rewrites the override layer and pushes a rebuilt config to the running
    /// app and every live surface. `nil` drops the override so the user's own
    /// ghostty config shows through unmodified.
    private func apply(_ name: String?) {
        guard name != appliedThemeName else { return }
        setAppliedName(name)
        Self.writeOverrideFile(themeName: name)
        GhosttyRuntime.shared.reloadConfig()
    }

    /// Publishes the applied name and mirrors it into UserDefaults so the next
    /// launch can seed `appliedThemeName` without parsing the override file.
    private func setAppliedName(_ name: String?) {
        appliedThemeName = name
        let defaults = UserDefaults.standard
        if let name {
            defaults.set(name, forKey: Self.appliedDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.appliedDefaultsKey)
        }
    }

    /// Called from the store when a space is deleted: drops that space's
    /// per-space theme override so the entry doesn't linger in storage. Kept
    /// here (rather than the store reaching into UserDefaults) so all
    /// per-space theme state stays owned by the manager.
    func spaceWasDeleted(_ spaceID: SidebarSpace.ID) {
        var map = themeBySpace
        guard map.removeValue(forKey: spaceID.uuidString) != nil else { return }
        UserDefaults.standard.set(map, forKey: Self.bySpaceDefaultsKey)
    }

    /// On quit: if a preview is still in flight, rewrite the override file back
    /// to the committed theme so the next launch's first paint isn't the
    /// abandoned preview (ensureStarted builds the startup config from this
    /// file before the manager attaches and reconciles).
    func reconcileOverrideOnTermination() {
        guard isPreviewing else { return }
        previewWorkItem?.cancel()
        previewWorkItem = nil
        isPreviewing = false
        let spaceID = store?.activeSpaceID
        let committed = spaceID.flatMap { effectiveThemeName(forSpace: $0) } ?? allSpacesTheme
        Self.writeOverrideFile(themeName: committed)
        setAppliedName(committed)
    }

    // MARK: - Enso's ghostty override file

    /// Enso-owned config fragment, loaded after the user's ghostty config
    /// whenever a ghostty_config_t is built. Never the user's own config file.
    nonisolated static var overrideFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Enso", isDirectory: true)
            .appendingPathComponent("ghostty-overrides.conf", isDirectory: false)
    }

    private static func writeOverrideFile(themeName: String?) {
        let url = overrideFileURL
        guard let themeName else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let contents = """
        # Managed by Enso. This is Enso's own layer over your Ghostty config;
        # your ~/.config/ghostty files are never modified.
        theme = \(themeName)

        """
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("TerminalThemeManager: failed to write override file: %@", "\(error)")
        }
    }

    // MARK: - Theme catalog

    private nonisolated static var themesDirectoryURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
    }

    private static func enumerateBundledThemes() -> [String] {
        guard
            let directory = themesDirectoryURL,
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
            !names.isEmpty
        else {
            // Previews / stripped bundles: a believable well-known subset.
            return [
                "Atom One Dark", "Ayu", "Catppuccin Mocha", "Dracula",
                "Everforest Dark Hard", "GitHub Dark", "Gruvbox Dark",
                "Kanagawa Wave", "Nord", "Rose Pine", "Solarized Dark Patched",
                "TokyoNight",
            ]
        }
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A representative color for a theme's row bullet: its ANSI blue
    /// (palette 4), falling back to its foreground. Parsed from the bundled
    /// theme file once and cached.
    func accentColor(for name: String) -> Color {
        if let cached = accentCache[name] { return cached }
        let color = Self.parseAccent(named: name) ?? Theme.ink.opacity(0.55)
        accentCache[name] = color
        return color
    }

    private static func parseAccent(named name: String) -> Color? {
        guard
            let url = themesDirectoryURL?.appendingPathComponent(name),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }

        var blue: Color?
        var foreground: Color?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("palette") {
                // "palette = 4=#89b4fa"
                let parts = trimmed.split(separator: "=", maxSplits: 2).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 3, parts[1] == "4" {
                    blue = color(fromHex: parts[2])
                }
            } else if trimmed.hasPrefix("foreground") {
                let parts = trimmed.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2 {
                    foreground = color(fromHex: parts[1])
                }
            }
            if blue != nil { break }
        }
        return blue ?? foreground
    }

    private static func color(fromHex string: String) -> Color? {
        var hex = string
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(nsColor: NSColor(hex: value))
    }
}
