import AppKit
import Foundation
import SwiftUI

/// One entry in the pinned zone's single ordered list: a loose tab or a
/// folder. Tabs and folders interleave freely; folders cannot nest.
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

    /// All pinned folders, in visual order.
    var pinnedFolders: [TerminalFolder] {
        pinnedItems.compactMap { item in
            if case .folder(let folder) = item { return folder }
            return nil
        }
    }

    /// Loose pinned tabs (folder members excluded), in visual order.
    var pinnedSessions: [TerminalSession] {
        pinnedItems.compactMap { item in
            if case .tab(let session) = item { return session }
            return nil
        }
    }

    var sessions: [TerminalSession] {
        pinnedItems.flatMap { item -> [TerminalSession] in
            switch item {
            case .tab(let session): return [session]
            case .folder(let folder): return folder.sessions
            }
        } + ephemeralSessions
    }

    /// Mutates the folder with the given ID in place; returns whether it
    /// was found.
    @discardableResult
    mutating func modifyFolder(
        _ folderID: TerminalFolder.ID,
        _ mutate: (inout TerminalFolder) -> Void
    ) -> Bool {
        for index in pinnedItems.indices {
            guard case .folder(var folder) = pinnedItems[index], folder.id == folderID else {
                continue
            }
            mutate(&folder)
            pinnedItems[index] = .folder(folder)
            return true
        }
        return false
    }

    /// Mutates every pinned folder in place.
    mutating func modifyFolders(_ mutate: (inout TerminalFolder) -> Void) {
        for index in pinnedItems.indices {
            guard case .folder(var folder) = pinnedItems[index] else { continue }
            mutate(&folder)
            pinnedItems[index] = .folder(folder)
        }
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
    var sessions: [TerminalSession]
    /// Last-known cwd of the folder's most recently active tab. A folder is,
    /// in practice, a project: this keeps the association alive after the
    /// last tab is gone so a new tab can start back in the project directory.
    /// Optional, so state files written before this field decode as nil.
    var lastWorkingDirectory: String?

    init(
        id: UUID = UUID(),
        title: String,
        sessions: [TerminalSession] = [],
        lastWorkingDirectory: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sessions = sessions
        self.lastWorkingDirectory = lastWorkingDirectory
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
    /// Live foreground-process detection; session-only, resets to a plain
    /// shell on relaunch, so it is not persisted.
    var runningProcess: TabProcess?

    private enum CodingKeys: String, CodingKey {
        case id, title, titleOrigin, workingDirectory, branch, status, accent, lastActivity
    }

    init(
        id: UUID = UUID(),
        title: String,
        titleOrigin: TitleOrigin = .shell,
        workingDirectory: String,
        branch: String? = nil,
        status: Status = .running,
        accent: SessionAccent = .blue,
        lastActivity: Date = .now
    ) {
        self.id = id
        self.title = title
        self.titleOrigin = titleOrigin
        self.workingDirectory = workingDirectory
        self.branch = branch
        self.status = status
        self.accent = accent
        self.lastActivity = lastActivity
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
