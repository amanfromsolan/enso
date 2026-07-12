import AppKit
import SwiftUI

struct GhosttyTerminalHostView: NSViewRepresentable {
    /// Optional so the container outlives any one session: swapping (or
    /// clearing) the surface happens inside a stable NSView in the same
    /// commit as SwiftUI's redraw. Destroying the representable instead
    /// tears the Metal layer down a frame late, flashing stale content.
    let session: TerminalSession?
    let store: TerminalSessionStore

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(GhosttyRuntime.shared.themeBackground).cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Track live theme changes; the container peeks through during
        // resizes and while no surface is mounted.
        container.layer?.backgroundColor = NSColor(GhosttyRuntime.shared.themeBackground).cgColor
        guard let session else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        let sessionID = session.id
        let surfaceView = GhosttySurfaceManager.shared.view(for: session)

        surfaceView.onTitleChange = { [weak store] title in
            store?.applyShellTitle(sessionID, title: title)
            TabAutoNamer.shared.noteActivity(sessionID)
        }
        surfaceView.onPwdChange = { [weak store] pwd in
            NSLog("GhosttyTerminalHostView: pwd -> %@", pwd)
            store?.updateWorkingDirectory(sessionID, to: pwd)
            TabAutoNamer.shared.noteActivity(sessionID)
        }
        surfaceView.onSurfaceClose = { [weak store] in
            store?.close(sessionID: sessionID)
        }

        guard surfaceView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        surfaceView.frame = container.bounds
        surfaceView.autoresizingMask = [.width, .height]
        container.addSubview(surfaceView)

        // While the ⌘T palette is up its search field owns the keyboard: a
        // tab mounted behind it (the theme flow's preview tab) must not grab
        // first responder or typing in the palette breaks. close() hands
        // focus back to the visible terminal when the palette dismisses.
        guard !CommandCenter.shared.isOpen else { return }
        if let window = container.window {
            window.makeFirstResponder(surfaceView)
        } else {
            // First appearance: the container isn't in a window yet.
            DispatchQueue.main.async {
                container.window?.makeFirstResponder(surfaceView)
            }
        }
    }
}
