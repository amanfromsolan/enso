import SwiftUI

/// Slim strip above the terminal that doubles as the window titlebar:
/// blends into the terminal background, drags the window. Double-click on
/// the title renames; double-click on empty strip zooms like a real
/// titlebar. Shows the tab name plus a live breadcrumb of the shell's cwd.
struct TerminalHeaderView: View {
    let session: TerminalSession
    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SidebarToggleButton(isSidebarVisible: isSidebarVisible, action: onToggleSidebar)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Circle()
                    .fill(session.accent.color.opacity(0.8))
                    .frame(width: 6, height: 6)

                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)

                breadcrumb
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onRename()
            }

            Spacer(minLength: 0)

            // Balances the toggle button so the title stays centered.
            Color.clear
                .frame(width: 26, height: 22)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .onTapGesture(count: 2) {
            NSApp.keyWindow?.performTitlebarDoubleClickAction()
        }
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        let trail = PathTrail(path: session.workingDirectory)

        return HStack(spacing: 4) {
            Image(systemName: trail.rootIcon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(trail.segments.isEmpty ? 0.42 : 0.3))

            if let rootLabel = trail.rootLabel {
                Text(rootLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.42))
            }

            ForEach(Array(trail.segments.enumerated()), id: \.offset) { index, segment in
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.18))

                Text(segment)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(
                        index == trail.segments.count - 1 ? 0.42 : 0.28
                    ))
                    .lineLimit(1)
            }
        }
    }
}

/// Sidebar toggle living at the leftmost of the terminal title strip;
/// quiet until hovered.
struct SidebarToggleButton: View {
    let isSidebarVisible: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(isHovered ? 0.8 : 0.4))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(isHovered ? 0.09 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isSidebarVisible ? "Hide Sidebar (⌘B)" : "Show Sidebar (⌘B)")
    }
}

extension NSWindow {
    /// Applies the system "double-click a window's title bar to" preference
    /// (zoom by default) to our custom titlebar strips.
    func performTitlebarDoubleClickAction() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            performMiniaturize(nil)
        case "None":
            break
        default:
            performZoom(nil)
        }
    }
}

/// Splits an absolute path into a friendly root (home / disk) plus trailing
/// components, collapsing deep paths around an ellipsis.
struct PathTrail {
    let rootIcon: String
    let rootLabel: String?
    let segments: [String]

    init(path: String) {
        let home = NSHomeDirectory()

        if path == home || path == "~" {
            rootIcon = "house.fill"
            rootLabel = "Home"
            segments = []
            return
        }

        var components: [String]
        if path.hasPrefix(home + "/") {
            rootIcon = "house.fill"
            rootLabel = nil
            components = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        } else {
            rootIcon = "internaldrive.fill"
            rootLabel = path == "/" ? "Macintosh HD" : nil
            components = path.split(separator: "/").map(String.init)
        }

        // Deep paths read as noise; keep the last two and hint at the rest.
        if components.count > 3 {
            components = ["…"] + components.suffix(2)
        }
        segments = components
    }
}

#Preview {
    TerminalHeaderView(
        session: TerminalSessionStore.preview.sessions[0],
        isSidebarVisible: true,
        onToggleSidebar: {},
        onRename: {}
    )
        .background(.black)
}
