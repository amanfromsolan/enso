import AppKit
import SwiftUI

/// Hosts the visible terminal area: a single surface for a plain tab, or
/// the whole split layout (every pane's surface, with draggable dividers)
/// when the selected tab belongs to a split container.
struct GhosttyTerminalHostView: NSViewRepresentable {
    /// Optional so the container outlives any one session: swapping (or
    /// clearing) the surfaces happens inside a stable NSView in the same
    /// commit as SwiftUI's redraw. Destroying the representable instead
    /// tears the Metal layer down a frame late, flashing stale content.
    let session: TerminalSession?
    /// The split container the selected tab is a pane of, when it is one.
    let container: SplitContainer?
    let store: TerminalSessionStore

    func makeNSView(context: Context) -> SplitLayoutHostView {
        let host = SplitLayoutHostView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(GhosttyRuntime.shared.themeBackground).cgColor
        return host
    }

    func updateNSView(_ host: SplitLayoutHostView, context: Context) {
        guard let session else {
            host.apply(tree: nil, sessions: [:], surfaces: [:], focusedID: nil)
            return
        }

        // A split tab shows its whole container; a plain tab is a
        // single-leaf "tree" through the same layout path.
        let tree: SplitNode = container?.tree ?? .leaf(session.id)

        var sessions: [TerminalSession.ID: TerminalSession] = [:]
        var surfaces: [TerminalSession.ID: GhosttySurfaceView] = [:]
        for id in tree.leafIDs {
            // Resolved against the live store so a pane's surface spawns
            // with its session's current working directory.
            guard let live = store.sessions.first(where: { $0.id == id }) else { continue }
            let surface = GhosttySurfaceManager.shared.view(for: live)
            store.wireSurfaceCallbacks(surface, for: id)
            sessions[id] = live
            surfaces[id] = surface
        }

        host.store = store
        let containerID = container?.id
        host.onRatioChange = { [weak store] path, ratio in
            guard let containerID else { return }
            store?.updateSplitRatio(containerID: containerID, path: path, ratio: ratio)
        }
        host.onRatioCommit = { [weak store] in
            store?.commitSplitLayout()
        }

        host.apply(tree: tree, sessions: sessions, surfaces: surfaces, focusedID: session.id)
    }
}

/// The stable AppKit container that owns pane geometry: recursively lays
/// out the split tree's surfaces and dividers inside its bounds, keeps
/// surfaces alive across selection changes within a container, and routes
/// divider drags back to the store as ratio updates.
final class SplitLayoutHostView: NSView {
    var onRatioChange: ((SplitPath, Double) -> Void)?
    var onRatioCommit: (() -> Void)?
    /// For the pane headers' rename plumbing; set by the representable
    /// before every apply.
    weak var store: TerminalSessionStore?

    private var tree: SplitNode?
    private var surfaces: [TerminalSession.ID: GhosttySurfaceView] = [:]
    /// One in-pane header per pane (icon + title + cwd), hosted SwiftUI.
    /// Living INSIDE the pane region — never above or across the split —
    /// is what lets the dividers run edge to edge.
    private var headers: [TerminalSession.ID: NSHostingView<PaneHeaderView>] = [:]
    private var focusedID: TerminalSession.ID?
    /// The pane last handed first responder by this host. Focus is granted
    /// only when the focused pane changes (or its surface is newly
    /// attached), never on every store publish — a rename field or the
    /// palette holding the keyboard must not have it snatched away by an
    /// unrelated re-render.
    private var lastFocusGrant: TerminalSession.ID?
    private var dividers: [SplitPath: SplitDividerView] = [:]

    /// Top-left origin so layout math reads top-to-bottom like the tree.
    override var isFlipped: Bool { true }

    func apply(
        tree: SplitNode?,
        sessions: [TerminalSession.ID: TerminalSession],
        surfaces: [TerminalSession.ID: GhosttySurfaceView],
        focusedID: TerminalSession.ID?
    ) {
        self.tree = tree
        self.focusedID = focusedID

        // Detach surfaces that left the layout (switched tab or closed
        // pane); their shells keep running in the surface manager.
        let incoming = Set(surfaces.values.map(ObjectIdentifier.init))
        for view in self.surfaces.values
        where !incoming.contains(ObjectIdentifier(view)) && view.superview === self {
            view.removeFromSuperview()
        }

        var newlyAttached = false
        for view in surfaces.values where view.superview !== self {
            view.autoresizingMask = []
            addSubview(view)
            newlyAttached = true
        }
        self.surfaces = surfaces

        // Headers track the surfaces one-to-one: refresh live ones with the
        // session's current title/process/cwd, drop the ones whose pane
        // left, and mount headers for new panes.
        for (id, header) in headers where surfaces[id] == nil || sessions[id] == nil {
            header.removeFromSuperview()
            headers.removeValue(forKey: id)
        }
        // Panes narrowed by a horizontal split (side-by-side, reduced
        // width) get the compact type treatment; unsplit tabs and
        // vertical-only (stacked, full-width) panes keep the full size.
        var narrowed: [TerminalSession.ID: Bool] = [:]
        if let tree {
            Self.collectNarrowedLeaves(tree, narrowed: false, into: &narrowed)
        }
        for id in surfaces.keys {
            guard let session = sessions[id], let store else { continue }
            let rootView = PaneHeaderView(
                session: session,
                store: store,
                compact: narrowed[id] ?? false
            ) { [weak self] in
                self?.focusPane(id)
            }
            if let header = headers[id] {
                header.rootView = rootView
            } else {
                let header = NSHostingView(rootView: rootView)
                header.sizingOptions = []
                // The card's top band sits under the window's transparent
                // titlebar; by default NSHostingView propagates that as a
                // safe-area inset and SwiftUI shoves the content downward,
                // out of its 46pt frame (hosting views don't clip) — the
                // header rendered mid-card over the terminal. Pane headers
                // are pane chrome, not window chrome: no safe areas.
                header.safeAreaRegions = []
                headers[id] = header
                addSubview(header)
            }
        }

        layoutPanes()

        if let focusedID, let surface = surfaces[focusedID],
           focusedID != lastFocusGrant || newlyAttached {
            lastFocusGrant = focusedID
            grantFocus(to: surface)
        }
        if focusedID == nil {
            lastFocusGrant = nil
        }
    }

    /// A pane header was clicked: hand the keyboard to that pane's
    /// terminal. Focus syncs the sidebar selection via onFocusGained, so
    /// this one call covers both the already-selected and sibling case.
    private func focusPane(_ id: TerminalSession.ID) {
        guard let surface = surfaces[id] else { return }
        window?.makeFirstResponder(surface)
    }

    private func grantFocus(to surface: GhosttySurfaceView) {
        if let window {
            window.makeFirstResponder(surface)
        } else {
            // First appearance: the host isn't in a window yet.
            DispatchQueue.main.async { [weak surface] in
                guard let surface else { return }
                surface.window?.makeFirstResponder(surface)
            }
        }
    }

    override func layout() {
        super.layout()
        layoutPanes()
    }

    // MARK: - Geometry

    /// Full divider hit target; the visible hairline is drawn centered
    /// inside it, so panes read nearly flush while the grab area stays
    /// comfortable.
    static let dividerThickness: CGFloat = 6

    /// The in-pane header band: two lines (title, then cwd breadcrumb)
    /// centered in the same 46pt the old header strip used, sitting on the
    /// terminal background inside the pane.
    static let paneHeaderHeight: CGFloat = 46

    /// Marks every leaf whose width a horizontal split reduces: any
    /// horizontal split on the path from the root narrows both children.
    private static func collectNarrowedLeaves(
        _ node: SplitNode,
        narrowed: Bool,
        into map: inout [TerminalSession.ID: Bool]
    ) {
        switch node {
        case .leaf(let id):
            map[id] = narrowed
        case .split(let branch):
            let next = narrowed || branch.direction == .horizontal
            collectNarrowedLeaves(branch.first, narrowed: next, into: &map)
            collectNarrowedLeaves(branch.second, narrowed: next, into: &map)
        }
    }

    private func layoutPanes() {
        guard let tree, bounds.width > 0, bounds.height > 0 else {
            dividers.values.forEach { $0.removeFromSuperview() }
            dividers = [:]
            return
        }
        var used: Set<SplitPath> = []
        place(tree, in: bounds, path: SplitPath(), used: &used)
        for (path, divider) in dividers where !used.contains(path) {
            divider.removeFromSuperview()
            dividers.removeValue(forKey: path)
        }
    }

    private func place(_ node: SplitNode, in rect: CGRect, path: SplitPath, used: inout Set<SplitPath>) {
        switch node {
        case .leaf(let id):
            // Header inside the pane's own region, surface below it — the
            // header claims the top band only within this leaf, so nothing
            // spans across a divider.
            let paneRect = rect.integral
            let headerHeight = min(Self.paneHeaderHeight, paneRect.height)
            headers[id]?.frame = CGRect(
                x: paneRect.minX, y: paneRect.minY,
                width: paneRect.width, height: headerHeight
            )
            surfaces[id]?.frame = CGRect(
                x: paneRect.minX, y: paneRect.minY + headerHeight,
                width: paneRect.width, height: max(paneRect.height - headerHeight, 0)
            )
        case .split(let branch):
            let thickness = Self.dividerThickness
            let firstRect: CGRect
            let dividerRect: CGRect
            let secondRect: CGRect
            if branch.direction == .horizontal {
                let firstWidth = ((rect.width - thickness) * branch.ratio).rounded()
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: max(firstWidth, 0), height: rect.height)
                dividerRect = CGRect(x: firstRect.maxX, y: rect.minY, width: thickness, height: rect.height)
                secondRect = CGRect(
                    x: dividerRect.maxX, y: rect.minY,
                    width: max(rect.maxX - dividerRect.maxX, 0), height: rect.height
                )
            } else {
                let firstHeight = ((rect.height - thickness) * branch.ratio).rounded()
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(firstHeight, 0))
                dividerRect = CGRect(x: rect.minX, y: firstRect.maxY, width: rect.width, height: thickness)
                secondRect = CGRect(
                    x: rect.minX, y: dividerRect.maxY,
                    width: rect.width, height: max(rect.maxY - dividerRect.maxY, 0)
                )
            }

            place(branch.first, in: firstRect, path: path.appending(.first), used: &used)
            place(branch.second, in: secondRect, path: path.appending(.second), used: &used)

            let divider = dividers[path] ?? {
                let view = SplitDividerView()
                view.onDrag = { [weak self] path, ratio in
                    self?.onRatioChange?(path, ratio)
                }
                view.onDragEnded = { [weak self] in
                    self?.onRatioCommit?()
                }
                dividers[path] = view
                return view
            }()
            divider.path = path
            divider.direction = branch.direction
            divider.regionRect = rect
            divider.frame = dividerRect
            if divider.superview !== self {
                // Above the surfaces; the divider owns the seam strip the
                // pane frames leave open, so hit areas never contend.
                addSubview(divider, positioned: .above, relativeTo: nil)
            }
            divider.window?.invalidateCursorRects(for: divider)
            used.insert(path)
        }
    }
}

/// One draggable split divider: a hairline over the terminal background
/// with a wider grab area, converting pointer position into the parent
/// split's first-child ratio.
final class SplitDividerView: NSView {
    var path = SplitPath()
    var direction: SplitDirection = .horizontal
    /// The whole region the parent split divides, in the host's
    /// coordinates; drags map the pointer into this to produce a ratio.
    var regionRect: CGRect = .zero
    var onDrag: ((SplitPath, Double) -> Void)?
    var onDragEnded: (() -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // The terminal theme background stays dark in both appearances;
        // a quiet light hairline reads as the pane seam.
        NSColor.white.withAlphaComponent(0.14).setFill()
        let line: NSRect
        if direction == .horizontal {
            line = NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
        } else {
            line = NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        }
        line.fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: direction == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        // Drag starts on the first mouseDragged; nothing to record — the
        // ratio is absolute (pointer position within the region).
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        let thickness = SplitLayoutHostView.dividerThickness
        let ratio: Double
        if direction == .horizontal {
            let usable = regionRect.width - thickness
            guard usable > 0 else { return }
            ratio = (point.x - regionRect.minX - thickness / 2) / usable
        } else {
            let usable = regionRect.height - thickness
            guard usable > 0 else { return }
            ratio = (point.y - regionRect.minY - thickness / 2) / usable
        }
        onDrag?(path, SplitBranch.clampRatio(ratio))
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}

// MARK: - Pane header

/// The header INSIDE each pane. Two variants with one gate:
/// `compact == false` — an unsplit tab or a pane only stacked by vertical
/// splits — renders the ORIGINAL pre-splits header strip verbatim
/// (FullPaneHeader): title and breadcrumb inline on one row, double-click
/// rename, window drag/zoom on the empty band. The stacked two-line
/// treatment (CompactPaneHeader) exists ONLY for panes whose width a
/// horizontal split reduced — never anywhere else.
struct PaneHeaderView: View {
    let session: TerminalSession
    let store: TerminalSessionStore
    let compact: Bool
    let onActivate: () -> Void

    var body: some View {
        if compact {
            CompactPaneHeader(session: session, onActivate: onActivate)
        } else {
            FullPaneHeader(session: session, store: store)
        }
    }
}

/// The original header strip, exactly as it was before splits shipped —
/// recovered from history, not approximated: 24pt badge, 15pt title with
/// the segmented breadcrumb INLINE on the same row, double-click-to-rename
/// with the invisible-twin field, the 80% cluster cap, the DEV badge, and
/// the AppKit drag/zoom handle behind the empty band. Living inside the
/// pane band, it is pixel-identical to the old strip for an unsplit tab.
private struct FullPaneHeader: View {
    let session: TerminalSession
    let store: TerminalSessionStore

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFieldFocused: Bool

    /// Measured strip width; caps the title cluster below.
    @State private var headerWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                // Leading slot mirrors the sidebar row: the detected-process
                // badge supplants the accent dot while something known is
                // running; idle tabs keep today's dot — never an empty slot.
                if let process = session.runningProcess {
                    HeaderProcessBadge(process: process, ink: terminalInk)
                } else {
                    // Idle terminal glyph, tinted like the tool badges;
                    // 24 pt from the full-bleed header artwork, same slot
                    // the agent marks occupy.
                    Image("TerminalIdleHeader")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(terminalInk.opacity(0.5))
                        .frame(width: 24, height: 24)
                }

                if isRenaming {
                    // An invisible twin of the title keeps the field exactly
                    // as wide as the typed text — a fixed-width field would
                    // shove the breadcrumb sideways the moment editing
                    // starts. The trailing space gives the caret room.
                    Text(draftTitle + " ")
                        .font(.system(size: 15, weight: .regular))
                        .lineLimit(1)
                        .opacity(0)
                        .overlay {
                            TextField("", text: $draftTitle)
                                .textFieldStyle(.plain)
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(terminalInk.opacity(0.9))
                                .environment(\.colorScheme, terminalColorScheme)
                                .focused($renameFieldFocused)
                                .onSubmit {
                                    commitRename()
                                    restoreTerminalFocus()
                                }
                                .onExitCommand {
                                    isRenaming = false
                                    restoreTerminalFocus()
                                }
                        }
                } else {
                    Text(session.title)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(terminalInk.opacity(0.9))
                        .lineLimit(1)
                }

                PaneHeaderBreadcrumb(
                    path: session.workingDirectory,
                    ink: terminalInk,
                    compact: false
                )
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                beginRename()
            }
            // A long title + breadcrumb never swallows the whole strip:
            // cap the cluster at 80% so the header keeps visible breathing
            // room (and drag/zoom target) on the right. A max, not a fixed
            // width — short titles still hug their content.
            .frame(
                maxWidth: headerWidth > 0 ? headerWidth * 0.8 : nil,
                alignment: .leading
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            headerWidth = width
        }
        #if DEBUG
        // Overlaid so the badge claims no room from the title cluster.
        .overlay(alignment: .trailing) {
            DevBadge()
                .frame(height: 22)
                .padding(.trailing, 12)
        }
        #endif
        // Drag + double-click-zoom handled in AppKit, not SwiftUI: a
        // WindowDragGesture claims the mouse-down to start dragging, so a
        // paired .onTapGesture(count: 2) never recognizes and zoom silently
        // did nothing. WindowDragHandle reads the raw clickCount instead.
        // Sits behind the title cluster, whose own double-click (rename)
        // keeps taking precedence.
        .background(WindowDragHandle())
        // Click-away while renaming: keep the edit (matching focus-loss
        // behavior) and let the click do its normal job — same contract as
        // the sidebar's inline renames.
        .background(
            RenameClickAway(active: isRenaming) {
                commitRename()
            }
        )
        .onChange(of: renameFieldFocused) { _, focused in
            if !focused, isRenaming {
                commitRename()
            }
        }
    }

    // MARK: Rename

    private func beginRename() {
        guard !isRenaming else { return }
        draftTitle = session.title
        isRenaming = true
        renameFieldFocused = true
    }

    /// Commit doubles as cancel: a blanked or untouched title leaves the
    /// session alone.
    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.title else { return }
        store.rename(session, to: trimmed)
    }

    /// Ending a rename leaves first responder parked nowhere, so Return
    /// stops reaching the shell; hand the keyboard back to the terminal.
    private func restoreTerminalFocus() {
        GhosttySurfaceManager.shared.restoreFocus(to: store.selection)
    }

    /// Ink for the process badge: dark ink on a light terminal theme, light
    /// ink on a dark one.
    private var terminalInk: Color {
        GhosttyRuntime.shared.terminalColorScheme == .light ? .black : .white
    }

    /// Appearance for the rename field's editing chrome — selection
    /// highlight, caret — so it keys off the terminal background rather than
    /// the app appearance.
    private var terminalColorScheme: ColorScheme {
        GhosttyRuntime.shared.terminalColorScheme
    }
}

/// Detected-process icon in the full header's leading slot — restored
/// verbatim from the original strip. Agents get their full-color mark
/// (24 pt, drawn from the 48-grid artwork); tool symbols render in the
/// luminance-derived ink at a subdued opacity to stay legible and quiet on
/// any Ghostty theme.
private struct HeaderProcessBadge: View {
    let process: TabProcess
    let ink: Color

    var body: some View {
        switch process.badge {
        case .agent(let base):
            // The header sits on the Ghostty theme background, not the app
            // chrome, so the artwork's light/dark appearance variant must
            // key off that color's luminance rather than the system
            // appearance. Overriding the environment colorScheme makes the
            // asset catalog resolve the matching variant.
            // 24 pt draws the 48-grid artwork: 24 pt @2x is 48 physical
            // pixels, so the marks land 1:1 on the Retina grid.
            Image("\(base)48")
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .environment(\.colorScheme, GhosttyRuntime.shared.terminalColorScheme)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink.opacity(0.6))
        case .dot:
            // A live process without artwork: the idle glyph turns blue.
            Image("TerminalIdleHeader")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Color.blue.opacity(0.8))
                .frame(width: 24, height: 24)
        }
    }
}

/// The narrowed-pane header: title with the working-directory breadcrumb
/// stacked on a line BELOW, compact type. Exists ONLY for panes reduced in
/// width by a horizontal split. Display only — no buttons, no hover
/// actions; clicking it focuses the pane's terminal. The badge keeps the
/// full header's 24pt — the compact treatment shrinks type, never the mark.
private struct CompactPaneHeader: View {
    let session: TerminalSession
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            PaneHeaderBadge(process: session.runningProcess, ink: ink)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(ink.opacity(0.9))
                    .lineLimit(1)

                PaneHeaderBreadcrumb(
                    path: session.workingDirectory,
                    ink: ink,
                    compact: true
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        // Row centered in the fixed 46pt band, icon centered against the
        // two-line text block.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Never steals the keyboard: a click routes focus to this pane's
        // terminal (which also syncs the sidebar selection).
        .onTapGesture { onActivate() }
    }

    /// Ink keyed to the terminal background's luminance, not the app
    /// appearance — the header sits on the Ghostty theme like the old
    /// strip did.
    private var ink: Color {
        GhosttyRuntime.shared.terminalColorScheme == .light ? .black : .white
    }
}

/// The old header strip's segmented breadcrumb, relocated under the title:
/// a home/disk root icon, then discrete path segments between compact
/// chevrons, deep paths collapsed around an ellipsis by PathTrail — never
/// one ellipsized string. `compact` only scales the type down.
private struct PaneHeaderBreadcrumb: View {
    let path: String
    let ink: Color
    let compact: Bool

    var body: some View {
        let trail = PathTrail(path: path)
        let textSize: CGFloat = compact ? 10.5 : 12

        HStack(spacing: compact ? 3 : 4) {
            Image(systemName: trail.rootIcon)
                .font(.system(size: compact ? 8 : 9, weight: .medium))
                .foregroundStyle(ink.opacity(trail.segments.isEmpty ? 0.42 : 0.3))

            if let rootLabel = trail.rootLabel {
                Text(rootLabel)
                    .font(.system(size: textSize))
                    .foregroundStyle(ink.opacity(0.42))
            }

            ForEach(Array(trail.segments.enumerated()), id: \.offset) { index, segment in
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: compact ? 7 : 8, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.18))

                Text(segment)
                    .font(.system(size: textSize))
                    .foregroundStyle(ink.opacity(
                        index == trail.segments.count - 1 ? 0.42 : 0.28
                    ))
                    .lineLimit(1)
            }
        }
    }
}

/// The compact header's icon slot — HeaderProcessBadge's rendering with
/// the idle fallback folded in and a uniform 24pt frame. Same size as the
/// full header's badge in every state: the compact treatment shrinks
/// type, never the mark.
private struct PaneHeaderBadge: View {
    let process: TabProcess?
    let ink: Color

    var body: some View {
        if let process {
            switch process.badge {
            case .agent(let base):
                // Asset variants key off the terminal background, not the
                // system appearance; overriding the environment scheme
                // makes the catalog resolve the matching one.
                Image("\(base)48")
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
                    .environment(\.colorScheme, GhosttyRuntime.shared.terminalColorScheme)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ink.opacity(0.6))
            case .dot:
                Image("TerminalIdleHeader")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.blue.opacity(0.8))
            }
        } else {
            Image("TerminalIdleHeader")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(ink.opacity(0.5))
        }
    }
}
