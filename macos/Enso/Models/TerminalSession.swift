import AppKit
import Foundation
import SwiftUI

/// One entry in an ordered sidebar list — the pinned zone's top level or a
/// folder's children: a tab or a folder. Tabs and folders interleave
/// freely, and folders nest to arbitrary depth (a folder's children are
/// this same item type).
enum SidebarPinnedItem: Identifiable, Hashable, Codable {
    case tab(TerminalSession)
    case folder(TerminalFolder)

    var id: UUID {
        switch self {
        case .tab(let session): return session.id
        case .folder(let folder): return folder.id
        }
    }
}

/// Tree operations shared by every ordered item list (a space's pinned
/// zone and each folder's children). All traversals are depth-first in
/// visual order, so flattened results always match what the sidebar draws.
extension Array where Element == SidebarPinnedItem {
    /// Every tab in the subtree, in visual order.
    var allSessions: [TerminalSession] {
        flatMap { item -> [TerminalSession] in
            switch item {
            case .tab(let session): return [session]
            case .folder(let folder): return folder.items.allSessions
            }
        }
    }

    /// Every folder in the subtree, in visual order (parents before their
    /// subfolders).
    var allFolders: [TerminalFolder] {
        flatMap { item -> [TerminalFolder] in
            guard case .folder(let folder) = item else { return [] }
            return [folder] + folder.items.allFolders
        }
    }

    /// The folder with the given ID, wherever it nests.
    func firstFolder(_ folderID: TerminalFolder.ID) -> TerminalFolder? {
        for item in self {
            guard case .folder(let folder) = item else { continue }
            if folder.id == folderID { return folder }
            if let nested = folder.items.firstFolder(folderID) { return nested }
        }
        return nil
    }

    /// The folder whose DIRECT children include the given session, at any
    /// depth.
    func folder(directlyContaining sessionID: TerminalSession.ID) -> TerminalFolder? {
        for item in self {
            guard case .folder(let folder) = item else { continue }
            if folder.sessions.contains(where: { $0.id == sessionID }) { return folder }
            if let nested = folder.items.folder(directlyContaining: sessionID) { return nested }
        }
        return nil
    }

    /// The chain of folder IDs from the top level down to (and including)
    /// the given folder; nil when it isn't in this subtree. Expanding every
    /// ID on the path is what makes a nested folder actually visible.
    func folderPath(to folderID: TerminalFolder.ID) -> [TerminalFolder.ID]? {
        for item in self {
            guard case .folder(let folder) = item else { continue }
            if folder.id == folderID { return [folder.id] }
            if let nested = folder.items.folderPath(to: folderID) {
                return [folder.id] + nested
            }
        }
        return nil
    }

    /// The chain of folder IDs from the top level down to the folder that
    /// directly contains the given session; nil for loose/absent sessions.
    func folderPath(containingSession sessionID: TerminalSession.ID) -> [TerminalFolder.ID]? {
        for item in self {
            guard case .folder(let folder) = item else { continue }
            if folder.sessions.contains(where: { $0.id == sessionID }) { return [folder.id] }
            if let nested = folder.items.folderPath(containingSession: sessionID) {
                return [folder.id] + nested
            }
        }
        return nil
    }

    /// Mutates the folder with the given ID in place, wherever it nests;
    /// returns whether it was found.
    @discardableResult
    mutating func modifyFolder(
        _ folderID: TerminalFolder.ID,
        _ mutate: (inout TerminalFolder) -> Void
    ) -> Bool {
        for index in indices {
            guard case .folder(var folder) = self[index] else { continue }
            if folder.id == folderID {
                mutate(&folder)
                self[index] = .folder(folder)
                return true
            }
            if folder.items.modifyFolder(folderID, mutate) {
                self[index] = .folder(folder)
                return true
            }
        }
        return false
    }

    /// Mutates every folder in the subtree in place, parents before their
    /// subfolders.
    mutating func modifyFolders(_ mutate: (inout TerminalFolder) -> Void) {
        for index in indices {
            guard case .folder(var folder) = self[index] else { continue }
            mutate(&folder)
            folder.items.modifyFolders(mutate)
            self[index] = .folder(folder)
        }
    }

    /// Detaches and returns the folder with the given ID, wherever it
    /// nests; nil when absent.
    mutating func removeFolder(_ folderID: TerminalFolder.ID) -> TerminalFolder? {
        for index in indices {
            guard case .folder(var folder) = self[index] else { continue }
            if folder.id == folderID {
                remove(at: index)
                return folder
            }
            if let nested = folder.items.removeFolder(folderID) {
                self[index] = .folder(folder)
                return nested
            }
        }
        return nil
    }

    /// Dissolves the folder in place: its row disappears but its children
    /// (tabs and subfolders) splice into the containing list at the same
    /// position. Returns whether it was found.
    @discardableResult
    mutating func dissolveFolder(_ folderID: TerminalFolder.ID) -> Bool {
        for index in indices {
            guard case .folder(var folder) = self[index] else { continue }
            if folder.id == folderID {
                replaceSubrange(index...index, with: folder.items)
                return true
            }
            if folder.items.dissolveFolder(folderID) {
                self[index] = .folder(folder)
                return true
            }
        }
        return false
    }

    /// Inserts the given items immediately before the item with the given
    /// ID, in whatever list (this one or any nested folder's) the anchor
    /// lives. Returns whether the anchor was found.
    mutating func insert(_ newItems: [SidebarPinnedItem], beforeItem itemID: UUID) -> Bool {
        if let index = firstIndex(where: { $0.id == itemID }) {
            insert(contentsOf: newItems, at: index)
            return true
        }
        for index in indices {
            guard case .folder(var folder) = self[index] else { continue }
            if folder.items.insert(newItems, beforeItem: itemID) {
                self[index] = .folder(folder)
                return true
            }
        }
        return false
    }

    /// The same tree with one tab removed wherever it appears — the
    /// collapsed-folder peek renders that row outside the children
    /// container, and its identity must never exist twice in the view tree.
    func excludingSession(_ sessionID: TerminalSession.ID?) -> [SidebarPinnedItem] {
        guard let sessionID else { return self }
        return compactMap { item in
            switch item {
            case .tab(let session):
                return session.id == sessionID ? nil : item
            case .folder(var folder):
                folder.items = folder.items.excludingSession(sessionID)
                return .folder(folder)
            }
        }
    }
}

/// One swipeable sidebar page: its own pinned zone and ephemeral tabs.
struct SidebarSpace: Identifiable, Hashable, Codable {
    enum Icon: Hashable, Codable {
        case dot
        case symbol(String)
        case emoji(String)
    }

    let id: UUID
    var name: String
    var icon: Icon
    /// The pinned zone in exact visual order: loose tabs and folders in one
    /// interleaved list.
    var pinnedItems: [SidebarPinnedItem]
    var ephemeralSessions: [TerminalSession]
    var lastSelection: TerminalSession.ID?

    init(
        id: UUID = UUID(),
        name: String,
        icon: Icon = .dot,
        pinnedItems: [SidebarPinnedItem] = [],
        ephemeralSessions: [TerminalSession] = [],
        lastSelection: TerminalSession.ID? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.pinnedItems = pinnedItems
        self.ephemeralSessions = ephemeralSessions
        self.lastSelection = lastSelection
    }

    /// Two-array convenience matching the pre-interleaving model: loose tabs
    /// first, then folders — the visual order that model always produced.
    /// (`pinnedFolders` has no default so this can't collide with the
    /// designated init.)
    init(
        id: UUID = UUID(),
        name: String,
        icon: Icon = .dot,
        pinnedFolders: [TerminalFolder],
        pinnedSessions: [TerminalSession] = [],
        ephemeralSessions: [TerminalSession] = [],
        lastSelection: TerminalSession.ID? = nil
    ) {
        self.init(
            id: id,
            name: name,
            icon: icon,
            pinnedItems: pinnedSessions.map(SidebarPinnedItem.tab)
                + pinnedFolders.map(SidebarPinnedItem.folder),
            ephemeralSessions: ephemeralSessions,
            lastSelection: lastSelection
        )
    }

    /// Top-level pinned folders, in visual order (nested subfolders
    /// excluded — see `allFolders`).
    var pinnedFolders: [TerminalFolder] {
        pinnedItems.compactMap { item in
            if case .folder(let folder) = item { return folder }
            return nil
        }
    }

    /// Every pinned folder at every depth, in visual order (parents before
    /// their subfolders).
    var allFolders: [TerminalFolder] {
        pinnedItems.allFolders
    }

    /// Loose pinned tabs (folder members excluded), in visual order.
    var pinnedSessions: [TerminalSession] {
        pinnedItems.compactMap { item in
            if case .tab(let session) = item { return session }
            return nil
        }
    }

    var sessions: [TerminalSession] {
        pinnedItems.allSessions + ephemeralSessions
    }

    /// The pinned folder whose direct children include the given session,
    /// at any depth.
    func folder(containing sessionID: TerminalSession.ID) -> TerminalFolder? {
        pinnedItems.folder(directlyContaining: sessionID)
    }

    /// Mutates the folder with the given ID in place, wherever it nests;
    /// returns whether it was found.
    @discardableResult
    mutating func modifyFolder(
        _ folderID: TerminalFolder.ID,
        _ mutate: (inout TerminalFolder) -> Void
    ) -> Bool {
        pinnedItems.modifyFolder(folderID, mutate)
    }

    /// Mutates every pinned folder in place, at every depth.
    mutating func modifyFolders(_ mutate: (inout TerminalFolder) -> Void) {
        pinnedItems.modifyFolders(mutate)
    }

    // MARK: Codable

    // Custom codec so state files written by the two-array model keep
    // loading: absent `pinnedItems`, the legacy keys migrate forward as
    // loose-tabs-first-then-folders. New saves write only the new shape.

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, pinnedItems, pinnedFolders, pinnedSessions, ephemeralSessions, lastSelection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(Icon.self, forKey: .icon)
        ephemeralSessions = try container.decode([TerminalSession].self, forKey: .ephemeralSessions)
        lastSelection = try container.decodeIfPresent(TerminalSession.ID.self, forKey: .lastSelection)
        if let items = try container.decodeIfPresent([SidebarPinnedItem].self, forKey: .pinnedItems) {
            pinnedItems = items
        } else {
            let folders = try container.decodeIfPresent([TerminalFolder].self, forKey: .pinnedFolders) ?? []
            let sessions = try container.decodeIfPresent([TerminalSession].self, forKey: .pinnedSessions) ?? []
            pinnedItems = sessions.map(SidebarPinnedItem.tab) + folders.map(SidebarPinnedItem.folder)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(pinnedItems, forKey: .pinnedItems)
        // Dual-write the legacy two-array shape so a rollback to a build
        // that requires these keys still decodes (at worst with loose tabs
        // regrouped above folders) instead of wiping the state file.
        try container.encode(pinnedFolders, forKey: .pinnedFolders)
        try container.encode(pinnedSessions, forKey: .pinnedSessions)
        try container.encode(ephemeralSessions, forKey: .ephemeralSessions)
        try container.encodeIfPresent(lastSelection, forKey: .lastSelection)
    }
}

struct TerminalFolder: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    /// Ordered children in exact visual order: tabs and subfolders
    /// interleaved, nesting to arbitrary depth.
    var items: [SidebarPinnedItem]
    /// Last-known cwd of the folder's most recently active tab. A folder is,
    /// in practice, a project: this keeps the association alive after the
    /// last tab is gone so a new tab can start back in the project directory.
    /// Optional, so state files written before this field decode as nil.
    var lastWorkingDirectory: String?

    init(
        id: UUID = UUID(),
        title: String,
        items: [SidebarPinnedItem],
        lastWorkingDirectory: String? = nil
    ) {
        self.id = id
        self.title = title
        self.items = items
        self.lastWorkingDirectory = lastWorkingDirectory
    }

    /// Sessions-only convenience matching the pre-nesting model.
    /// (`sessions` has no default in the designated init's place — `items`
    /// does — so the two can't collide.)
    init(
        id: UUID = UUID(),
        title: String,
        sessions: [TerminalSession] = [],
        lastWorkingDirectory: String? = nil
    ) {
        self.init(
            id: id,
            title: title,
            items: sessions.map(SidebarPinnedItem.tab),
            lastWorkingDirectory: lastWorkingDirectory
        )
    }

    /// Direct child tabs, in order (subfolder members excluded).
    var sessions: [TerminalSession] {
        items.compactMap { item in
            if case .tab(let session) = item { return session }
            return nil
        }
    }

    /// Direct child folders, in order.
    var subfolders: [TerminalFolder] {
        items.compactMap { item in
            if case .folder(let folder) = item { return folder }
            return nil
        }
    }

    /// Every tab in the folder's subtree, in visual order.
    var allSessions: [TerminalSession] {
        items.allSessions
    }

    /// Whether the given folder nests anywhere in this folder's subtree
    /// (descendants only — a folder does not contain itself). The cycle
    /// check for every nesting mutation.
    func contains(folderID: TerminalFolder.ID) -> Bool {
        items.firstFolder(folderID) != nil
    }

    // MARK: Codable

    // Custom codec so state files written by the sessions-only model keep
    // loading: absent `items`, the legacy `sessions` key migrates forward
    // as tab children. Saves dual-write `sessions` (the subtree flattened)
    // so a rollback to a build that requires that key still decodes — at
    // worst with nested structure flattened, but no tab lost.

    private enum CodingKeys: String, CodingKey {
        case id, title, items, sessions, lastWorkingDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let title = try container.decode(String.self, forKey: .title)
        let lastWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .lastWorkingDirectory)
        if let items = try container.decodeIfPresent([SidebarPinnedItem].self, forKey: .items) {
            self.init(id: id, title: title, items: items, lastWorkingDirectory: lastWorkingDirectory)
        } else {
            let sessions = try container.decodeIfPresent([TerminalSession].self, forKey: .sessions) ?? []
            self.init(id: id, title: title, sessions: sessions, lastWorkingDirectory: lastWorkingDirectory)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(items, forKey: .items)
        try container.encode(allSessions, forKey: .sessions)
        try container.encodeIfPresent(lastWorkingDirectory, forKey: .lastWorkingDirectory)
    }
}

struct TerminalSession: Identifiable, Hashable, Codable {
    enum Status: String, CaseIterable, Codable {
        case running = "Running"
        case idle = "Idle"
        case attention = "Needs Attention"
    }

    /// Who last named the tab; higher origins are never overwritten by
    /// lower ones (user > auto > shell).
    enum TitleOrigin: String, Codable {
        /// Live shell-integration title; keeps updating as commands run.
        case shell
        /// One-shot LLM auto-name; freezes the title against shell updates.
        case auto
        /// Manual rename; nothing may touch it again.
        case user
    }

    let id: UUID
    var title: String
    var titleOrigin: TitleOrigin
    var workingDirectory: String
    var branch: String?
    var status: Status
    var accent: SessionAccent
    var lastActivity: Date
    /// Asleep: the tab keeps its row but its shell is gone — put down on
    /// purpose to free resources, with the working directory (and any agent
    /// conversation, via AgentSessionStore) saved for the wake. Persisted so
    /// a sleeping tab is still asleep after a relaunch. A plain flag rather
    /// than a status case so a future auto-sleep only has to flip it.
    var isSleeping: Bool
    /// What was detected in the foreground when the tab went to sleep;
    /// powers the sleeping card's "Claude was working in …" summary.
    /// Persisted with the flag (a relaunch must still know) and cleared on
    /// wake.
    var sleepingProcess: TabProcess?
    /// The surface's font size (⌘+/⌘- zoom) when the tab went to sleep,
    /// nil when it slept at the config default. Persisted with the flag so
    /// a wake — even after a relaunch — spawns the shell at the size the
    /// user left it. Cleared on wake, like sleepingProcess.
    var sleepingFontSize: Float?
    /// Live foreground-process detection; session-only, resets to a plain
    /// shell on relaunch, so it is not persisted.
    var runningProcess: TabProcess?

    /// The cwd the way people read it: home-relative with a tilde.
    var displayWorkingDirectory: String {
        (workingDirectory as NSString).abbreviatingWithTildeInPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, titleOrigin, workingDirectory, branch, status, accent, lastActivity,
             isSleeping, sleepingProcess, sleepingFontSize
    }

    init(
        id: UUID = UUID(),
        title: String,
        titleOrigin: TitleOrigin = .shell,
        workingDirectory: String,
        branch: String? = nil,
        status: Status = .running,
        accent: SessionAccent = .blue,
        lastActivity: Date = .now,
        isSleeping: Bool = false,
        sleepingProcess: TabProcess? = nil,
        sleepingFontSize: Float? = nil
    ) {
        self.id = id
        self.title = title
        self.titleOrigin = titleOrigin
        self.workingDirectory = workingDirectory
        self.branch = branch
        self.status = status
        self.accent = accent
        self.lastActivity = lastActivity
        self.isSleeping = isSleeping
        self.sleepingProcess = sleepingProcess
        self.sleepingFontSize = sleepingFontSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        // Absent in pre-auto-naming state files.
        titleOrigin = try container.decodeIfPresent(TitleOrigin.self, forKey: .titleOrigin) ?? .shell
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        status = try container.decode(Status.self, forKey: .status)
        accent = try container.decode(SessionAccent.self, forKey: .accent)
        lastActivity = try container.decode(Date.self, forKey: .lastActivity)
        // Absent in state files written before sleep shipped. The process
        // decode is tolerant on top: a raw value this build doesn't know
        // degrades to the plain-shell summary instead of failing the tab.
        isSleeping = try container.decodeIfPresent(Bool.self, forKey: .isSleeping) ?? false
        sleepingProcess = (try? container.decodeIfPresent(TabProcess.self, forKey: .sleepingProcess)) ?? nil
        sleepingFontSize = try container.decodeIfPresent(Float.self, forKey: .sleepingFontSize)
        runningProcess = nil
    }
}

enum SessionAccent: String, CaseIterable, Hashable, Codable {
    case blue
    case green
    case orange
    case pink
    case violet

    /// Jewel tones tuned for the dark frosted sidebar, plus deeper variants for
    /// the light sidebar. The pale dark-mode tones have almost no contrast on a
    /// light background, so light mode resolves to saturated, darker versions.
    var color: Color {
        let pair = hexPair
        return Color(nsColor: Theme.dynamic(
            dark: NSColor(hex: pair.dark),
            light: NSColor(hex: pair.light)
        ))
    }

    private var hexPair: (dark: UInt32, light: UInt32) {
        switch self {
        case .blue: (0x6FA8FF, 0x2F6FE0)
        case .green: (0x5BD9A9, 0x12A176)
        case .orange: (0xFFB454, 0xD97D0F)
        case .pink: (0xFF7EB6, 0xDE3F86)
        case .violet: (0xB18CFF, 0x7B4DE0)
        }
    }

    static func cycling(index: Int) -> SessionAccent {
        let accents = Self.allCases
        return accents[index % accents.count]
    }
}
