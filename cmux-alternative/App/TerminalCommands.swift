import SwiftUI

struct TerminalCommands: Commands {
    @ObservedObject var store: TerminalSessionStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                store.createSession()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("New Folder") {
                store.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Session") {
            Button("Duplicate Session") {
                store.duplicateSelectedSession()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Close Session") {
                store.closeSelectedSession()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(store.sessions.count == 1)

            Divider()

            Button("Previous Session") {
                store.focusPreviousSession()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Next Session") {
                store.focusNextSession()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button("Select Session \(index)") {
                    store.focusSession(atShortcutIndex: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                .disabled(store.sessions.count < index)
            }
        }
    }
}
