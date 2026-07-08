import Foundation
import SwiftUI

/// One swipeable sidebar page: its own pinned/ephemeral tabs and folders.
struct SidebarSpace: Identifiable, Hashable, Codable {
    enum Icon: Hashable, Codable {
        case dot
        case symbol(String)
        case emoji(String)
    }

    let id: UUID
    var name: String
    var icon: Icon
    var pinnedFolders: [TerminalFolder]
    var pinnedSessions: [TerminalSession]
    var ephemeralSessions: [TerminalSession]
    var lastSelection: TerminalSession.ID?

    init(
        id: UUID = UUID(),
        name: String,
        icon: Icon = .dot,
        pinnedFolders: [TerminalFolder] = [],
        pinnedSessions: [TerminalSession] = [],
        ephemeralSessions: [TerminalSession] = [],
        lastSelection: TerminalSession.ID? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.pinnedFolders = pinnedFolders
        self.pinnedSessions = pinnedSessions
        self.ephemeralSessions = ephemeralSessions
        self.lastSelection = lastSelection
    }

    var sessions: [TerminalSession] {
        pinnedSessions + pinnedFolders.flatMap(\.sessions) + ephemeralSessions
    }
}

struct TerminalFolder: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var sessions: [TerminalSession]

    init(
        id: UUID = UUID(),
        title: String,
        sessions: [TerminalSession] = []
    ) {
        self.id = id
        self.title = title
        self.sessions = sessions
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

    /// Jewel tones tuned for the dark frosted sidebar: matched saturation
    /// and lightness so no dot shouts louder than the others.
    var color: Color {
        switch self {
        case .blue:
            Color(hex: 0x6FA8FF)
        case .green:
            Color(hex: 0x5BD9A9)
        case .orange:
            Color(hex: 0xFFB454)
        case .pink:
            Color(hex: 0xFF7EB6)
        case .violet:
            Color(hex: 0xB18CFF)
        }
    }

    static func cycling(index: Int) -> SessionAccent {
        let accents = Self.allCases
        return accents[index % accents.count]
    }
}
