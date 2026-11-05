import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The sidebar's floating chrome: the top line (space name + menu, the
// Folders/Active capsule) and the bottom bar (the spaces pill, the + circle),
// plus the one glass implementation all three controls share.

enum SidebarViewMode: String {
    case folders
    case active
}

/// Every number the chrome is laid out from, window-relative unless noted.
/// The lights, the Folders/Active capsule and the terminal's top bar centre on
/// y = 26; the space name has the line below.
enum SidebarChromeMetrics {
    /// The window's gutter, shared with the terminal card's inset.
    static let edgeInset: CGFloat = 6
    /// Lines the space name up with the rows' content below it.
    static let nameLeading: CGFloat = 19
    /// The name's padding inside its hover shape, which lines up with the
    /// rows' selection shape: their same 9pt inset.
    static let namePadding: CGFloat = 9
    static let nameHeight: CGFloat = 28

    /// First line: the capsule, on the lights' centre line (10 + 32 / 2 = 26).
    static let modeCapsuleTop: CGFloat = 10
    /// Second line: the space name, on the rows' 36pt rhythm.
    static let nameRowTop: CGFloat = 46
    static let nameRowHeight: CGFloat = 32
    /// Where the pager starts; also the height of the window-drag band.
    static let topClearance: CGFloat = nameRowTop + nameRowHeight

    static let modeCapsuleHeight: CGFloat = 32
    static let modeCellWidth: CGFloat = 36
    static let modeCellHeight: CGFloat = 26
    static let modeInset: CGFloat = 3

    /// The bottom bar is as compact as the top capsule, so the two read as a
    /// pair; the + is a circle of the same height.
    static let pillHeight: CGFloat = 32
    static let pillCellWidth: CGFloat = 36
    static let pillCellHeight: CGFloat = 26
    static let pillInset: CGFloat = 3
    /// How far rows must clear to sit above the bottom bar.
    static let footerHeight: CGFloat = edgeInset + pillHeight + edgeInset
}

// MARK: - Glass

enum SidebarGlass {
    /// DEBUG only: `ENSO_GLASS_FALLBACK=1` draws the pre-macOS 26 fallback
    /// so it can be judged on a current machine.
    static let forcesFallback: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ENSO_GLASS_FALLBACK"] == "1"
        #else
        return false
        #endif
    }()

    /// The thumbs' slide: the only motion this chrome adds, and quick enough
    /// that a click feels instant.
    static func thumbAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.14, bounce: 0)
    }
}

extension View {
    /// The bases of the three controls. Below macOS 26 (or forced), a thin
    /// material with a one-point ink rim.
    @ViewBuilder
    func sidebarGlass<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26, *), !SidebarGlass.forcesFallback {
            glassEffect(.regular, in: shape)
        } else {
            background(shape.fill(.ultraThinMaterial))
                .overlay(shape.strokeBorder(Theme.ink.opacity(0.1), lineWidth: 1).allowsHitTesting(false))
        }
    }

    /// The bases sit above scrolling content on their own terms; the system's
    /// edge effect would add a second fade inside the pill.
    @ViewBuilder
    fileprivate func hidesScrollEdgeEffect() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

/// The sliding selection in both capsules: a plain neutral fill, because glass
/// inside glass reads muddy. Only the capsules themselves are glass.
struct SidebarThumb: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Always darker than the capsule it sits in, in both appearances.
    var body: some View {
        Capsule().fill(Color.black.opacity(colorScheme == .dark ? 0.4 : 0.14))
    }
}

private struct SidebarAttentionDot: View {
    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
            .allowsHitTesting(false)
    }
}

/// The inactive-window dim, for what sits on or beside the glass. It can't go
/// on an ancestor of the glass: those effects flatten it.
private struct SidebarInactiveDim: ViewModifier {
    let isInactive: Bool

    func body(content: Content) -> some View {
        content
            .saturation(isInactive ? 0 : 1)
            .opacity(isInactive ? 0.6 : 1)
    }
}

// MARK: - Top line

/// The sidebar's top two lines: the Folders/Active capsule across from the
/// lights, then the active space's name with its menu. Only the controls take
/// clicks; everything else falls through to the window-drag band underneath.
struct SidebarTopBar: View {
    @ObservedObject var store: TerminalSessionStore
    let isWindowInactive: Bool
    let onSelectSpace: (SidebarSpace.ID) -> Void
    let onEditSpace: (SidebarSpace) -> Void
    let onCreateSpace: () -> Void

    @State private var menu = SidebarSpaceMenu()
    @State private var isHovered = false
    @State private var renamingSpaceID: SidebarSpace.ID?
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                SidebarModeCapsule(store: store, isWindowInactive: isWindowInactive)
            }
            .padding(.top, SidebarChromeMetrics.modeCapsuleTop)
            .padding(.trailing, SidebarChromeMetrics.edgeInset)

            HStack(spacing: 0) {
                if renamingSpaceID != nil {
                    renameField
                        .padding(.leading, SidebarChromeMetrics.namePadding)
                } else {
                    nameLabel
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: SidebarChromeMetrics.nameRowHeight)
            .padding(.leading, SidebarChromeMetrics.nameLeading - SidebarChromeMetrics.namePadding)
            .padding(.trailing, SidebarChromeMetrics.edgeInset)
            .padding(
                .top,
                SidebarChromeMetrics.nameRowTop
                    - SidebarChromeMetrics.modeCapsuleTop
                    - SidebarChromeMetrics.modeCapsuleHeight
            )
        }
        // A rename belongs to the space it started on; a swipe away ends it.
        .onChange(of: store.activeSpaceID) { _, _ in
            commitRename()
        }
    }

    private var space: SidebarSpace { store.activeSpace }

    /// One button, name and chevron together: a click opens the menu right
    /// away. Hovering shows the rows' rounded shape, in ink, so it darkens on
    /// light and lightens on dark.
    private var nameLabel: some View {
        Button(action: openMenu) {
            HStack(spacing: 4) {
                Text(space.name)
                    .font(PaletteFont.primary(.semibold))
                    .tracking(PaletteFont.tracking)
                    .foregroundStyle(Theme.text(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text(isHovered ? 0.9 : 0.65))
                    .frame(width: 14)
            }
            .padding(.leading, SidebarChromeMetrics.namePadding)
            .padding(.trailing, 5)
            .frame(height: SidebarChromeMetrics.nameHeight)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.ink.opacity(isHovered ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .background(SidebarSpaceMenuAnchor(menu: menu))
        .onHover { isHovered = $0 }
        .modifier(SidebarInactiveDim(isInactive: isWindowInactive))
        .accessibilityLabel(space.name)
        .accessibilityHint("Opens the space menu")
    }

    private var renameField: some View {
        TextField("", text: $draftName)
            .textFieldStyle(.plain)
            .font(PaletteFont.primary(.semibold))
            .foregroundStyle(Theme.text(1))
            .focused($nameFocused)
            .onSubmit {
                commitRename()
                restoreTerminalFocus()
            }
            .onExitCommand {
                renamingSpaceID = nil
                restoreTerminalFocus()
            }
            .onChange(of: nameFocused) { _, focused in
                if !focused {
                    commitRename()
                }
            }
            .background(RenameClickAway(active: true) {
                commitRename()
            })
    }

    // MARK: Menu

    private func openMenu() {
        menu.present(menuEntries)
    }

    private var menuEntries: [SidebarSpaceMenu.Entry] {
        let current = space
        var entries: [SidebarSpaceMenu.Entry] = store.spaces.map { other in
            .item(title: other.name, isChecked: other.id == current.id) {
                onSelectSpace(other.id)
            }
        }
        entries.append(.separator)
        entries.append(.item(title: "New Space…", symbol: "plus", action: onCreateSpace))
        entries.append(.item(title: "Rename", symbol: "pencil") {
            beginRename()
        })
        entries.append(.item(title: "Edit Icon & Name…", symbol: "pencil.and.outline") {
            onEditSpace(current)
        })
        if !current.allFolders.isEmpty {
            let allCollapsed = current.allFolders.allSatisfy { store.collapsedFolderIDs.contains($0.id) }
            entries.append(.item(
                title: allCollapsed ? "Expand All Folders" : "Collapse All Folders",
                image: NSImage(named: allCollapsed ? "ExpandFolders" : "CollapseFolders")
            ) {
                if allCollapsed {
                    store.expandAllFolders(inSpace: current.id)
                } else {
                    store.collapseAllFolders(inSpace: current.id)
                }
            })
        }
        entries.append(.separator)
        entries.append(.item(title: "Delete Space", symbol: "trash", isEnabled: store.spaces.count > 1) {
            CloseConfirmation.deleteSpace(store, current.id)
        })
        return entries
    }

    // MARK: Rename

    private func beginRename() {
        draftName = space.name
        renamingSpaceID = space.id
        nameFocused = true
    }

    private func commitRename() {
        guard let id = renamingSpaceID else { return }
        renamingSpaceID = nil
        store.renameSpace(id, to: draftName)
    }

    /// Ending a rename leaves first responder parked nowhere, so Return
    /// stops reaching the shell; hand the keyboard back to the terminal.
    private func restoreTerminalFocus() {
        GhosttySurfaceManager.shared.restoreFocus(to: store.selection)
    }
}

/// The space menu as a real NSMenu popped from the label: SwiftUI's `Menu`
/// styles impose their own label metrics. Same shape as PaneOverflowMenu.
@MainActor
final class SidebarSpaceMenu {
    enum Entry {
        case entry(title: String, image: NSImage?, isChecked: Bool, isEnabled: Bool, action: () -> Void)
        case separator

        static func item(
            title: String,
            symbol: String? = nil,
            image: NSImage? = nil,
            isChecked: Bool = false,
            isEnabled: Bool = true,
            action: @escaping () -> Void
        ) -> Entry {
            let resolved = image ?? symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            return .entry(title: title, image: resolved, isChecked: isChecked, isEnabled: isEnabled, action: action)
        }
    }

    weak var anchor: NSView?

    func present(_ entries: [Entry]) {
        guard let anchor else { return }
        let menu = NSMenu()
        // Our own enablement, not the responder chain's guesswork.
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .entry(let title, let image, let isChecked, let isEnabled, let action):
                let item = ActionItem(title: title, handler: action)
                item.image = image
                item.state = isChecked ? .on : .off
                item.isEnabled = isEnabled
                menu.addItem(item)
            }
        }
        let gap: CGFloat = 6
        let origin = NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + gap : -gap)
        menu.popUp(positioning: nil, at: origin, in: anchor)
    }

    /// NSMenuItem carries a target/action pair, not a closure.
    private final class ActionItem: NSMenuItem {
        private let handler: () -> Void

        init(title: String, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        @objc private func fire() {
            handler()
        }
    }
}

/// The AppKit view the space menu drops from. Never takes a click.
private struct SidebarSpaceMenuAnchor: NSViewRepresentable {
    let menu: SidebarSpaceMenu

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        menu.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        menu.anchor = nsView
    }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The Folders/Active capsule: two icon-only cells under a sliding thumb.
private struct SidebarModeCapsule: View {
    @ObservedObject var store: TerminalSessionStore
    let isWindowInactive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var thumbX: CGFloat {
        SidebarChromeMetrics.modeInset
            + (store.sidebarViewMode == .folders ? 0 : SidebarChromeMetrics.modeCellWidth)
    }

    private var activeHasAttention: Bool {
        store.activeSpace.sessions.contains { $0.status == .attention }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear.sidebarGlass(in: Capsule())

            SidebarThumb()
                .frame(width: SidebarChromeMetrics.modeCellWidth, height: SidebarChromeMetrics.modeCellHeight)
                .offset(x: thumbX)
                .animation(SidebarGlass.thumbAnimation(reduceMotion: reduceMotion), value: store.sidebarViewMode)
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                cell(.folders, symbol: "folder", name: "Folders", hasAttention: false)
                cell(.active, symbol: "line.3.horizontal.decrease", name: "Active", hasAttention: activeHasAttention)
            }
            .padding(.horizontal, SidebarChromeMetrics.modeInset)
            .modifier(SidebarInactiveDim(isInactive: isWindowInactive))
        }
        .frame(
            width: SidebarChromeMetrics.modeCellWidth * 2 + SidebarChromeMetrics.modeInset * 2,
            height: SidebarChromeMetrics.modeCapsuleHeight
        )
    }

    private func cell(_ mode: SidebarViewMode, symbol: String, name: String, hasAttention: Bool) -> some View {
        let isSelected = store.sidebarViewMode == mode
        return Button {
            store.sidebarViewMode = mode
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text(isSelected ? 0.95 : 0.7))
                // This glyph's ink sits half a point low; the folder's doesn't.
                .offset(y: mode == .active ? -0.5 : 0)
                .frame(width: SidebarChromeMetrics.modeCellWidth, height: SidebarChromeMetrics.modeCellHeight)
                .overlay {
                    if hasAttention {
                        SidebarAttentionDot().offset(x: 9, y: -7)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Bottom bar

/// The spaces pill and the + circle, same height and centred as one group. The
/// pill grows with its spaces until the gaps left, between and right are equal,
/// then scrolls inside. An overlay on the sidebar, so rows scroll under the
/// glass.
struct SidebarFooter: View {
    @ObservedObject var store: TerminalSessionStore
    let isWindowInactive: Bool
    let onSelect: (SidebarSpace.ID) -> Void
    let onEdit: (SidebarSpace) -> Void
    let onCreate: () -> Void

    @State private var plusHovered = false

    var body: some View {
        HStack(spacing: SidebarChromeMetrics.edgeInset) {
            SpacePill(
                store: store,
                isWindowInactive: isWindowInactive,
                onSelect: onSelect,
                onEdit: onEdit
            )

            Button(action: onCreate) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text(plusHovered ? 1 : 0.85))
                    .modifier(SidebarInactiveDim(isInactive: isWindowInactive))
                    .frame(width: SidebarChromeMetrics.pillHeight, height: SidebarChromeMetrics.pillHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Not interactive glass: that stretches toward the pointer, and
            // this has to stay a true circle.
            .sidebarGlass(in: Circle())
            .frame(width: SidebarChromeMetrics.pillHeight, height: SidebarChromeMetrics.pillHeight)
            .onHover { plusHovered = $0 }
            .help("New Space (or swipe past the last space)")
            .accessibilityLabel("New Space")
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, SidebarChromeMetrics.edgeInset)
    }
}

/// One cell per space inside a glass capsule. Three layers, because a mask or
/// clip on an ancestor of glass breaks it: the base and the thumb stay
/// unmasked, and only the scrolling icons on top carry the soft edges. When
/// the spaces fit, nothing scrolls and the offset stays at zero.
private struct SpacePill: View {
    @ObservedObject var store: TerminalSessionStore
    let isWindowInactive: Bool
    let onSelect: (SidebarSpace.ID) -> Void
    let onEdit: (SidebarSpace) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Written only while the icons actually scroll.
    @State private var scrollOffset: CGFloat = 0
    @State private var hoveredSpaceID: SidebarSpace.ID?
    /// The insertion index a hovered space drag would commit to, or nil when
    /// nothing droppable is hovered (including the dragged cell's own slot).
    @State private var dropIndex: Int?
    /// When a drag near a faded end last scrolled a step.
    @State private var lastDragStep: CFTimeInterval = 0

    private static let cell = SidebarChromeMetrics.pillCellWidth
    private static let inset = SidebarChromeMetrics.pillInset
    private static let fadeLength: CGFloat = 14
    private static let dragStepInterval: CFTimeInterval = 0.35

    private var contentWidth: CGFloat {
        CGFloat(store.spaces.count) * Self.cell + Self.inset * 2
    }

    /// What's left of the sidebar beside the + circle and the three insets.
    private var maxWidth: CGFloat {
        store.sidebarWidth
            - SidebarChromeMetrics.edgeInset * 3
            - SidebarChromeMetrics.pillHeight
    }

    private var width: CGFloat { min(contentWidth, maxWidth) }
    private var overflows: Bool { contentWidth > maxWidth }
    private var maxOffset: CGFloat { max(0, contentWidth - width) }

    private var activeIndex: Int {
        store.spaces.firstIndex { $0.id == store.activeSpaceID } ?? 0
    }

    private var fadesLeading: Bool { overflows && scrollOffset > 0.5 }
    private var fadesTrailing: Bool { overflows && scrollOffset < maxOffset - 0.5 }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .leading) {
                Color.clear.sidebarGlass(in: Capsule())

                thumb

                icons
                    .mask(fadeMask)
                    .modifier(SidebarInactiveDim(isInactive: isWindowInactive))

                scrolledOutAttention
                    .modifier(SidebarInactiveDim(isInactive: isWindowInactive))

                dropIndicator
            }
            .frame(width: width, height: SidebarChromeMetrics.pillHeight)
            .contentShape(Capsule())
            .onDrop(of: [.text], delegate: SidebarSpaceDropDelegate(
                onUpdate: { handleDragUpdate(at: $0, proxy: proxy) },
                onExited: { dropIndex = nil },
                onPerform: { performDrop($0) }
            ))
            .onChange(of: store.activeSpaceID) { _, _ in
                reveal(proxy, animated: true)
            }
            .onChange(of: overflows) { _, _ in
                reveal(proxy, animated: false)
            }
            .onAppear {
                // The scroll view has no size to scroll within until the
                // pass after this one.
                DispatchQueue.main.async {
                    reveal(proxy, animated: false)
                }
            }
        }
    }

    // MARK: Layers

    /// Two offsets on purpose: the spring owns the index, and the scroll
    /// offset and edge clamp apply on top without disturbing it. The thumb
    /// fades as its place leaves the capsule and is held inside the capsule's
    /// edge meanwhile, because glass can't be clipped.
    private var thumb: some View {
        let rest = Self.inset + CGFloat(activeIndex) * Self.cell
        let scrolled = rest - scrollOffset
        let clamped = min(max(scrolled, Self.inset), width - Self.inset - Self.cell)
        let opacity = max(0, 1 - abs(clamped - scrolled) / 12)
        return SidebarThumb()
            .frame(width: Self.cell, height: SidebarChromeMetrics.pillCellHeight)
            .offset(x: rest)
            .animation(SidebarGlass.thumbAnimation(reduceMotion: reduceMotion), value: activeIndex)
            .offset(x: clamped - rest)
            .opacity(opacity)
            .allowsHitTesting(false)
    }

    private var icons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(store.spaces) { space in
                    cell(for: space)
                        .id(space.id)
                }
            }
            .padding(.horizontal, Self.inset)
            .frame(height: SidebarChromeMetrics.pillHeight)
            // Keyed to the order, not wrapped around the store mutation: the
            // reorder must stay un-animated store-wide (see performDrop), so
            // only the pill slides its cells.
            .animation(.spring(duration: 0.32, bounce: 0.12), value: store.spaces.map(\.id))
        }
        .scrollDisabled(!overflows)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .hidesScrollEdgeEffect()
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.x + geometry.contentInsets.leading
        } action: { _, offset in
            scrollOffset = offset
        }
    }

    private func cell(for space: SidebarSpace) -> some View {
        let isActive = store.activeSpaceID == space.id
        let isHovered = hoveredSpaceID == space.id
        let hasAttention = space.sessions.contains { $0.status == .attention }
        return Button {
            onSelect(space.id)
        } label: {
            SpaceIndicatorIcon(icon: space.icon, isActive: isActive, size: 18)
                .frame(width: Self.cell, height: SidebarChromeMetrics.pillCellHeight)
                .overlay {
                    if hasAttention {
                        SidebarAttentionDot().offset(x: 9, y: -7)
                    }
                }
                .background(
                    Capsule().fill(Theme.ink.opacity(isHovered && !isActive ? 0.08 : 0))
                )
                .contentShape(Capsule())
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
        .accessibilityLabel(space.name)
        .contextMenu {
            Button("Edit Space…", systemImage: "pencil") {
                onEdit(space)
            }
            Button("Delete Space", systemImage: "trash") {
                CloseConfirmation.deleteSpace(store, space.id)
            }
            .disabled(store.spaces.count == 1)
        }
        .onDrag {
            let payload = SidebarDragPayload.space(space.id)
            store.activeSidebarDrag = payload
            return NSItemProvider(object: payload.stringValue as NSString)
        } preview: {
            SpaceIndicatorIcon(icon: space.icon, isActive: true, size: 18)
                .frame(width: 24, height: 24)
        }
    }

    /// Soft edges on the icons only, on an end with something beyond it.
    private var fadeMask: some View {
        let fade = min(Self.fadeLength / max(width, 1), 0.5)
        return LinearGradient(
            stops: [
                .init(color: fadesLeading ? .clear : .black, location: 0),
                .init(color: .black, location: fade),
                .init(color: .black, location: 1 - fade),
                .init(color: fadesTrailing ? .clear : .black, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Attention mustn't vanish with the cell that carries it: a space
    /// scrolled out wears its dot on the capsule's edge instead.
    @ViewBuilder
    private var scrolledOutAttention: some View {
        if overflows {
            let centres = store.spaces.enumerated().compactMap { index, space -> CGFloat? in
                guard space.sessions.contains(where: { $0.status == .attention }) else { return nil }
                return Self.inset + (CGFloat(index) + 0.5) * Self.cell - scrollOffset
            }
            ZStack {
                if centres.contains(where: { $0 < 0 }) {
                    SidebarAttentionDot()
                        .padding(.leading, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if centres.contains(where: { $0 > width }) {
                    SidebarAttentionDot()
                        .padding(.trailing, 6)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The insertion indicator: a short vertical line on the seam between
    /// cells, the pill's rotation of the sidebar's drop line. Static on purpose.
    @ViewBuilder
    private var dropIndicator: some View {
        if let dropIndex {
            let x = min(
                max(Self.inset + CGFloat(dropIndex) * Self.cell - scrollOffset, Self.inset),
                width - Self.inset
            )
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(width: 2, height: 16)
                .offset(x: x - 1)
                .allowsHitTesting(false)
        }
    }

    // MARK: Keeping the active space in view

    private func reveal(_ proxy: ScrollViewProxy, animated: Bool) {
        guard overflows else { return }
        let id = store.activeSpaceID
        if animated, !reduceMotion {
            withAnimation(.spring(duration: 0.14, bounce: 0)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    // MARK: Reordering

    /// How many cells sit with their midpoint left of the pointer.
    private func insertionIndex(at x: CGFloat) -> Int {
        let raw = ((x + scrollOffset - Self.inset) / Self.cell).rounded()
        return min(max(Int(raw), 0), store.spaces.count)
    }

    private func handleDragUpdate(at location: CGPoint, proxy: ScrollViewProxy) -> Bool {
        guard case .space(let draggedID) = store.activeSidebarDrag else {
            dropIndex = nil
            return false
        }
        stepScrollIfAtEdge(location.x, proxy: proxy)
        let index = insertionIndex(at: location.x)
        // The dragged cell's own slot: a drop would change nothing, so show
        // nothing — but it isn't a forbidden position either.
        if let from = store.spaces.firstIndex(where: { $0.id == draggedID }),
           index == from || index == from + 1 {
            dropIndex = nil
        } else {
            dropIndex = index
        }
        return true
    }

    /// A drag resting on a faded end brings the next cell in, one at a time.
    private func stepScrollIfAtEdge(_ x: CGFloat, proxy: ScrollViewProxy) {
        guard overflows else { return }
        let now = CACurrentMediaTime()
        guard now - lastDragStep >= Self.dragStepInterval else { return }
        let target: (index: Int, anchor: UnitPoint)
        if x < Self.fadeLength, fadesLeading {
            let firstWhole = Int(((scrollOffset - Self.inset) / Self.cell).rounded(.up))
            target = (firstWhole - 1, .leading)
        } else if x > width - Self.fadeLength, fadesTrailing {
            let lastWhole = Int(((scrollOffset + width - Self.inset) / Self.cell).rounded(.down)) - 1
            target = (lastWhole + 1, .trailing)
        } else {
            return
        }
        guard store.spaces.indices.contains(target.index) else { return }
        lastDragStep = now
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(store.spaces[target.index].id, anchor: target.anchor)
        }
    }

    private func performDrop(_ info: DropInfo) -> Bool {
        let index = dropIndex
        dropIndex = nil
        store.activeSidebarDrag = nil
        // Only space drags get past dropUpdated, so even the no-op own-slot
        // release reports handled: returning false would fly the drag image
        // back to its origin.
        guard let index else { return true }
        let providers = info.itemProviders(for: [.text])
        guard !providers.isEmpty else { return true }
        Task { @MainActor in
            var items: [String] = []
            for provider in providers {
                if let item = await provider.sidebarDragString() {
                    items.append(item)
                }
            }
            guard case .space(let spaceID) = SidebarDragPayload.decode(items: items) else { return }
            // No withAnimation: the pager derives its offset from the active
            // space's index, so an animated reorder sweeps neighboring space
            // pages through the tab list above the pill. Un-animated, the
            // offset jumps while the same page stays on screen — invisible —
            // and the pill's keyed animation slides the cells on its own.
            store.moveSpace(spaceID, toIndex: index)
        }
        return true
    }
}
