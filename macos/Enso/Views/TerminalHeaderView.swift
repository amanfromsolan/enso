import SwiftUI

// The old full-width header strip above the terminal is gone: each pane
// draws its own in-pane header (see PaneHeaderView in
// GhosttyTerminalHostView.swift) so split dividers run edge to edge with
// no chrome across them. This file keeps the window-chrome helpers the
// strip used to own — they serve the root view's drag strips, the
// titlebar sidebar toggle, and the pane headers' ink math.

extension GhosttyRuntime {
    /// Pane headers sit on the Ghostty theme background, not the app
    /// chrome, so ink, artwork variants, and editing chrome all key off
    /// that color's luminance rather than the system appearance. The
    /// single home for the threshold — ink and badge must never disagree.
    var terminalColorScheme: ColorScheme {
        themeBackground.relativeLuminance > 0.179 ? .light : .dark
    }
}

extension Color {
    /// WCAG relative luminance (sRGB, linearized). Used to pick dark vs
    /// light ink against the terminal background; the 0.179 threshold is
    /// where black and white text reach equal contrast.
    var relativeLuminance: Double {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return 0 }
        func lin(_ channel: CGFloat) -> Double {
            let c = Double(channel)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(srgb.redComponent)
            + 0.7152 * lin(srgb.greenComponent)
            + 0.0722 * lin(srgb.blueComponent)
    }
}

#if DEBUG
/// Marks an "Enso Dev" window so it's never mistaken for the installed
/// Enso while dogfooding. Debug builds only.
struct DevBadge: View {
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
/// content — overlaid content's own gestures still win over it.
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
/// components, collapsing deep paths around an ellipsis. Drives the pane
/// headers' segmented breadcrumb (PaneHeaderBreadcrumb).
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
