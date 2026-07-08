import AppKit
import Combine
import SwiftUI

/// Ctrl-Tab MRU switcher. A quick tap flips to the last-used tab silently;
/// holding Ctrl surfaces a HUD listing the space's tabs in recency order,
/// each Tab walks the highlight (Shift reverses), releasing Ctrl commits and
/// Esc restores the origin. Cycling drives the real selection, so the live
/// terminal behind the HUD is the preview.
@MainActor
final class TabSwitcher: ObservableObject {
    @Published private(set) var isShowingHUD = false
    /// Frozen at cycle start so rows don't reorder mid-walk.
    @Published private(set) var sessions: [TerminalSession] = []
    @Published private(set) var highlightedIndex = 0

    private weak var store: TerminalSessionStore?
    private var isActive = false
    private var originalSelection: TerminalSession.ID?
    private var hudDelay: DispatchWorkItem?
    // Freed from deinit, which is nonisolated under strict concurrency.
    nonisolated(unsafe) private var monitors: [Any] = []
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

    func attach(to store: TerminalSessionStore) {
        self.store = store
        guard monitors.isEmpty else { return }

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event) ?? event
        })
        // Losing app focus mid-cycle means we'll never see the Ctrl release.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.commit()
            }
        }
    }

    deinit {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 48, event.modifierFlags.contains(.control) { // tab
            // Ctrl+Tab takes over from the command center; never show both.
            if CommandCenter.shared.isOpen {
                CommandCenter.shared.close()
            }
            let backwards = event.modifierFlags.contains(.shift)
            if isActive {
                advance(by: backwards ? -1 : 1)
            } else {
                begin(backwards: backwards)
            }
            return nil
        }
        if isActive, event.keyCode == 53 { // esc
            cancel()
            return nil
        }
        return event
    }

    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        if isActive, !event.modifierFlags.contains(.control) {
            commit()
        }
        return event
    }

    private func begin(backwards: Bool) {
        guard let store else { return }
        let ordered = store.recencyOrderedSessions(inSpace: store.activeSpaceID)
        guard ordered.count > 1 else { return }

        sessions = ordered
        originalSelection = store.selection
        highlightedIndex = ordered.firstIndex { $0.id == store.selection } ?? 0
        isActive = true
        store.isCyclingSelection = true
        advance(by: backwards ? -1 : 1)

        // Quick taps flip silently; the list only appears while Ctrl is held.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.isShowingHUD = true
        }
        hudDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func advance(by delta: Int) {
        guard isActive, !sessions.isEmpty else { return }
        highlightedIndex = (highlightedIndex + delta + sessions.count) % sessions.count
        store?.selection = sessions[highlightedIndex].id
    }

    private func commit() {
        finish()
        store?.recordSelectionRecency()
    }

    private func cancel() {
        let restore = originalSelection
        finish()
        store?.selection = restore
    }

    private func finish() {
        isActive = false
        hudDelay?.cancel()
        hudDelay = nil
        isShowingHUD = false
        store?.isCyclingSelection = false
        originalSelection = nil
    }
}

/// The frosted recency list shown over the terminal while Ctrl is held.
struct TabSwitcherHUD: View {
    @ObservedObject var switcher: TabSwitcher
    @ObservedObject var store: TerminalSessionStore

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(switcher.sessions.enumerated()), id: \.element.id) { index, session in
                row(session, isHighlighted: index == switcher.highlightedIndex)
            }
        }
        .padding(8)
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
                // Tight hard shadow for definition + wide diffused one for depth.
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                .shadow(color: .black.opacity(0.65), radius: 70, y: 30)
        )
    }

    private func row(_ session: TerminalSession, isHighlighted: Bool) -> some View {
        HStack(spacing: 12) {
            // Column 1: accent dot + tab title, takes the remaining width.
            HStack(spacing: 9) {
                Circle()
                    .fill(session.accent.color.opacity(isHighlighted ? 0.95 : 0.55))
                    .frame(width: 7, height: 7)

                Text(session.title)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(isHighlighted ? 0.95 : 0.6))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            // Column 2: containing folder, when any.
            HStack(spacing: 5) {
                if let folder = folderTitle(for: session) {
                    FolderBadgeGlyph()
                    Text(folder)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white.opacity(isHighlighted ? 0.55 : 0.35))
            .frame(width: 130, alignment: .leading)

            // Column 3: switch affordance, only on the highlighted row.
            HStack(spacing: 4) {
                Text("Switch")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: 64, alignment: .trailing)
            .opacity(isHighlighted ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHighlighted ? Color.white.opacity(0.09) : Color.clear)
        )
    }

    private func folderTitle(for session: TerminalSession) -> String? {
        store.activeSpace.pinnedFolders
            .first { $0.sessions.contains { $0.id == session.id } }?
            .title
    }
}

/// Tiny folder marker for HUD rows (SF Symbol is fine at this size).
private struct FolderBadgeGlyph: View {
    var body: some View {
        Image(systemName: "folder.fill")
            .font(.system(size: 9, weight: .medium))
    }
}
