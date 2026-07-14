import SwiftUI

struct TerminalRootView: View {
    @ObservedObject var store: TerminalSessionStore
    @StateObject private var switcher = TabSwitcher()
    @ObservedObject private var commandCenter = CommandCenter.shared
    @ObservedObject private var updateController = UpdateController.shared
    @Environment(\.openWindow) private var openWindow
    @State private var spaceEditor: SpaceEditorSheet.Mode?
    @State private var isPeeking = false
    // Full screen relocates the sidebar toggle: the titlebar (and the
    // traffic lights with it) lives in the auto-hiding reveal strip there,
    // so a persistent copy sits at the window's top-leading instead.
    @State private var isFullScreen = false
    // Card corner radius, kept concentric with the window's own curve so the
    // frame reads as one shape. Read live off the NSWindow (see
    // WindowCornerRadiusReader); starts at the fixed floor and only grows once
    // the window reports a larger radius, so a failed read stays put.
    @State private var cardCornerRadius: CGFloat = WindowCornerRadiusReader.inset
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
                // Drag the trailing edge to resize. The handle spans the full
                // height and insets its own hit strip below the top 40pt so it
                // never steals the window-drag strip up in the traffic-light
                // row, while its indicator can still reach the card's top.
                .overlay(alignment: .trailing) {
                    SidebarResizeHandle(store: store)
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
                .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .strokeBorder(Theme.ink.opacity(0.09), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 12, y: 3)
                .overlay {
                    if switcher.isShowingHUD {
                        ZStack {
                            // Dim the terminal behind the HUD; purely visual,
                            // so it never swallows a stray click.
                            Color.black.opacity(0.35)
                                .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                                .allowsHitTesting(false)

                            TabSwitcherHUD(switcher: switcher, store: store)
                        }
                    }
                }
                // No leading inset beside the sidebar: the card starts flush
                // at the sidebar's trailing edge, so the resize handle sits
                // exactly where the terminal begins instead of a gutter short
                // of it.
                .padding(EdgeInsets(
                    top: 10,
                    leading: store.isSidebarVisible ? 0 : 10,
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
            onToggleSidebar: { store.isSidebarVisible.toggle() },
            onFullScreenChange: { isFullScreen = $0 }
        ))
        // Publishes the window's live corner radius up into the card radius so
        // the two curves stay concentric.
        .background(WindowCornerRadiusReader { cardCornerRadius = $0 })
        .background(
            SidebarMaterial()
                .overlay(Theme.windowWash)
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
        // Above the peek overlay so it stays clickable on a hovered-in
        // sidebar; in full screen this is the only toggle affordance.
        .overlay(alignment: .topLeading) {
            if isFullScreen {
                SidebarToggleButton(isSidebarVisible: store.isSidebarVisible) {
                    store.isSidebarVisible.toggle()
                }
                .padding(.leading, 16)
                .padding(.top, 8)
            }
        }
        .overlay(alignment: .top) {
            if commandCenter.isOpen {
                ZStack(alignment: .top) {
                    // Scrim: invisible, but swallows clicks outside the
                    // palette to dismiss.
                    Color.clear
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
                            .padding(.bottom, 110)
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
        // What's New: same owned-modal treatment as the space editor —
        // native sheets were tried and rejected (animation too slow, scrim
        // unfixably light-on-light, no styling knobs). Update Now / Skip
        // This Version reply to Sparkle through the controller; close just
        // tucks the sheet away, card stays. The palette's "What's New"
        // command reuses the sheet in changelog mode: the running
        // version's notes, no update buttons.
        .overlay {
            if updateController.isShowingWhatsNew, let notes = updateController.presentedWhatsNewNotes {
                ZStack {
                    Color.black.opacity(0.5)
                        .contentShape(Rectangle())
                        .onTapGesture { dismissWhatsNew() }
                        .ignoresSafeArea()
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.16)),
                            removal: .opacity.animation(.easeOut(duration: 0.07))
                        ))

                    WhatsNewSheet(
                        content: notes,
                        isUpdatePending: updateController.whatsNewMode == .pendingUpdate
                    ) {
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
                .overlay(Theme.windowWash)
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.ink.opacity(0.08))
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

/// Reads the window's live corner radius and hands back the card radius that
/// nests concentrically inside it: `windowRadius − inset`, floored at the old
/// fixed 10 so macOS 15 (square-ish window) keeps today's exact look. macOS 26
/// with the unified toolbar reports a noticeably larger radius, so the card
/// comes out visibly rounder than 10.
///
/// The window is AppKit-side, so a hidden representable pulls it from
/// `view.window` and publishes it up. The read uses the same defensive KVC
/// pattern Ghostty uses (see TerminalViewContainer.windowCornerRadius):
/// `responds(to:)`-guarded and typed as an optional, so a missing or renamed
/// private API fails open to the fixed radius instead of crashing.
private struct WindowCornerRadiusReader: NSViewRepresentable {
    /// Card inset from the window edge; also the floor for the computed radius.
    static let inset: CGFloat = 10

    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.onChange = onChange
        // The window isn't wired up yet inside makeNSView; wait a runloop.
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        // If the window arrived after makeNSView, this catches it.
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var onChange: (CGFloat) -> Void = { _ in }
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        /// Last value handed up; publish only on change so the double-read
        /// below doesn't churn SwiftUI state.
        private var lastPublished: CGFloat?

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window

            // The radius shifts with window state: fullscreen squares it off,
            // and becoming key is a safe point to re-read once the toolbar
            // (which bumps the radius) has settled.
            let center = NotificationCenter.default
            for name in [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ] {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publish() }
                }
                observers.append(token)
            }

            // The attach-time read races window setup: launched unfocused,
            // AppKit hasn't settled _cornerRadius yet, the read comes back at
            // the floor, and didBecomeKey — the only re-read — never fires
            // until the window is first focused, so the card sat wrong from
            // launch. A short, fixed burst of deferred re-reads (next tick,
            // then ~0.1s and ~0.5s) covers however late setup lands; publish-
            // on-change makes the extras free, and the burst ends — no
            // permanent polling.
            publishIfChanged()
            for delay in [0.1, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.publishIfChanged()
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.publishIfChanged()
            }
        }

        /// Reads now and once more on the next runloop tick: AppKit can settle
        /// the private radius slightly after the notification fires. Two cheap
        /// reads, no timers; the change guard keeps SwiftUI writes to a minimum.
        private func publish() {
            publishIfChanged()
            DispatchQueue.main.async { [weak self] in
                self?.publishIfChanged()
            }
        }

        private func publishIfChanged() {
            let radius = Self.cardRadius(for: window)
            guard radius != lastPublished else { return }
            lastPublished = radius
            onChange(radius)
        }

        /// Read-only private API, the same defensive KVC read Ghostty uses;
        /// fails open to the fixed inset radius when the key is absent.
        static func cardRadius(for window: NSWindow?) -> CGFloat {
            guard
                let window,
                window.responds(to: Selector(("_cornerRadius"))),
                let radius = window.value(forKey: "_cornerRadius") as? CGFloat
            else {
                return WindowCornerRadiusReader.inset
            }
            return max(WindowCornerRadiusReader.inset, radius - WindowCornerRadiusReader.inset)
        }

        func stop() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
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
    /// The coordinator owns full-screen truth (it sees the window, including
    /// one restored straight into full screen at launch) and reports it up.
    var onFullScreenChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onFullScreenChange = onFullScreenChange
        context.coordinator.setButtonsHidden(buttonsHidden)
        context.coordinator.updateToggle(isSidebarVisible: isSidebarVisible, action: onToggleSidebar)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var buttonsHidden = false
        private var isFullScreen = false
        var onFullScreenChange: (Bool) -> Void = { _ in }
        private var isSidebarVisible = true
        private var toggleAction: () -> Void = {}
        private var toggleHost: NSHostingView<TitlebarSidebarToggle>?

        nonisolated(unsafe) private var fullScreenObservers: [NSObjectProtocol] = []

        deinit {
            fullScreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window

            // The window may already be in full screen (state restoration
            // relaunches straight into it), in which case the toolbar must
            // not be installed — see below.
            let startsFullScreen = window.styleMask.contains(.fullScreen)
            if !startsFullScreen {
                installToolbar(in: window)
            }
            window.titlebarAppearsTransparent = true

            // In full screen the titlebar stops overlaying and the unified
            // toolbar reserves real layout space — a giant blank bar across
            // the top. Drop the toolbar for the duration; the lowered
            // traffic lights only matter in windowed mode anyway.
            fullScreenObservers = [
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.setFullScreen(true) }
                },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.setFullScreen(false) }
                },
            ]

            installToggle(in: window)
            applyVisibility(animated: false)
            setFullScreen(startsFullScreen, force: true)
        }

        /// Empty unified toolbar: AppKit gives the titlebar its taller
        /// metrics and vertically centers the traffic lights in it — the
        /// standard technique for lowered lights without frame-fighting.
        private func installToolbar(in window: NSWindow) {
            let toolbar = NSToolbar(identifier: "EnsoTitlebar")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }

        func setButtonsHidden(_ hidden: Bool) {
            guard hidden != buttonsHidden else { return }
            buttonsHidden = hidden
            applyVisibility(animated: true)
            pushToggleState()
        }

        /// Full screen shows a content-hosted toggle instead; conceal the
        /// titlebar copy so the reveal strip doesn't show a duplicate, swap
        /// the toolbar out/in, and report upward for the SwiftUI overlay.
        private func setFullScreen(_ fullScreen: Bool, force: Bool = false) {
            guard force || fullScreen != isFullScreen else { return }
            isFullScreen = fullScreen
            if let window {
                if fullScreen {
                    window.toolbar = nil
                } else if window.toolbar == nil {
                    installToolbar(in: window)
                }
            }
            pushToggleState()
            onFullScreenChange(fullScreen)
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
                isConcealed: buttonsHidden || isFullScreen,
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
/// 3pt capsule that only shows while hovered or dragging; the drag writes
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
            // Visible indicator: rides the card's full vertical run — the
            // card is inset 10pt from the window top and bottom, so the
            // capsule matches its height. Purely visual; hit-testing stays
            // with the grab strip so the top band keeps dragging the window.
            Capsule()
                .fill(Theme.ink.opacity(isActive ? 0.22 : 0))
                .frame(width: 3)
                .padding(.vertical, 10)
                .allowsHitTesting(false)

            // Invisible grab area at the edge; wider than the indicator so
            // the pointer catches it without pixel-hunting. Starts below the
            // top 40pt so it never steals the window-drag strip up in the
            // traffic-light row.
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
                .overlay(ResizeCursor())
                .onHover { isHovering = $0 }
                .padding(.top, 40)
        }
        .frame(maxHeight: .infinity)
        .gesture(
            // Track in global space: the handle rides the sidebar's trailing
            // edge, so its own local space slides as the width changes and a
            // translation read there oscillates. Global coordinates stay put
            // under the pointer, so the delta from the drag's start location is
            // stable frame to frame.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let base = dragStartWidth ?? store.sidebarWidth
                    if dragStartWidth == nil { dragStartWidth = base }
                    store.setSidebarWidth(base + (value.location.x - value.startLocation.x))
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
