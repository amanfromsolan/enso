import SwiftUI

/// Slim strip above the terminal that doubles as the window titlebar:
/// blends into the terminal background, drags the window. Double-click on
/// the title renames; double-click on empty strip zooms like a real
/// titlebar. Shows the tab name plus a live breadcrumb of the shell's cwd.
struct TerminalHeaderView: View {
    let session: TerminalSession
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 8) {
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
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        #if DEBUG
        // Overlaid so the badge never pushes the centered title off-axis.
        .overlay(alignment: .trailing) {
            DevBadge()
                .frame(height: 22)
                .padding(.trailing, 12)
        }
        #endif
        // Drag + double-click-zoom handled in AppKit, not SwiftUI: a
        // WindowDragGesture claims the mouse-down to start dragging, so a
        // paired .onTapGesture(count: 2) never recognizes and zoom silently
        // did nothing. WindowDragHandle reads the raw clickCount instead.
        // Sits behind the title cluster, whose own double-click (rename)
        // keeps taking precedence.
        .background(WindowDragHandle())
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

#if DEBUG
/// Marks an "Enso Dev" window so it's never mistaken for the installed
/// Enso while dogfooding. Debug builds only.
private struct DevBadge: View {
    var body: some View {
        Text("DEV")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(Color.yellow.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.yellow.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.yellow.opacity(0.3), lineWidth: 1))
    }
}
#endif

/// Sidebar toggle rendered in the window titlebar beside the traffic
/// lights (see TrafficLightInset); quiet until hovered.
struct SidebarToggleButton: View {
    let isSidebarVisible: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text(isHovered ? 0.8 : 0.4))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.ink.opacity(isHovered ? 0.09 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isSidebarVisible ? "Hide Sidebar (⌘B)" : "Show Sidebar (⌘B)")
    }
}

/// AppKit shim that makes our custom titlebar strips behave like a real one:
/// single-click drags the window, double-click runs the system titlebar
/// action (zoom by default). We handle the raw mouseDown ourselves because
/// SwiftUI's WindowDragGesture eats the mouse-down to begin its own drag,
/// which starves any paired double-click tap. This is the same drag/double-
/// click split Ghostty uses for its titlebar (WindowDragView). Drop it behind
/// content — the title cluster's own rename gesture still wins over it.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        // We start the drag ourselves via performDrag, so AppKit must not
        // also move the window — that would swallow the mouseDown before we
        // can read its clickCount and tell a drag from a double-click.
        override var mouseDownCanMoveWindow: Bool { false }

        // Let an inactive window be dragged/zoomed on the first click, the
        // way a stock titlebar does.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // clickCount == 1 on the first press of a double-click too:
            // performDrag returns immediately if the mouse doesn't move, so
            // the release still lands as the second click and zooms.
            if event.clickCount >= 2 {
                window?.performTitlebarDoubleClickAction()
            } else {
                window?.performDrag(with: event)
            }
        }
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
        onRename: {}
    )
        .background(.black)
}
