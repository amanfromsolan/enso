import SwiftUI

struct TerminalCommands: Commands {
    @ObservedObject var store: TerminalSessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Custom settings Window scene instead of the native Settings scene,
        // so the window keeps the app's own chrome; ⌘, still opens it.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: SettingsPanel.windowID)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        // Drop the stock File > Close (⌘W closes the window); the shortcut
        // belongs to Tab > Close Tab. ⌘S is repurposed as a second sidebar
        // toggle alongside ⌘B.
        CommandGroup(replacing: .saveItem) {
            Button("Toggle Sidebar") {
                store.isSidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) {
            Button("Command Center") {
                CommandCenter.shared.toggle()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("Go to Tab…") {
                CommandCenter.shared.toggle()
            }
            .keyboardShortcut("p", modifiers: .command)

            Button("Command Palette") {
                CommandCenter.shared.openCommandMode()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button("New Tab") {
                store.createSession()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Folder") {
                store.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // View menu.
        CommandGroup(after: .toolbar) {
            Button(store.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                store.isSidebarVisible.toggle()
            }
            .keyboardShortcut("b", modifiers: .command)
        }

        CommandMenu("Tab") {
            Button(pinTitle) {
                guard let selection = store.selection else { return }
                if store.isPinned(selection) {
                    store.unpin([selection], inSpace: store.activeSpaceID)
                } else {
                    store.pin([selection], inSpace: store.activeSpaceID)
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(store.selection == nil)

            Button("Close Tab") {
                store.closeSelectedSession()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(store.selection == nil)

            Button("Rename Tab") {
                store.requestRenameOfSelection()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.selection == nil)

            Button("Rename Folder") {
                store.requestRenameOfSelectionContainer()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(store.selection == nil)

            Divider()

            Button("Previous Tab") {
                store.focusPreviousSession()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Next Tab") {
                store.focusNextSession()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button("Select Tab \(index)") {
                    store.focusSession(atShortcutIndex: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                .disabled(store.sessions.count < index)
            }
        }
    }

    private var pinTitle: String {
        guard let selection = store.selection, store.isPinned(selection) else {
            return "Pin Tab"
        }
        return "Unpin Tab"
    }
}
