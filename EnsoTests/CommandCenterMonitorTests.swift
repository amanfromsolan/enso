import AppKit
import Testing
@testable import Enso

/// Regression tests for the leaked-key-monitor bug: executing a palette item
/// with Enter poisoned `swallowedKeyCodes`, which kept the monitor installed
/// after later closes, and each reopen stacked another orphaned monitor —
/// every one of which still turned Enter into "New Terminal".
@Suite(.serialized)
@MainActor
struct CommandCenterMonitorTests {
    private let center = CommandCenter.shared

    private func makeStore() -> TerminalSessionStore {
        TerminalSessionStore(persistToDisk: false)
    }

    private func key(_ type: NSEvent.EventType, code: UInt16, characters: String = "\r") -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )!
    }

    /// Leaves the singleton with no palette open and no monitor installed.
    private func reset() {
        center.close()
        for code: UInt16 in [36, 76, 53, 125, 126] {
            _ = center.handleKey(key(.keyUp, code: code))
        }
        #expect(!center.isMonitorInstalled)
    }

    @Test func enterExecutesOnceAndMonitorDrainsOnKeyUp() {
        let store = makeStore()
        center.attach(to: store)
        reset()

        center.open()
        let before = store.sessions.count

        // Enter executes the default "New Terminal" row and closes the
        // palette; the monitor must outlive close() to swallow the keyUp.
        #expect(center.handleKey(key(.keyDown, code: 36)) == nil)
        #expect(!center.isOpen)
        #expect(store.sessions.count == before + 1)
        #expect(center.isMonitorInstalled)

        // The release drains the monitor instead of reaching the terminal.
        #expect(center.handleKey(key(.keyUp, code: 36)) == nil)
        #expect(!center.isMonitorInstalled)
    }

    @Test func keyDownsPassThroughUntouchedWhileClosed() {
        let store = makeStore()
        center.attach(to: store)
        reset()

        // Even if a monitor lingered, Enter while closed must never execute
        // a palette item — this is what spawned terminals on every Enter.
        let before = store.sessions.count
        let down = key(.keyDown, code: 36)
        #expect(center.handleKey(down) === down)
        #expect(store.sessions.count == before)
    }

    @Test func mouseExecuteAfterKeyboardCycleReleasesMonitor() {
        let store = makeStore()
        center.attach(to: store)
        reset()

        // Cycle 1: keyboard execute (down + up), fully drained.
        center.open()
        _ = center.handleKey(key(.keyDown, code: 36))
        _ = center.handleKey(key(.keyUp, code: 36))
        #expect(!center.isMonitorInstalled)

        // Cycle 2: mouse click on a row — no key events at all. A stale
        // entry in swallowedKeyCodes used to keep the monitor alive here.
        center.open()
        #expect(center.isMonitorInstalled)
        center.execute(0)
        #expect(!center.isOpen)
        #expect(!center.isMonitorInstalled)
    }

    @Test func reopenWhileDrainingReusesTheMonitor() {
        let store = makeStore()
        center.attach(to: store)
        reset()

        // Close via Enter, then reopen before the keyUp arrives.
        center.open()
        _ = center.handleKey(key(.keyDown, code: 36))
        #expect(center.isMonitorInstalled)
        center.open()

        // The pending keyUp drains without tearing down the live palette.
        #expect(center.handleKey(key(.keyUp, code: 36)) == nil)
        #expect(center.isOpen)
        #expect(center.isMonitorInstalled)

        // A full keyboard cycle still unwinds to zero monitors.
        let before = store.sessions.count
        _ = center.handleKey(key(.keyDown, code: 36))
        _ = center.handleKey(key(.keyUp, code: 36))
        #expect(store.sessions.count == before + 1)
        #expect(!center.isMonitorInstalled)
    }

    @Test func escCloseDrainsCleanly() {
        let store = makeStore()
        center.attach(to: store)
        reset()

        center.open()
        let before = store.sessions.count
        #expect(center.handleKey(key(.keyDown, code: 53, characters: "\u{1b}")) == nil)
        #expect(!center.isOpen)
        #expect(center.isMonitorInstalled)
        #expect(center.handleKey(key(.keyUp, code: 53, characters: "\u{1b}")) == nil)
        #expect(!center.isMonitorInstalled)
        #expect(store.sessions.count == before)
    }
}
