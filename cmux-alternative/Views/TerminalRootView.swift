import SwiftUI

struct TerminalRootView: View {
    @ObservedObject var store: TerminalSessionStore
    @StateObject private var switcher = TabSwitcher()
    @ObservedObject private var commandCenter = CommandCenter.shared
    @SceneStorage("selectedSessionID") private var storedSelection: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Clear space for the traffic lights; drags the window.
                Color.clear
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())

                SidebarView(store: store)
            }
            .frame(width: 248)

            // Terminal floats as an inset card on the frosted window.
            TerminalWorkspaceView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 16, y: 4)
                .overlay {
                    if switcher.isShowingHUD {
                        TabSwitcherHUD(switcher: switcher, store: store)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: switcher.isShowingHUD)
                .padding(EdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            SidebarMaterial()
                .overlay(Color.black.opacity(0.38))
                .ignoresSafeArea()
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if commandCenter.isOpen {
                ZStack(alignment: .top) {
                    // Scrim: swallows clicks outside the palette to dismiss.
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { commandCenter.close() }
                        .ignoresSafeArea()

                    // Mirror the root layout so the palette centers on the
                    // terminal column, not the whole window.
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: 248)
                            .allowsHitTesting(false)

                        CommandCenterView(center: commandCenter)
                            .padding(.top, 90)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .onAppear {
            restoreSelection()
            switcher.attach(to: store)
            commandCenter.attach(to: store)
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

/// Frosted backdrop that blurs whatever is behind the window.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

#Preview {
    TerminalRootView(store: .preview)
}
