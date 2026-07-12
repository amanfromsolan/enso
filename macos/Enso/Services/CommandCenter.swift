import AppKit
import Combine
import SwiftUI

/// The ⌘T/⌘P command center: one fuzzy palette over tabs, spaces, and
/// commands, grouped into "Recent Tabs", "Spaces", and "Commands" sections.
/// The empty sheet preselects the top recent tab (Enter jumps back to it) and
/// offers a short command menu; typing filters across everything at once, each
/// section sorted by score. The first nine rows keep ⌘1–9 quick-select.
@MainActor
final class CommandCenter: ObservableObject {
    static let shared = CommandCenter()

    /// Search is the palette; the rename modes turn the search field into
    /// an argument input ("new name") without leaving the palette. The theme
    /// modes are the "Terminal Theme" token flow: a live-previewing theme
    /// list, then an apply-scope step for the chosen theme.
    enum Mode {
        case search
        case renameTab(TerminalSession.ID)
        case renameSpace(SidebarSpace.ID)
        case themePicker
        case themeScope(String)
    }

    @Published private(set) var isOpen = false
    @Published private(set) var mode: Mode = .search
    @Published var query = "" {
        didSet { rebuild() }
    }
    @Published private(set) var items: [PaletteItem] = []
    @Published var highlightedIndex = 0 {
        didSet { previewHighlightedThemeIfNeeded() }
    }
    /// Live preview follows the highlight only after the picker has settled
    /// on its opening row; otherwise merely opening the picker would recolor
    /// the terminal to whatever sat at the top of "Recent".
    private var themePreviewArmed = false
    /// Screen location the cursor sat at when the row list last changed under
    /// it (opening the picker, stepping back from the scope). Hover-driven
    /// highlight changes are ignored until the mouse actually moves off this
    /// point, so a freshly swapped row under a still cursor can't hijack the
    /// restored highlight — and its live preview.
    private var hoverAnchor: NSPoint?
    /// Non-nil while a command's option sheet is up (e.g. "Change
    /// Appearance"): the palette shows only these items, filtered by the
    /// query, and Esc backs out to the main sheet instead of closing.
    private var submenuItems: [PaletteItem]?

    var isRenaming: Bool {
        switch mode {
        case .renameTab, .renameSpace: return true
        case .search, .themePicker, .themeScope: return false
        }
    }

    /// The plain search sheet: not a token flow, a rename, or an open submenu.
    private var isPlainSearch: Bool {
        if case .search = mode { return submenuItems == nil }
        return false
    }

    /// Either theme stage: the search field grows the "Terminal Theme" token.
    var isThemeMode: Bool {
        switch mode {
        case .themePicker, .themeScope: return true
        case .search, .renameTab, .renameSpace: return false
        }
    }

    /// The theme awaiting an apply scope, while in the scope stage.
    var themeScopeName: String? {
        if case .themeScope(let name) = mode { return name }
        return nil
    }

    /// Test hook: whether the local key monitor is currently installed.
    var isMonitorInstalled: Bool { monitor != nil }

    var inputPlaceholder: String {
        switch mode {
        case .search: "Search tabs, commands or processes"
        case .renameTab: "New tab name…"
        case .renameSpace: "New space name…"
        case .themePicker: "Search Themes"
        case .themeScope: ""
        }
    }

    private weak var store: TerminalSessionStore?
    /// Injected by CommandCenterView: opening the custom settings Window
    /// scene needs SwiftUI's environment openWindow action.
    var openWindow: OpenWindowAction?
    // Freed from deinit, which is nonisolated under strict concurrency.
    nonisolated(unsafe) private var monitor: Any?
    /// KeyDowns we swallowed whose keyUp hasn't arrived yet. The monitor
    /// outlives close() until this drains — otherwise the release lands on
    /// the refocused terminal and kitty-protocol TUIs act on it.
    private var swallowedKeyCodes = Set<UInt16>()

    private init() {}

    func attach(to store: TerminalSessionStore) {
        self.store = store
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard store != nil, !isOpen else { return }
        mode = .search
        submenuItems = nil
        hoverAnchor = nil
        query = ""
        highlightedIndex = 0
        rebuild()
        isOpen = true

        // The previous close's monitor may still be draining swallowed
        // keyUps; reuse it. Installing a second would orphan the first,
        // and orphaned monitors turn every Enter into "New Terminal".
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                self?.handleKey(event) ?? event
            }
        }
    }

    /// ⇧⌘P: opens straight into the ">" command filter.
    func openCommandMode() {
        if !isOpen {
            open()
        } else if !isPlainSearch {
            // Already open in a transient mode (theme flow, rename, or an open
            // submenu): drop back to plain search first — cancelling any live
            // preview — so "> " filters commands instead of wedging the token
            // flow (query "> " would otherwise filter themes to "No matches").
            resetToSearch()
        }
        query = "> "
        // Focusing the field selects its contents (so typing would erase
        // the prefix); park the cursor at the end once focus settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let editor = NSApp.keyWindow?.fieldEditor(false, for: nil) as? NSTextView else { return }
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
    }

    func close() {
        guard isOpen else { return }
        // Dismissing mid-preview (Esc, click-away) reverts the terminal to
        // the committed theme; after a commit this is a no-op.
        TerminalThemeManager.shared.cancelPreview()
        isOpen = false
        mode = .search
        removeMonitorWhenDrained()
        // Hand the keyboard back to the visible terminal.
        GhosttySurfaceManager.shared.restoreFocus(to: store?.selection)
    }

    /// Returns the open palette to plain search from any transient mode (theme
    /// flow, rename, or an open submenu), cancelling an uncommitted theme
    /// preview on the way out. The caller sets the query afterwards, which
    /// rebuilds against the now-restored `.search` mode.
    private func resetToSearch() {
        themePreviewArmed = false
        TerminalThemeManager.shared.cancelPreview()
        submenuItems = nil
        mode = .search
    }

    func execute(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        if item.keepsOpen {
            item.perform()
        } else {
            close()
            item.perform()
        }
    }

    // MARK: - Rename modes

    private func beginRename() {
        guard let store, let selection = store.selection,
              let session = store.sessions.first(where: { $0.id == selection })
        else {
            close()
            return
        }
        mode = .renameTab(selection)
        query = session.title
    }

    private func beginSpaceRename() {
        guard let store else {
            close()
            return
        }
        let space = store.activeSpace
        mode = .renameSpace(space.id)
        query = space.name
    }

    private func commitRename() {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .renameTab(let sessionID):
            if let store, let session = store.sessions.first(where: { $0.id == sessionID }), !name.isEmpty {
                store.rename(session, to: name)
            }
        case .renameSpace(let spaceID):
            store?.renameSpace(spaceID, to: name)
        case .search, .themePicker, .themeScope:
            break
        }
        close()
    }

    private func cancelRename() {
        mode = .search
        query = ""
    }

    // MARK: - Theme picker flow

    /// "Change Terminal Theme" → token mode listing themes, previewing live.
    private func beginThemePicker() {
        guard store != nil else {
            close()
            return
        }
        themePreviewArmed = false
        mode = .themePicker
        query = "" // didSet rebuilds into the theme list
        parkHighlightOnCurrentTheme()
        // The list just replaced the command menu under the (likely
        // stationary) cursor; ignore hover until the mouse moves so the parked
        // highlight survives.
        hoverAnchor = NSEvent.mouseLocation
        themePreviewArmed = true
    }

    /// Backspace on an empty query pops the token back to plain search.
    private func exitThemePicker() {
        themePreviewArmed = false
        TerminalThemeManager.shared.cancelPreview()
        mode = .search
        query = ""
    }

    /// Enter on a theme row: keep previewing it and ask for the apply scope.
    private func beginThemeScope(_ name: String) {
        TerminalThemeManager.shared.preview(name)
        mode = .themeScope(name)
        query = ""
        // Scope rows replaced the theme list under a stationary cursor.
        hoverAnchor = NSEvent.mouseLocation
    }

    /// Esc/backspace out of the scope step back to the list, still previewing.
    private func backToThemePicker(highlighting name: String?) {
        themePreviewArmed = false
        mode = .themePicker
        query = ""
        if let name, let index = items.firstIndex(where: { $0.id == "theme-\(name)" }) {
            highlightedIndex = index
        }
        // The list replaced the scope rows under a stationary cursor; hold off
        // hover so the restored highlight isn't clobbered.
        hoverAnchor = NSEvent.mouseLocation
        themePreviewArmed = true
    }

    private func commitTheme(_ name: String, scope: TerminalThemeManager.Scope) {
        // Commit first: it clears the preview flag, so close() won't revert
        // the freshly applied colors.
        TerminalThemeManager.shared.commit(name, scope: scope)
        close()
    }

    /// Live preview: the terminal recolors as the highlight moves through the
    /// theme list (arrow keys and hover both land here via highlightedIndex).
    private func previewHighlightedThemeIfNeeded() {
        guard themePreviewArmed, case .themePicker = mode,
              items.indices.contains(highlightedIndex)
        else { return }
        let id = items[highlightedIndex].id
        guard id.hasPrefix("theme-") else { return }
        TerminalThemeManager.shared.preview(String(id.dropFirst("theme-".count)))
    }

    /// Opening the picker parks the highlight on the current theme (visible
    /// as its muted "Current" tag), so nothing recolors until the user moves.
    private func parkHighlightOnCurrentTheme() {
        guard let store,
              let current = TerminalThemeManager.shared.effectiveThemeName(forSpace: store.activeSpaceID),
              let index = items.firstIndex(where: { $0.id == "theme-\(current)" })
        else { return }
        highlightedIndex = index
    }

    /// "Recent" (recently applied) then "All Themes", both query-filtered.
    private func themePickerItems() -> [PaletteItem] {
        guard let store else { return [] }
        let manager = TerminalThemeManager.shared
        let current = manager.effectiveThemeName(forSpace: store.activeSpaceID)

        func item(_ name: String, section: PaletteItem.Section) -> PaletteItem {
            PaletteItem(
                id: "theme-\(name)",
                icon: .themeAccent(name),
                title: name,
                context: name == current ? "Current" : nil,
                verb: "Select",
                section: section,
                keepsOpen: true
            ) { [weak self] in
                self?.beginThemeScope(name)
            }
        }

        let recents = manager.recentThemeNames.filter { manager.themes.contains($0) }
        let recentItems = recents.map { item($0, section: .recentThemes) }
        let allItems = manager.themes
            .filter { !recents.contains($0) }
            .map { item($0, section: .allThemes) }

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return recentItems + allItems }
        return Self.filter(recentItems, query: trimmed) + Self.filter(allItems, query: trimmed)
    }

    /// "Apply theme for": the active space (named) or everywhere.
    private func themeScopeItems(theme name: String) -> [PaletteItem] {
        guard let store else { return [] }
        let space = store.activeSpace
        return [
            PaletteItem(
                id: "scope-this-space",
                icon: .space(space.icon),
                title: "This Space",
                context: space.name.isEmpty ? nil : space.name,
                verb: "Apply",
                section: .themeScope,
                keepsOpen: true
            ) { [weak self] in
                self?.commitTheme(name, scope: .thisSpace(space.id))
            },
            PaletteItem(
                id: "scope-all-spaces",
                icon: .symbol("square.grid.2x2"),
                title: "All Spaces",
                context: nil,
                verb: "Apply",
                section: .themeScope,
                keepsOpen: true
            ) { [weak self] in
                self?.commitTheme(name, scope: .allSpaces)
            },
        ]
    }

    // MARK: - Keyboard

    func handleKey(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyUp {
            guard swallowedKeyCodes.remove(event.keyCode) != nil else { return event }
            removeMonitorWhenDrained()
            return nil
        }
        // Closed palette: the monitor only lingers to drain swallowed
        // keyUps; keyDowns belong to the terminal.
        guard isOpen else { return event }
        // Registered before the action runs: Enter/Esc close() the palette
        // mid-handling, and close's drain check must count this key as
        // pending or it tears the monitor down before the keyUp arrives.
        swallowedKeyCodes.insert(event.keyCode)
        let result = handleKeyDown(event)
        if result != nil {
            swallowedKeyCodes.remove(event.keyCode)
            removeMonitorWhenDrained()
        }
        return result
    }

    /// Drops the monitor once the palette is closed and every swallowed
    /// key has been released.
    private func removeMonitorWhenDrained() {
        guard !isOpen, swallowedKeyCodes.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if isRenaming {
            switch event.keyCode {
            case 53: // esc backs out to the search sheet
                cancelRename()
                return nil
            case 36, 76: // return / keypad enter
                commitRename()
                return nil
            default:
                return event
            }
        }

        // Theme-flow specific keys before the shared navigation handling.
        switch mode {
        case .themePicker:
            if event.keyCode == 51, query.isEmpty { // ⌫ on empty query pops the token
                exitThemePicker()
                return nil
            }
        case .themeScope(let name):
            switch event.keyCode {
            case 51, 53: // ⌫ / esc step back to the theme list, still previewing
                backToThemePicker(highlighting: name)
                return nil
            case 125, 126, 36, 76:
                break // shared arrows/enter below
            default:
                // The scope step takes no text; swallow stray typing so the
                // field stays empty. ⌘-chords still pass through.
                if !event.modifierFlags.contains(.command) {
                    return nil
                }
            }
        case .search, .renameTab, .renameSpace:
            break
        }

        switch event.keyCode {
        case 53: // esc backs out of a submenu first, then closes
            if submenuItems != nil {
                submenuItems = nil
                query = ""
            } else {
                close()
            }
            return nil
        case 125: // down
            moveHighlight(1)
            return nil
        case 126: // up
            moveHighlight(-1)
            return nil
        case 36, 76: // return / keypad enter
            execute(highlightedIndex)
            return nil
        default:
            break
        }

        // ⌘1–9 executes the corresponding visible row directly.
        if event.modifierFlags.contains(.command),
           let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
           (1...9).contains(digit) {
            execute(digit - 1)
            return nil
        }

        return event
    }

    private func moveHighlight(_ delta: Int) {
        guard !items.isEmpty else { return }
        highlightedIndex = (highlightedIndex + delta + items.count) % items.count
    }

    /// A row reported hover. Honored only once the mouse has moved since the
    /// last stage transition, so rows rearranged under a stationary cursor
    /// don't steal the highlight (and re-fire the theme preview).
    func hoverHighlight(_ index: Int) {
        if let anchor = hoverAnchor {
            guard NSEvent.mouseLocation != anchor else { return }
            hoverAnchor = nil
        }
        guard items.indices.contains(index) else { return }
        highlightedIndex = index
    }

    // MARK: - Results

    private func rebuild() {
        switch mode {
        case .renameTab, .renameSpace:
            // Rename mode: the query is the new tab name, not a search.
            return
        case .themePicker:
            items = themePickerItems()
            highlightedIndex = 0
            return
        case .themeScope(let name):
            items = themeScopeItems(theme: name)
            highlightedIndex = 0
            return
        case .search:
            break
        }
        guard let store else {
            items = []
            return
        }

        // Submenu mode: only the submenu's options, filtered.
        if let submenuItems {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            items = trimmed.isEmpty ? submenuItems : Self.filter(submenuItems, query: trimmed)
            highlightedIndex = 0
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(">") {
            // VS Code-style command filter: "> " shows commands only.
            let commandQuery = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            let commands = commandItems(in: store)
            items = commandQuery.isEmpty ? commands : Self.filter(commands, query: commandQuery)
        } else if trimmed.isEmpty {
            // Default sheet: "Suggestions" up top with the new-tab actions
            // (Enter opens a fresh tab, as before the redesign), four recent
            // tabs from the current space, then a short "Commands" menu,
            // with other spaces below the fold.
            items = newTabItems(in: store, section: .suggestions)
                + Array(recentTabItems(in: store).prefix(4))
                + menuCommandItems(in: store)
                + extraSpaceItems(in: store)
        } else {
            // Filtered results stay grouped by kind so section headers read
            // cleanly: tabs, then spaces, then commands — each sorted by score.
            items = Self.filter(tabItems(in: store), query: trimmed)
                + Self.filter(spaceItems(in: store), query: trimmed)
                + Self.filter(commandItems(in: store), query: trimmed)
        }
        highlightedIndex = 0
    }

    /// Fuzzy-filters items by title (and hidden aliases, so e.g. "ghostty
    /// theme" finds "Change Terminal Theme") and sorts survivors by score.
    private static func filter(_ candidates: [PaletteItem], query: String) -> [PaletteItem] {
        candidates
            .compactMap { item -> (PaletteItem, Int)? in
                let haystacks = [item.title] + item.aliases
                guard let score = haystacks.compactMap({ fuzzyScore(query: query, in: $0) }).max()
                else { return nil }
                return (item, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Every tab across all spaces, recency-ordered — the search corpus.
    private func tabItems(in store: TerminalSessionStore) -> [PaletteItem] {
        store.recencyOrderedSessionsAcrossSpaces().map { session, space in
            tabItem(for: session, in: space, store: store)
        }
    }

    /// The default sheet's "Recent Tabs": current space only.
    private func recentTabItems(in store: TerminalSessionStore) -> [PaletteItem] {
        let space = store.activeSpace
        return store.recencyOrderedSessions(inSpace: space.id).map { session in
            tabItem(for: session, in: space, store: store)
        }
    }

    private func tabItem(
        for session: TerminalSession,
        in space: SidebarSpace,
        store: TerminalSessionStore
    ) -> PaletteItem {
        let folder = Self.folder(of: session.id, in: space)
        return PaletteItem(
            id: "tab-\(session.id)",
            icon: .accent(session.accent.color),
            title: session.title,
            context: folder?.title,
            contextSymbol: folder == nil ? nil : "folder",
            verb: "Switch",
            section: .recentTabs,
            kindLabel: "Tab"
        ) { [weak store] in
            store?.reveal(session.id)
        }
    }

    /// The sidebar folder a tab lives in, if any.
    private static func folder(of sessionID: TerminalSession.ID, in space: SidebarSpace) -> TerminalFolder? {
        space.pinnedFolders.first { $0.sessions.contains { $0.id == sessionID } }
    }

    private func spaceItems(in store: TerminalSessionStore) -> [PaletteItem] {
        store.spaces.map { space in
            PaletteItem(
                id: "space-\(space.id)",
                icon: .space(space.icon),
                title: space.name,
                context: nil,
                verb: "Go",
                section: .spaces,
                kindLabel: "Space"
            ) { [weak store] in
                store?.setActiveSpace(space.id)
            }
        }
    }

    /// Spaces other than the active one — the only ones worth switching to
    /// from the default sheet. Collapses the "Spaces" section when there is
    /// nowhere else to go.
    private func extraSpaceItems(in store: TerminalSessionStore) -> [PaletteItem] {
        spaceItems(in: store).filter { $0.id != "space-\(store.activeSpaceID)" }
    }

    private func newTabItems(
        in store: TerminalSessionStore,
        section: PaletteItem.Section = .commands
    ) -> [PaletteItem] {
        var items: [PaletteItem] = []
        items.append(PaletteItem(
            id: "cmd-new-tab",
            icon: .symbol("plus.square"),
            title: "New Tab",
            context: nil,
            verb: "Open",
            section: section
        ) { [weak store] in
            store?.createSession(workingDirectory: NSHomeDirectory())
        })
        if let selection = store.selection,
           let folder = Self.folder(of: selection, in: store.activeSpace) {
            // The selected tab lives in a sidebar folder: new siblings go
            // into that folder.
            items.append(PaletteItem(
                id: "cmd-new-tab-folder",
                icon: .symbol("folder.badge.plus"),
                title: "New Tab in Current Folder",
                context: folder.title,
                contextSymbol: "folder",
                verb: "Open",
                section: section
            ) { [weak store] in
                store?.createSession(inFolder: folder.id)
            })
        } else if let current = store.selectedSession {
            // Loose tab: "folder" means the working directory instead.
            let cwd = current.workingDirectory
            items.append(PaletteItem(
                id: "cmd-new-tab-cwd",
                icon: .symbol("folder.badge.plus"),
                title: "New Tab in Current Folder",
                context: Self.folderName(for: cwd),
                verb: "Open",
                section: section
            ) { [weak store] in
                store?.createSession(besideSelectionWithWorkingDirectory: cwd)
            })
        }
        return items
    }

    /// The short "Commands" menu shown under the recent tabs on the empty
    /// sheet — the handful the mock surfaces, not the full command list
    /// (that appears once you start typing).
    /// "Change Appearance" option sheet: System / Light / Dark, with the
    /// active choice marked. Selecting one applies and closes.
    private func openAppearanceMenu() {
        let current = AppAppearance.current
        func option(_ value: AppAppearance, _ title: String, _ icon: String) -> PaletteItem {
            PaletteItem(
                id: "appearance-\(value.rawValue)",
                icon: .symbol(icon),
                title: title,
                context: current == value ? "Current" : nil,
                verb: "Apply",
                section: .appearance
            ) {
                AppAppearance.set(value)
            }
        }
        submenuItems = [
            option(.system, "System", "circle.lefthalf.filled"),
            option(.light, "Light", "sun.max"),
            option(.dark, "Dark", "moon"),
        ]
        highlightedIndex = 0
        query = ""
    }

    private func menuCommandItems(in store: TerminalSessionStore) -> [PaletteItem] {
        // New-tab items live in the "Suggestions" section up top on the
        // default sheet, so the menu carries only the rest.
        var items: [PaletteItem] = []
        if store.selection != nil {
            items.append(PaletteItem(
                id: "cmd-auto-rename-tab",
                icon: .symbol("pencil"),
                title: "Auto Rename Tab",
                context: nil,
                verb: "Run"
            ) { [weak store] in
                guard let store, let selection = store.selection else { return }
                TabAutoNamer.shared.forceName(selection)
            })
        }
        items.append(changeThemeItem())
        items.append(PaletteItem(
            id: "cmd-settings",
            icon: .symbol("gearshape"),
            title: "Settings",
            context: nil,
            verb: "Run"
        ) { [weak self] in
            self?.openWindow?(id: SettingsPanel.windowID)
        })
        return items
    }

    /// Entry point into the theme flow, surfaced on the default sheet's menu
    /// and in the full command list. The aliases make loose queries land:
    /// "theme", "ghostty theme", "terminal theme", even typos like "hteme"
    /// (the fuzzy subsequence walk finds h-t-e-m-e inside the title).
    private func changeThemeItem() -> PaletteItem {
        PaletteItem(
            id: "cmd-change-theme",
            icon: .symbol("paintpalette"),
            title: "Change Terminal Theme",
            context: nil,
            verb: "Open",
            aliases: ["ghostty theme", "terminal theme", "theme", "color scheme", "colors"],
            keepsOpen: true
        ) { [weak self] in
            self?.beginThemePicker()
        }
    }

    /// The full path never fits the narrow context column, so show just the
    /// deepest folder name.
    private static func folderName(for path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded != NSHomeDirectory(), expanded != "/" else { return "~" }
        return (expanded as NSString).lastPathComponent
    }

    private func commandItems(in store: TerminalSessionStore) -> [PaletteItem] {
        var commands = newTabItems(in: store)

        commands.append(PaletteItem(
            id: "cmd-new-folder",
            icon: .symbol("folder.badge.plus"),
            title: "New Folder",
            context: nil,
            verb: "Run"
        ) { [weak store] in
            store?.createFolder()
        })

        commands.append(PaletteItem(
            id: "cmd-new-space",
            icon: .symbol("rectangle.stack.badge.plus"),
            title: "New Space",
            context: nil,
            verb: "Run"
        ) { [weak store] in
            store?.createSpace(name: "", icon: .dot)
        })

        commands.append(PaletteItem(
            id: "cmd-check-updates",
            icon: .symbol("arrow.down.circle"),
            title: "Check for Updates",
            context: nil,
            verb: "Run"
        ) { [weak store] in
            // All update feedback lives in the sidebar card; surface it.
            store?.isSidebarVisible = true
            UpdateController.shared.checkForUpdates()
        })

        commands.append(PaletteItem(
            id: "cmd-toggle-appearance",
            icon: .symbol("circle.lefthalf.filled"),
            title: "Toggle Light/Dark Mode",
            context: nil,
            verb: "Run"
        ) {
            AppAppearance.toggle()
        })

        commands.append(PaletteItem(
            id: "cmd-change-appearance",
            icon: .symbol("paintbrush"),
            title: "Change Appearance",
            context: nil,
            verb: "Open",
            keepsOpen: true
        ) { [weak self] in
            self?.openAppearanceMenu()
        })

        commands.append(changeThemeItem())

        if let selection = store.selection {
            commands.append(PaletteItem(
                id: "cmd-rename-tab",
                icon: .symbol("pencil"),
                title: "Rename Tab",
                context: nil,
                verb: "Rename",
                keepsOpen: true
            ) { [weak self] in
                self?.beginRename()
            })

            commands.append(PaletteItem(
                id: "cmd-auto-rename-tab",
                icon: .symbol("pencil"),
                title: "Auto Rename Tab",
                context: nil,
                verb: "Run"
            ) { [weak store] in
                guard let store, let selection = store.selection else { return }
                TabAutoNamer.shared.forceName(selection)
            })

            commands.append(PaletteItem(
                id: "cmd-duplicate-tab",
                icon: .symbol("plus.square.on.square"),
                title: "Duplicate Tab",
                context: nil,
                verb: "Open"
            ) { [weak store] in
                guard let store, let selection = store.selection,
                      let current = store.sessions.first(where: { $0.id == selection })
                else { return }
                store.createSession(workingDirectory: current.workingDirectory)
            })

            let pinned = store.isPinned(selection)
            commands.append(PaletteItem(
                id: "cmd-toggle-pin",
                icon: .symbol(pinned ? "pin.slash" : "pin"),
                title: pinned ? "Unpin Tab" : "Pin Tab",
                context: nil,
                verb: "Run"
            ) { [weak store] in
                guard let store, let selection = store.selection else { return }
                if store.isPinned(selection) {
                    store.unpin([selection], inSpace: store.activeSpaceID)
                } else {
                    store.pin([selection], inSpace: store.activeSpaceID)
                }
            })

            commands.append(PaletteItem(
                id: "cmd-close-tab",
                icon: .symbol("xmark"),
                title: "Close Tab",
                context: nil,
                verb: "Run"
            ) { [weak store] in
                store?.closeSelectedSession()
            })

            commands.append(PaletteItem(
                id: "cmd-close-other-tabs",
                icon: .symbol("xmark.circle"),
                title: "Close Other Tabs",
                context: nil,
                verb: "Run"
            ) { [weak store] in
                guard let store, let selection = store.selection else { return }
                let others = store.activeSpace.sessions.map(\.id).filter { $0 != selection }
                guard !others.isEmpty else { return }
                store.close(sessionIDs: Set(others))
            })

            commands.append(PaletteItem(
                id: "cmd-copy-cwd",
                icon: .symbol("doc.on.clipboard"),
                title: "Copy Working Directory",
                context: nil,
                verb: "Copy"
            ) { [weak store] in
                guard let store, let selection = store.selection,
                      let session = store.sessions.first(where: { $0.id == selection })
                else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.workingDirectory, forType: .string)
            })

            commands.append(PaletteItem(
                id: "cmd-open-in-finder",
                icon: .symbol("folder"),
                title: "Open in Finder",
                context: nil,
                verb: "Open"
            ) { [weak store] in
                guard let store, let selection = store.selection,
                      let session = store.sessions.first(where: { $0.id == selection })
                else { return }
                NSWorkspace.shared.open(URL(fileURLWithPath: session.workingDirectory, isDirectory: true))
            })

            for space in store.spaces where space.id != store.activeSpaceID {
                commands.append(PaletteItem(
                    id: "cmd-move-\(space.id)",
                    icon: .space(space.icon),
                    title: "Move Tab to \(space.name)",
                    context: nil,
                    verb: "Run"
                ) { [weak store] in
                    guard let store, let selection = store.selection else { return }
                    store.unpin([selection], inSpace: space.id)
                    store.reveal(selection)
                })
            }
        }

        commands.append(PaletteItem(
            id: "cmd-rename-space",
            icon: .symbol("pencil.and.outline"),
            title: "Rename Space",
            context: nil,
            verb: "Rename",
            keepsOpen: true
        ) { [weak self] in
            self?.beginSpaceRename()
        })

        commands.append(PaletteItem(
            id: "cmd-toggle-sidebar",
            icon: .symbol("sidebar.left"),
            title: store.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
            context: nil,
            verb: "Run"
        ) { [weak store] in
            store?.isSidebarVisible.toggle()
        })

        commands.append(PaletteItem(
            id: "cmd-settings",
            icon: .symbol("gearshape"),
            title: "Settings",
            context: nil,
            verb: "Run"
        ) { [weak self] in
            self?.openWindow?(id: SettingsPanel.windowID)
        })

        return commands
    }

    /// Case-insensitive subsequence match with bonuses for prefix, word
    /// starts, and consecutive runs. Returns nil when the query doesn't match.
    static func fuzzyScore(query: String, in candidate: String) -> Int? {
        let query = Array(query.lowercased())
        let candidate = Array(candidate.lowercased())
        guard !query.isEmpty else { return 0 }

        var score = 0
        var queryIndex = 0
        var lastMatch = -1

        for (index, char) in candidate.enumerated() where queryIndex < query.count {
            guard char == query[queryIndex] else { continue }
            if index == 0 {
                score += 5
            } else if candidate[index - 1] == " " || candidate[index - 1] == "-" {
                score += 3
            }
            if lastMatch == index - 1 {
                score += 2
            }
            score += 1
            lastMatch = index
            queryIndex += 1
        }

        return queryIndex == query.count ? score : nil
    }
}

struct PaletteItem: Identifiable {
    enum Icon {
        case accent(Color)
        /// A theme's accent bullet, carried as the theme NAME so the color is
        /// resolved (and cached) at render time — the LazyVStack then parses
        /// only the theme files whose rows are actually on screen.
        case themeAccent(String)
        case space(SidebarSpace.Icon)
        case symbol(String)
    }

    /// Drives the grouped section headers in the palette.
    enum Section: String {
        case suggestions = "Suggestions"
        case appearance = "Change Appearance To"
        case recentTabs = "Recent Tabs"
        case spaces = "Spaces"
        case commands = "Commands"
        case recentThemes = "Recent"
        case allThemes = "All Themes"
        case themeScope = "Apply Theme For"
    }

    let id: String
    let icon: Icon
    let title: String
    let context: String?
    /// Small SF Symbol shown before the trailing context text (e.g. a
    /// folder glyph next to a folder name).
    var contextSymbol: String? = nil
    let verb: String
    /// Which grouped section this row falls under.
    var section: Section = .commands
    /// A dimmed suffix after the title naming the result kind ("Tab"),
    /// shown when a bare title is ambiguous among mixed results.
    var kindLabel: String? = nil
    /// Hidden search terms fuzzy-matched alongside the title, never shown
    /// (e.g. "ghostty theme" for "Change Terminal Theme").
    var aliases: [String] = []
    /// Items that transition the palette (rename mode) instead of acting.
    var keepsOpen: Bool = false
    let perform: () -> Void
}

// MARK: - View

struct CommandCenterView: View {
    @ObservedObject var center: CommandCenter
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    // Palette-only typography: SF Compact (installed via Apple's SF font
    // pack; bundle the faces before shipping). The variable "SF Compact"
    // for titles, Text for small labels. Symbols stay on .system.
    private func compactDisplay(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        PaletteFont.display(size, weight.bumped(for: colorScheme))
    }

    private func compactText(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        PaletteFont.text(size, weight.bumped(for: colorScheme))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: center.isRenaming ? "pencil" : "magnifyingglass")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.text(0.4))

                // The theme flow turns the field into a token input: a
                // "Terminal Theme" chip, plus the chosen theme's chip while
                // picking the apply scope.
                if center.isThemeMode {
                    chip(label: "Terminal Theme") {
                        Image(systemName: "paintpalette")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                }
                if let name = center.themeScopeName {
                    chip(label: name) {
                        Circle()
                            .fill(TerminalThemeManager.shared.accentColor(for: name))
                            .frame(width: 8, height: 8)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                }

                TextField(center.inputPlaceholder, text: $center.query)
                    .textFieldStyle(.plain)
                    .font(compactDisplay(18))
                    .foregroundStyle(Theme.text(0.92))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .animation(.easeOut(duration: 0.14), value: center.isThemeMode)
            .animation(.easeOut(duration: 0.14), value: center.themeScopeName)

            Rectangle()
                .fill(Theme.ink.opacity(0.06))
                .frame(height: 1)

            if center.isRenaming {
                HStack(spacing: 6) {
                    Text("↵ Rename")
                    Text("·")
                        .foregroundStyle(Theme.text(0.2))
                    Text("esc Cancel")
                }
                .font(compactText(12, .regular))
                .foregroundStyle(Theme.text(0.4))
                .padding(.vertical, 14)
            } else if center.items.isEmpty {
                Text("No matches")
                    .font(compactText(13))
                    .tracking(PaletteFont.tracking)
                    .foregroundStyle(Theme.text(0.35))
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Lazy: the theme picker lists every bundled Ghostty
                        // theme (~460 rows); eager row building would lag.
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(center.items.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || center.items[index - 1].section != item.section {
                                    sectionHeader(item.section.rawValue, isFirst: index == 0)
                                }
                                row(item, at: index)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 12)
                    }
                    .frame(maxHeight: 440)
                    // Inset the viewport itself: scrollTo pins the last row
                    // to the viewport's bottom edge, so in-content padding
                    // alone never shows under it.
                    .padding(.bottom, 10)
                    .onChange(of: center.highlightedIndex) { _, index in
                        guard center.items.indices.contains(index) else { return }
                        proxy.scrollTo(center.items[index].id)
                    }
                }
            }
        }
        .frame(width: 600)
        .paletteCardChrome()
        .onAppear {
            center.openWindow = openWindow
            // A beat later so focus wins over the terminal NSView, which is
            // first responder when the palette opens.
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
    }

    /// The rounded token badge the theme flow plants at the field's left: a
    /// leading glyph or accent dot, then a label. Used both for the "Terminal
    /// Theme" token and, during the scope step, the chosen theme's chip.
    private func chip<Leading: View>(
        label: String,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: 6) {
            leading()
            Text(label)
                .font(compactText(13, .medium))
                .tracking(PaletteFont.tracking)
        }
        .foregroundStyle(Theme.text(0.85))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.ink.opacity(0.1))
        )
        .fixedSize()
    }

    private func sectionHeader(_ title: String, isFirst: Bool) -> some View {
        Text(title)
            .font(compactText(13.5, .regular))
            .tracking(PaletteFont.tracking)
            .foregroundStyle(Theme.text(0.38))
            .padding(.leading, 16)
            .padding(.top, isFirst ? 6 : 18)
            .padding(.bottom, 6)
    }

    private func row(_ item: PaletteItem, at index: Int) -> some View {
        let isHighlighted = index == center.highlightedIndex

        return HStack(spacing: 14) {
            iconView(item.icon, isHighlighted: isHighlighted)
                .frame(width: 20, alignment: .center)

            HStack(spacing: 8) {
                Text(item.title)
                    .font(compactDisplay(16))
                    .tracking(PaletteFont.tracking)
                    .foregroundStyle(Theme.text(isHighlighted ? 0.98 : 0.85))
                    .lineLimit(1)

                if let kind = item.kindLabel {
                    Text(kind)
                        .font(compactDisplay(16))
                        .tracking(PaletteFont.tracking)
                        .foregroundStyle(Theme.text(0.28))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 16)

            if let context = item.context {
                HStack(spacing: 6) {
                    Text(context)
                        .font(compactText(15))
                        .tracking(PaletteFont.tracking)
                        .foregroundStyle(Theme.text(isHighlighted ? 0.5 : 0.38))
                        .lineLimit(1)
                    if let symbol = item.contextSymbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Theme.text(isHighlighted ? 0.45 : 0.34))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isHighlighted ? Theme.ink.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                center.hoverHighlight(index)
            }
        }
        .onTapGesture {
            center.execute(index)
        }
    }

    @ViewBuilder
    private func iconView(_ icon: PaletteItem.Icon, isHighlighted: Bool) -> some View {
        switch icon {
        case .accent(let color):
            Circle()
                .fill(color.opacity(isHighlighted ? 1 : 0.9))
                .frame(width: 9, height: 9)
        case .themeAccent(let themeName):
            Circle()
                .fill(TerminalThemeManager.shared.accentColor(for: themeName).opacity(isHighlighted ? 1 : 0.9))
                .frame(width: 9, height: 9)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Theme.text(isHighlighted ? 0.9 : 0.7))
        case .space(let spaceIcon):
            switch spaceIcon {
            case .dot:
                Circle()
                    .fill(Theme.ink.opacity(isHighlighted ? 0.9 : 0.55))
                    .frame(width: 9, height: 9)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Theme.text(isHighlighted ? 0.9 : 0.7))
            case .emoji(let emoji):
                Text(emoji)
                    .font(.system(size: 15))
                    .opacity(isHighlighted ? 1 : 0.7)
            }
        }
    }
}

// MARK: - Shared palette chrome

/// System font (SF Pro) for palette and chrome typography. The system face
/// is a real variable font: weights track the wght axis and Text/Display
/// optical sizing follows point size automatically, so both helpers resolve
/// the same way — they remain distinct only to keep call sites semantic.
/// (Bundled SF Compact was dropped: weight selection is inert for
/// ATS-registered variable fonts and rendered the Black default instance on
/// machines without Apple's dev font pack.)
enum PaletteFont {
    /// Gentle letterspacing across chrome text, on top of SF's own
    /// size-dependent tracking.
    static let tracking: CGFloat = 0.25

    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// SwiftUI materials clamp to a grey floor even over pure black; the raw HUD
/// material is the strongest real blur macOS offers. It follows the system
/// appearance, so the palette card frosts dark in dark mode, light in light.
struct PaletteBlurBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The floating-card look shared by the ⌘T palette and the Ctrl-Tab HUD: a
/// black-gradient blur card in front of a hollow blurred ring, separated
/// from the terminal by a diffused slab at the very back instead of a scrim.
struct PaletteCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(
                PaletteBlurBackdrop()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Theme.paletteCardTop,
                                        Theme.paletteCardBottom,
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    .shadow(color: .black.opacity(0.65), radius: 70, y: 30)
            )
            .padding(5)
            .background(
                // A hollow 5pt ring only — no fill behind the card, so the
                // ring's blur can't grey the card down. Radii stay
                // concentric (19 = 14 + 5).
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(.ultraThinMaterial, lineWidth: 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .strokeBorder(Theme.ink.opacity(0.15), lineWidth: 5)
                    )
            )
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .padding(-28)
                    .blur(radius: 55)
                    .offset(y: 22)
            )
    }
}

extension View {
    func paletteCardChrome() -> some View {
        modifier(PaletteCardChrome())
    }
}
