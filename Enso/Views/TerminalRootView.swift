import SwiftUI

struct TerminalRootView: View {
    @ObservedObject var store: TerminalSessionStore
    @StateObject private var switcher = TabSwitcher()
    @ObservedObject private var commandCenter = CommandCenter.shared
    @ObservedObject private var updateController = UpdateController.shared
    @Environment(\.openWindow) private var openWindow
    @State private var spaceEditor: SpaceEditorSheet.Mode?
    @State private var isPeeking = false
    @SceneStorage("selectedSessionID") private var storedSelection: String?

    var body: some View {
        HStack(spacing: 0) {
            if store.isSidebarVisible {
                VStack(spacing: 0) {
                    // Clear space for the traffic lights.
                    Color.clear.frame(height: 40)

                    SidebarView(store: store, spaceEditor: $spaceEditor)
                }
                // Drags the window, double-click zooms like a real titlebar.
                // Handled in AppKit (see WindowDragHandle) because SwiftUI's
                // WindowDragGesture starves a paired double-click tap. An
                // overlay, not a stacked sibling: macOS 26 floats a scroll-
                // edge pocket (NSScrollPocket) over the sidebar's top that
                // out-z-orders anything earlier in the stack and ate these
                // clicks; the overlay sits above it.
                .overlay(alignment: .top) {
                    WindowDragHandle().frame(height: 40)
                }
                .frame(width: store.sidebarWidth)
                // Drag the trailing edge to resize. Inset below the top 40pt
                // so the handle never steals the window-drag strip up in the
                // traffic-light row.
                .overlay(alignment: .trailing) {
                    SidebarResizeHandle(store: store)
                        .padding(.top, 40)
                }
                // Pinned from a peek, the panel is already on screen, so it
                // appears in place. Shown cold (⌘B), it slides in.
                .transition(
                    isPeeking
                        ? .identity
                        : .move(edge: .leading).combined(with: .opacity)
                )
            }

            // Terminal floats as an inset card on the frosted window.
            TerminalWorkspaceView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 12, y: 3)
                .overlay {
                    if switcher.isShowingHUD {
                        ZStack {
                            // Dim the terminal behind the HUD; purely visual,
                            // so it never swallows a stray click.
                            Color.black.opacity(0.35)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .allowsHitTesting(false)

                            TabSwitcherHUD(switcher: switcher, store: store)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: switcher.isShowingHUD)
                .padding(EdgeInsets(
                    top: 10,
                    leading: store.isSidebarVisible ? 6 : 10,
                    bottom: 10,
                    trailing: 10
                ))
                // The gutter above the card reads as titlebar to the eye but
                // belonged to no view, so double-clicks there silently died.
                // An overlay, like the sidebar's: in the window's top band
                // SwiftUI only routes clicks to AppKit handles hosted above
                // the content, never to ones parked behind it. It ends where
                // the card begins, so the card's own handle and the title
                // cluster keep their clicks.
                .overlay(alignment: .top) {
                    WindowDragHandle().frame(height: 10)
                }
        }
        // Pinning while peeked commits instantly: the panel is already on
        // screen, and animating the handoff flashes the sidebar untinted
        // for a frame (the frosted NSVisualEffectView composites ahead of
        // its SwiftUI tint). Toggles without a peek (⌘B) keep the spring.
        .animation(
            isPeeking ? nil : .spring(duration: 0.28, bounce: 0.12),
            value: store.isSidebarVisible
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TrafficLightInset(
            buttonsHidden: !(store.isSidebarVisible || isPeeking),
            isSidebarVisible: store.isSidebarVisible,
            onToggleSidebar: { store.isSidebarVisible.toggle() }
        ))
        .background(
            SidebarMaterial()
                .overlay(Color.black.opacity(0.38))
                .ignoresSafeArea()
        )
        .ignoresSafeArea()
        // Hidden sidebar: nearing the left side peeks it back in as a
        // floating panel; it retracts once the pointer passes its edge.
        .overlay(alignment: .leading) {
            if !store.isSidebarVisible {
                ZStack(alignment: .leading) {
                    PeekMouseMonitor(isPeeking: isPeeking, dismissEdge: store.sidebarWidth + PeekMouseMonitor.dismissMargin) { peek in
                        withAnimation(.spring(duration: 0.24, bounce: peek ? 0.1 : 0)) {
                            isPeeking = peek
                        }
                    }
                    .frame(width: 0, height: 0)

                    if isPeeking {
                        peekSidebar
                            .transition(.move(edge: .leading))
                    }
                }
                .ignoresSafeArea()
            }
        }
        .onChange(of: store.isSidebarVisible) { _, visible in
            if visible {
                isPeeking = false
            }
        }
        .overlay(alignment: .top) {
            if commandCenter.isOpen {
                ZStack(alignment: .top) {
                    // Scrim: dims the window and swallows clicks outside the
                    // palette to dismiss.
                    Color.black.opacity(0.4)
                        .contentShape(Rectangle())
                        .onTapGesture { commandCenter.close() }
                        .ignoresSafeArea()

                    // Mirror the root layout so the palette centers on the
                    // terminal column, not the whole window.
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: store.isSidebarVisible ? store.sidebarWidth : 0)
                            .allowsHitTesting(false)

                        // A fixed-height slot the card top-aligns into: the
                        // slot stays vertically centered, so the search bar
                        // never moves as results grow or shrink.
                        CommandCenterView(center: commandCenter)
                            .frame(height: 480, alignment: .top)
                            .padding(.top, 90)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        // Space editor as an owned in-window modal: macOS sheet windows
        // force their own chrome (border, corner radius), so we draw the
        // card and dimming scrim ourselves.
        .overlay {
            if let mode = spaceEditor {
                ZStack {
                    Color.black.opacity(0.5)
                        .contentShape(Rectangle())
                        .onTapGesture { dismissSpaceEditor() }
                        .ignoresSafeArea()
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.16)),
                            removal: .opacity.animation(.easeOut(duration: 0.07))
                        ))

                    SpaceEditorSheet(mode: mode) { name, icon in
                        switch mode {
                        case .create:
                            store.createSpace(name: name, icon: icon)
                        case .edit(let space):
                            store.updateSpace(space.id, name: name, icon: icon)
                        }
                    } onDismiss: {
                        dismissSpaceEditor()
                    }
                    // Pops in sharpening from a blur while scaling up;
                    // leaves with a near-instant fade.
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: ModalPopEffect(progress: 0),
                            identity: ModalPopEffect(progress: 1)
                        )
                        .animation(.spring(duration: 0.18, bounce: 0.24)),
                        removal: .opacity.animation(.easeOut(duration: 0.07))
                    ))
                }
            }
        }
        // What's New: same owned-modal treatment as the space editor.
        // Update Now / Skip This Version reply to Sparkle through the
        // controller; close just tucks the sheet away, card stays.
        .overlay {
            if updateController.isShowingWhatsNew, let notes = updateController.releaseNotes {
                ZStack {
                    Color.black.opacity(0.5)
                        .contentShape(Rectangle())
                        .onTapGesture { dismissWhatsNew() }
                        .ignoresSafeArea()
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.16)),
                            removal: .opacity.animation(.easeOut(duration: 0.07))
                        ))

                    WhatsNewSheet(content: notes) {
                        updateController.installNow()
                        restoreTerminalFocus()
                    } onSkip: {
                        updateController.skipThisVersion()
                        restoreTerminalFocus()
                    } onDismiss: {
                        dismissWhatsNew()
                    }
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: ModalPopEffect(progress: 0),
                            identity: ModalPopEffect(progress: 1)
                        )
                        .animation(.spring(duration: 0.18, bounce: 0.24)),
                        removal: .opacity.animation(.easeOut(duration: 0.07))
                    ))
                }
            }
        }
        .onAppear {
            restoreSelection()
            switcher.attach(to: store)
            commandCenter.attach(to: store)
            #if DEBUG
            // Design scaffold, opt-in: ENSO_WHATS_NEW=1 fakes a found
            // update (sidebar card); =sheet also opens the What's New
            // sheet. Unset, dev launches stay clean.
            if ProcessInfo.processInfo.environment["ENSO_WHATS_NEW"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    UpdateController.shared.debugSimulateUpdateFound()
                }
            }
            #endif
            // Screenshot/UI-test hook: sandboxed runners can't send ⌘,.
            if ProcessInfo.processInfo.environment["CMUX_OPEN_SETTINGS"] == "1" {
                openWindow(id: SettingsPanel.windowID)
            }
        }
        .onChange(of: store.selection) { _, selection in
            storedSelection = selection?.uuidString
        }
    }

    private func dismissSpaceEditor() {
        spaceEditor = nil
        GhosttySurfaceManager.shared.restoreFocus(to: store.selection)
    }

    private func dismissWhatsNew() {
        updateController.closeWhatsNew()
        restoreTerminalFocus()
    }

    private func restoreTerminalFocus() {
        GhosttySurfaceManager.shared.restoreFocus(to: store.selection)
    }

    /// The hidden sidebar shown as an overlay while the left edge is hovered.
    private var peekSidebar: some View {
        VStack(spacing: 0) {
            // Breathing room under the floating traffic lights.
            Color.clear.frame(height: 40)
            SidebarView(store: store, spaceEditor: $spaceEditor)
        }
        .frame(width: store.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(
            // Same tint the pinned sidebar sits on, so pinning from a peek
            // doesn't shift the panel's brightness.
            SidebarMaterial()
                .overlay(Color.black.opacity(0.38))
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 30, x: 10)
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

/// Entrance for owned modals: fades in from a blur while scaling up.
private struct ModalPopEffect: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.8 + 0.2 * progress)
            .blur(radius: 10 * (1 - progress))
            .opacity(Double(progress))
    }
}

/// Drives the peeked sidebar from the real pointer position: nearing the
/// window's left side reveals it, passing the panel's right edge dismisses
/// it. SwiftUI hover is unreliable over the terminal's NSView (it owns its
/// own tracking areas), so a local monitor watches every move.
private struct PeekMouseMonitor: NSViewRepresentable {
    static let revealEdge: CGFloat = 84
    /// The peek dismisses once the pointer clears the panel's right edge by
    /// this much; added to the live sidebar width rather than baked into a
    /// constant, so a resized sidebar peeks and retracts at the right place.
    static let dismissMargin: CGFloat = 4

    var isPeeking: Bool
    var dismissEdge: CGFloat
    let setPeeking: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.start(view: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isPeeking = isPeeking
        context.coordinator.dismissEdge = dismissEdge
        context.coordinator.setPeeking = setPeeking
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPeeking: isPeeking, dismissEdge: dismissEdge, setPeeking: setPeeking)
    }

    @MainActor
    final class Coordinator {
        var isPeeking: Bool
        var dismissEdge: CGFloat
        var setPeeking: (Bool) -> Void
        private weak var view: NSView?
        nonisolated(unsafe) private var monitor: Any?

        init(isPeeking: Bool, dismissEdge: CGFloat, setPeeking: @escaping (Bool) -> Void) {
            self.isPeeking = isPeeking
            self.dismissEdge = dismissEdge
            self.setPeeking = setPeeking
        }

        func start(view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window = view?.window, event.window === window else { return }
            let x = event.locationInWindow.x
            if isPeeking {
                if x > dismissEdge {
                    setPeeking(false)
                }
            } else if x >= 0, x < PeekMouseMonitor.revealEdge {
                setPeeking(true)
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

/// Owns traffic-light chrome. The lights sit lower than stock via an empty
/// unified toolbar (taller titlebar metrics) — AppKit centers them natively,
/// so the position is stable through every relayout, live resize included;
/// no frame-fighting. Hiding fades alpha only, which never relayouts.
/// Also hosts the sidebar toggle in the titlebar as a "fourth light":
/// constrained to the zoom button with the lights' own gap, it shows and
/// hides exactly when they do.
private struct TrafficLightInset: NSViewRepresentable {
    var buttonsHidden: Bool
    var isSidebarVisible: Bool
    var onToggleSidebar: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.setButtonsHidden(buttonsHidden)
        context.coordinator.updateToggle(isSidebarVisible: isSidebarVisible, action: onToggleSidebar)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var buttonsHidden = false
        private var isSidebarVisible = true
        private var toggleAction: () -> Void = {}
        private var toggleHost: NSHostingView<TitlebarSidebarToggle>?

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window

            // Empty unified toolbar: AppKit gives the titlebar its taller
            // metrics and vertically centers the traffic lights in it — the
            // standard technique for lowered lights without frame-fighting.
            let toolbar = NSToolbar(identifier: "EnsoTitlebar")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.titlebarAppearsTransparent = true

            installToggle(in: window)
            applyVisibility(animated: false)
        }

        func setButtonsHidden(_ hidden: Bool) {
            guard hidden != buttonsHidden else { return }
            buttonsHidden = hidden
            applyVisibility(animated: true)
            pushToggleState()
        }

        func updateToggle(isSidebarVisible: Bool, action: @escaping () -> Void) {
            self.isSidebarVisible = isSidebarVisible
            self.toggleAction = action
            pushToggleState()
        }

        /// Seats the toggle in the titlebar view, pinned to the zoom button
        /// with the same gap the lights keep between themselves — AppKit
        /// moves the lights, the constraint drags the toggle along.
        private func installToggle(in window: NSWindow) {
            guard
                toggleHost == nil,
                let close = window.standardWindowButton(.closeButton),
                let mini = window.standardWindowButton(.miniaturizeButton),
                let zoom = window.standardWindowButton(.zoomButton),
                let titlebar = zoom.superview
            else { return }

            let host = NSHostingView(rootView: currentToggleState())
            host.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(host)
            let gap = mini.frame.minX - close.frame.maxX
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: zoom.trailingAnchor, constant: gap),
                host.centerYAnchor.constraint(equalTo: zoom.centerYAnchor),
            ])
            toggleHost = host
        }

        private func pushToggleState() {
            toggleHost?.rootView = currentToggleState()
        }

        private func currentToggleState() -> TitlebarSidebarToggle {
            TitlebarSidebarToggle(
                isSidebarVisible: isSidebarVisible,
                isConcealed: buttonsHidden,
                action: toggleAction
            )
        }

        private func applyVisibility(animated: Bool) {
            guard let window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }

            let target: CGFloat = buttonsHidden ? 0 : 1
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = self.buttonsHidden ? 0.15 : 0.2
                    buttons.forEach { $0.animator().alphaValue = target }
                }
            } else {
                buttons.forEach { $0.alphaValue = target }
            }
            // Invisible buttons must not swallow clicks over the terminal.
            buttons.forEach { $0.isEnabled = !buttonsHidden }
        }
    }
}

/// Titlebar wrapper for the sidebar toggle: fades in step with the traffic
/// lights (SwiftUI-side, so AppKit alpha animation never fights the hosting
/// view) and stops taking clicks while concealed.
private struct TitlebarSidebarToggle: View {
    var isSidebarVisible: Bool
    var isConcealed: Bool
    var action: () -> Void

    var body: some View {
        SidebarToggleButton(isSidebarVisible: isSidebarVisible, action: action)
            .opacity(isConcealed ? 0 : 1)
            .allowsHitTesting(!isConcealed)
            .animation(.easeOut(duration: isConcealed ? 0.15 : 0.2), value: isConcealed)
    }
}

/// Trailing-edge grip that drag-resizes the sidebar. An 8pt hit strip with a
/// 1pt hairline that only shows while hovered or dragging; the drag writes
/// store.sidebarWidth live (the store clamps to its min/max). Shows the
/// standard horizontal-resize cursor over the strip.
private struct SidebarResizeHandle: View {
    @ObservedObject var store: TerminalSessionStore
    /// Width at the moment the drag began; the gesture translates from it so
    /// the pointer stays glued to the edge no matter how far it travels.
    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false

    private var isActive: Bool { isHovering || dragStartWidth != nil }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Invisible grab area straddling the edge; wider than the hairline
            // so the pointer catches it without pixel-hunting.
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())

            Rectangle()
                .fill(Color.white.opacity(isActive ? 0.22 : 0))
                .frame(width: 1)
        }
        .frame(maxHeight: .infinity)
        .overlay(ResizeCursor())
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let base = dragStartWidth ?? store.sidebarWidth
                    if dragStartWidth == nil { dragStartWidth = base }
                    store.setSidebarWidth(base + value.translation.width)
                }
                .onEnded { _ in dragStartWidth = nil }
        )
    }
}

/// Paints the horizontal-resize cursor over its bounds. A cursor rect (rather
/// than hover push/pop) so AppKit keeps it correct through relayouts and never
/// leaves a stale cursor if the view vanishes mid-hover.
private struct ResizeCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
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
