import Foundation
import SwiftUI

struct TerminalSession: Identifiable, Hashable {
    enum Status: String, CaseIterable {
        case running = "Running"
        case idle = "Idle"
        case attention = "Needs Attention"
    }

    let id: UUID
    var title: String
    var workingDirectory: String
    var branch: String?
    var status: Status
    var accent: SessionAccent
    var lastActivity: Date

    init(
        id: UUID = UUID(),
        title: String,
        workingDirectory: String,
        branch: String? = nil,
        status: Status = .running,
        accent: SessionAccent = .blue,
        lastActivity: Date = .now
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.branch = branch
        self.status = status
        self.accent = accent
        self.lastActivity = lastActivity
    }
}

enum SessionAccent: String, CaseIterable, Hashable {
    case blue
    case green
    case orange
    case pink
    case violet

    var color: Color {
        switch self {
        case .blue:
            .blue
        case .green:
            .green
        case .orange:
            .orange
        case .pink:
            .pink
        case .violet:
            .purple
        }
    }

    static func cycling(index: Int) -> SessionAccent {
        let accents = Self.allCases
        return accents[index % accents.count]
    }
}
