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
            guard let session = sessions[id] else { continue }
            let rootView = PaneHeaderView(
                session: session,
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

/// The header INSIDE each pane: the tab's process icon and title, with the
/// working directory breadcrumb on a quieter second line below. One
/// component serves split panes and the unsplit tab alike (a plain tab is
/// a single-leaf tree through the same host path). Display only — no
/// buttons, no hover actions; clicking it focuses the pane's terminal.
///
/// Type responds to splitting: `compact` (set only for panes narrowed by
/// a horizontal split) shrinks the title and breadcrumb; an unsplit tab
/// and vertical-only (full-width) panes keep the old header strip's
/// full-size treatment. The icon never changes size.
struct PaneHeaderView: View {
    let session: TerminalSession
    let compact: Bool
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Fixed 24pt in every state — the old strip's badge size; the
            // compact treatment shrinks type only, never the mark.
            PaneHeaderBadge(process: session.runningProcess, ink: ink)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: compact ? 12.5 : 15, weight: compact ? .medium : .regular))
                    .foregroundStyle(ink.opacity(0.9))
                    .lineLimit(1)

                PaneHeaderBreadcrumb(
                    path: session.workingDirectory,
                    ink: ink,
                    compact: compact
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

/// The pane header's icon slot — the old strip's badge, unchanged in size
/// across states and inked off the terminal background's luminance: agents
/// keep their full-color mark (24pt draws the 48-grid artwork 1:1 on the
/// Retina grid), known tools their symbol, live-but-unknown processes the
/// blue glyph, idle panes the quiet grey one.
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
