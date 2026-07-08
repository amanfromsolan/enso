import AppKit
import Combine
import SwiftUI

/// ⌘Q safety net. Quitting Enso kills every live terminal, so the first
/// quit request (⌘Q, app menu, or Dock) arms a short window and surfaces a
/// HUD instead of terminating; a second request inside the window quits for
/// real. Any other keypress, a click, or the timeout stands the guard down.
@MainActor
final class QuitGuard: ObservableObject {
    static let shared = QuitGuard()

    @Published private(set) var isShowingHUD = false
    /// Frozen when the guard arms so the HUD copy doesn't shift mid-display.
    @Published private(set) var sessionCount = 0

    private weak var store: TerminalSessionStore?
    private var expiry: DispatchWorkItem?
    // Freed from deinit, which is nonisolated under strict concurrency.
    nonisolated(unsafe) private var monitor: Any?

    func attach(store: TerminalSessionStore) {
        self.store = store
        guard monitor == nil else { return }

        // While armed, any interaction that isn't the quit chord means the
        // user kept working — dismiss rather than leave a live tripwire.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isShowingHUD else { return event }
            if event.type == .keyDown,
               event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "q" {
                return event // the re-quit lands via applicationShouldTerminate
            }
            self.disarm()
            if event.type == .keyDown, event.keyCode == 53 { // esc
                return nil // esc only dismisses; keep it out of the terminal
            }
            return event
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Called from applicationShouldTerminate for every quit path.
    /// Returns whether termination may proceed.
    func consentsToTerminate() -> Bool {
        // Nothing to lose, nothing to confirm.
        guard let store, !store.sessions.isEmpty else { return true }
        // No visible window means no HUD to explain a blocked quit — and it
        // covers logout/shutdown after windows close, where cancelling would
        // make macOS report that Enso interrupted shutdown.
        guard NSApp.windows.contains(where: \.isVisible) else { return true }

        if isShowingHUD {
            disarm()
            return true
        }
        arm(count: store.sessions.count)
        return false
    }

    private func arm(count: Int) {
        sessionCount = count
        isShowingHUD = true

        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.disarm()
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.75, execute: work)
    }

    private func disarm() {
        expiry?.cancel()
        expiry = nil
        isShowingHUD = false
    }
}

/// AppKit lifecycle hook for EnsoApp; SwiftUI has no native quit intercept.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitGuard.shared.consentsToTerminate() ? .terminateNow : .terminateCancel
    }
}

/// The frosted confirmation shown over the terminal on the first ⌘Q.
struct QuitConfirmationHUD: View {
    @ObservedObject var quitGuard: QuitGuard

    var body: some View {
        VStack(spacing: 0) {
            KeycapGlyph(label: "⌘Q")
                .padding(.bottom, 20)

            Text("Quit Enso?")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.bottom, 8)

            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)

            Text("Press ⌘Q again to quit")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
                // Tight hard shadow for definition + wide diffused one for depth.
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                .shadow(color: .black.opacity(0.65), radius: 70, y: 30)
        )
    }

    private var subtitle: String {
        quitGuard.sessionCount == 1
            ? "This will end your terminal session and anything running in it."
            : "This will end all \(quitGuard.sessionCount) terminal sessions and anything running in them."
    }
}

/// A rendered keyboard key: the icon doubles as the instruction.
private struct KeycapGlyph: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 21, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 0, y: 1.5)
            )
    }
}
