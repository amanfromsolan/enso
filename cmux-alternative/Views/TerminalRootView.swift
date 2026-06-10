import SwiftUI

struct TerminalRootView: View {
    @ObservedObject var store: TerminalSessionStore
    @SceneStorage("selectedSessionID") private var storedSelection: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            TerminalWorkspaceView(store: store)
        }
        .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
        .onAppear {
            restoreSelection()
        }
        .onChange(of: store.selection) { _, selection in
            storedSelection = selection?.uuidString
        }
    }

    private func restoreSelection() {
        guard
            let storedSelection,
            let id = UUID(uuidString: storedSelection),
            store.sessions.contains(where: { $0.id == id })
        else {
            return
        }

        store.selection = id
    }
}

#Preview {
    TerminalRootView(store: .preview)
}
