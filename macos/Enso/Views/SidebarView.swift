import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var store: TerminalSessionStore

    @State private var dragOffset: CGFloat = 0
    @State private var trailingOverscroll: CGFloat = 0
    /// Presented by the root view as an in-window modal (owned chrome —
    /// macOS sheet windows force their own border and corner radius).
    @Binding var spaceEditor: SpaceEditorSheet.Mode?

    /// Overscroll distance past the last space that triggers space creation.
    static let newSpaceThreshold: CGFloat = 45

    var body: some View {
        VStack(spacing: 0) {
            pager
            UpdateCardView(controller: .shared)
            SpaceIndicatorBar(
                store: store,
                onEdit: { spaceEditor = .edit($0) },
                onCreate: { spaceEditor = .create }
            )
        }
    }

    /// One space page is exactly one sidebar's width, so the paging math
    /// tracks the live (drag-resizable) sidebar width, not a constant.
    private var pageWidth: CGFloat { store.sidebarWidth }

    private var currentIndex: Int {
        store.spaces.firstIndex { $0.id == store.activeSpaceID } ?? 0
    }

    /// Drag offset with rubber-band resistance at both ends, hard-clamped to
    /// one page so a single gesture can never travel further than a neighbor.
    private var visualDrag: CGFloat {
        var offset = dragOffset
        if offset > 0 && currentIndex == 0 {
            offset *= 0.5
        }
        if offset < 0 && currentIndex == store.spaces.count - 1 {
            offset *= 0.5
        }
        return min(pageWidth, max(-pageWidth, offset))
    }

    private var pager: some View {
        let width = pageWidth
        // Fractional page position, shared by the offset and the fade/blur.
        let position = CGFloat(currentIndex) - visualDrag / width

        return HStack(spacing: 0) {
            ForEach(Array(store.spaces.enumerated()), id: \.element.id) { index, space in
                let distance = min(abs(CGFloat(index) - position), 1)
                SpacePage(
                    store: store,
                    space: space,
                    onEditSpace: { spaceEditor = .edit($0) }
                )
                .frame(width: width)
                // Incoming space fades in and sharpens from a blur as it
                // slides in; the outgoing one does the reverse.
                .opacity(1 - 0.65 * distance)
                .blur(radius: 5 * distance)
            }
        }
        .offset(x: -position * width)
        .frame(width: width, alignment: .leading)
        .clipped()
        .background(
            SidebarSwipeCapture(
                onChanged: { translation in
                    dragOffset = translation
                    updateOverscroll()
                },
                onEnded: { translation, velocity in
                    finishSwipe(translation: translation, velocity: velocity)
                }
            )
        )
        .overlay(alignment: .trailing) {
            if trailingOverscroll > 4 {
                NewSpaceTeaser(progress: min(trailingOverscroll / Self.newSpaceThreshold, 1))
                    .allowsHitTesting(false)
            }
        }
    }

    private func updateOverscroll() {
        if currentIndex == store.spaces.count - 1, dragOffset < 0 {
            trailingOverscroll = -visualDrag
        } else {
            trailingOverscroll = 0
        }
    }

    private func finishSwipe(translation: CGFloat, velocity: CGFloat) {
        let atLast = currentIndex == store.spaces.count - 1

        if atLast, translation < 0, -translation * 0.5 > Self.newSpaceThreshold {
            spaceEditor = .create
        }

        var target = currentIndex
        if translation < 0, -translation > pageWidth * 0.35 || velocity < -6 {
            target += 1
        } else if translation > 0, translation > pageWidth * 0.35 || velocity > 6 {
            target -= 1
        }
        target = min(max(target, 0), store.spaces.count - 1)

        withAnimation(.spring(duration: 0.32, bounce: 0.12)) {
            dragOffset = 0
            trailingOverscroll = 0
            if target != currentIndex {
                store.setActiveSpace(store.spaces[target].id)
            }
        }
    }
}

/// Captures two-finger horizontal pans over the sidebar with a local event
/// monitor, bypassing NSScrollView's momentum system entirely. One gesture
/// produces one translation stream; trailing momentum events are swallowed,
/// so a flick can never carry the pager past the adjacent space.
private struct SidebarSwipeCapture: NSViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }

    final class CaptureView: NSView {
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: ((CGFloat, CGFloat) -> Void)?

        private var monitor: Any?
        private var gestureState: GestureState = .idle
        private var translation: CGFloat = 0
        private var recentDeltas: [CGFloat] = []

        private enum GestureState {
            case idle
            /// Fingers down over us, direction not yet determined.
            case pending
            /// Horizontal pan in progress; we own every event until it ends.
            case active
            /// Gesture was ours; swallow the momentum tail.
            case coasting
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.handle(event) ?? event
                }
            }
            if window == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }

            if event.momentumPhase != [] {
                guard gestureState == .coasting else { return event }
                if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                    gestureState = .idle
                }
                return nil
            }

            switch event.phase {
            case .began:
                let point = convert(event.locationInWindow, from: nil)
                gestureState = bounds.contains(point) ? .pending : .idle
                translation = 0
                recentDeltas = []
                return event

            case .changed:
                if gestureState == .pending {
                    // First meaningful delta decides the gesture's direction.
                    guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
                        gestureState = .idle
                        return event
                    }
                    gestureState = .active
                }
                guard gestureState == .active else { return event }
                translation += event.scrollingDeltaX
                recentDeltas.append(event.scrollingDeltaX)
                if recentDeltas.count > 5 {
                    recentDeltas.removeFirst()
                }
                onChanged?(translation)
                return nil

            case .ended, .cancelled:
                guard gestureState == .active else {
                    gestureState = .idle
                    return event
                }
                gestureState = .coasting
                let velocity = recentDeltas.isEmpty
                    ? 0
                    : recentDeltas.reduce(0, +) / CGFloat(recentDeltas.count)
                onEnded?(translation, velocity)
                return nil

            default:
                return event
            }
        }
    }
}

/// The plus badge that fades in while over-swiping past the last space:
/// it slides in from the edge, grows, and its ring fills with the drag —
/// release when full to create.
private struct NewSpaceTeaser: View {
    let progress: CGFloat

    var body: some View {
        ZStack {
                Circle()
                    // Dark keeps the original HUD-style black disc; a black
                    // disc on the light sidebar reads as a heavy blot, so
                    // light mode sinks a soft grey well instead (iconWell's
                    // weight) and lets the ink glyph carry the contrast.
                    .fill(Color(nsColor: Theme.dynamic(
                        dark: NSColor(white: 0, alpha: 0.45),
                        light: NSColor(white: 0, alpha: 0.12)
                    )))
                Circle()
                    .stroke(Theme.ink.opacity(0.14), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.35 + 0.65 * progress))
        }
        .frame(width: 30, height: 30)
        .scaleEffect(0.72 + 0.42 * progress)
        .padding(.trailing, 8)
        .offset(x: -14 * progress)
        .animation(.interactiveSpring, value: progress)
    }
}

// MARK: - One space page

private struct SpacePage: View {
    @ObservedObject var store: TerminalSessionStore
    @ObservedObject private var namer = TabAutoNamer.shared
    @Environment(\.colorScheme) private var colorScheme
    let space: SidebarSpace
    let onEditSpace: (SidebarSpace) -> Void

    @State private var hoveredSessionID: TerminalSession.ID?
    @State private var renamingSessionID: TerminalSession.ID?
    @State private var draftTitle = ""
    @FocusState private var renameFieldFocused: Bool

    @State private var hoveredFolderID: TerminalFolder.ID?
    /// The one piece of drop-feedback state: the current projection of the
    /// in-flight drag onto the sidebar, or nil when nothing valid is hovered.
    @State private var dropProposal: SidebarDropProposal?
    /// Row frames in the drop container's coordinate space, collected via
    /// preferences; the resolver hit-tests against these.
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var dividerFrame: CGRect?
    /// Last drag pointer, viewport-relative, so auto-scroll ticks can keep
    /// the proposal in sync while content slides under a still pointer.
    @State private var pointerInViewport: CGPoint?
    /// Pointer X where the drag entered; ambiguous gaps read the horizontal
    /// travel from here to pick nest-into-folder vs loose.
    @State private var dragReferenceX: CGFloat?
    /// SwiftUI has no end-of-drag callback, so a slow watcher polls the
    /// mouse button during a tracked drag; button-up with no drop delivered
    /// means the drag was cancelled (ESC, or released outside any target).
    @State private var dragWatchTimer: Timer?
    @State private var dragReleaseTicks = 0
    @State private var scrollDriver = SidebarScrollDriver()
    @State private var renamingFolderID: TerminalFolder.ID?
    @State private var draftFolderTitle = ""
    @FocusState private var folderRenameFocused: Bool
    @State private var headerHovered = false
    @State private var headerMenuHovered = false
    @State private var newTabHovered = false
    @State private var isRenamingSpace = false
    @State private var draftSpaceName = ""
    @FocusState private var spaceNameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                pinnedZone
                zoneDivider
                ephemeralZone
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .animation(.snappy(duration: 0.22), value: rowLayout)
            .animation(.snappy(duration: 0.22), value: store.collapsedFolderIDs)
            // Behind the rows, so it only catches clicks on empty sidebar
            // space — row clicks never race it into cancelling a rename.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { cancelRenames() }
            )
            .background(SidebarScrollViewCapture(driver: scrollDriver))
            .overlay(alignment: .topLeading) { dropIndicatorLine }
            .contentShape(Rectangle())
            // One drop target for the whole page: every pointer position
            // resolves through the projection model, no per-zone strips.
            .onDrop(of: [.text], delegate: SidebarSpaceDropDelegate(
                onUpdate: { handleDragUpdate(at: $0) },
                onExited: { endDragTracking() },
                onPerform: { performDrop($0) }
            ))
            .coordinateSpace(name: Self.dropSpaceName)
            .onPreferenceChange(SidebarRowFrameKey.self) { rowFrames = $0 }
            .onPreferenceChange(SidebarDividerFrameKey.self) { dividerFrame = $0 }
        }
        .background(
            RenameClickAway(
                active: renamingSessionID != nil || renamingFolderID != nil || isRenamingSpace
            ) {
                commitActiveRename()
            }
        )
        .onChange(of: folderRenameFocused) { _, focused in
            if !focused, let id = renamingFolderID,
               let folder = space.pinnedFolders.first(where: { $0.id == id }) {
                commitFolderRename(folder)
            }
        }
        .onChange(of: store.renameRequest) { _, request in
            switch request {
            case .session(let id):
                guard let session = space.sessions.first(where: { $0.id == id }) else { return }
                store.renameRequest = nil
                beginRename(session)
            case .folder(let id):
                guard let folder = space.pinnedFolders.first(where: { $0.id == id }) else { return }
                store.renameRequest = nil
                beginFolderRename(folder)
            case nil:
                break
            }
        }
    }

    /// Row layout identity: animates structural changes (add/remove/reorder,
    /// pin/unpin) without animating metadata-only updates — selecting a tab
    /// stamps its lastActivity, and that must not fade the highlight in.
    private var rowLayout: [UUID] {
        var ids: [UUID] = []
        for item in space.pinnedItems {
            switch item {
            case .tab(let session):
                ids.append(session.id)
            case .folder(let folder):
                ids.append(folder.id)
                ids.append(contentsOf: folder.sessions.map(\.id))
            }
        }
        ids.append(contentsOf: space.ephemeralSessions.map(\.id))
        return ids
    }

    /// Click-away while renaming: keep the edit (matching focus-loss
    /// behavior) and let the click do its normal job.
    private func commitActiveRename() {
        if isRenamingSpace {
            commitSpaceRename()
        }
        if let id = renamingSessionID, let session = space.sessions.first(where: { $0.id == id }) {
            commitRename(session)
        }
        if let id = renamingFolderID, let folder = space.pinnedFolders.first(where: { $0.id == id }) {
            commitFolderRename(folder)
        }
    }

    /// Clicking empty sidebar space backs out of any in-progress rename.
    private func cancelRenames() {
        guard isRenamingSpace || renamingSessionID != nil || renamingFolderID != nil else { return }
        isRenamingSpace = false
        renamingSessionID = nil
        renamingFolderID = nil
        restoreTerminalFocus()
    }

    /// Ending a rename leaves first responder parked nowhere, so Return
    /// stops reaching the shell; hand the keyboard back to the terminal.
    private func restoreTerminalFocus() {
        GhosttySurfaceManager.shared.restoreFocus(to: store.selection)
    }

    // MARK: - Space header

    private var spaceHeader: some View {
        HStack(spacing: 8) {
            SpaceIndicatorIcon(icon: space.icon, isActive: true, size: 20)
                .frame(width: 20)

            if isRenamingSpace {
                TextField("", text: $draftSpaceName)
                    .textFieldStyle(.plain)
                    .font(PaletteFont.text(14, .medium))
                    .foregroundStyle(Theme.text(1))
                    .focused($spaceNameFocused)
                    .onSubmit {
                        commitSpaceRename()
                        restoreTerminalFocus()
                    }
                    .onExitCommand {
                        isRenamingSpace = false
                        restoreTerminalFocus()
                    }
            } else {
                Text(space.name)
                    .font(PaletteFont.text(14, .medium))
                    .tracking(PaletteFont.tracking)
                    .foregroundStyle(Theme.text(0.78))
                    .lineLimit(1)
                    // Rename only on the name text, not the whole header.
                    .onTapGesture(count: 2) {
                        beginSpaceRename()
                    }
            }

            Spacer(minLength: 0)

            // Inserted only on hover so the title gets the full row width when
            // idle; the fixed minHeight below keeps the row from shifting.
            if headerHovered && !isRenamingSpace {
                // Collapse/expand-all toggle, left of the ⋯ menu. Only present
                // when the space has folders to fold; laid out alongside the
                // menu so the header height never shifts. Shows the inward
                // chevrons while any folder is open (click folds everything)
                // and flips to the outward chevrons once all are folded (click
                // reopens). Custom template assets so they tint like the
                // neighboring SF Symbols.
                if !space.pinnedFolders.isEmpty {
                    HoverIconButton(
                        help: allFoldersCollapsed ? "Expand All Folders" : "Collapse All Folders",
                        action: {
                            if allFoldersCollapsed {
                                store.expandAllFolders(inSpace: space.id)
                            } else {
                                store.collapseAllFolders(inSpace: space.id)
                            }
                        }
                    ) {
                        Image(allFoldersCollapsed ? "ExpandFolders" : "CollapseFolders")
                            .renderingMode(.template)
                    }
                }

                Menu {
                    Button("Rename", systemImage: "pencil") {
                        beginSpaceRename()
                    }
                    Button("Edit Icon & Name…", systemImage: "pencil.and.outline") {
                        onEditSpace(space)
                    }
                    Divider()
                    Button("Delete Space", systemImage: "trash") {
                        store.deleteSpace(space.id)
                    }
                    .disabled(store.spaces.count == 1)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.text(headerMenuHovered ? 0.9 : 0.55))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                // Without fixedSize the borderless popup cell still reserves
                // trailing indicator width, so the 18pt frame centers a wider
                // cell and shoves the glyph left; fixedSize lets the reclaimed
                // label be its true size and sit dead-center.
                .fixedSize()
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.ink.opacity(headerMenuHovered ? 0.12 : 0))
                )
                .onHover { headerMenuHovered = $0 }
                // The hover state outlives the view (it belongs to the page),
                // and removal can beat the exit event — picking Rename tears
                // this branch out mid-hover. Reset on the way out so the ⋯
                // never comes back pre-highlighted.
                .onDisappear { headerMenuHovered = false }
            }
        }
        .frame(minHeight: 18)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(headerHovered ? Theme.ink.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            headerHovered = hovering
        }
        .padding(.bottom, 4)
    }

    /// Every folder in this space is collapsed — the toggle then offers to
    /// expand rather than collapse.
    private var allFoldersCollapsed: Bool {
        space.pinnedFolders.allSatisfy { store.collapsedFolderIDs.contains($0.id) }
    }

    private func beginSpaceRename() {
        draftSpaceName = space.name
        isRenamingSpace = true
        spaceNameFocused = true
    }

    private func commitSpaceRename() {
        guard isRenamingSpace else { return }
        isRenamingSpace = false
        store.renameSpace(space.id, to: draftSpaceName)
    }

    private var pinnedZone: some View {
        // Zero list spacing: the row gap lives inside each row's vertical
        // padding instead, so drag hit-areas stay contiguous. Drops anywhere
        // in the zone resolve through the page-level projection.
        VStack(alignment: .leading, spacing: 0) {
            spaceHeader
                .onChange(of: spaceNameFocused) { _, focused in
                    if !focused, isRenamingSpace {
                        commitSpaceRename()
                    }
                }

            if space.pinnedItems.isEmpty {
                Text("Drag tabs here to keep them")
                    .font(PaletteFont.text(12, .regular))
                    .tracking(PaletteFont.tracking)
                    .foregroundStyle(Theme.text(0.28))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }

            // Loose tabs and folders render in one interleaved order — the
            // same order the drop projection flattens.
            ForEach(space.pinnedItems) { item in
                switch item {
                case .tab(let session):
                    sessionRow(session)
                case .folder(let folder):
                    folderSection(folder)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var zoneDivider: some View {
        Rectangle()
            .fill(Theme.ink.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            // Its midline is the boundary between the two drop zones.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SidebarDividerFrameKey.self,
                        value: geo.frame(in: .named(Self.dropSpaceName))
                    )
                }
            )
    }

    private var ephemeralZone: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(space.ephemeralSessions) { session in
                sessionRow(session)
            }

            Button {
                store.createSession(inSpace: space.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text("New Terminal")
                        .font(PaletteFont.text(14, .regular))
                        .tracking(PaletteFont.tracking)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.text(newTabHovered ? 0.7 : 0.45))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(newTabHovered ? Theme.ink.opacity(0.05) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { newTabHovered = $0 }

            Spacer(minLength: 120)
        }
    }

    // In-flight drag image: a ghost of the row, translucent enough that the
    // insertion line and folder highlights stay readable underneath it.
    private func dragPreviewPill(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(icon)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Theme.ink.opacity(0.6))
                .frame(width: 16, height: 16)
            Text(title)
                .font(PaletteFont.text(14, .regular))
                .tracking(PaletteFont.tracking)
                .foregroundStyle(Theme.text(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.ink.opacity(0.12))
        )
        .opacity(0.45)
    }

    private func sessionDragPreview(_ session: TerminalSession) -> some View {
        let targets = contextTargets(for: session)
        return dragPreviewPill(
            icon: "TerminalIdle16",
            title: targets.count > 1 ? "\(targets.count) tabs" : session.title
        )
    }

    private func folderSection(_ folder: TerminalFolder) -> some View {
        let isExpanded = !store.collapsedFolderIDs.contains(folder.id)
        let isHovered = hoveredFolderID == folder.id
        let isRenaming = renamingFolderID == folder.id
        // Dragged tabs hovering the row's middle land inside the folder.
        let isDropInto = dropProposal?.indicator == .folderHighlight(folder.id)
        // A collapsed folder still shows its active tab: the selected row
        // peeks out under the folder so the current tab never vanishes from
        // the sidebar. Selecting a tab elsewhere retracts it.
        let peekingSession = isExpanded
            ? nil
            : folder.sessions.first { $0.id == store.selection }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(isExpanded ? "FolderOpen16" : "FolderClosed16")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .frame(width: 16, height: 16)
                    .frame(width: 16)

                if isRenaming {
                    TextField("", text: $draftFolderTitle)
                        .textFieldStyle(.plain)
                        .font(PaletteFont.text(14, .medium))
                        .foregroundStyle(Theme.text(1))
                        .focused($folderRenameFocused)
                        .onSubmit {
                            commitFolderRename(folder)
                        }
                        .onExitCommand {
                            renamingFolderID = nil
                        }
                } else {
                    Text(folder.title)
                        .font(PaletteFont.text(14, .medium))
                        .tracking(PaletteFont.tracking)
                        .foregroundStyle(Theme.text(0.82))
                        .lineLimit(1)
                        // Rename only on the title text; elsewhere the row
                        // just toggles expansion.
                        .simultaneousGesture(TapGesture().onEnded {
                            guard renamingFolderID != folder.id else { return }
                            if NSApp.currentEvent?.clickCount == 2 {
                                // Undo the first click's expansion flip,
                                // then rename inline.
                                toggleExpansion(folder)
                                beginFolderRename(folder)
                            }
                        })
                }

                Spacer(minLength: 0)

                // Inserted only on hover so the title gets the full row width
                // when idle — see spaceHeader. Gated off during rename too,
                // so hovering can't resize the focused rename field.
                // A flush cluster: 24pt frames touching each other, filling
                // the content box so the row's 4pt insets are what set their
                // distance from the edges.
                if isHovered && !isRenaming {
                    HStack(spacing: 0) {
                        HoverIconButton(systemName: "plus", help: "New Terminal in Folder", size: 24, washOpacity: 0.09) {
                            store.createSession(inFolder: folder.id)
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.text(0.4))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 24, height: 24)
                    }
                }
            }
            // 24pt content box in 4pt vertical insets: same 32pt row as the
            // old 18-in-7, but the hover icons reach to 4pt off every edge.
            // The extra leading keeps the text block where it always was.
            .frame(minHeight: 24)
            .padding(.leading, 9)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        isDropInto
                            ? Color.accentColor.opacity(0.22)
                            : (isHovered ? Theme.ink.opacity(0.06) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
            .modifier(RowPressScale())
            .onHover { hovering in
                if hovering {
                    hoveredFolderID = folder.id
                } else if hoveredFolderID == folder.id {
                    hoveredFolderID = nil
                }
            }
            // Simultaneous so the title text's rename gesture doesn't eat
            // the single click (child gestures beat a plain onTapGesture).
            .simultaneousGesture(TapGesture().onEnded {
                guard renamingFolderID != folder.id else { return }
                if NSApp.currentEvent?.clickCount == 1 {
                    toggleExpansion(folder)
                }
            })
            .contextMenu {
                Button("New Terminal in Folder", systemImage: "plus") {
                    store.createSession(inFolder: folder.id)
                }
                Divider()
                Button("Rename Folder", systemImage: "pencil") {
                    beginFolderRename(folder)
                }
                if store.spaces.count > 1 {
                    Menu("Move to Space") {
                        ForEach(store.spaces.filter { $0.id != space.id }) { other in
                            Button(other.name) {
                                store.moveFolder(folder.id, toSpace: other.id)
                            }
                        }
                    }
                }
                Divider()
                Button("Delete Folder", systemImage: "trash") {
                    store.deleteFolder(folder.id)
                }
            }
            .onDrag {
                // Folders travel collapsed: one compact row in flight
                // instead of a whole column of children.
                store.sidebarDragFolderWasExpanded = !store.collapsedFolderIDs.contains(folder.id)
                withAnimation(.easeOut(duration: 0.15)) {
                    store.collapsedFolderIDs.insert(folder.id)
                }
                let payload = SidebarDragPayload.folder(folder.id)
                beginDragTracking(payload)
                return NSItemProvider(object: payload.stringValue as NSString)
            } preview: {
                dragPreviewPill(icon: "FolderClosed16", title: folder.title)
            }
            .background(rowFrameReporter(folder.id))
            // The same uniform row gap as sessionRow.
            .padding(.top, SpacePage.rowGap)

            // Children live in a container that collapses to zero height and
            // clips, so rows disappear into the folder instead of floating.
            // The peeking session is pulled out (it renders below instead),
            // so its row — and a rename field's focus binding — never exists
            // twice in the tree.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(folder.sessions.filter { $0.id != peekingSession?.id }) { session in
                    sessionRow(session)
                }
            }
            .padding(.leading, 14)
            // Breathing room so the selected row's drop shadow isn't clipped
            // sideways or below by this container's collapse clip (the clip
            // is what lets rows vanish into the folder when it folds). The
            // bottom room is reclaimed after the clip so the folder's height
            // and the gap to the next row don't change.
            .padding(.trailing, 6)
            .padding(.bottom, 5)
            .frame(height: isExpanded ? nil : 0, alignment: .top)
            .clipped()
            .padding(.bottom, isExpanded ? -5 : 0)
            .allowsHitTesting(isExpanded)
            .opacity(isExpanded ? 1 : 0)

            // The active tab peeking out of a collapsed folder: the ordinary
            // session row at child indentation, fully interactive.
            if let peekingSession {
                sessionRow(peekingSession)
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
            }
        }
        .geometryGroup()
    }

    /// A dropped folder reopens if it was expanded before its drag
    /// collapsed it.
    private func restoreDraggedFolderExpansion(_ folderID: TerminalFolder.ID) {
        guard store.sidebarDragFolderWasExpanded else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            _ = store.collapsedFolderIDs.remove(folderID)
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: TerminalSession) -> some View {
        let isSelected = store.selection == session.id
        let isMultiSelected = store.multiSelection.contains(session.id)
        let isRenaming = renamingSessionID == session.id

        HStack(spacing: 8) {
            // Uniform slot: detected-process badge when something known
            // is running, spinner while naming, accent dot otherwise.
            // The badge outranks the spinner: auto-naming fires on a
            // tab's first real command, and hiding the fresh badge
            // behind the spinner read as the icon skipping that command.
            Group {
                if let process = session.runningProcess {
                    ProcessBadgeView(process: process, isSelected: isSelected)
                } else if let dormant = AgentSessionStore.shared.dormantAgent(forTab: session.id) {
                    // An agent session lives here but isn't running yet
                    // (eager sweep hasn't reached it, or it's past the warm
                    // cap). AgentSessionStore isn't observed; the flip to
                    // the full-color badge rides on process detection
                    // updating the session once the resume command runs.
                    DormantAgentBadgeView(process: dormant, isSelected: isSelected)
                } else if namer.namingSessions.contains(session.id) {
                    AutoNamingIndicator()
                        .frame(width: 8, height: 8)
                } else {
                    // Idle terminal glyph in the folder grey — a
                    // template, so Theme.ink adapts it to the light/
                    // dark sidebar. Unselected rows stay whisper-quiet.
                    Image("TerminalIdle16")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(Theme.ink.opacity(isSelected ? 0.85 : 0.4))
                        .frame(width: 16, height: 16)
                }
            }
            .frame(width: 16, height: 16)

            if isRenaming {
                TextField("", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(PaletteFont.text(14, .regular))
                    .foregroundStyle(Theme.text(1))
                    .focused($renameFieldFocused)
                    .onSubmit {
                        commitRename(session)
                        restoreTerminalFocus()
                    }
                    .onExitCommand {
                        renamingSessionID = nil
                        restoreTerminalFocus()
                    }
            } else {
                Text(session.title)
                    .font(PaletteFont.text(14, .regular))
                    .tracking(PaletteFont.tracking)
                    .foregroundStyle(Theme.text(isSelected ? 0.95 : 0.62))
                    .lineLimit(1)
                    .nameShimmer(namer.namingSessions.contains(session.id))
                    // Rename only when the double-click lands on the
                    // title itself, not anywhere in the row.
                    .simultaneousGesture(TapGesture().onEnded {
                        if NSApp.currentEvent?.clickCount == 2 {
                            beginRename(session)
                        }
                    })
            }

            Spacer(minLength: 0)
            if hoveredSessionID == session.id && !isRenaming {
                // Hover-revealed × on the tab row; same frame and insets as
                // the folder header's trailing icons.
                HoverIconButton(
                    help: "Close Tab",
                    size: 24,
                    idleTint: 0.5,
                    washOpacity: 0.09,
                    action: { store.close(sessionID: session.id) }
                ) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
            } else if session.status == .attention {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    // The dot keeps its pre-icon-inset spot (9pt optical)
                    // instead of following the icons out to the 4pt inset.
                    .padding(.trailing, 5)
            }
        }
        // 24pt content box in 4pt insets — see the folder header: same 32pt
        // row, hover × reaches to 4pt off the edges, text stays put.
        .frame(minHeight: 24)
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selectedRowBackground(
                isSelected: isSelected,
                isMultiSelected: isMultiSelected,
                isHovered: hoveredSessionID == session.id
            )
        )
        .contentShape(Rectangle())
        .modifier(RowPressScale())
        .onHover { hovering in
            if hovering {
                hoveredSessionID = session.id
            } else if hoveredSessionID == session.id {
                hoveredSessionID = nil
            }
        }
        // A single immediate gesture (no TapGesture(count: 2) sibling):
        // pairing single+double tap makes SwiftUI hold every click for
        // the double-click interval before selecting. Instead, select on
        // every click instantly; rename lives on the title text itself.
        .simultaneousGesture(TapGesture().onEnded {
            if NSApp.currentEvent?.clickCount == 1 {
                handleTap(session)
            }
        })
        .onDrag {
            let payload = SidebarDragPayload.tabs(Array(contextTargets(for: session)))
            beginDragTracking(payload)
            return NSItemProvider(object: payload.stringValue as NSString)
        } preview: {
            sessionDragPreview(session)
        }
        .contextMenu {
            contextMenu(for: session)
        }
        .background(rowFrameReporter(session.id))
        // Every sidebar row spaces itself with the same top gap, so the
        // rhythm is uniform across tabs and folders and drag hit-areas stay
        // contiguous. The gap sits outside the reported frame.
        .padding(.top, SpacePage.rowGap)
        .onChange(of: renameFieldFocused) { _, focused in
            if !focused, renamingSessionID == session.id {
                commitRename(session)
            }
        }
        // Rows shifted by a folder collapse move as one geometry unit;
        // without this the icon and text interpolate at different rates.
        .geometryGroup()
    }

    /// Selected tab background. In dark mode it's the familiar bright wash; in
    /// light mode the selected row lifts off the sidebar as a solid white card
    /// with a soft shadow rather than reading as a flat grey fill.
    @ViewBuilder
    private func selectedRowBackground(
        isSelected: Bool,
        isMultiSelected: Bool,
        isHovered: Bool
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        if isSelected {
            shape
                .fill(colorScheme == .light ? Color.white : Color.white.opacity(0.14))
                .shadow(color: .black.opacity(0.14), radius: 0.40357, x: 0, y: 0.75)
                .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 2)
        } else if isMultiSelected {
            shape.fill(Theme.ink.opacity(0.07))
        } else if isHovered {
            shape.fill(Theme.ink.opacity(0.05))
        } else {
            shape.fill(Color.clear)
        }
    }

    private func beginRename(_ session: TerminalSession) {
        draftTitle = session.title
        renamingSessionID = session.id
        renameFieldFocused = true
    }

    private func toggleExpansion(_ folder: TerminalFolder) {
        if store.collapsedFolderIDs.contains(folder.id) {
            store.collapsedFolderIDs.remove(folder.id)
        } else {
            store.collapsedFolderIDs.insert(folder.id)
        }
    }

    private func beginFolderRename(_ folder: TerminalFolder) {
        draftFolderTitle = folder.title
        renamingFolderID = folder.id
        folderRenameFocused = true
    }

    private func commitFolderRename(_ folder: TerminalFolder) {
        guard renamingFolderID == folder.id else { return }
        renamingFolderID = nil
        store.rename(folder, to: draftFolderTitle)
    }

    private func commitRename(_ session: TerminalSession) {
        guard renamingSessionID == session.id else { return }
        renamingSessionID = nil
        store.rename(session, to: draftTitle)
    }

    @ViewBuilder
    private func contextMenu(for session: TerminalSession) -> some View {
        let targets = contextTargets(for: session)
        let plural = targets.count > 1 ? " \(targets.count) Tabs" : " Tab"

        Button("New Folder with\(plural)", systemImage: "folder.badge.plus") {
            store.createFolder(with: targets, inSpace: space.id)
        }

        if !space.pinnedFolders.isEmpty {
            Menu("Move to Folder") {
                ForEach(space.pinnedFolders) { folder in
                    Button(folder.title) {
                        store.move(targets, toFolder: folder.id)
                    }
                }
            }
        }

        if store.spaces.count > 1 {
            Menu("Move to Space") {
                ForEach(store.spaces.filter { $0.id != space.id }) { other in
                    Button(other.name) {
                        store.unpin(targets, inSpace: other.id)
                    }
                }
            }
        }

        if targets.contains(where: { !store.isPinned($0) }) {
            Button("Pin\(plural)", systemImage: "pin") {
                store.pin(targets, inSpace: space.id)
            }
        }
        if targets.contains(where: { store.isPinned($0) }) {
            Button("Unpin\(plural)", systemImage: "pin.slash") {
                store.unpin(targets, inSpace: space.id)
            }
        }

        if targets.count == 1 {
            Button("Rename", systemImage: "pencil") {
                beginRename(session)
            }
        }

        Divider()

        Button("Close\(plural)", systemImage: "xmark") {
            store.close(sessionIDs: targets)
        }
    }

    private func handleTap(_ session: TerminalSession) {
        // The row tap fires alongside the close button's action; never
        // select a session the button just closed.
        guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        cancelRenames()
        let flags = NSEvent.modifierFlags

        if flags.contains(.command) {
            if store.multiSelection.contains(session.id) {
                store.multiSelection.remove(session.id)
            } else {
                store.multiSelection.insert(session.id)
            }
            store.selection = session.id
        } else if flags.contains(.shift), let anchor = store.selection {
            let order = visibleOrder()
            if let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: session.id) {
                store.multiSelection.formUnion(order[min(from, to)...max(from, to)])
            }
        } else {
            store.selection = session.id
            store.multiSelection = [session.id]
        }
    }

    private func contextTargets(for session: TerminalSession) -> Set<TerminalSession.ID> {
        store.multiSelection.count > 1 && store.multiSelection.contains(session.id)
            ? store.multiSelection
            : [session.id]
    }

    /// Visible tab order for shift-click ranges; derived from the same
    /// flatten as drop projection, so the two can never drift.
    private func visibleOrder() -> [TerminalSession.ID] {
        flatRows.filter { $0.kind == .tab }.map(\.id)
    }

    // MARK: - Drag and drop

    private static let dropSpaceName = "sidebarDropSpace"

    /// The uniform gap between all sidebar rows.
    private static let rowGap: CGFloat = 4

    /// The sidebar's visual order, flattened; shared by drop projection and
    /// selection ranges.
    private var flatRows: [SidebarFlatRow] {
        flattenSidebar(
            space: space,
            collapsedFolderIDs: store.collapsedFolderIDs,
            selection: store.selection
        )
    }

    private func rowFrameReporter(_ id: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: SidebarRowFrameKey.self,
                value: [id: geo.frame(in: .named(Self.dropSpaceName))]
            )
        }
    }

    /// The single insertion indicator: a small open ring at the leading
    /// edge with the line running from its right edge — both following the
    /// proposal's depth indent.
    @ViewBuilder
    private var dropIndicatorLine: some View {
        if let proposal = dropProposal,
           case .line(let y, let minX, let maxX) = proposal.indicator {
            let ringSize: CGFloat = 7
            ZStack(alignment: .topLeading) {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: ringSize, height: ringSize)
                    .offset(x: minX, y: y - ringSize / 2)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: max(maxX - minX - ringSize - 1, 2), height: 2)
                    .offset(x: minX + ringSize + 1, y: y - 1)
            }
            .allowsHitTesting(false)
        }
    }

    /// Records the in-flight payload at drag start and resets any state a
    /// previous drag left behind.
    private func beginDragTracking(_ payload: SidebarDragPayload) {
        store.activeSidebarDrag = payload
        dropProposal = nil
        dragReferenceX = nil
        startDragWatch()
    }

    /// Hover: projects the pointer onto exactly one proposal. Returns
    /// whether the position is valid, for the drop operation cursor.
    private func handleDragUpdate(at location: CGPoint) -> Bool {
        if dragReferenceX == nil {
            dragReferenceX = location.x
        }
        startDragWatch()
        pointerInViewport = CGPoint(
            x: location.x,
            y: scrollDriver.viewportY(forContentY: location.y)
        )
        // While auto-scroll slides content under a still pointer, keep the
        // proposal tracking the row that is actually underneath it.
        scrollDriver.onAutoScroll = { offset in
            guard let pointer = pointerInViewport else { return }
            _ = updateProposal(at: CGPoint(x: pointer.x, y: pointer.y + offset))
        }
        scrollDriver.updateAutoScroll(pointerViewportY: pointerInViewport?.y ?? location.y)
        return updateProposal(at: location)
    }

    private func updateProposal(at location: CGPoint) -> Bool {
        // No recorded payload: either a foreign drag (text from outside —
        // the drop would no-op, so promise nothing) or a trailing
        // dropUpdated after a completed drop, which must not resurrect the
        // indicator (dropExited doesn't reliably fire after a drop).
        guard let payload = store.activeSidebarDrag else {
            if dropProposal != nil { dropProposal = nil }
            return false
        }
        let resolver = SidebarDropResolver(
            rows: flatRows,
            rowFrames: rowFrames,
            dividerFrame: dividerFrame
        )
        let resolution = resolver.resolve(
            at: location,
            dragging: payload,
            horizontalDelta: location.x - (dragReferenceX ?? location.x)
        )
        dropProposal = resolution.proposal
        // A no-op slot shows nothing but keeps the move cursor; only truly
        // invalid positions read as forbidden.
        return !resolution.isInvalid
    }

    private func endDragTracking() {
        dropProposal = nil
        pointerInViewport = nil
        dragReferenceX = nil
        scrollDriver.onAutoScroll = nil
        scrollDriver.stop()
    }

    // MARK: End-of-drag watch

    private func startDragWatch() {
        guard dragWatchTimer == nil else { return }
        dragReleaseTicks = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in dragWatchTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragWatchTimer = timer
    }

    private func stopDragWatch() {
        dragWatchTimer?.invalidate()
        dragWatchTimer = nil
        dragReleaseTicks = 0
    }

    private func dragWatchTick() {
        guard NSEvent.pressedMouseButtons == 0 else {
            dragReleaseTicks = 0
            return
        }
        // Grace ticks: a release over a drop target delivers performDrop
        // within the first beat and stops the watch before we get here.
        dragReleaseTicks += 1
        guard dragReleaseTicks >= 2 else { return }
        cancelDrag()
    }

    /// The drag ended without a drop (ESC, or released outside every
    /// target): undo everything the flight changed.
    private func cancelDrag() {
        stopDragWatch()
        if case .folder(let folderID) = store.activeSidebarDrag {
            restoreDraggedFolderExpansion(folderID)
        }
        store.activeSidebarDrag = nil
        endDragTracking()
    }

    /// Commit: decodes the real payload (the recorded one may be stale for
    /// foreign drags) and maps the final proposal onto store mutations.
    private func performDrop(_ info: DropInfo) -> Bool {
        stopDragWatch()
        let proposal = dropProposal
        endDragTracking()
        // Cleared synchronously so any trailing dropUpdated resolves to no
        // payload — and therefore no indicator.
        store.activeSidebarDrag = nil
        guard let proposal else { return false }
        let providers = info.itemProviders(for: [.text])
        guard !providers.isEmpty else { return false }
        let spaceID = space.id
        Task { @MainActor in
            var items: [String] = []
            for provider in providers {
                if let item = await provider.sidebarDragString() {
                    items.append(item)
                }
            }
            guard let payload = SidebarDragPayload.decode(items: items) else { return }
            store.applySidebarDrop(payload, target: proposal.target, inSpace: spaceID)
            if case .folder(let folderID) = payload {
                restoreDraggedFolderExpansion(folderID)
            }
            // A tab that landed inside a collapsed folder must stay
            // visible: open the folder it ended up in.
            var landedFolderID: TerminalFolder.ID?
            if case .tabs(let ids) = payload, let first = ids.first {
                landedFolderID = store.spaces
                    .compactMap { $0.folder(containing: first) }
                    .first?.id
            }
            if let landedFolderID {
                _ = store.collapsedFolderIDs.remove(landedFolderID)
            }
        }
        return true
    }
}

/// Icon button with its own hover wash so the click target reads before the
/// mouse commits. Defaults to the 18×18 frame the header icons share; the
/// label is arbitrary content so custom template assets and resized glyphs
/// fit the same treatment.
private struct HoverIconButton<Label: View>: View {
    let help: String
    let size: CGFloat
    let idleTint: Double
    let washOpacity: Double
    let action: () -> Void
    let label: Label
    @State private var isHovered = false

    init(
        help: String,
        size: CGFloat = 18,
        idleTint: Double = 0.55,
        washOpacity: Double = 0.12,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.help = help
        self.size = size
        self.idleTint = idleTint
        self.washOpacity = washOpacity
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(Theme.text(isHovered ? 0.9 : idleTint))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.ink.opacity(isHovered ? washOpacity : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

extension HoverIconButton where Label == AnyView {
    /// SF Symbol shorthand at the shared header glyph size.
    init(systemName: String, help: String, size: CGFloat = 18, washOpacity: Double = 0.12, action: @escaping () -> Void) {
        self.init(help: help, size: size, washOpacity: washOpacity, action: action) {
            AnyView(
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
            )
        }
    }
}

/// Detected-process icon in the tab row's leading slot: adaptive artwork
/// for agents (full color, dimmed when inactive), SF Symbol in neutral
/// ink for known tools, the running-blue dot for anything else alive.
private struct ProcessBadgeView: View {
    let process: TabProcess
    let isSelected: Bool

    var body: some View {
        switch process.badge {
        case .agent(let base):
            // 16 pt matches the artwork's 16 px pixel grid (and the row's
            // badge slot) so pixel edges land on whole pixels. Full-color
            // mark on every tab — its light/dark appearance variants track
            // the app theme via the asset catalog. (The "<base>16Tinted"
            // template glyphs are the dormant treatment; see
            // DormantAgentBadgeView.)
            Image("\(base)16")
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .opacity(isSelected ? 1 : 0.8)
                .frame(width: 16, height: 16)
        case .symbol(let name):
            // Neutral ink like the folder glyphs — tool badges are status,
            // not identity, so they don't take the tab accent (issue #43).
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(isSelected ? 0.8 : 0.55))
        case .dot:
            // A live process without artwork: the idle terminal glyph
            // turns blue so "something is running here" reads at a glance;
            // unselected rows keep it as quiet as the idle grey.
            Image("TerminalIdle16")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Color.blue.opacity(isSelected ? 0.95 : 0.45))
                .frame(width: 16, height: 16)
        }
    }
}

/// Tinted agent mark for a tab whose agent session will resume on first
/// visit (or when the eager sweep reaches it). Quiet ink instead of the
/// full-color mark, so "an agent lives here but isn't running" reads at a
/// glance without claiming the active treatment — the row flips to
/// ProcessBadgeView once the resume runs and detection sees the agent.
private struct DormantAgentBadgeView: View {
    let process: TabProcess
    let isSelected: Bool

    var body: some View {
        if case .agent(let base) = process.badge {
            Image("\(base)16Tinted")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Theme.ink.opacity(isSelected ? 0.7 : 0.45))
                .frame(width: 16, height: 16)
        }
    }
}

/// Small spinner in the tab row's dot slot while the LLM is naming it.
private struct AutoNamingIndicator: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.18, to: 1)
            .stroke(
                Theme.ink.opacity(0.6),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
            )
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}

/// Gradient band sweeping across the tab title while it's being auto-named.
private struct NameShimmer: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    let band = geo.size.width * 0.9
                    LinearGradient(
                        colors: [.clear, .cyan, .purple, .pink, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: band)
                    .offset(x: -band + phase * (geo.size.width + band * 2))
                }
                .allowsHitTesting(false)
            )
            .mask(content)
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private extension View {
    /// Conditional shimmer; the if/else swap resets the animation each time
    /// naming starts.
    @ViewBuilder
    func nameShimmer(_ active: Bool) -> some View {
        if active {
            modifier(NameShimmer())
        } else {
            self
        }
    }
}

/// While a rename is active, watches for any mouse-down that doesn't land
/// in the text editor and ends the rename before the click proceeds —
/// clicking the terminal, another row, or anywhere else exits edit mode.
/// Shared with the terminal header's inline rename.
struct RenameClickAway: NSViewRepresentable {
    var active: Bool
    let onClickAway: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onClickAway = onClickAway
        context.coordinator.setActive(active)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onClickAway: () -> Void = {}
        nonisolated(unsafe) private var monitor: Any?

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown]
                ) { [weak self] event in
                    self?.handle(event)
                    return event
                }
            } else if !active, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window = view?.window, event.window === window else { return }
            let hit = window.contentView?.hitTest(event.locationInWindow)
            // The active field editor is an NSTextView; anything else ends
            // the rename. Async so the click still dispatches normally.
            guard !(hit is NSTextView) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onClickAway()
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - Space indicators

private struct SpaceIndicatorBar: View {
    @ObservedObject var store: TerminalSessionStore
    let onEdit: (SidebarSpace) -> Void
    let onCreate: () -> Void

    @State private var hoveredSpaceID: SidebarSpace.ID?
    @State private var plusHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)

            ForEach(store.spaces) { space in
                let isActive = store.activeSpaceID == space.id
                let isHovered = hoveredSpaceID == space.id
                Button {
                    withAnimation(.spring(duration: 0.32, bounce: 0.12)) {
                        store.setActiveSpace(space.id)
                    }
                } label: {
                    SpaceIndicatorIcon(icon: space.icon, isActive: isActive, size: 18)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle().fill(Theme.ink.opacity(isHovered ? 0.1 : 0))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        hoveredSpaceID = space.id
                    } else if hoveredSpaceID == space.id {
                        hoveredSpaceID = nil
                    }
                }
                .help(space.name)
                .contextMenu {
                    Button("Edit Space…", systemImage: "pencil") {
                        onEdit(space)
                    }
                    Button("Delete Space", systemImage: "trash") {
                        store.deleteSpace(space.id)
                    }
                    .disabled(store.spaces.count == 1)
                }
            }

            Button(action: onCreate) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.text(plusHovered ? 0.7 : 0.3))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(Theme.ink.opacity(plusHovered ? 0.1 : 0))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { plusHovered = $0 }
            .help("New Space (or swipe past the last space)")

            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .padding(.bottom, 6)
    }
}

private struct SpaceIndicatorIcon: View {
    let icon: SidebarSpace.Icon
    let isActive: Bool
    var size: CGFloat = 18

    var body: some View {
        switch icon {
        case .dot:
            Circle()
                .fill(Theme.ink.opacity(isActive ? 0.85 : 0.25))
                .frame(width: size * 0.36, height: size * 0.36)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.61, weight: .medium))
                .foregroundStyle(Theme.text(isActive ? 0.9 : 0.3))
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: size * 0.67))
                .opacity(isActive ? 1 : 0.4)
        }
    }
}

// MARK: - Space editor

struct SpaceEditorSheet: View {
    enum Mode: Equatable {
        case create
        case edit(SidebarSpace)
    }

    private enum PickerTab: Hashable {
        case icons
        case emoji
    }

    /// What the icon disc is showing: the space's icon, or the hover-state
    /// plus. One keyed identity means the hover swap rides exactly the same
    /// iconSwap transition as a shuffle, and a shuffle mid-hover can't fight
    /// it — each change is just a new key.
    private enum DiscContent: Hashable {
        case icon(SidebarSpace.Icon)
        case plus
    }

    let mode: Mode
    let onSave: (String, SidebarSpace.Icon) -> Void
    let onDismiss: () -> Void

    @State private var name = ""
    @State private var icon: SidebarSpace.Icon = .dot
    @State private var pickerTab: PickerTab = .icons
    @State private var symbolQuery = ""
    @State private var emojiQuery = ""
    /// Drives the shuffle button's squash-and-pop on each press.
    @State private var shufflePop = false
    @State private var closeHovered = false
    /// Icon disc hover: rings the disc in accent and swaps the icon for a
    /// plus, signalling that the disc opens the picker.
    @State private var iconHovered = false
    /// The Icons/Emoji picker now floats in a popover anchored to the disc,
    /// so the sheet stays compact instead of embedding the grids inline.
    @State private var pickerPresented = false
    @FocusState private var nameFocused: Bool

    private let catalog = IconCatalog.shared

    var body: some View {
        VStack(spacing: 0) {
            iconPreview
                .padding(.top, 32)
                .padding(.bottom, 14)

            Text(isCreating ? "Create a Space" : "Edit Space")
                .font(.system(size: 17, weight: .semibold))
                .padding(.bottom, 14)

            TextField("Name your space", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($nameFocused)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.ink.opacity(nameFocused ? 0.12 : 0.06))
                )
                .onSubmit(saveAndDismiss)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)

            // Bottom-aligned footer, web-modal style: two equal-width
            // solid buttons spanning the sheet.
            HStack(spacing: 8) {
                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(ModalSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button {
                    saveAndDismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCreating ? "plus" : "checkmark")
                            .font(.system(size: 11, weight: .bold))
                        Text(isCreating ? "Create Space" : "Save")
                    }
                }
                .buttonStyle(ModalPrimaryButtonStyle(accent: .accentColor))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 340)
        .overlay(alignment: .topTrailing) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text(closeHovered ? 0.85 : 0.45))
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(Theme.ink.opacity(closeHovered ? 0.08 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { closeHovered = $0 }
            .arrowCursorOnHover()
            .padding(10)
        }
        // Fully owned chrome: presented as an in-window overlay, not a
        // macOS sheet, so no system border or forced corner radius. Same
        // frost as What's New.
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(ModalFrostBackdrop())
        .onAppear {
            if case .edit(let space) = mode {
                name = space.name
                icon = space.icon
            } else {
                // A random pick greets new spaces; the dot is always one tap
                // away as the first Icons tile.
                icon = catalog.shuffleChoices.randomElement() ?? .dot
                nameFocused = true
            }
        }
    }

    // MARK: Preview + shuffle

    private var iconPreview: some View {
        ZStack(alignment: .bottomTrailing) {
            iconDisc
            shuffleButton
                .offset(x: 4, y: 4)
        }
        // Every disc change — shuffle, tile tap, or the hover plus — rides
        // the same spring, so the preview always animates its swap.
        .animation(.spring(duration: 0.32, bounce: 0.32), value: discContent)
    }

    /// The clickable icon well. It opens the picker popover; on hover a ring
    /// thickens in and the icon swaps out for a plus, reading as "change".
    private var iconDisc: some View {
        Button {
            pickerPresented = true
        } label: {
            ZStack {
                // Recessed well so the preview reads as a distinct disc.
                // A dedicated token keeps the black well in dark mode and
                // swaps to a visible grey in light mode, where a white well
                // would disappear into the light panel.
                Circle()
                    .fill(Theme.iconWell)

                // Keyed on what's showing, so every swap — a shuffle or the
                // hover plus — plays the shrink-out / spring-in transition
                // instead of cross-fading in place.
                Group {
                    switch discContent {
                    case .icon(let current):
                        SpaceIndicatorIcon(icon: current, isActive: true, size: 46)
                    case .plus:
                        // Sized like the space icon it stands in for.
                        Image(systemName: "plus")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Theme.text(0.9))
                    }
                }
                .id(discContent)
                .transition(iconSwap)
            }
            .frame(width: 84, height: 84)
            // Faint ring marks the disc as the picker's trigger: its stroke
            // grows from nothing on hover, so it thickens in rather than fades.
            .overlay(
                Circle()
                    .stroke(
                        Theme.ink.opacity(0.2),
                        style: StrokeStyle(lineWidth: iconHovered ? 2 : 0)
                    )
                    .animation(.easeInOut(duration: 0.14), value: iconHovered)
            )
            .contentShape(Circle())
        }
        .buttonStyle(IconDiscButtonStyle(hovered: iconHovered))
        .onHover { hovering in
            iconHovered = hovering
            // Pointing-hand cursor confirms the disc is clickable.
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // Anchored below the disc; the picker keeps all its original
        // functionality, just floated instead of embedded.
        .popover(isPresented: $pickerPresented, arrowEdge: .bottom) {
            pickerPopover
        }
    }

    /// What the disc currently shows; hover trumps the icon.
    private var discContent: DiscContent {
        iconHovered ? .plus : .icon(icon)
    }

    private var shuffleButton: some View {
        Button {
            shuffle()
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.inverseInk.opacity(0.8))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.ink.opacity(0.94)))
                // A low-damping spring back to 1 overshoots into a pop.
                .scaleEffect(shufflePop ? 0.8 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.42), value: shufflePop)
        }
        .buttonStyle(.plain)
        .arrowCursorOnHover()
        .help("Shuffle icon")
    }

    /// Springy squash on press, then a fresh icon from the full curated set
    /// (symbols + emoji), never repeating what's already showing.
    private func shuffle() {
        shufflePop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            shufflePop = false
        }

        let choices = catalog.shuffleChoices.filter { $0 != icon }
        guard let next = choices.randomElement() else { return }
        icon = next
    }

    /// Outgoing icon shrinks and blurs away; the incoming one blurs in and
    /// springs up to full scale (asymmetric, in the spirit of ModalPopEffect).
    private var iconSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: IconSwapEffect(progress: 0),
                identity: IconSwapEffect(progress: 1)
            ),
            removal: .modifier(
                active: IconSwapEffect(progress: 0),
                identity: IconSwapEffect(progress: 1)
            )
        )
    }

    // MARK: Icon / emoji picker

    private var picker: some View {
        VStack(spacing: 10) {
            tabBar

            searchField(
                text: pickerTab == .icons ? $symbolQuery : $emojiQuery,
                prompt: pickerTab == .icons ? "Search icons" : "Search emoji"
            )

            // Fills the popover; the grids scroll within whatever space is left.
            Group {
                switch pickerTab {
                case .icons: iconsGrid
                case .emoji: emojiGrid
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// The picker, floated in a popover anchored to the icon disc. The
    /// NSPopover chrome is system-drawn; a dark presentation background plus
    /// forced dark scheme keep it from coming up glaring white against Enso.
    private var pickerPopover: some View {
        picker
            .padding(14)
            .frame(width: 340, height: 380)
            .background(popoverBackground)
            .presentationBackground(popoverBackground)
    }

    /// Matches the sheet's own panel fill; adaptive so the floated picker
    /// follows the system appearance like the rest of the editor.
    private var popoverBackground: Color {
        Theme.panel
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton("Icons", tab: .icons)
            tabButton("Emoji", tab: .emoji)
            Spacer(minLength: 0)
        }
    }

    private func tabButton(_ title: String, tab: PickerTab) -> some View {
        let selected = pickerTab == tab
        return Button {
            pickerTab = tab
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text(selected ? 0.92 : 0.5))
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.ink.opacity(selected ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .arrowCursorOnHover()
    }

    private func searchField(text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text(0.35))
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.ink.opacity(0.06))
        )
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 38), spacing: 6)]
    }

    private var iconsGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 6) {
                ForEach(filteredIconTiles) { tile in
                    tileButton(isSelected: icon == tile.icon) {
                        select(tile.icon)
                    } content: {
                        SpaceIndicatorIcon(icon: tile.icon, isActive: true, size: 22)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var emojiGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 6, pinnedViews: [.sectionHeaders]) {
                if emojiQuery.isEmpty {
                    // Unfiltered: gemoji categories, each under a sticky header.
                    ForEach(catalog.emojiCategories, id: \.self) { category in
                        Section {
                            ForEach(catalog.emojiByCategory[category] ?? [], id: \.emoji) { entry in
                                emojiTile(entry)
                            }
                        } header: {
                            sectionHeader(category)
                        }
                    }
                } else {
                    ForEach(filteredEmoji, id: \.emoji) { entry in
                        emojiTile(entry)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func emojiTile(_ entry: EmojiEntry) -> some View {
        tileButton(isSelected: icon == .emoji(entry.emoji)) {
            select(.emoji(entry.emoji))
        } content: {
            Text(entry.emoji)
                .font(.system(size: 20))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.text(0.4))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
        .background(Theme.panel.opacity(0.92))
    }

    /// One selectable grid cell: a rounded well that fills with the accent
    /// when it holds the current icon. Hover and press chrome live in the
    /// button style, which keeps its own per-tile state.
    private func tileButton<Content: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 38, height: 34)
        }
        .buttonStyle(PickerTileStyle(isSelected: isSelected))
    }

    // MARK: Filtering

    private var filteredIconTiles: [IconTile] {
        let tokens = queryTokens(symbolQuery)
        guard !tokens.isEmpty else { return catalog.iconTiles }
        return catalog.iconTiles.filter { tile in
            tokens.allSatisfy { tile.searchText.contains($0) }
        }
    }

    private var filteredEmoji: [EmojiEntry] {
        let tokens = queryTokens(emojiQuery)
        guard !tokens.isEmpty else { return catalog.emoji }
        return catalog.emoji.filter { entry in
            let text = entry.searchText
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    /// Whitespace-split, lowercased query terms; a tile must match them all.
    private func queryTokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: Save

    /// Applies a picked tile and closes the popover — close-on-pick keeps the
    /// flow tight; the disc reopens it for another change.
    private func select(_ newIcon: SidebarSpace.Icon) {
        icon = newIcon
        pickerPresented = false
    }

    private func saveAndDismiss() {
        onSave(name, icon)
        onDismiss()
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }
}

/// Picker grid-tile chrome: accent fill when selected, a slightly brighter
/// well plus a small swell on hover, and a settle back to rest while the
/// mouse is down. Hover is per-tile @State inside the style, so hovering
/// repaints one tile — never the whole lazy grid.
private struct PickerTileStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isSelected: isSelected)
    }

    private struct Styled: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(0.85)
                                : Theme.ink.opacity(hovering ? 0.09 : 0.04)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Theme.ink.opacity(isSelected ? 0.5 : 0), lineWidth: 1)
                )
                .contentShape(Rectangle())
                // Pressing brings the hovered swell back down to rest, so the
                // click reads as a push into the grid.
                .scaleEffect(configuration.isPressed ? 1 : (hovering ? 1.04 : 1))
                .onHover { hovering = $0 }
                .arrowCursorOnHover()
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
                .animation(.easeInOut(duration: 0.14), value: hovering)
        }
    }
}

/// The icon disc's hover/press feel: swells a hair on hover, dips while the
/// mouse is down — same snappy press timing as the modal buttons.
private struct IconDiscButtonStyle: ButtonStyle {
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : (hovered ? 1.05 : 1))
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.14), value: hovered)
    }
}

/// Pressed feel for sidebar rows: dips to 0.98 while the mouse is down and
/// springs back on release. Tracked with a zero-distance drag held in
/// `@GestureState`, so the scale resets the instant the pointer moves or the
/// system cancels the gesture (a drag-to-reorder taking over) — the dip never
/// follows a drag.
private struct RowPressScale: ViewModifier {
    /// One-way press tracking: `began` on the first event, `released` once
    /// the pointer strays past the threshold. Wandering back over the press
    /// point never re-engages the dip; `@GestureState` clears both on end or
    /// cancel.
    private struct PressState {
        var began = false
        var released = false
    }

    @GestureState private var press = PressState()

    func body(content: Content) -> some View {
        let pressed = press.began && !press.released
        return content
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.12), value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($press) { value, state, _ in
                        state.began = true
                        if hypot(value.translation.width, value.translation.height) >= 2 {
                            state.released = true
                        }
                    }
            )
    }
}

/// Icon-swap transition: shrinks and blurs the outgoing icon away, blurs the
/// incoming one in and springs it up to full scale (progress 1 = settled).
private struct IconSwapEffect: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.4 + 0.6 * progress)
            .blur(radius: 8 * (1 - progress))
            .opacity(Double(progress))
    }
}

extension View {
    /// Forces the arrow cursor while the pointer is over an interactive
    /// control. The space editor hosts a focused `TextField`, whose AppKit
    /// I-beam cursor rect otherwise bleeds onto the surrounding buttons and
    /// picker tiles; pushing/popping an explicit arrow cursor on hover keeps
    /// the I-beam confined to the actual text fields.
    func arrowCursorOnHover() -> some View {
        onHover { inside in
            inside ? NSCursor.arrow.push() : NSCursor.pop()
        }
    }
}

// MARK: - Button styles

/// Solid white primary action, web-modal style: full-width rounded
/// rectangle, dark label, no gradient or border. Brightens on hover.
struct ModalPrimaryButtonStyle: ButtonStyle {
    /// Optional tint override (e.g. `.accentColor` for the system blue);
    /// nil keeps the ink fill with its appearance-aware ramp.
    var accent: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, accent: accent)
    }

    private struct Styled: View {
        let configuration: Configuration
        let accent: Color?
        @Environment(\.colorScheme) private var scheme
        @State private var hovering = false

        // Light mode drives the fill near-solid so the primary button reads
        // as dark as the app's primary text (`Theme.ink` is near-black there);
        // the airy 0.9 ramp that looks right as a white button on dark is far
        // too pale as a dark button on the light panel. Dark mode keeps its
        // original white ramp untouched.
        private var fillOpacity: Double {
            if accent != nil {
                return configuration.isPressed ? 0.8 : (hovering ? 0.9 : 1)
            }
            if scheme == .light {
                return configuration.isPressed ? 0.86 : (hovering ? 0.92 : 1)
            }
            return configuration.isPressed ? 0.78 : (hovering ? 1 : 0.9)
        }

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent == nil ? Theme.inverseInk.opacity(0.88) : Color.white.opacity(0.95))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((accent ?? Theme.ink).opacity(fillOpacity))
                )
                .onHover { hovering = $0 }
                .arrowCursorOnHover()
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Muted gray secondary action matching the primary's geometry.
struct ModalSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text(hovering ? 0.92 : 0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.ink.opacity(
                            configuration.isPressed ? 0.16 : (hovering ? 0.13 : 0.09)
                        ))
                )
                .onHover { hovering = $0 }
                .arrowCursorOnHover()
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
        }
    }
}

#Preview {
    SidebarView(store: .preview, spaceEditor: .constant(nil))
        .frame(width: 264, height: 600)
        .background(.black)
}
