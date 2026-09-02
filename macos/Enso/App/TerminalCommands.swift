import SwiftUI

struct TerminalCommands: Commands {
    @ObservedObject var store: TerminalSessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                // All update feedback lives in the sidebar card; surface it.
                store.isSidebarVisible = true
                UpdateController.shared.checkForUpdates()
            }
        }

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

            Button("New Terminal") {
                store.createSessionInheritingWorkingDirectory()
            }
            .keyboardShortcut("n", modifiers: .command)

            // Escape hatch (#28): ⌘N follows the active tab into its folder,
            // so ⌥⌘N stays the deliberate way to make a top-level tab. Still
            // continues in the active tab's working directory.
            Button("New Top-Level Terminal") {
                store.createSession(workingDirectory: store.selectedSession?.workingDirectory)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("New Folder") {
                store.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // Edit ▸ Find, in place of SwiftUI's stock Find submenu — whose ⌘F
        // targets NSTextFinder and would swallow the key before the
        // terminal saw it. Each item round-trips through libghostty, so the
        // menu, ghostty's own ⌘F/⌘G/Esc keybinds, and the bar all land in
        // the same surface callbacks. Aimed at the focused pane: with
        // splits, the sidebar selection follows pane focus.
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") {
                    focusedSurface?.startSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(store.selection == nil)

                Button("Find Next") {
                    focusedSurface?.navigateSearch(.next)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(store.selection == nil)

                Button("Find Previous") {
                    focusedSurface?.navigateSearch(.previous)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(store.selection == nil)

                Button("Use Selection for Find") {
                    focusedSurface?.searchSelection()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(store.selection == nil)

                Divider()

                Button("Hide Find Bar") {
                    focusedSurface?.endSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.selection == nil)
            }
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

            // ⌘W closes outright, pinned or not — the keyboard gesture
            // means "close" everywhere else on the Mac. Sleep stays on the
            // row affordance, context menu, and palette.
            Button("Close Tab") {
                guard let selection = store.selection else { return }
                guard CloseConfirmation.consentsToClose(store, sessionIDs: [selection]) else { return }
                store.close(sessionID: selection)
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

            // Ghostty's split convention: ⌘D right, ⇧⌘D down. Each split is
            // a real new tab continuing in the focused pane's directory, so
            // it also subsumes "Duplicate Tab" (which stays palette-only).
            Button("Split Right") {
                store.splitSelection(direction: .horizontal)
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(store.selection == nil)

            Button("Split Down") {
                store.splitSelection(direction: .vertical)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
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

    /// The live surface of the focused pane, if it has one (a sleeping tab
    /// has nothing to search).
    private var focusedSurface: GhosttySurfaceView? {
        guard let selection = store.selection else { return nil }
        return GhosttySurfaceManager.shared.existingView(for: selection)
    }

    private var pinTitle: String {
        guard let selection = store.selection, store.isPinned(selection) else {
            return "Pin Tab"
        }
        return "Unpin Tab"
    }

}
