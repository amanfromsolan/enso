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
    /// The single card's live corner radius; each split pane card reuses
    /// it so panes read as the same card, only smaller.
    let paneCornerRadius: CGFloat

    func makeNSView(context: Context) -> SplitLayoutHostView {
        // Transparent: for the unsplit tab the workspace paints the
        // terminal background behind us; when split, the window chrome
        // must show through the gaps between the pane cards.
        SplitLayoutHostView()
    }

    func updateNSView(_ host: SplitLayoutHostView, context: Context) {
        guard let session else {
            host.apply(tree: nil, sessions: [:], surfaces: [:], focusedID: nil)
            return
        }

        // An unsplit sleeping tab renders nothing here: the workspace
        // overlay draws the full sleeping card in the single-card chrome.
        if container == nil, session.isSleeping {
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
            sessions[id] = live
            // A sleeping pane keeps its card — the host shows the in-pane
            // sleeping view in the terminal's place — but mounts no
            // surface: creating one would respawn the very shell the sleep
            // just put down.
            guard !live.isSleeping else { continue }
            let surface = GhosttySurfaceManager.shared.view(for: live)
            store.wireSurfaceCallbacks(surface, for: id)
            surfaces[id] = surface
        }

        host.store = store
        host.paneCornerRadius = paneCornerRadius
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
    /// The card corner radius split panes wear; set by the representable.
    var paneCornerRadius: CGFloat = 10

    private var tree: SplitNode?
    /// The tree with the in-flight divider drag applied. Divider drags stay
    /// LOCAL until mouse-up: routing every mouse event through the store's
    /// @Published containers re-evaluated every observing view (the whole
    /// sidebar) 60+ times a second for zero visible change there. During a
    /// drag the host lays out from this working copy; release pushes the
    /// final ratio through the store once, which also persists it.
    private var dragTree: SplitNode?
    /// The dragged divider's latest (path, ratio), committed on mouse-up.
    private var pendingDragRatio: (path: SplitPath, ratio: Double)?
    private var surfaces: [TerminalSession.ID: GhosttySurfaceView] = [:]
    /// One card per pane, holding that pane's header and surface. When the
    /// layout is split each card wears the app's terminal-card chrome
    /// (rounded corners, hairline, shadow) so panes sit as individual
    /// cards on the window chrome; the unsplit tab's single card is drawn
    /// by the root view and its lone pane card renders chromeless.
    private var cards: [TerminalSession.ID: PaneCardView] = [:]
    /// Live session snapshots for the panes on screen; kept so a layout
    /// pass can rebuild a header's content when its width crosses the
    /// compact threshold.
    private var sessions: [TerminalSession.ID: TerminalSession] = [:]
    /// Which panes currently wear the compact header. Decided from the
    /// pane's LAID-OUT width (responsive), not from tree topology — a
    /// 50/50 horizontal split at typical window widths goes compact, but
    /// the same split in a very wide window keeps full headers, and a
    /// very narrow window can go compact even unsplit.
    private var compactHeaders: [TerminalSession.ID: Bool] = [:]
    /// One in-pane header per pane (icon + title + cwd), hosted SwiftUI.
    /// Living INSIDE the pane region — never above or across the split —
    /// is what lets the dividers run edge to edge.
    private var headers: [TerminalSession.ID: NSHostingView<PaneHeaderView>] = [:]
    /// The moon view a sleeping pane wears where its terminal would be;
    /// one per sleeping pane, removed the moment the pane wakes.
    private var sleepOverlays: [TerminalSession.ID: NSHostingView<PaneSleepingView>] = [:]
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
        // A structural change under an active drag (pane closed, tab
        // switched) invalidates the working copy; the store's tree wins.
        if dragTree != nil, tree?.leafIDs != self.tree?.leafIDs {
            dragTree = nil
            pendingDragRatio = nil
        }
        self.tree = tree
        self.focusedID = focusedID
        self.sessions = sessions

        // A pane that left the layout (switched tab, closed pane) takes
        // its card — header included — with it; its surface detaches but
        // keeps running in the surface manager. Sleeping panes are still
        // panes (session without surface), so only a missing session
        // removes the card.
        for (id, card) in cards where sessions[id] == nil {
            self.surfaces[id]?.removeFromSuperview()
            card.removeFromSuperview()
            cards.removeValue(forKey: id)
            headers.removeValue(forKey: id)
            sleepOverlays.removeValue(forKey: id)
            compactHeaders.removeValue(forKey: id)
        }
        // A pane that fell asleep in place keeps its card but its dead
        // surface view must not linger under the moon.
        for (id, surface) in self.surfaces where surfaces[id] == nil {
            surface.removeFromSuperview()
        }
        self.surfaces = surfaces

        // Split layouts draw every pane as its own rounded card on the
        // window chrome; the unsplit tab keeps the root view's single-card
        // treatment, so its lone pane renders chromeless.
        let isSplitLayout = if case .split = tree { true } else { false }

        var newlyAttached = false
        for id in sessions.keys {
            let card = cards[id] ?? {
                let card = PaneCardView()
                cards[id] = card
                // Below every sibling: dividers overhang the card edges by
                // a few points, and their grab strips must stay on top of
                // cards added later.
                addSubview(card, positioned: .below, relativeTo: nil)
                return card
            }()
            card.setChrome(enabled: isSplitLayout, cornerRadius: paneCornerRadius)
            // The focused pane of a split wears the accent ring (the card
            // gates it off chrome, so an unsplit tab never rings).
            card.setFocused(id == focusedID)

            if let surface = surfaces[id] {
                if surface.superview !== card.content {
                    surface.autoresizingMask = []
                    card.content.addSubview(surface)
                    newlyAttached = true
                }
                // A woken pane drops its moon.
                if let overlay = sleepOverlays.removeValue(forKey: id) {
                    overlay.removeFromSuperview()
                }
            } else {
                // Sleeping pane: the moon view sits where the terminal
                // would. Clicking it is a pick, like clicking a live
                // pane's surface — selection follows, and the selection
                // observer wakes just this pane.
                let sessionID = id
                let rootView = PaneSleepingView { [weak self] in
                    self?.store?.selection = sessionID
                }
                if let overlay = sleepOverlays[id] {
                    overlay.rootView = rootView
                } else {
                    let overlay = NSHostingView(rootView: rootView)
                    overlay.sizingOptions = []
                    overlay.safeAreaRegions = []
                    sleepOverlays[id] = overlay
                    card.content.addSubview(overlay)
                }
            }

            // Headers live inside the card, above the surface. Which
            // VARIANT one wears (full vs compact) is a width question,
            // settled during the layout pass below once pane rects are
            // known.
            guard let rootView = headerRootView(for: id) else { continue }
            if let header = headers[id] {
                header.rootView = rootView
                card.headerView = header
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
                card.content.addSubview(header)
                card.headerView = header
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
        guard let surface = surfaces[id] else {
            // A sleeping pane has no surface; treat its header click like
            // any other pick of that tab — same path as the moon body.
            store?.selection = id
            return
        }
        window?.makeFirstResponder(surface)
        // Move the focus ring on the click itself; the store publish that
        // onFocusGained triggers confirms the same state a beat later.
        focusedID = id
        for (cardID, card) in cards {
            card.setFocused(cardID == id)
        }
        // The badge tint keys off focus: rebuild the hosted headers so the
        // gray/colored swap lands on the click, not on the store publish
        // that follows.
        for (headerID, header) in headers {
            if let rootView = headerRootView(for: headerID) {
                header.rootView = rootView
            }
        }
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

    /// The gap between pane cards — window chrome showing through. The
    /// divider's grab strip extends a few points past the gap onto the
    /// card edges (see grabOutset), like standard split views, so the
    /// gap stays comfortable to hit.
    static let dividerThickness: CGFloat = 8

    /// How far the divider's invisible grab strip (and hover dots)
    /// overhang the neighboring card edges on each side.
    static let dividerGrabOutset: CGFloat = 4

    /// The absolute floor a divider drag leaves each pane, in points —
    /// room for the header band plus a few lines of terminal. The purely
    /// proportional clamp (SplitBranch.minRatio) compounds under nesting
    /// into slivers; the drag clamps against the real region instead (see
    /// SplitDividerView.clampedRatio).
    static let minPaneExtent: CGFloat = 160

    /// The in-pane header band: two lines (title, then cwd breadcrumb)
    /// centered in the same 46pt the old header strip used, sitting on the
    /// terminal background inside the pane.
    static let paneHeaderHeight: CGFloat = 46

    /// Below this pane height the header collapses entirely and the
    /// surface takes every point: the band plus ~3 lines of terminal is
    /// the least that still reads as a terminal with a title — a pane must
    /// never render as a title with no terminal under it.
    static let headerCollapseHeight: CGFloat = paneHeaderHeight + 40

    /// The responsive compact gate: a pane whose laid-out width drops
    /// below this goes compact. 500pt lands a 50/50 horizontal split
    /// compact at typical window widths while an unsplit tab (or a
    /// full-width stacked pane) stays full — yet the same split in a very
    /// wide window keeps full headers, and a very narrow window can go
    /// compact even unsplit.
    static let compactHeaderEnterWidth: CGFloat = 500
    /// A compact pane returns to full only once it clears this — 40pt of
    /// hysteresis so a divider parked right at the threshold can't flap
    /// the header between variants while dragging.
    static let compactHeaderExitWidth: CGFloat = 540

    /// Rebuilds a pane header's content from the current session snapshot
    /// and compact state; nil when the pane's session or the store is gone.
    private func headerRootView(for id: TerminalSession.ID) -> PaneHeaderView? {
        guard let session = sessions[id], let store else { return nil }
        return PaneHeaderView(
            session: session,
            store: store,
            compact: compactHeaders[id] ?? false,
            focused: id == focusedID
        ) { [weak self] in
            self?.focusPane(id)
        }
    }

    /// The width decision, applied wherever leaf rects are computed: flips
    /// the pane's header variant when its laid-out width crosses the
    /// threshold (with hysteresis), rebuilding the hosted content in place.
    private func updateHeaderVariant(for id: TerminalSession.ID, paneWidth: CGFloat) {
        let wasCompact = compactHeaders[id] ?? false
        let isCompact = wasCompact
            ? paneWidth < Self.compactHeaderExitWidth
            : paneWidth < Self.compactHeaderEnterWidth
        guard isCompact != wasCompact else { return }
        compactHeaders[id] = isCompact
        if let rootView = headerRootView(for: id) {
            headers[id]?.rootView = rootView
        }
    }

    private func layoutPanes() {
        // Mid-drag the working copy wins, so panes track the divider live
        // without a store round trip.
        guard let tree = dragTree ?? tree, bounds.width > 0, bounds.height > 0 else {
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
            // The pane's card claims the whole region; header and surface
            // stack inside it (card-local coordinates), so nothing ever
            // spans across the gap between panes.
            let paneRect = rect.integral
            // The full-vs-compact call is made here, off the measured
            // width, so window resizes and divider drags respond live.
            updateHeaderVariant(for: id, paneWidth: paneRect.width)
            cards[id]?.frame = paneRect
            // A pane squeezed under the collapse threshold hides its header
            // outright: whatever height remains belongs to the surface.
            let headerHeight = paneRect.height < Self.headerCollapseHeight ? 0 : Self.paneHeaderHeight
            headers[id]?.isHidden = headerHeight == 0
            headers[id]?.frame = CGRect(
                x: 0, y: 0,
                width: paneRect.width, height: headerHeight
            )
            // The moon view of a sleeping pane claims the exact region its
            // terminal would.
            let bodyRect = CGRect(
                x: 0, y: headerHeight,
                width: paneRect.width, height: max(paneRect.height - headerHeight, 0)
            )
            surfaces[id]?.frame = bodyRect
            sleepOverlays[id]?.frame = bodyRect
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
                    self?.dragDividerRatio(path: path, to: ratio)
                }
                view.onDragEnded = { [weak self] in
                    self?.commitDividerDrag()
                }
                dividers[path] = view
                return view
            }()
            divider.path = path
            divider.direction = branch.direction
            divider.regionRect = rect
            // The frame overhangs the gap onto the card edges: a wider
            // invisible grab strip, and room for the hover dots to draw.
            divider.frame = branch.direction == .horizontal
                ? dividerRect.insetBy(dx: -Self.dividerGrabOutset, dy: 0)
                : dividerRect.insetBy(dx: 0, dy: -Self.dividerGrabOutset)
            if divider.superview !== self {
                // Above the surfaces; the divider owns the seam strip the
                // pane frames leave open, so hit areas never contend.
                addSubview(divider, positioned: .above, relativeTo: nil)
            }
            divider.window?.invalidateCursorRects(for: divider)
            used.insert(path)
        }
    }

    // MARK: - Divider drags

    /// Live divider drag: applies the ratio to the local working tree and
    /// relays out directly, so the panes follow the pointer without the
    /// store (and every sidebar row observing it) hearing each mouse event.
    private func dragDividerRatio(path: SplitPath, to ratio: Double) {
        guard let base = dragTree ?? tree else { return }
        dragTree = base.updatingRatio(at: path, to: ratio)
        pendingDragRatio = (path, ratio)
        layoutPanes()
    }

    /// Mouse-up: the drag's final ratio goes through the store exactly once
    /// — one publish for the whole gesture — and the existing commit path
    /// persists it.
    private func commitDividerDrag() {
        if let pending = pendingDragRatio {
            onRatioChange?(pending.path, pending.ratio)
        }
        dragTree = nil
        pendingDragRatio = nil
        onRatioCommit?()
    }
}

/// One draggable split divider: an invisible strip spanning the chrome
/// gap between two pane cards (overhanging their edges a few points),
/// converting pointer position into the parent split's first-child
/// ratio. The strip itself draws nothing at rest — the gap is the visual
/// — but hovering fades in a quiet affordance pair: three grab dots and
/// a whisper-opacity seam line along the divider's long axis, both kept
/// visible through a drag. The resize cursor covers the strip.
final class SplitDividerView: NSView {
    var path = SplitPath()
    var direction: SplitDirection = .horizontal {
        didSet {
            dots.direction = direction
            layoutDots()
            layoutSeamLine()
            dots.needsDisplay = true
        }
    }
    /// The whole region the parent split divides, in the host's
    /// coordinates; drags map the pointer into this to produce a ratio.
    var regionRect: CGRect = .zero
    var onDrag: ((SplitPath, Double) -> Void)?
    var onDragEnded: (() -> Void)?

    /// The hover affordance: three quiet dots centered in the gap.
    private let dots = SplitDividerDotsView()
    /// The hover/drag seam line: the sidebar insertion line's language
    /// (2pt, rounded caps, accent) at a whisper opacity, running along the
    /// divider's long axis so what's being grabbed reads without shouting.
    private let seamLine = SeamLineView()
    /// Keeps the affordance up while the pointer is dragging outside the
    /// strip (tracking exits don't apply mid-drag, but be explicit).
    private var isDragging = false

    /// The seam line's thickness; cornerRadius at half fully rounds the caps.
    private static let seamLineThickness: CGFloat = 2
    /// Inset from the divider's ends, keeping the rounded caps clear of
    /// the pane cards' rounded corners.
    private static let seamLineEndInset: CGFloat = 6

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        seamLine.wantsLayer = true
        seamLine.layer?.cornerRadius = Self.seamLineThickness / 2
        seamLine.alphaValue = 0
        addSubview(seamLine)
        applySeamLineColor()
        dots.wantsLayer = true
        dots.alphaValue = 0
        // Dots above the line, centered on it.
        addSubview(dots)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutDots()
        layoutSeamLine()
    }

    private func layoutDots() {
        let size = direction == .horizontal
            ? NSSize(width: SplitDividerDotsView.thickness, height: SplitDividerDotsView.length)
            : NSSize(width: SplitDividerDotsView.length, height: SplitDividerDotsView.thickness)
        dots.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    /// The seam line runs the divider's long axis, centered across the gap.
    private func layoutSeamLine() {
        let t = Self.seamLineThickness
        let inset = Self.seamLineEndInset
        seamLine.frame = direction == .horizontal
            ? NSRect(
                x: (bounds.width - t) / 2, y: inset,
                width: t, height: max(bounds.height - inset * 2, 0)
            )
            : NSRect(
                x: inset, y: (bounds.height - t) / 2,
                width: max(bounds.width - inset * 2, 0), height: t
            )
    }

    /// The sidebar insertion line's accent, taken down to a whisper —
    /// hover feedback, not a drag indicator. Re-resolved on appearance
    /// changes because CALayer colors don't adapt on their own.
    private func applySeamLineColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            seamLine.layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.35).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySeamLineColor()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        fadeAffordance(to: 1)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        fadeAffordance(to: 0)
    }

    /// Quick opacity-only transition — a hover affordance, not a motion
    /// effect.
    private func fadeAffordance(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            dots.animator().alphaValue = alpha
            seamLine.animator().alphaValue = alpha
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: direction == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        // Nothing to record for the ratio — it's absolute (pointer position
        // within the region) — but the affordance must survive the drag
        // even when the pointer leaves the strip.
        isDragging = true
        fadeAffordance(to: 1)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        let thickness = SplitLayoutHostView.dividerThickness
        let usable: CGFloat
        let ratio: Double
        if direction == .horizontal {
            usable = regionRect.width - thickness
            guard usable > 0 else { return }
            ratio = (point.x - regionRect.minX - thickness / 2) / usable
        } else {
            usable = regionRect.height - thickness
            guard usable > 0 else { return }
            ratio = (point.y - regionRect.minY - thickness / 2) / usable
        }
        onDrag?(path, Self.clampedRatio(ratio, usable: usable))
    }

    /// The drag-time ratio clamp: converts the absolute pane floor
    /// (SplitLayoutHostView.minPaneExtent) into a per-region ratio bound,
    /// so no drag can squeeze a pane into a sliver no matter how splits
    /// nest. A region too small to give both panes the floor pins the
    /// divider at the midpoint. `SplitBranch.clampRatio` stays as the
    /// persistence backstop for ratios arriving outside a drag.
    static func clampedRatio(_ ratio: Double, usable: CGFloat) -> Double {
        let minExtent = SplitLayoutHostView.minPaneExtent
        guard usable >= minExtent * 2 else { return 0.5 }
        let minRatio = max(minExtent / usable, SplitBranch.minRatio)
        return min(1 - minRatio, max(minRatio, ratio))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if !bounds.contains(convert(event.locationInWindow, from: nil)) {
            fadeAffordance(to: 0)
        }
        onDragEnded?()
    }

    /// Display-only layer host for the seam line; never intercepts the
    /// divider's clicks.
    private final class SeamLineView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The divider's hover affordance: three small dots in the system's
/// secondary ink (appearance-adaptive, quiet on the frost), laid out
/// along the divider's LONG axis — a vertical column on the seam between
/// side-by-side cards, a horizontal row on the seam between stacked ones
/// — and sized to sit centered within the gap. Display only; never
/// intercepts the divider's clicks.
final class SplitDividerDotsView: NSView {
    var direction: SplitDirection = .horizontal

    static let dotDiameter: CGFloat = 2.5
    static let dotGap: CGFloat = 2.5
    static var length: CGFloat { dotDiameter * 3 + dotGap * 2 }
    static var thickness: CGFloat { dotDiameter }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        let d = Self.dotDiameter
        for index in 0..<3 {
            let offset = CGFloat(index) * (d + Self.dotGap)
            // A horizontal split's divider is a vertical seam: dots stack
            // top-to-bottom. A vertical split's divider runs left-to-right.
            let rect = direction == .horizontal
                ? NSRect(x: (bounds.width - d) / 2, y: offset, width: d, height: d)
                : NSRect(x: offset, y: (bounds.height - d) / 2, width: d, height: d)
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}

// MARK: - Pane card

/// One pane's card: the same treatment as the app's single terminal card
/// — theme background, `Theme.ink` 9% hairline, the soft drop shadow, and
/// continuous rounded corners at the card's own radius — applied per pane
/// when the layout is split, so each pane reads as a mini terminal card
/// sitting on the window chrome. The unsplit tab's chrome is drawn by the
/// root view, so its lone card renders chromeless (flat theme background).
///
/// Structure: the outer view carries the shadow (masksToBounds off, with
/// an explicit shadowPath so the Metal-backed content never forces
/// offscreen shadow rendering); the inner `content` view rounds and clips
/// the header and surface.
final class PaneCardView: NSView {
    /// Rounded clipping container for the pane's header and surface.
    let content: NSView = FlippedContentView()

    /// The focused pane's ring: a 2pt accent stroke hugging the card's
    /// rounded rect (same radius, centered on the edge, so it reads as a
    /// ring around the card rather than an inset box). Only split layouts
    /// wear it — an unsplit tab has no siblings to disambiguate, so it
    /// keeps zero resting chrome. A dedicated shape layer ABOVE the
    /// content, deliberately independent of the outer layer's shadowPath:
    /// the shadow's synchronous-path plumbing (see updateShadowPath) was
    /// fiddly to get right and the ring must never disturb it.
    private let ringLayer = CAShapeLayer()
    private var isFocused = false

    /// Unfocused dim: a scrim in the terminal's own background color, so
    /// content recedes toward its background by the same perceptual step
    /// in light and dark themes alike (Ghostty's unfocused-split
    /// treatment — an alpha fade would instead blend toward whatever
    /// chrome sits behind the card, flipping character between themes).
    /// A bare CALayer never participates in hit-testing.
    private let scrimLayer = CALayer()
    private static let scrimOpacity: Float = 0.25

    /// The pane's header hosting view. The focus treatment fades it —
    /// title, breadcrumb, and all — so an unfocused pane's header reads
    /// as deactivated the way a background window's titlebar does. The
    /// terminal body itself stays at full strength.
    weak var headerView: NSView? {
        didSet {
            guard headerView !== oldValue else { return }
            applyRingVisibility(animated: false)
        }
    }

    static let focusRingWidth: CGFloat = 6

    private var chromeEnabled = false
    private var cornerRadius: CGFloat = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerCurve = .continuous
        content.layer?.backgroundColor = NSColor(GhosttyRuntime.shared.themeBackground).cgColor
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        // Inside the clipped content so the rounded corners contain it;
        // zPosition lifts it above the surface and header backing layers.
        scrimLayer.backgroundColor = NSColor(GhosttyRuntime.shared.themeBackground).cgColor
        scrimLayer.opacity = 0
        scrimLayer.zPosition = 10
        content.layer?.addSublayer(scrimLayer)
        // Added after the content subview so the stroke draws above the
        // card's clipped edge (its outer half lives past the bounds, which
        // masksToBounds = false on this view leaves visible).
        ringLayer.fillColor = nil
        ringLayer.lineWidth = Self.focusRingWidth
        ringLayer.opacity = 0
        layer?.addSublayer(ringLayer)
        applyRingColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setChrome(enabled: Bool, cornerRadius radius: CGFloat) {
        chromeEnabled = enabled
        cornerRadius = radius
        content.layer?.cornerRadius = enabled ? radius : 0
        content.layer?.borderWidth = enabled ? 1 : 0
        applyBorderColor()
        if enabled {
            // The single card's SwiftUI shadow, translated: black 22% at
            // 12pt blur, 3pt downward.
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.22
            layer?.shadowRadius = 12
            layer?.shadowOffset = CGSize(width: 0, height: -3)
        } else {
            layer?.shadowOpacity = 0
        }
        updateShadowPath()
        updateRingPath()
        // A chrome flip (split ⇄ unsplit) snaps rather than fades: the
        // whole card treatment changes in the same commit.
        applyRingVisibility(animated: false)
    }

    /// Focus moved between panes: fade the ring over rather than popping
    /// it. Only meaningful on split cards — the chrome gate above keeps an
    /// unsplit tab's lone card ringless no matter what focus says.
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        applyRingVisibility(animated: true)
    }

    override func layout() {
        super.layout()
        updateShadowPath()
        updateRingPath()
    }

    /// The one guaranteed-synchronous hook on every resize. The first
    /// setChrome runs at creation while bounds are still zero, so the
    /// path guard leaves shadowPath nil — and with no path, CALayer
    /// derives the shadow from the composited content, which renders as
    /// a squarish clipped blob around the Metal-backed card until some
    /// later pass (an appearance change, any store publish) re-ran
    /// setChrome with real bounds. A plain NSView gets no reliable
    /// layout() call after the host assigns its frame, so the path must
    /// chase the frame here.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShadowPath()
        updateRingPath()
    }

    private func updateShadowPath() {
        guard chromeEnabled, bounds.width > 0, bounds.height > 0 else {
            layer?.shadowPath = nil
            return
        }
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: radius, cornerHeight: radius,
            transform: nil
        )
    }

    /// The ring chases the card frame like the shadow path does, but with
    /// implicit animations off — a divider drag resizes cards every mouse
    /// event, and the ring must track rigidly, never wobble after the
    /// frame.
    private func updateRingPath() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.frame = bounds
        scrimLayer.frame = content.bounds
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        ringLayer.path = CGPath(
            roundedRect: bounds,
            cornerWidth: radius, cornerHeight: radius,
            transform: nil
        )
        CATransaction.commit()
    }

    /// Shows the ring only while this card is the focused pane OF A SPLIT,
    /// and drops the unfocused siblings to 90% so the eye lands on the
    /// live pane. The focus question doesn't exist for a lone card, so the
    /// unsplit tab keeps zero resting chrome and full brightness.
    private func applyRingVisibility(animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.1)
        } else {
            CATransaction.setDisableActions(true)
        }
        ringLayer.opacity = chromeEnabled && isFocused ? 1 : 0
        scrimLayer.opacity = chromeEnabled && !isFocused ? Self.scrimOpacity : 0
        CATransaction.commit()

        // The content view's backing layer ignores CATransaction for
        // implicit animation, so the dim goes through the view animator.
        let headerAlpha: CGFloat = chromeEnabled && !isFocused ? 0.55 : 1
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                headerView?.animator().alphaValue = headerAlpha
            }
        } else {
            headerView?.alphaValue = headerAlpha
        }
    }

    /// Accent (respects the user's system accent setting) at a weight that
    /// reads clearly without shouting; the unfocused cards keep the quiet
    /// ink hairline. Re-resolved on appearance changes because CALayer
    /// colors don't adapt on their own.
    private func applyRingColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ringLayer.strokeColor = NSColor.controlAccentColor
                .withAlphaComponent(0.7).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
        applyRingColor()
    }

    /// The single card's hairline is `Theme.ink` at 9% — white ink on the
    /// dark appearance, near-black on light. CALayer colors don't adapt on
    /// their own, so re-resolve whenever the effective appearance changes.
    private func applyBorderColor() {
        guard chromeEnabled else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink = isDark
            ? NSColor(white: 1, alpha: 0.09)
            : NSColor(white: 0.08, alpha: 0.09)
        content.layer?.borderColor = ink.cgColor
    }

    /// Header/surface frames are computed top-down; a flipped container
    /// keeps the math identical to the host's.
    private final class FlippedContentView: NSView {
        override var isFlipped: Bool { true }
    }
}

// MARK: - Pane header

/// The header INSIDE each pane. Two variants with one gate, decided
/// responsively from the pane's LAID-OUT width (see updateHeaderVariant):
/// wide panes — an unsplit tab, a full-width stacked pane, or even a
/// horizontal split in a very wide window — render the ORIGINAL
/// pre-splits header strip verbatim (FullPaneHeader): title and
/// breadcrumb inline on one row. The stacked two-line treatment
/// (CompactPaneHeader) appears only when a pane's width falls under the
/// compact threshold. BOTH variants keep the band's contract: the title
/// cluster owns its clicks (double-click renames inline), and the empty
/// remainder is window chrome — drag to move, double-click to zoom —
/// which matters most when a 50/50 split turns the whole window top into
/// pane headers.
struct PaneHeaderView: View {
    let session: TerminalSession
    let store: TerminalSessionStore
    let compact: Bool
    let focused: Bool
    let onActivate: () -> Void

    var body: some View {
        if compact {
            CompactPaneHeader(session: session, store: store, focused: focused, onActivate: onActivate)
        } else {
            FullPaneHeader(session: session, store: store, focused: focused)
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
    /// False only for the unfocused members of a split: their badge grays
    /// out, so the colored mark always names the pane holding the keyboard.
    let focused: Bool

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
                if session.isSleeping {
                    // Sleeping pane: the moon takes the badge slot,
                    // matching the sidebar row, palette, and switcher.
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(terminalInk.opacity(0.6))
                        .frame(width: 24, height: 24)
                } else if let process = session.runningProcess {
                    HeaderProcessBadge(process: process, ink: terminalInk)
                        .grayscale(focused ? 0 : 1)
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
                    PaneRenameField(
                        fontSize: 15,
                        ink: terminalInk,
                        colorScheme: terminalColorScheme,
                        draftTitle: $draftTitle,
                        focused: $renameFieldFocused,
                        onCommit: {
                            commitRename()
                            restoreTerminalFocus()
                        },
                        onCancel: {
                            isRenaming = false
                            restoreTerminalFocus()
                        }
                    )
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

/// The narrow-pane header: title with the working-directory breadcrumb
/// stacked on a line BELOW, compact type. Appears only when a pane's
/// laid-out width falls under the compact threshold. The badge keeps the
/// full header's 24pt — the compact treatment shrinks type, never the
/// mark. Same band contract as the full header: only the badge+text
/// cluster claims clicks (single click focuses this pane's terminal,
/// double-click renames inline), while the empty trailing band belongs to
/// the window drag handle — with a 50/50 ⌘D split both headers span the
/// window top, and losing drag/zoom there made the window feel nailed
/// down.
private struct CompactPaneHeader: View {
    let session: TerminalSession
    let store: TerminalSessionStore
    /// Same contract as FullPaneHeader: unfocused split members gray
    /// their badge.
    let focused: Bool
    let onActivate: () -> Void

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                PaneHeaderBadge(
                    process: session.runningProcess,
                    sleeping: session.isSleeping,
                    ink: ink
                )
                    .grayscale(focused ? 0 : 1)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    if isRenaming {
                        PaneRenameField(
                            fontSize: 11.5,
                            ink: ink,
                            colorScheme: terminalColorScheme,
                            draftTitle: $draftTitle,
                            focused: $renameFieldFocused,
                            onCommit: {
                                commitRename()
                                restoreTerminalFocus()
                            },
                            onCancel: {
                                isRenaming = false
                                restoreTerminalFocus()
                            }
                        )
                    } else {
                        Text(session.title)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(ink.opacity(0.9))
                            .lineLimit(1)
                    }

                    PaneHeaderBreadcrumb(
                        path: session.workingDirectory,
                        ink: ink,
                        compact: true
                    )
                }
            }
            .contentShape(Rectangle())
            // One immediate gesture reading the raw click count (the
            // sidebar rows' pattern): pairing single+double TapGestures
            // would hold every click for the double-click interval. The
            // first click focuses this pane's terminal — never steals the
            // keyboard for the header — and the second begins the rename.
            .simultaneousGesture(TapGesture().onEnded {
                guard !isRenaming else { return }
                switch NSApp.currentEvent?.clickCount {
                case 1: onActivate()
                case 2: beginRename()
                default: break
                }
            })

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        // Row centered in the fixed 46pt band, icon centered against the
        // two-line text block.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // The band beyond the cluster is window chrome — drag to move,
        // double-click to zoom — in AppKit for the same reason as the full
        // header (see FullPaneHeader's note on WindowDragHandle).
        .background(WindowDragHandle())
        // Click-away while renaming: keep the edit and let the click do
        // its normal job — same contract as the full header's rename.
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

    /// Ink keyed to the terminal background's luminance, not the app
    /// appearance — the header sits on the Ghostty theme like the old
    /// strip did.
    private var ink: Color {
        GhosttyRuntime.shared.terminalColorScheme == .light ? .black : .white
    }

    /// Appearance for the rename field's editing chrome, keyed off the
    /// terminal background rather than the app appearance.
    private var terminalColorScheme: ColorScheme {
        GhosttyRuntime.shared.terminalColorScheme
    }
}

/// The inline-rename field both header variants share: an invisible twin
/// of the draft keeps the field exactly as wide as the typed text — a
/// fixed-width field would shove the breadcrumb sideways the moment
/// editing starts — and the trailing space gives the caret room. Only the
/// type size differs between the full (15pt) and compact (11.5pt) headers.
private struct PaneRenameField: View {
    let fontSize: CGFloat
    let ink: Color
    let colorScheme: ColorScheme
    @Binding var draftTitle: String
    var focused: FocusState<Bool>.Binding
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Text(draftTitle + " ")
            .font(.system(size: fontSize, weight: .regular))
            .lineLimit(1)
            .opacity(0)
            .overlay {
                TextField("", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(ink.opacity(0.9))
                    .environment(\.colorScheme, colorScheme)
                    .focused(focused)
                    .onSubmit(onCommit)
                    .onExitCommand(perform: onCancel)
            }
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

/// What a sleeping pane shows where its terminal would be: the moon and a
/// quiet wake hint on the pane's theme background. No button — like a
/// sidebar row, focusing the pane is what wakes it, and the whole region
/// is the click target.
struct PaneSleepingView: View {
    let onWake: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text("Sleeping")
                .font(.system(size: 13, weight: .semibold))
            Text("Click to wake")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onWake)
        // Ink keyed to the terminal background's luminance, like the pane
        // headers — the view sits on the Ghostty theme, not app chrome.
        .colorScheme(GhosttyRuntime.shared.terminalColorScheme)
    }
}

/// The compact header's icon slot — HeaderProcessBadge's rendering with
/// the idle fallback folded in and a uniform 24pt frame. Same size as the
/// full header's badge in every state: the compact treatment shrinks
/// type, never the mark.
private struct PaneHeaderBadge: View {
    let process: TabProcess?
    let sleeping: Bool
    let ink: Color

    var body: some View {
        if sleeping {
            // The moon takes the badge slot, matching the sidebar row.
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink.opacity(0.6))
        } else if let process {
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
