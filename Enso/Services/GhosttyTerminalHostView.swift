import AppKit
import SwiftUI

struct GhosttyTerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    let store: TerminalSessionStore

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(GhosttyRuntime.shared.themeBackground).cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
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
