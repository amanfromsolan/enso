import SwiftUI

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
                    .fill(Color.black.opacity(0.45))
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35 + 0.65 * progress))
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
    let space: SidebarSpace
    let onEditSpace: (SidebarSpace) -> Void

    @State private var dropTargetID: TerminalSession.ID?
    @State private var hoveredSessionID: TerminalSession.ID?
    @State private var renamingSessionID: TerminalSession.ID?
    @State private var draftTitle = ""
    @FocusState private var renameFieldFocused: Bool

    @State private var hoveredFolderID: TerminalFolder.ID?
    /// Folder currently targeted by an in-flight drag (highlight or line).
    @State private var folderDropTargetID: TerminalFolder.ID?
    /// Folder whose end-of-children strip is targeted.
    @State private var folderEndDropFolderID: TerminalFolder.ID?
    @State private var headerDropTargeted = false
    @State private var pinnedZoneTargeted = false
    @State private var ephemeralZoneTargeted = false
    /// Set at drag start so hover feedback knows a folder (not tabs) is in
    /// flight; healed by the next drag start if a drag is cancelled.
    @State private var draggedFolderID: TerminalFolder.ID?
    /// Folders collapse for the flight; remember whether to reopen on drop.
    @State private var draggedFolderWasExpanded = false
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
        var ids = space.pinnedSessions.map(\.id)
        for folder in space.pinnedFolders {
            ids.append(folder.id)
            ids.append(contentsOf: folder.sessions.map(\.id))
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
            SpaceIndicatorIcon(icon: space.icon, isActive: true, size: 15)
                .frame(width: 16)

            if isRenamingSpace {
                TextField("", text: $draftSpaceName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    // Rename only on the name text, not the whole header.
                    .onTapGesture(count: 2) {
                        beginSpaceRename()
                    }
            }

            Spacer(minLength: 0)

            // Always laid out, faded on hover: conditionally inserting the
            // 18pt controls changes the row height and jolts the sidebar.
            Group {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        beginSpaceRename()
                    }
                    Button("Edit Icon & Name…", systemImage: "pencil.and.outline") {
                        onEditSpace(space)
                    }
                    // Bulk folder controls, shown only when the space has any.
                    if !space.pinnedFolders.isEmpty {
                        Divider()
                        Button("Collapse All Folders", systemImage: "chevron.right") {
                            store.collapseAllFolders(inSpace: space.id)
                        }
                        .disabled(allFoldersCollapsed)
                        Button("Expand All Folders", systemImage: "chevron.down") {
                            store.expandAllFolders(inSpace: space.id)
                        }
                        .disabled(allFoldersExpanded)
                    }
                    Divider()
                    Button("Delete Space", systemImage: "trash") {
                        store.deleteSpace(space.id)
                    }
                    .disabled(store.spaces.count == 1)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(headerMenuHovered ? 0.9 : 0.55))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(headerMenuHovered ? 0.12 : 0))
                )
                .onHover { headerMenuHovered = $0 }
            }
            .opacity(headerHovered && !isRenamingSpace ? 1 : 0)
            .allowsHitTesting(headerHovered && !isRenamingSpace)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(headerHovered ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            headerHovered = hovering
        }
        .padding(.bottom, 4)
    }

    /// Every folder in this space is collapsed — nothing left to collapse.
    private var allFoldersCollapsed: Bool {
        space.pinnedFolders.allSatisfy { store.collapsedFolderIDs.contains($0.id) }
    }

    /// Every folder in this space is expanded — nothing left to expand.
    private var allFoldersExpanded: Bool {
        space.pinnedFolders.allSatisfy { !store.collapsedFolderIDs.contains($0.id) }
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
        VStack(alignment: .leading, spacing: 2) {
            spaceHeader
                .onChange(of: spaceNameFocused) { _, focused in
                    if !focused, isRenamingSpace {
                        commitSpaceRename()
                    }
                }
                // Dropping on the header lands before the first pinned tab;
                // the line hugs its bottom edge so it reads "list starts here".
                .overlay(alignment: .bottom) {
                    insertionLine(headerDropTargeted && draggedFolderID == nil)
                }
                .dropDestination(for: String.self) { items, _ in
                    defer { clearDropFeedback() }
                    guard folderID(from: items) == nil else { return false }
                    let ids = sessionIDs(from: items)
                    if let first = space.pinnedSessions.first {
                        store.insert(ids, before: first.id)
                    } else {
                        store.pin(ids, inSpace: space.id)
                    }
                    return true
                } isTargeted: { headerDropTargeted = $0 }

            if space.pinnedSessions.isEmpty && space.pinnedFolders.isEmpty {
                Text("Drag tabs here to keep them")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }

            ForEach(space.pinnedSessions) { session in
                sessionRow(session)
            }

            // No indicator for tab drops on the zone's leftover dead space:
            // the landing spot (after the loose tabs, far from the pointer)
            // reads as a glitch. Every intentional position has its own
            // target — rows, header, folder strips.

            ForEach(space.pinnedFolders) { folder in
                // Breathing room between a folder and its neighbors comes
                // entirely from the folder's own drop strip.
                folderSection(folder)
            }

            // Where a folder dropped on the zone's empty space will land:
            // after the last folder.
            insertionLine(pinnedZoneTargeted && draggedFolderID != nil && folderEndDropFolderID == nil)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            defer { clearDropFeedback() }
            if let dragged = folderID(from: items) {
                store.moveFolder(dragged, toSpace: space.id)
                restoreDraggedFolderExpansion(dragged)
                return true
            }
            // With folders present, a tab landing here missed a strip by a
            // few points; bounce it back rather than teleporting it to the
            // top of the loose list.
            guard space.pinnedFolders.isEmpty else { return false }
            store.pin(sessionIDs(from: items), inSpace: space.id)
            return true
        } isTargeted: { pinnedZoneTargeted = $0 }
    }

    private var zoneDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
    }

    private var ephemeralZone: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(space.ephemeralSessions) { session in
                sessionRow(session)
            }

            // Where a tab dropped on the zone's empty space will land: the
            // end of the list.
            insertionLine(ephemeralZoneTargeted && draggedFolderID == nil)

            Button {
                store.createSession(inSpace: space.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text("New Terminal")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(newTabHovered ? 0.7 : 0.45))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(newTabHovered ? Color.white.opacity(0.05) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { newTabHovered = $0 }

            Spacer(minLength: 120)
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            defer { clearDropFeedback() }
            // Folders are pinned-only; don't swallow their drops here.
            guard folderID(from: items) == nil else { return false }
            store.unpin(sessionIDs(from: items), inSpace: space.id)
            return true
        } isTargeted: { ephemeralZoneTargeted = $0 }
    }

    private func folderSection(_ folder: TerminalFolder) -> some View {
        let isExpanded = !store.collapsedFolderIDs.contains(folder.id)
        let isHovered = hoveredFolderID == folder.id
        let isRenaming = renamingFolderID == folder.id
        let isDropTarget = folderDropTargetID == folder.id
        // A dragged folder lands before this one (line); dragged tabs land
        // inside it (highlight).
        let isFolderDragOver = isDropTarget && draggedFolderID != nil
        let isSessionDragOver = isDropTarget && draggedFolderID == nil

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                FolderGlyph(isOpen: isExpanded)
                    .fill(.white.opacity(0.6), style: FillStyle(eoFill: true))
                    .frame(width: 14, height: 14)
                    .frame(width: 16)

                if isRenaming {
                    TextField("", text: $draftFolderTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .focused($folderRenameFocused)
                        .onSubmit {
                            commitFolderRename(folder)
                        }
                        .onExitCommand {
                            renamingFolderID = nil
                        }
                } else {
                    Text(folder.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
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

                // Always laid out, faded on hover — see spaceHeader.
                HoverIconButton(systemName: "plus", help: "New Terminal in Folder") {
                    store.createSession(inFolder: folder.id)
                }
                .opacity(isHovered && !isRenaming ? 1 : 0)
                .allowsHitTesting(isHovered && !isRenaming)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        isSessionDragOver
                            ? Color.accentColor.opacity(0.22)
                            : (isHovered ? Color.white.opacity(0.06) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
            // Insertion indicator while another folder is dragged over this
            // one; an overlay so it costs no layout height.
            .overlay(alignment: .top) {
                insertionLine(isFolderDragOver)
            }
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
                draggedFolderWasExpanded = !store.collapsedFolderIDs.contains(folder.id)
                withAnimation(.easeOut(duration: 0.15)) {
                    store.collapsedFolderIDs.insert(folder.id)
                }
                draggedFolderID = folder.id
                return NSItemProvider(object: folderDragPayload(for: folder) as NSString)
            }
            .dropDestination(for: String.self) { items, _ in
                defer { clearDropFeedback() }
                if let dragged = folderID(from: items) {
                    guard dragged != folder.id else { return false }
                    store.insertFolder(dragged, before: folder.id)
                    restoreDraggedFolderExpansion(dragged)
                    return true
                }
                store.move(sessionIDs(from: items), toFolder: folder.id)
                return true
            } isTargeted: { targeted in
                if targeted {
                    folderDropTargetID = folder.id
                } else if folderDropTargetID == folder.id {
                    folderDropTargetID = nil
                }
            }

            // Children live in a container that collapses to zero height and
            // clips, so rows disappear into the folder instead of floating.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(folder.sessions) { session in
                    sessionRow(session)
                }
            }
            .padding(.leading, 14)
            .frame(height: isExpanded ? nil : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(isExpanded)
            .opacity(isExpanded ? 1 : 0)

            // The gap after a folder is its landing strip: a dragged tab
            // becomes the folder's last item (short line at child depth),
            // a dragged folder slots in between the folders (full line).
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.leading, draggedFolderID == nil ? 18 : 4)
                .padding(.trailing, 4)
                .opacity(folderEndDropFolderID == folder.id ? 1 : 0)
                .frame(maxWidth: .infinity)
                // Swallows (nearly) the whole inter-folder gap; anything
                // that slips past it hits the zone, which shows nothing.
                // Collapsed folders sit tighter.
                .frame(height: isExpanded ? 12 : 6)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    defer { clearDropFeedback() }
                    return handleFolderEndDrop(items, folder: folder)
                } isTargeted: { targeted in
                    if targeted {
                        folderEndDropFolderID = folder.id
                    } else if folderEndDropFolderID == folder.id {
                        folderEndDropFolderID = nil
                    }
                }
        }
    }

    /// A drop on the strip after a folder: tabs append into the folder, a
    /// dragged folder reorders to sit right after this one.
    private func handleFolderEndDrop(_ items: [String], folder: TerminalFolder) -> Bool {
        if let dragged = folderID(from: items) {
            guard dragged != folder.id else { return false }
            if let index = space.pinnedFolders.firstIndex(where: { $0.id == folder.id }),
               index + 1 < space.pinnedFolders.count {
                store.insertFolder(dragged, before: space.pinnedFolders[index + 1].id)
            } else {
                store.moveFolder(dragged, toSpace: space.id)
            }
            restoreDraggedFolderExpansion(dragged)
            return true
        }
        let ids = sessionIDs(from: items)
        guard !ids.isEmpty else { return false }
        store.move(ids, toFolder: folder.id)
        return true
    }

    /// A dropped folder reopens if it was expanded before its drag
    /// collapsed it.
    private func restoreDraggedFolderExpansion(_ folderID: TerminalFolder.ID) {
        guard draggedFolderWasExpanded else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            _ = store.collapsedFolderIDs.remove(folderID)
        }
    }

    /// One drop just ended (or a new drag just began): no indicator may
    /// survive it. Individual isTargeted callbacks don't always fire after
    /// a successful drop, so every handler resets the lot.
    private func clearDropFeedback() {
        dropTargetID = nil
        folderDropTargetID = nil
        folderEndDropFolderID = nil
        headerDropTargeted = false
        pinnedZoneTargeted = false
        ephemeralZoneTargeted = false
        draggedFolderID = nil
    }

    @ViewBuilder
    private func sessionRow(_ session: TerminalSession) -> some View {
        let isSelected = store.selection == session.id
        let isMultiSelected = store.multiSelection.contains(session.id)
        let isRenaming = renamingSessionID == session.id

        VStack(spacing: 0) {
            // Insertion indicator while another tab is dragged over this row.
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 4)
                .opacity(dropTargetID == session.id && draggedFolderID == nil ? 1 : 0)

            HStack(spacing: 8) {
                // Uniform slot: spinner while naming, detected-process badge
                // when something known is running, accent dot otherwise.
                Group {
                    if namer.namingSessions.contains(session.id) {
                        AutoNamingIndicator()
                            .frame(width: 7, height: 7)
                    } else if let process = session.runningProcess {
                        ProcessBadgeView(
                            process: process,
                            accent: session.accent.color,
                            isSelected: isSelected
                        )
                    } else {
                        Circle()
                            .fill(session.accent.color.opacity(isSelected ? 0.95 : 0.55))
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(width: 14, height: 14)

                if isRenaming {
                    TextField("", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
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
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.62))
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
                    SessionCloseButton {
                        store.close(sessionID: session.id)
                    }
                } else if session.status == .attention {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        isSelected
                            ? Color.white.opacity(0.14)
                            : (isMultiSelected
                                ? Color.white.opacity(0.07)
                                : (hoveredSessionID == session.id
                                    ? Color.white.opacity(0.05)
                                    : Color.clear))
                    )
            )
            .contentShape(Rectangle())
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
                draggedFolderID = nil
                return NSItemProvider(object: dragPayload(for: session) as NSString)
            }
            .contextMenu {
                contextMenu(for: session)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            defer { clearDropFeedback() }
            // Folders can't interleave with tabs; their drops land on
            // folder headers or the pinned zone.
            guard folderID(from: items) == nil else { return false }
            store.insert(sessionIDs(from: items), before: session.id)
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTargetID = session.id
            } else if dropTargetID == session.id {
                dropTargetID = nil
            }
        }
        .onChange(of: renameFieldFocused) { _, focused in
            if !focused, renamingSessionID == session.id {
                commitRename(session)
            }
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

    private func visibleOrder() -> [TerminalSession.ID] {
        var order = space.pinnedSessions.map(\.id)
        for folder in space.pinnedFolders where !store.collapsedFolderIDs.contains(folder.id) {
            order += folder.sessions.map(\.id)
        }
        order += space.ephemeralSessions.map(\.id)
        return order
    }

    private func dragPayload(for session: TerminalSession) -> String {
        contextTargets(for: session).map(\.uuidString).joined(separator: ",")
    }

    private func sessionIDs(from items: [String]) -> Set<TerminalSession.ID> {
        Set(items.flatMap { $0.split(separator: ",") }.compactMap { UUID(uuidString: String($0)) })
    }

    private func insertionLine(_ visible: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 4)
            .opacity(visible ? 1 : 0)
    }

    private func folderDragPayload(for folder: TerminalFolder) -> String {
        "folder:" + folder.id.uuidString
    }

    private func folderID(from items: [String]) -> TerminalFolder.ID? {
        for item in items where item.hasPrefix("folder:") {
            return UUID(uuidString: String(item.dropFirst("folder:".count)))
        }
        return nil
    }

}

/// 18×18 icon button with its own hover wash so the click target reads
/// before the mouse commits.
private struct HoverIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 0.9 : 0.55))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(isHovered ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// Detected-process icon in the tab row's leading slot: brand logo for
/// agents (in brand color), SF Symbol for known tools (in the tab accent).
private struct ProcessBadgeView: View {
    let process: TabProcess
    let accent: Color
    let isSelected: Bool

    var body: some View {
        switch process.badge {
        case .asset(let name, let brand):
            Image(name)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(brand.opacity(isSelected ? 1 : 0.8))
                .frame(width: 12, height: 12)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(accent.opacity(isSelected ? 0.95 : 0.65))
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
                .white.opacity(0.6),
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
private struct RenameClickAway: NSViewRepresentable {
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

/// Hover-revealed × on a tab row; its own hover highlight so the click
/// target reads before the mouse commits.
private struct SessionCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(isHovered ? 0.9 : 0.5))
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(isHovered ? 0.14 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Close Tab")
    }
}

/// Phosphor folder icons. SF Symbols has no open-folder glyph. Closed is
/// the regular weight flattened to normalized polylines; open is the fill
/// weight, hand-traced with quad curves for the rounded corners.
private struct FolderGlyph: Shape {
    let isOpen: Bool

    func path(in rect: CGRect) -> Path {
        if isOpen {
            return Self.openFilled(in: rect)
        }
        var path = Path()
        for sub in Self.closed {
            guard let first = sub.first else { continue }
            path.move(to: scaled(first, rect))
            for point in sub.dropFirst() {
                path.addLine(to: scaled(point, rect))
            }
            path.closeSubpath()
        }
        return path
    }

    /// Phosphor "folder-open-fill" (256 viewBox); the second subpath cuts
    /// the notch out via the even-odd fill the caller applies.
    private static func openFilled(in rect: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 256 * rect.width, y: rect.minY + y / 256 * rect.height)
        }
        var path = Path()
        path.move(to: pt(245, 110.6))
        path.addQuadCurve(to: pt(232, 104), control: pt(244, 104))
        path.addLine(to: pt(216, 104))
        path.addLine(to: pt(216, 88))
        path.addQuadCurve(to: pt(200, 72), control: pt(216, 72))
        path.addLine(to: pt(130.7, 72))
        path.addLine(to: pt(102.9, 51.2))
        path.addQuadCurve(to: pt(93.3, 48), control: pt(98.7, 48))
        path.addLine(to: pt(40, 48))
        path.addQuadCurve(to: pt(24, 64), control: pt(24, 48))
        path.addLine(to: pt(24, 208))
        path.addQuadCurve(to: pt(32, 216), control: pt(24, 216))
        path.addLine(to: pt(211.1, 216))
        path.addQuadCurve(to: pt(218.7, 210.5), control: pt(216.9, 216))
        path.addLine(to: pt(247.2, 125.1))
        path.addQuadCurve(to: pt(245, 110.6), control: pt(249, 113))
        path.closeSubpath()

        path.move(to: pt(93.3, 64))
        path.addLine(to: pt(123.2, 86.4))
        path.addQuadCurve(to: pt(128, 88), control: pt(125.3, 88))
        path.addLine(to: pt(200, 88))
        path.addLine(to: pt(200, 104))
        path.addLine(to: pt(69.8, 104))
        path.addQuadCurve(to: pt(54.6, 114.9), control: pt(58.2, 104))
        path.addLine(to: pt(40, 158.7))
        path.addLine(to: pt(40, 64))
        path.closeSubpath()
        return path
    }

    private func scaled(_ point: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    private static let closed: [[CGPoint]] = [
        [CGPoint(x: 0.8438, y: 0.2656), CGPoint(x: 0.8241, y: 0.2656), CGPoint(x: 0.8045, y: 0.2656), CGPoint(x: 0.7849, y: 0.2656), CGPoint(x: 0.7653, y: 0.2656), CGPoint(x: 0.7457, y: 0.2656), CGPoint(x: 0.726, y: 0.2656), CGPoint(x: 0.7064, y: 0.2656), CGPoint(x: 0.6868, y: 0.2656), CGPoint(x: 0.6672, y: 0.2656), CGPoint(x: 0.6476, y: 0.2656), CGPoint(x: 0.6279, y: 0.2656), CGPoint(x: 0.6083, y: 0.2656), CGPoint(x: 0.5887, y: 0.2656), CGPoint(x: 0.5691, y: 0.2656), CGPoint(x: 0.5495, y: 0.2656), CGPoint(x: 0.5298, y: 0.2656), CGPoint(x: 0.5139, y: 0.2575), CGPoint(x: 0.5008, y: 0.2428), CGPoint(x: 0.4878, y: 0.2282), CGPoint(x: 0.4748, y: 0.2135), CGPoint(x: 0.4618, y: 0.1988), CGPoint(x: 0.4487, y: 0.1842), CGPoint(x: 0.4357, y: 0.1695), CGPoint(x: 0.4227, y: 0.1548), CGPoint(x: 0.4087, y: 0.1411), CGPoint(x: 0.3918, y: 0.1313), CGPoint(x: 0.373, y: 0.1259), CGPoint(x: 0.3534, y: 0.125), CGPoint(x: 0.3338, y: 0.125), CGPoint(x: 0.3141, y: 0.125), CGPoint(x: 0.2945, y: 0.125), CGPoint(x: 0.2749, y: 0.125), CGPoint(x: 0.2553, y: 0.125), CGPoint(x: 0.2357, y: 0.125), CGPoint(x: 0.216, y: 0.125), CGPoint(x: 0.1964, y: 0.125), CGPoint(x: 0.1768, y: 0.125), CGPoint(x: 0.1572, y: 0.125), CGPoint(x: 0.1377, y: 0.1272), CGPoint(x: 0.1195, y: 0.1342), CGPoint(x: 0.1035, y: 0.1455), CGPoint(x: 0.0908, y: 0.1604), CGPoint(x: 0.0823, y: 0.178), CGPoint(x: 0.0784, y: 0.1972), CGPoint(x: 0.0781, y: 0.2168), CGPoint(x: 0.0781, y: 0.2364), CGPoint(x: 0.0781, y: 0.256), CGPoint(x: 0.0781, y: 0.2757), CGPoint(x: 0.0781, y: 0.2953), CGPoint(x: 0.0781, y: 0.3149), CGPoint(x: 0.0781, y: 0.3345), CGPoint(x: 0.0781, y: 0.3541), CGPoint(x: 0.0781, y: 0.3738), CGPoint(x: 0.0781, y: 0.3934), CGPoint(x: 0.0781, y: 0.413), CGPoint(x: 0.0781, y: 0.4326), CGPoint(x: 0.0781, y: 0.4522), CGPoint(x: 0.0781, y: 0.4719), CGPoint(x: 0.0781, y: 0.4915), CGPoint(x: 0.0781, y: 0.5111), CGPoint(x: 0.0781, y: 0.5307), CGPoint(x: 0.0781, y: 0.5503), CGPoint(x: 0.0781, y: 0.57), CGPoint(x: 0.0781, y: 0.5896), CGPoint(x: 0.0781, y: 0.6092), CGPoint(x: 0.0781, y: 0.6288), CGPoint(x: 0.0781, y: 0.6484), CGPoint(x: 0.0781, y: 0.6681), CGPoint(x: 0.0781, y: 0.6877), CGPoint(x: 0.0781, y: 0.7073), CGPoint(x: 0.0781, y: 0.7269), CGPoint(x: 0.0781, y: 0.7465), CGPoint(x: 0.0781, y: 0.7662), CGPoint(x: 0.0782, y: 0.7858), CGPoint(x: 0.0812, y: 0.8051), CGPoint(x: 0.0892, y: 0.823), CGPoint(x: 0.1014, y: 0.8382), CGPoint(x: 0.1172, y: 0.8499), CGPoint(x: 0.1354, y: 0.8571), CGPoint(x: 0.1548, y: 0.8594), CGPoint(x: 0.1744, y: 0.8594), CGPoint(x: 0.194, y: 0.8594), CGPoint(x: 0.2136, y: 0.8594), CGPoint(x: 0.2333, y: 0.8594), CGPoint(x: 0.2529, y: 0.8594), CGPoint(x: 0.2725, y: 0.8594), CGPoint(x: 0.2921, y: 0.8594), CGPoint(x: 0.3117, y: 0.8594), CGPoint(x: 0.3314, y: 0.8594), CGPoint(x: 0.351, y: 0.8594), CGPoint(x: 0.3706, y: 0.8594), CGPoint(x: 0.3902, y: 0.8594), CGPoint(x: 0.4098, y: 0.8594), CGPoint(x: 0.4295, y: 0.8594), CGPoint(x: 0.4491, y: 0.8594), CGPoint(x: 0.4687, y: 0.8594), CGPoint(x: 0.4883, y: 0.8594), CGPoint(x: 0.5079, y: 0.8594), CGPoint(x: 0.5276, y: 0.8594), CGPoint(x: 0.5472, y: 0.8594), CGPoint(x: 0.5668, y: 0.8594), CGPoint(x: 0.5864, y: 0.8594), CGPoint(x: 0.606, y: 0.8594), CGPoint(x: 0.6256, y: 0.8594), CGPoint(x: 0.6453, y: 0.8594), CGPoint(x: 0.6649, y: 0.8594), CGPoint(x: 0.6845, y: 0.8594), CGPoint(x: 0.7041, y: 0.8594), CGPoint(x: 0.7237, y: 0.8594), CGPoint(x: 0.7434, y: 0.8594), CGPoint(x: 0.763, y: 0.8594), CGPoint(x: 0.7826, y: 0.8594), CGPoint(x: 0.8022, y: 0.8594), CGPoint(x: 0.8218, y: 0.8594), CGPoint(x: 0.8415, y: 0.8594), CGPoint(x: 0.861, y: 0.8581), CGPoint(x: 0.8796, y: 0.852), CGPoint(x: 0.8959, y: 0.8412), CGPoint(x: 0.909, y: 0.8266), CGPoint(x: 0.9177, y: 0.8092), CGPoint(x: 0.9217, y: 0.79), CGPoint(x: 0.9219, y: 0.7704), CGPoint(x: 0.9219, y: 0.7508), CGPoint(x: 0.9219, y: 0.7311), CGPoint(x: 0.9219, y: 0.7115), CGPoint(x: 0.9219, y: 0.6919), CGPoint(x: 0.9219, y: 0.6723), CGPoint(x: 0.9219, y: 0.6527), CGPoint(x: 0.9219, y: 0.633), CGPoint(x: 0.9219, y: 0.6134), CGPoint(x: 0.9219, y: 0.5938), CGPoint(x: 0.9219, y: 0.5742), CGPoint(x: 0.9219, y: 0.5546), CGPoint(x: 0.9219, y: 0.5349), CGPoint(x: 0.9219, y: 0.5153), CGPoint(x: 0.9219, y: 0.4957), CGPoint(x: 0.9219, y: 0.4761), CGPoint(x: 0.9219, y: 0.4565), CGPoint(x: 0.9219, y: 0.4368), CGPoint(x: 0.9219, y: 0.4172), CGPoint(x: 0.9219, y: 0.3976), CGPoint(x: 0.9219, y: 0.378), CGPoint(x: 0.9219, y: 0.3584), CGPoint(x: 0.9217, y: 0.3388), CGPoint(x: 0.918, y: 0.3195), CGPoint(x: 0.9097, y: 0.3018), CGPoint(x: 0.8972, y: 0.2868), CGPoint(x: 0.8814, y: 0.2753), CGPoint(x: 0.8632, y: 0.2681), CGPoint(x: 0.8438, y: 0.2656)],
        [CGPoint(x: 0.1719, y: 0.2188), CGPoint(x: 0.1917, y: 0.2188), CGPoint(x: 0.2115, y: 0.2188), CGPoint(x: 0.2313, y: 0.2188), CGPoint(x: 0.2512, y: 0.2188), CGPoint(x: 0.271, y: 0.2188), CGPoint(x: 0.2908, y: 0.2188), CGPoint(x: 0.3106, y: 0.2188), CGPoint(x: 0.3305, y: 0.2188), CGPoint(x: 0.3503, y: 0.2188), CGPoint(x: 0.3647, y: 0.2308), CGPoint(x: 0.3779, y: 0.2456), CGPoint(x: 0.391, y: 0.2605), CGPoint(x: 0.3827, y: 0.2656), CGPoint(x: 0.3629, y: 0.2656), CGPoint(x: 0.3431, y: 0.2656), CGPoint(x: 0.3232, y: 0.2656), CGPoint(x: 0.3034, y: 0.2656), CGPoint(x: 0.2836, y: 0.2656), CGPoint(x: 0.2638, y: 0.2656), CGPoint(x: 0.2439, y: 0.2656), CGPoint(x: 0.2241, y: 0.2656), CGPoint(x: 0.2043, y: 0.2656), CGPoint(x: 0.1845, y: 0.2656), CGPoint(x: 0.1719, y: 0.2584), CGPoint(x: 0.1719, y: 0.2386), CGPoint(x: 0.1719, y: 0.2188)],
        [CGPoint(x: 0.8281, y: 0.7656), CGPoint(x: 0.8084, y: 0.7656), CGPoint(x: 0.7888, y: 0.7656), CGPoint(x: 0.7691, y: 0.7656), CGPoint(x: 0.7494, y: 0.7656), CGPoint(x: 0.7297, y: 0.7656), CGPoint(x: 0.7101, y: 0.7656), CGPoint(x: 0.6904, y: 0.7656), CGPoint(x: 0.6707, y: 0.7656), CGPoint(x: 0.651, y: 0.7656), CGPoint(x: 0.6314, y: 0.7656), CGPoint(x: 0.6117, y: 0.7656), CGPoint(x: 0.592, y: 0.7656), CGPoint(x: 0.5723, y: 0.7656), CGPoint(x: 0.5527, y: 0.7656), CGPoint(x: 0.533, y: 0.7656), CGPoint(x: 0.5133, y: 0.7656), CGPoint(x: 0.4936, y: 0.7656), CGPoint(x: 0.474, y: 0.7656), CGPoint(x: 0.4543, y: 0.7656), CGPoint(x: 0.4346, y: 0.7656), CGPoint(x: 0.4149, y: 0.7656), CGPoint(x: 0.3953, y: 0.7656), CGPoint(x: 0.3756, y: 0.7656), CGPoint(x: 0.3559, y: 0.7656), CGPoint(x: 0.3362, y: 0.7656), CGPoint(x: 0.3166, y: 0.7656), CGPoint(x: 0.2969, y: 0.7656), CGPoint(x: 0.2772, y: 0.7656), CGPoint(x: 0.2575, y: 0.7656), CGPoint(x: 0.2378, y: 0.7656), CGPoint(x: 0.2182, y: 0.7656), CGPoint(x: 0.1985, y: 0.7656), CGPoint(x: 0.1788, y: 0.7656), CGPoint(x: 0.1719, y: 0.7529), CGPoint(x: 0.1719, y: 0.7332), CGPoint(x: 0.1719, y: 0.7135), CGPoint(x: 0.1719, y: 0.6939), CGPoint(x: 0.1719, y: 0.6742), CGPoint(x: 0.1719, y: 0.6545), CGPoint(x: 0.1719, y: 0.6348), CGPoint(x: 0.1719, y: 0.6152), CGPoint(x: 0.1719, y: 0.5955), CGPoint(x: 0.1719, y: 0.5758), CGPoint(x: 0.1719, y: 0.5561), CGPoint(x: 0.1719, y: 0.5365), CGPoint(x: 0.1719, y: 0.5168), CGPoint(x: 0.1719, y: 0.4971), CGPoint(x: 0.1719, y: 0.4774), CGPoint(x: 0.1719, y: 0.4578), CGPoint(x: 0.1719, y: 0.4381), CGPoint(x: 0.1719, y: 0.4184), CGPoint(x: 0.1719, y: 0.3987), CGPoint(x: 0.1719, y: 0.3791), CGPoint(x: 0.1719, y: 0.3594), CGPoint(x: 0.1916, y: 0.3594), CGPoint(x: 0.2112, y: 0.3594), CGPoint(x: 0.2309, y: 0.3594), CGPoint(x: 0.2506, y: 0.3594), CGPoint(x: 0.2703, y: 0.3594), CGPoint(x: 0.2899, y: 0.3594), CGPoint(x: 0.3096, y: 0.3594), CGPoint(x: 0.3293, y: 0.3594), CGPoint(x: 0.349, y: 0.3594), CGPoint(x: 0.3686, y: 0.3594), CGPoint(x: 0.3883, y: 0.3594), CGPoint(x: 0.408, y: 0.3594), CGPoint(x: 0.4277, y: 0.3594), CGPoint(x: 0.4473, y: 0.3594), CGPoint(x: 0.467, y: 0.3594), CGPoint(x: 0.4867, y: 0.3594), CGPoint(x: 0.5064, y: 0.3594), CGPoint(x: 0.526, y: 0.3594), CGPoint(x: 0.5457, y: 0.3594), CGPoint(x: 0.5654, y: 0.3594), CGPoint(x: 0.5851, y: 0.3594), CGPoint(x: 0.6047, y: 0.3594), CGPoint(x: 0.6244, y: 0.3594), CGPoint(x: 0.6441, y: 0.3594), CGPoint(x: 0.6638, y: 0.3594), CGPoint(x: 0.6834, y: 0.3594), CGPoint(x: 0.7031, y: 0.3594), CGPoint(x: 0.7228, y: 0.3594), CGPoint(x: 0.7425, y: 0.3594), CGPoint(x: 0.7622, y: 0.3594), CGPoint(x: 0.7818, y: 0.3594), CGPoint(x: 0.8015, y: 0.3594), CGPoint(x: 0.8212, y: 0.3594), CGPoint(x: 0.8281, y: 0.3721), CGPoint(x: 0.8281, y: 0.3918), CGPoint(x: 0.8281, y: 0.4115), CGPoint(x: 0.8281, y: 0.4311), CGPoint(x: 0.8281, y: 0.4508), CGPoint(x: 0.8281, y: 0.4705), CGPoint(x: 0.8281, y: 0.4902), CGPoint(x: 0.8281, y: 0.5098), CGPoint(x: 0.8281, y: 0.5295), CGPoint(x: 0.8281, y: 0.5492), CGPoint(x: 0.8281, y: 0.5689), CGPoint(x: 0.8281, y: 0.5885), CGPoint(x: 0.8281, y: 0.6082), CGPoint(x: 0.8281, y: 0.6279), CGPoint(x: 0.8281, y: 0.6476), CGPoint(x: 0.8281, y: 0.6672), CGPoint(x: 0.8281, y: 0.6869), CGPoint(x: 0.8281, y: 0.7066), CGPoint(x: 0.8281, y: 0.7263), CGPoint(x: 0.8281, y: 0.7459), CGPoint(x: 0.8281, y: 0.7656)],
    ]

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
                            Circle().fill(Color.white.opacity(isHovered ? 0.1 : 0))
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
                    .foregroundStyle(.white.opacity(plusHovered ? 0.7 : 0.3))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(Color.white.opacity(plusHovered ? 0.1 : 0))
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
                .fill(.white.opacity(isActive ? 0.85 : 0.25))
                .frame(width: size * 0.36, height: size * 0.36)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.61, weight: .medium))
                .foregroundStyle(.white.opacity(isActive ? 0.9 : 0.3))
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
                        .fill(Color.white.opacity(nameFocused ? 0.12 : 0.06))
                )
                .onSubmit(saveAndDismiss)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            picker
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

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
                .buttonStyle(ModalPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 420)
        .overlay(alignment: .topTrailing) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(closeHovered ? 0.85 : 0.45))
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(Color.white.opacity(closeHovered ? 0.08 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { closeHovered = $0 }
            .padding(10)
        }
        // Fully owned chrome: presented as an in-window overlay, not a
        // macOS sheet, so no system border or forced corner radius.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.094, green: 0.096, blue: 0.105))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                .shadow(color: .black.opacity(0.65), radius: 70, y: 30)
        )
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
            ZStack {
                // Recessed well so the preview reads as a distinct disc.
                Circle()
                    .fill(Color.black.opacity(0.32))

                // Keyed on the icon so a swap plays the shrink-out /
                // spring-in transition instead of cross-fading in place.
                SpaceIndicatorIcon(icon: icon, isActive: true, size: 46)
                    .id(icon)
                    .transition(iconSwap)
            }
            .frame(width: 84, height: 84)

            shuffleButton
                .offset(x: 4, y: 4)
        }
        // Every icon change (shuffle or a tile tap) rides the same spring,
        // so the preview always animates its swap.
        .animation(.spring(duration: 0.32, bounce: 0.32), value: icon)
    }

    private var shuffleButton: some View {
        Button {
            shuffle()
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.94)))
                // A low-damping spring back to 1 overshoots into a pop.
                .scaleEffect(shufflePop ? 0.8 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.42), value: shufflePop)
        }
        .buttonStyle(.plain)
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

            // A fixed height keeps the sheet from growing with the catalog;
            // the grids scroll within it.
            Group {
                switch pickerTab {
                case .icons: iconsGrid
                case .emoji: emojiGrid
                }
            }
            .frame(height: 208)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
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
                .foregroundStyle(.white.opacity(selected ? 0.92 : 0.5))
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(selected ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func searchField(text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.06))
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
                        icon = tile.icon
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
            icon = .emoji(entry.emoji)
        } content: {
            Text(entry.emoji)
                .font(.system(size: 20))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
        .background(Color(red: 0.094, green: 0.096, blue: 0.105).opacity(0.92))
    }

    /// One selectable grid cell: a rounded well that fills with the accent
    /// when it holds the current icon.
    private func tileButton<Content: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 38, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(isSelected ? 0.5 : 0), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private func saveAndDismiss() {
        onSave(name, icon)
        onDismiss()
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
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

// MARK: - Button styles

/// Solid white primary action, web-modal style: full-width rounded
/// rectangle, dark label, no gradient or border. Brightens on hover.
struct ModalPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.88))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(
                            configuration.isPressed ? 0.78 : (hovering ? 1 : 0.9)
                        ))
                )
                .onHover { hovering = $0 }
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
                .foregroundStyle(.white.opacity(hovering ? 0.92 : 0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(
                            configuration.isPressed ? 0.16 : (hovering ? 0.13 : 0.09)
                        ))
                )
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
        }
    }
}

#Preview {
    SidebarView(store: .preview, spaceEditor: .constant(nil))
        .frame(width: 264, height: 600)
        .background(.black)
}
