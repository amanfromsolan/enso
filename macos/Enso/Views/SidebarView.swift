import CoreImage
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var store: TerminalSessionStore

    @ObservedObject private var updateController = UpdateController.shared
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var trailingOverscroll: CGFloat = 0
    @State private var spacePager = SpacePager()
    /// Presented by the root view as an in-window modal (owned chrome —
    /// macOS sheet windows force their own border and corner radius).
    @Binding var spaceEditor: SpaceEditorSheet.Mode?

    /// Overscroll distance past the last space that triggers space creation.
    static let newSpaceThreshold: CGFloat = 45

    // Inactive-window chrome dim, the standard macOS treatment: sidebar text,
    // icons, and tints drop toward grey while the window isn't key.
    private var isWindowInactive: Bool { controlActiveState == .inactive }

    /// With no update card the pager reaches the window's bottom so rows pass
    /// under the bar's glass. A card sits above the bar instead, and the pager
    /// stops above the card.
    private var pagerRunsUnderFooter: Bool { updateController.phase == .idle }

    var body: some View {
        VStack(spacing: 0) {
            pager
            UpdateCardView(controller: .shared)
            if !pagerRunsUnderFooter {
                Color.clear.frame(height: SidebarChromeMetrics.footerHeight)
            }
        }
        // Down here rather than on the column: on an ancestor of the glass
        // controls, these two would flatten it.
        .saturation(isWindowInactive ? 0 : 1)
        .opacity(isWindowInactive ? 0.6 : 1)
        // Clear space for the traffic lights and the top line.
        .padding(.top, SidebarChromeMetrics.topClearance)
        .overlay(alignment: .bottom) {
            SidebarFooter(
                store: store,
                isWindowInactive: isWindowInactive,
                onSelect: { spacePager.switchSpace(to: $0) },
                onEdit: { spaceEditor = .edit($0) },
                onCreate: { spaceEditor = .create }
            )
        }
        // Drags the window, double-click zooms like a real titlebar. Handled
        // in AppKit (see WindowDragHandle) because SwiftUI's WindowDragGesture
        // starves a paired double-click tap. An overlay, not a stacked sibling:
        // macOS 26 floats a scroll-edge pocket (NSScrollPocket) over the
        // sidebar's top that out-z-orders anything earlier in the stack and
        // ate these clicks; the overlay sits above it. The top line goes in
        // the same overlay, above the handle, so its controls take their
        // clicks and the empty parts of the band still drag.
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                WindowDragHandle()
                    .frame(height: SidebarChromeMetrics.topClearance)

                SidebarTopBar(
                    store: store,
                    isWindowInactive: isWindowInactive,
                    onSelectSpace: { spacePager.switchSpace(to: $0) },
                    onEditSpace: { spaceEditor = .edit($0) },
                    onCreateSpace: { spaceEditor = .create }
                )
            }
        }
    }

    /// One space page is exactly one sidebar's width, so the paging math
    /// tracks the live (drag-resizable) sidebar width, not a constant.
    private var pageWidth: CGFloat { store.sidebarWidth }

    private var pager: some View {
        SpacePagerRepresentable(
            pager: spacePager,
            store: store,
            spaces: store.spaces,
            activeSpaceID: store.activeSpaceID,
            pageWidth: pageWidth
        )
        .frame(width: pageWidth)
        .background(
            SidebarSwipeCapture(
                onChanged: { translation in
                    // No view state here: fingers move one layer, and only
                    // the overscroll past the last space touches SwiftUI.
                    spacePager.track(translation: translation)
                    updateOverscroll(translation: translation)
                },
                onEnded: { translation, velocity, pointsPerSecond in
                    finishSwipe(translation: translation, velocity: velocity, pointsPerSecond: pointsPerSecond)
                }
            )
            // The capture owns horizontal scrolls over its bounds; it must
            // stop short of the bar or it would steal them from the pill.
            .padding(.bottom, pagerRunsUnderFooter ? SidebarChromeMetrics.footerHeight : 0)
        )
        .overlay(alignment: .trailing) {
            if trailingOverscroll > 4 {
                NewSpaceTeaser(progress: min(trailingOverscroll / Self.newSpaceThreshold, 1))
                    .allowsHitTesting(false)
            }
        }
    }

    private func updateOverscroll(translation: CGFloat) {
        var overscroll: CGFloat = 0
        if spacePager.targetIndex == store.spaces.count - 1, translation < 0 {
            overscroll = min(pageWidth, -translation * 0.5)
        }
        if overscroll != trailingOverscroll {
            trailingOverscroll = overscroll
        }
    }

    private func finishSwipe(translation: CGFloat, velocity: CGFloat, pointsPerSecond: CGFloat) {
        let current = spacePager.targetIndex
        let atLast = current == store.spaces.count - 1

        if atLast, translation < 0, -translation * 0.5 > Self.newSpaceThreshold {
            spaceEditor = .create
        }

        var target = current
        if translation < 0, -translation > pageWidth * 0.35 || velocity < -6 {
            target += 1
        } else if translation > 0, translation > pageWidth * 0.35 || velocity > 6 {
            target -= 1
        }
        target = min(max(target, 0), store.spaces.count - 1)

        if trailingOverscroll != 0 {
            withAnimation(.spring(duration: 0.32, bounce: 0.12)) {
                trailingOverscroll = 0
            }
        }
        spacePager.release(toIndex: target, fingerPointsPerSecond: pointsPerSecond)
    }
}

// MARK: - Pager

/// The slide's feel. The swipe tuner overrides these in dev tools builds.
enum SlideTuning {
    static let bounce: CGFloat = 0.12
    static let defaultDuration: TimeInterval = 0.25
    static let defaultFade: CGFloat = 0.30
    static let defaultBlur: CGFloat = 0

    #if ENSO_DEVTOOLS
    static var duration: TimeInterval { SwipeTuner.shared.duration }
    static var fade: CGFloat { SwipeTuner.shared.fadePercent / 100 }
    static var blur: CGFloat { SwipeTuner.shared.blur }
    #else
    static var duration: TimeInterval { defaultDuration }
    static var fade: CGFloat { defaultFade }
    static var blur: CGFloat { defaultBlur }
    #endif
}

/// Moves the space pages as one Core Animation layer, so neither a swipe nor
/// the settle after it runs SwiftUI or AppKit layout per frame. Page content
/// lives in one hosting view per space, outside the root view's graph.
///
/// The strip's frame always holds the page it is heading to, so clicks and
/// scrolling land correctly the moment the motion ends. The motion itself is a
/// transform on top: fingers set it directly, and a release hands it to a
/// spring in the render server, which keeps moving whatever the main thread is
/// doing. The store only hears about a new space once that spring is committed.
@MainActor
final class SpacePager {
    #if ENSO_DEVTOOLS
    /// For the space switch test, so it drives the real path.
    static weak var current: SpacePager?
    #endif

    /// A flick can be faster than the page can usefully move; past this the
    /// overshoot would show the next page. At the default spring and 12 pages
    /// a second, the overshoot is about 1% of a page.
    private static let maxPagesPerSecond: CGFloat = 12
    /// A click during a settle finishes the motion this quickly, because
    /// simply dropping the animation would jump the page up to a full width.
    private static let landingDuration: TimeInterval = 0.08

    /// How long after the spring starts the store (and so the terminal) changes.
    /// `-EnsoSlideCommitDelay <ms>` compares moments; 340 means as it lands.
    private static let commitDelay: TimeInterval = {
        #if ENSO_DEVTOOLS
        return UserDefaults.standard.double(forKey: "EnsoSlideCommitDelay") / 1000
        #else
        return 0
        #endif
    }()

    fileprivate weak var view: SpacePagerView?
    fileprivate weak var store: TerminalSessionStore?

    private var spaces: [SidebarSpace] = []
    private var hosts: [SidebarSpace.ID: NSHostingView<SpacePage>] = [:]
    private var pageWidth: CGFloat = 0

    /// The page at rest or being headed for; ahead of the store while a commit
    /// is pending.
    private(set) var targetIndex = 0
    private(set) var targetSpaceID: SidebarSpace.ID?

    private var isTracking = false
    private var trackingStart: CGFloat = 0
    private var trackedPosition: CGFloat = 0
    /// The running spring, in pages, for carrying its speed into the next one.
    private var activeSlide: (spring: Spring, start: CFTimeInterval, from: CGFloat, to: CGFloat, velocity: CGFloat)?
    private var blurClear: DispatchWorkItem?
    private var hasBlurFilters = false

    private var pendingCommit: DispatchWorkItem?
    private var pendingSpaceID: SidebarSpace.ID?

    // MARK: Driving it

    /// Fingers down. Takes over from a running spring exactly where it is.
    func track(translation: CGFloat) {
        guard pageWidth > 0 else { return }
        if !isTracking {
            trackingStart = stopMotion()
            trackedPosition = trackingStart
            isTracking = true
            view?.ignoresClicks = true
            prepareBlur()
        }
        var offset = translation
        if (offset > 0 && targetIndex == 0) || (offset < 0 && targetIndex == spaces.count - 1) {
            offset *= 0.5
        }
        offset = min(pageWidth, max(-pageWidth, offset))
        trackedPosition = trackingStart - offset / pageWidth
        place(at: trackedPosition)
    }

    /// Fingers up: the spring starts at the finger's speed.
    func release(toIndex index: Int, fingerPointsPerSecond: CGFloat) {
        let pages = pageWidth > 0 ? -fingerPointsPerSecond / pageWidth : 0
        let velocity = min(Self.maxPagesPerSecond, max(-Self.maxPagesPerSecond, pages))
        slide(toIndex: index, velocity: velocity, flushes: true)
        if spaces.indices.contains(index) {
            commit(spaces[index].id)
        }
    }

    /// A click on a space's icon. Also what the store-side switch hangs off.
    func switchSpace(to spaceID: SidebarSpace.ID) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }), view != nil else {
            store?.activateSpace(spaceID)
            return
        }
        if index != targetIndex {
            slide(toIndex: index, velocity: nil, flushes: true)
        }
        commit(spaceID)
    }

    /// The spring is already in the render server by now, so the store update
    /// and terminal swap can't hold up its first frames.
    private func commit(_ spaceID: SidebarSpace.ID) {
        pendingCommit?.cancel()
        pendingCommit = nil
        pendingSpaceID = nil
        guard let store, spaceID != store.activeSpaceID else { return }
        guard Self.commitDelay > 0 else {
            store.activateSpace(spaceID)
            return
        }
        let work = DispatchWorkItem { [weak self, weak store] in
            self?.pendingCommit = nil
            self?.pendingSpaceID = nil
            store?.activateSpace(spaceID)
        }
        pendingCommit = work
        pendingSpaceID = spaceID
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commitDelay, execute: work)
    }

    private func commitNow(_ spaceID: SidebarSpace.ID) {
        pendingCommit?.cancel()
        pendingCommit = nil
        pendingSpaceID = nil
        store?.activateSpace(spaceID)
    }

    // MARK: Motion

    private func slide(toIndex index: Int, velocity: CGFloat?, flushes: Bool) {
        guard let view, let stripLayer = view.strip.layer, spaces.indices.contains(index) else { return }
        let startVelocity = velocity ?? currentVelocity()
        let from = isTracking ? trackedPosition : stopMotion()
        isTracking = false
        targetIndex = index
        targetSpaceID = spaces[index].id
        let target = CGFloat(index)
        let distance = target - from
        let moves = abs(distance) > 0.0005
        let duration = SlideTuning.duration
        prepareBlur()
        // The spring's velocity is in full journeys per second.
        let journeys = moves ? min(50, max(-50, startVelocity / distance)) : 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The model jumps to the end; the animations play back the way there.
        layoutPages()
        stripLayer.transform = CATransform3DIdentity
        var settle: CFTimeInterval = 0
        if moves {
            let motion = springAnimation(
                "transform.translation.x", from: distance * pageWidth, to: 0, duration: duration, journeys: journeys
            )
            settle = motion.settlingDuration
            stripLayer.add(motion, forKey: Self.motionKey)
        }
        for (pageIndex, space) in spaces.enumerated() {
            guard let host = hosts[space.id] else { continue }
            let start = Self.opacity(page: pageIndex, position: from)
            let end = Self.opacity(page: pageIndex, position: target)
            host.alphaValue = end
            if abs(start - end) > 0.001 {
                host.layer?.add(
                    springAnimation("opacity", from: start, to: end, duration: duration, journeys: journeys),
                    forKey: Self.motionKey
                )
            }
            if SlideTuning.blur > 0 {
                let blurStart = Self.blurRadius(page: pageIndex, position: from)
                let blurEnd = Self.blurRadius(page: pageIndex, position: target)
                setBlur(on: host, radius: blurEnd)
                if abs(blurStart - blurEnd) > 0.01 {
                    host.layer?.add(
                        springAnimation(Self.blurKeyPath, from: blurStart, to: blurEnd, duration: duration, journeys: journeys),
                        forKey: Self.blurMotionKey
                    )
                }
            }
        }
        CATransaction.commit()
        if flushes {
            CATransaction.flush()
        }

        view.ignoresClicks = false
        activeSlide = moves
            ? (Spring(duration: duration, bounce: SlideTuning.bounce), CACurrentMediaTime(), from, target, startVelocity)
            : nil
        scheduleBlurClear(after: settle)
    }

    /// A mouse-down on a settling page. The model is already at the destination,
    /// so the click reaches the row under the pointer straight away; the picture
    /// catches up in a blink, and the store too if its commit was waiting.
    fileprivate func landForClick() {
        guard !isTracking, activeSlide != nil, let stripLayer = view?.strip.layer else { return }
        let offset = (stripLayer.presentation() ?? stripLayer).transform.m41
        let position = CGFloat(targetIndex) - (pageWidth > 0 ? offset / pageWidth : 0)
        removeMotion()
        activeSlide = nil
        if let pendingSpaceID {
            commitNow(pendingSpaceID)
        }

        guard abs(offset) > 0.5 else {
            clearBlur()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripLayer.add(
            landingAnimation("transform.translation.x", from: offset, to: 0),
            forKey: Self.motionKey
        )
        let target = CGFloat(targetIndex)
        for (pageIndex, space) in spaces.enumerated() {
            guard let host = hosts[space.id] else { continue }
            let start = Self.opacity(page: pageIndex, position: position)
            let end = Self.opacity(page: pageIndex, position: target)
            if abs(start - end) > 0.001 {
                host.layer?.add(landingAnimation("opacity", from: start, to: end), forKey: Self.motionKey)
            }
            if hasBlurFilters {
                let blurStart = Self.blurRadius(page: pageIndex, position: position)
                let blurEnd = Self.blurRadius(page: pageIndex, position: target)
                host.layer?.add(landingAnimation(Self.blurKeyPath, from: blurStart, to: blurEnd), forKey: Self.blurMotionKey)
            }
        }
        CATransaction.commit()
        CATransaction.flush()
        scheduleBlurClear(after: Self.landingDuration)
    }

    private func landingAnimation(_ keyPath: String, from: CGFloat, to: CGFloat) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = Self.landingDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        return animation
    }

    private func springAnimation(
        _ keyPath: String, from: CGFloat, to: CGFloat, duration: TimeInterval, journeys: CGFloat
    ) -> CASpringAnimation {
        let animation = CASpringAnimation(perceptualDuration: duration, bounce: SlideTuning.bounce)
        animation.keyPath = keyPath
        animation.fromValue = from
        animation.toValue = to
        animation.initialVelocity = journeys
        animation.duration = animation.settlingDuration
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        return animation
    }

    private static let motionKey = "spacePagerMotion"
    private static let blurMotionKey = "spacePagerBlurMotion"
    private static let blurFilterName = "spacePagerBlur"
    private static let blurKeyPath = "filters.spacePagerBlur.inputRadius"

    // MARK: Blur

    /// With blur at 0, nothing here adds a filter or changes how a layer
    /// renders. Above 0, each page needs Core Image rendering while it moves;
    /// filters come off once the page has stopped.
    private func prepareBlur() {
        blurClear?.cancel()
        blurClear = nil
        let wanted = SlideTuning.blur > 0
        if !wanted {
            clearBlur()
        }
        for host in hosts.values where host.layerUsesCoreImageFilters != wanted {
            host.layerUsesCoreImageFilters = wanted
        }
    }

    private func setBlur(on host: NSHostingView<SpacePage>, radius: CGFloat) {
        guard let layer = host.layer else { return }
        if layer.filters?.isEmpty == false {
            layer.setValue(radius, forKeyPath: Self.blurKeyPath)
        } else if let filter = CIFilter(name: "CIGaussianBlur") {
            filter.name = Self.blurFilterName
            filter.setValue(radius, forKey: kCIInputRadiusKey)
            layer.filters = [filter]
            hasBlurFilters = true
        }
    }

    private func scheduleBlurClear(after delay: TimeInterval) {
        guard hasBlurFilters else { return }
        blurClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.clearBlur()
        }
        blurClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func clearBlur() {
        guard hasBlurFilters else { return }
        hasBlurFilters = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for host in hosts.values {
            host.layer?.removeAnimation(forKey: Self.blurMotionKey)
            host.layer?.filters = nil
        }
        CATransaction.commit()
    }

    private static func blurRadius(page: Int, position: CGFloat) -> CGFloat {
        SlideTuning.blur * min(abs(CGFloat(page) - position), 1)
    }

    /// Halts any spring where it is on screen and leaves the model there.
    /// Returns that position, in pages.
    @discardableResult
    private func stopMotion() -> CGFloat {
        guard let view, let stripLayer = view.strip.layer else { return CGFloat(targetIndex) }
        let offset = (stripLayer.presentation() ?? stripLayer).transform.m41
        let position = pageWidth > 0 ? CGFloat(targetIndex) - offset / pageWidth : CGFloat(targetIndex)
        removeMotion()
        activeSlide = nil
        place(at: position)
        return position
    }

    private func removeMotion() {
        view?.strip.layer?.removeAnimation(forKey: Self.motionKey)
        for host in hosts.values {
            host.layer?.removeAnimation(forKey: Self.motionKey)
            host.layer?.removeAnimation(forKey: Self.blurMotionKey)
        }
    }

    private func currentVelocity() -> CGFloat {
        guard let slide = activeSlide else { return 0 }
        return slide.spring.velocity(
            fromValue: slide.from,
            toValue: slide.to,
            initialVelocity: slide.velocity,
            time: CACurrentMediaTime() - slide.start
        )
    }

    /// Puts the pages at a position with no animation.
    private func place(at position: CGFloat) {
        guard let stripLayer = view?.strip.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripLayer.transform = CATransform3DMakeTranslation((CGFloat(targetIndex) - position) * pageWidth, 0, 0)
        for (pageIndex, space) in spaces.enumerated() {
            guard let host = hosts[space.id] else { continue }
            let opacity = Self.opacity(page: pageIndex, position: position)
            if host.alphaValue != opacity {
                host.alphaValue = opacity
            }
            if SlideTuning.blur > 0, isTracking || hasBlurFilters {
                setBlur(on: host, radius: Self.blurRadius(page: pageIndex, position: position))
            }
        }
        CATransaction.commit()
    }

    /// Incoming page fades in as it slides in; the outgoing one does the
    /// reverse.
    private static func opacity(page: Int, position: CGFloat) -> CGFloat {
        1 - SlideTuning.fade * min(abs(CGFloat(page) - position), 1)
    }

    // MARK: Keeping up with the store

    fileprivate func sync(
        spaces newSpaces: [SidebarSpace],
        activeSpaceID: SidebarSpace.ID,
        pageWidth newWidth: CGFloat,
        animated: Bool,
        makePage: (SidebarSpace) -> SpacePage
    ) {
        guard let view else { return }
        let previous = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        let liveIDs = Set(newSpaces.map(\.id))
        for (id, host) in hosts where !liveIDs.contains(id) {
            host.removeFromSuperview()
            hosts[id] = nil
        }
        for space in newSpaces {
            if let host = hosts[space.id] {
                if previous[space.id] != space {
                    host.rootView = makePage(space)
                }
            } else {
                let host = NSHostingView(rootView: makePage(space))
                // The pager sets its frames, and the sidebar column already
                // sits below the titlebar.
                host.sizingOptions = []
                host.safeAreaRegions = []
                host.wantsLayer = true
                hosts[space.id] = host
                view.strip.addSubview(host)
            }
        }
        let structureChanged = spaces.map(\.id) != newSpaces.map(\.id) || pageWidth != newWidth
        spaces = newSpaces
        pageWidth = newWidth

        let pending = pendingSpaceID.flatMap { liveIDs.contains($0) ? $0 : nil }
        let expected = pending ?? activeSpaceID
        let index = newSpaces.firstIndex { $0.id == expected } ?? 0
        if targetSpaceID == expected {
            // The same space, perhaps at a new index after a reorder.
            if index != targetIndex || structureChanged {
                targetIndex = index
                layoutPages()
                if activeSlide == nil, !isTracking {
                    place(at: CGFloat(index))
                }
            }
        } else if targetSpaceID != nil, animated {
            slide(toIndex: index, velocity: nil, flushes: false)
        } else {
            let moved = targetSpaceID != nil
            if moved {
                stopMotion()
            }
            targetIndex = index
            targetSpaceID = expected
            layoutPages()
            place(at: CGFloat(index))
            if isTracking {
                trackingStart = CGFloat(index)
                trackedPosition = trackingStart
            } else {
                view.ignoresClicks = false
                clearBlur()
            }
        }
    }

    fileprivate func layoutPages() {
        guard let view else { return }
        let height = view.bounds.height
        let stripFrame = NSRect(
            x: -CGFloat(targetIndex) * pageWidth,
            y: 0,
            width: CGFloat(spaces.count) * pageWidth,
            height: height
        )
        if view.strip.frame != stripFrame {
            view.strip.frame = stripFrame
        }
        for (pageIndex, space) in spaces.enumerated() {
            let frame = NSRect(x: CGFloat(pageIndex) * pageWidth, y: 0, width: pageWidth, height: height)
            if let host = hosts[space.id], host.frame != frame {
                host.frame = frame
            }
        }
    }
}

/// Clips the moving strip to one page.
private final class SpacePagerView: NSView {
    let strip = NSView()
    weak var pager: SpacePager?
    /// True while fingers are down: the page under the pointer is moving with
    /// them, so a click has nothing reliable to land on.
    var ignoresClicks = false
    private var mouseDownMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        strip.wantsLayer = true
        addSubview(strip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
        }
    }

    /// Runs ahead of the click's normal dispatch, so the slide has landed by
    /// the time the click reaches a row.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, mouseDownMonitor == nil {
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                if let self, event.window === self.window,
                   self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.pager?.landForClick()
                }
                return event
            }
        }
        if window == nil, let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
    }

    override func layout() {
        super.layout()
        pager?.layoutPages()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        ignoresClicks ? nil : super.hitTest(point)
    }
}

private struct SpacePagerRepresentable: NSViewRepresentable {
    let pager: SpacePager
    let store: TerminalSessionStore
    let spaces: [SidebarSpace]
    let activeSpaceID: SidebarSpace.ID
    let pageWidth: CGFloat

    func makeNSView(context: Context) -> SpacePagerView {
        let view = SpacePagerView(frame: .zero)
        view.pager = pager
        pager.view = view
        pager.store = store
        #if ENSO_DEVTOOLS
        SpacePager.current = pager
        #endif
        return view
    }

    func updateNSView(_ view: SpacePagerView, context: Context) {
        pager.sync(
            spaces: spaces,
            activeSpaceID: activeSpaceID,
            pageWidth: pageWidth,
            animated: context.transaction.animation != nil
        ) { space in
            SpacePage(store: store, space: space)
        }
        view.needsLayout = true
    }
}

/// Captures two-finger horizontal pans over the sidebar with a local event
/// monitor, bypassing NSScrollView's momentum system entirely. One gesture
/// produces one translation stream; trailing momentum events are swallowed,
/// so a flick can never carry the pager past the adjacent space.
private struct SidebarSwipeCapture: NSViewRepresentable {
    let onChanged: (CGFloat) -> Void
    /// Translation, average recent delta, finger speed in points per second.
    let onEnded: (CGFloat, CGFloat, CGFloat) -> Void

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
        var onEnded: ((CGFloat, CGFloat, CGFloat) -> Void)?

        private var monitor: Any?
        private var gestureState: GestureState = .idle
        private var translation: CGFloat = 0
        private var recentDeltas: [CGFloat] = []
        private var recentSamples: [(delta: CGFloat, time: TimeInterval)] = []
        /// Finger speed at release: only what moved this recently counts, so
        /// a finger that paused before lifting reads as still.
        private static let velocityWindow: TimeInterval = 0.08

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
            #if ENSO_DEVTOOLS
            SpaceSwitchTest.shared.noteScrollEvent(event)
            #endif

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
                recentSamples = []
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
                recentSamples.append((event.scrollingDeltaX, event.timestamp))
                if recentSamples.count > 24 {
                    recentSamples.removeFirst()
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
                onEnded?(translation, velocity, fingerSpeed(at: event.timestamp))
                return nil

            default:
                return event
            }
        }

        private func fingerSpeed(at time: TimeInterval) -> CGFloat {
            let recent = recentSamples.filter { time - $0.time <= Self.velocityWindow }
            guard recent.count >= 2, let first = recent.first, time > first.time else { return 0 }
            // The first sample's delta covers the time before it.
            let moved = recent.dropFirst().reduce(0) { $0 + $1.delta }
            return moved / CGFloat(time - first.time)
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

/// One renderable sidebar entry after split-container grouping: a plain
/// tab row, a split container's stacked member rows, or a folder.
private enum SidebarDisplayEntry: Identifiable {
    case tab(TerminalSession)
    case splitGroup(SplitContainer.ID, [TerminalSession])
    case folder(TerminalFolder)

    var id: UUID {
        switch self {
        case .tab(let session): session.id
        case .splitGroup(let containerID, _): containerID
        case .folder(let folder): folder.id
        }
    }
}

private struct SpacePage: View {
    @ObservedObject var store: TerminalSessionStore
    @ObservedObject private var namer = TabAutoNamer.shared
    /// Observed so dormant moons track the store live: consumption, tab
    /// close, the Settings toggle, and launch-time restorability resolution
    /// all publish, and each re-render re-asks dormantAgent(forTab:) below.
    @ObservedObject private var agentSessions = AgentSessionStore.shared
    @Environment(\.colorScheme) private var colorScheme
    let space: SidebarSpace

    @State private var hoveredSessionID: TerminalSession.ID?
    /// The row whose hover button (× or −) claimed the click currently
    /// being dispatched. Transient by construction: `handleTap` clears it
    /// as it consumes it, and leaving the row clears it too, so a click the
    /// tap gesture never followed up on can't swallow a later one.
    @State private var consumedClickSessionID: TerminalSession.ID?
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
    @State private var newTabHovered = false
    /// The Active list's order while the pointer is over it, so rows don't
    /// reshuffle under the cursor; nil when the pointer is elsewhere.
    @State private var frozenActiveOrder: [TerminalSession.ID]?

    var body: some View {
        ScrollView {
            if store.sidebarViewMode == .active {
                activeList
            } else {
                folderTree
            }
        }
        // Keeps the overlay scroller clear of the bottom bar's glass.
        .contentMargins(.bottom, SidebarChromeMetrics.footerHeight, for: .scrollIndicators)
        .background(
            RenameClickAway(
                active: renamingSessionID != nil || renamingFolderID != nil
            ) {
                commitActiveRename()
            }
        )
        // The views swap instantly. Row hover and any drag state belong to the
        // rows that were just removed, and drop feedback only exists in Folders.
        .onChange(of: store.sidebarViewMode) { _, _ in
            hoveredSessionID = nil
            hoveredFolderID = nil
            frozenActiveOrder = nil
            if dragWatchTimer != nil {
                cancelDrag()
            }
        }
        .onChange(of: folderRenameFocused) { _, focused in
            if !focused, let id = renamingFolderID,
               let folder = space.allFolders.first(where: { $0.id == id }) {
                commitFolderRename(folder)
            }
        }
        .onChange(of: store.renameRequest) { _, request in
            switch request {
            case .session(let id):
                guard let session = space.sessions.first(where: { $0.id == id }) else { return }
                store.renameRequest = nil
                // A rename needs a row to happen in.
                if store.sidebarViewMode == .active,
                   !displayedActiveSessions.contains(where: { $0.id == id }) {
                    store.sidebarViewMode = .folders
                }
                beginRename(session)
            case .folder(let id):
                guard let folder = space.allFolders.first(where: { $0.id == id }) else { return }
                store.renameRequest = nil
                store.sidebarViewMode = .folders
                beginFolderRename(folder)
            case nil:
                break
            }
        }
    }

    private var folderTree: some View {
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

    // MARK: - Active view

    /// The flat list: the ordinary session rows with a line saying where each
    /// one lives. No page drop target, and rows don't start drags.
    private var activeList: some View {
        let rows = displayedActiveSessions
        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("Nothing active")
                    .font(PaletteFont.secondary(.regular))
                    .tracking(PaletteFont.tracking)
                    .foregroundStyle(Theme.text(0.28))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }
            ForEach(rows) { session in
                sessionRow(session, activeSubtitle: activeSubtitle(for: session))
            }
        }
        .padding(.horizontal, 10)
        // Unlike the tree, nothing here leaves room for the last row to
        // scroll out from under the bottom bar.
        .padding(.bottom, SidebarChromeMetrics.footerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { cancelRenames() }
        )
        // Selecting a row clears its attention, which would move it right as
        // the pointer sits on it. Order holds until the pointer leaves.
        .onHover { hovering in
            frozenActiveOrder = hovering ? liveActiveSessions.map(\.id) : nil
        }
    }

    /// What needs you first, then what's running, each in tree order.
    private var liveActiveSessions: [TerminalSession] {
        let sessions = space.sessions
        return sessions.filter { $0.status == .attention }
            + sessions.filter { $0.status != .attention && $0.runningProcess != nil }
    }

    /// While frozen, every row stays put, even one that just stopped being
    /// active (selecting it can do that), until it's closed. New ones append.
    private var displayedActiveSessions: [TerminalSession] {
        let live = liveActiveSessions
        guard let frozenActiveOrder else { return live }
        let sessions = space.sessions
        let kept = frozenActiveOrder.compactMap { id in sessions.first { $0.id == id } }
        let added = live.filter { !frozenActiveOrder.contains($0.id) }
        return kept + added
    }

    private func activeSubtitle(for session: TerminalSession) -> String {
        space.pinnedItems.folder(directlyContaining: session.id)?.title
            ?? (session.workingDirectory as NSString).lastPathComponent
    }

    /// Row layout identity: animates structural changes (add/remove/reorder,
    /// pin/unpin) without animating metadata-only updates — selecting a tab
    /// stamps its lastActivity, and that must not fade the highlight in.
    private var rowLayout: [UUID] {
        func append(_ items: [SidebarPinnedItem], into ids: inout [UUID]) {
            for item in items {
                switch item {
                case .tab(let session):
                    ids.append(session.id)
                case .folder(let folder):
                    ids.append(folder.id)
                    append(folder.items, into: &ids)
                }
            }
        }
        var ids: [UUID] = []
        append(space.pinnedItems, into: &ids)
        ids.append(contentsOf: space.ephemeralSessions.map(\.id))
        return ids
    }

    /// Click-away while renaming: keep the edit (matching focus-loss
    /// behavior) and let the click do its normal job.
    private func commitActiveRename() {
        if let id = renamingSessionID, let session = space.sessions.first(where: { $0.id == id }) {
            commitRename(session)
        }
        if let id = renamingFolderID, let folder = space.allFolders.first(where: { $0.id == id }) {
            commitFolderRename(folder)
        }
    }

    /// Clicking empty sidebar space backs out of any in-progress rename.
    private func cancelRenames() {
        guard renamingSessionID != nil || renamingFolderID != nil else { return }
        renamingSessionID = nil
        renamingFolderID = nil
        restoreTerminalFocus()
    }

    /// Ending a rename leaves first responder parked nowhere, so Return
    /// stops reaching the shell; hand the keyboard back to the terminal.
    private func restoreTerminalFocus() {
        GhosttySurfaceManager.shared.restoreFocus(to: store.selection)
    }

    private var pinnedZone: some View {
        // Zero list spacing: the row gap lives inside each row's vertical
        // padding instead, so drag hit-areas stay contiguous. Drops anywhere
        // in the zone resolve through the page-level projection.
        VStack(alignment: .leading, spacing: 0) {
            if space.pinnedItems.isEmpty {
                Text("Drag tabs here to keep them")
                    .font(PaletteFont.secondary(.regular))
                    .tracking(PaletteFont.tracking)
                    .foregroundStyle(Theme.text(0.28))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }

            // Loose tabs and folders render in one interleaved order — the
            // same order the drop projection flattens — with split-container
            // members folded into their group chrome.
            ForEach(pinnedEntries) { entry in
                displayEntry(entry, depth: 0)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Split-container grouping

    /// The pinned zone's display entries: folders pass through; loose tabs
    /// fold into split groups where they are container members. The group
    /// renders at the first member's position and absorbs the others —
    /// tolerant of members that ended up non-adjacent.
    private var pinnedEntries: [SidebarDisplayEntry] {
        displayEntries(for: space.pinnedItems)
    }

    /// Display entries for one ordered item list — the pinned zone's top
    /// level or a folder's children. Same grouping rules at every depth:
    /// split members hoist against the list's own direct tabs, exactly as
    /// the drop projection's flatten does.
    private func displayEntries(for items: [SidebarPinnedItem]) -> [SidebarDisplayEntry] {
        var entries: [SidebarDisplayEntry] = []
        var consumed: Set<TerminalSession.ID> = []
        let directTabs = items.compactMap { item -> TerminalSession? in
            if case .tab(let session) = item { return session }
            return nil
        }
        for item in items {
            switch item {
            case .folder(let folder):
                entries.append(.folder(folder))
            case .tab(let session):
                guard !consumed.contains(session.id) else { continue }
                if let container = store.splitContainer(containing: session.id) {
                    let members = directTabs.filter { container.tree.contains($0.id) }
                    members.forEach { consumed.insert($0.id) }
                    entries.append(.splitGroup(container.id, members))
                } else {
                    entries.append(.tab(session))
                }
            }
        }
        return entries
    }

    /// Same grouping for a flat tab list (folder children, ephemeral zone).
    private func groupedTabEntries(_ tabs: [TerminalSession]) -> [SidebarDisplayEntry] {
        var entries: [SidebarDisplayEntry] = []
        var consumed: Set<TerminalSession.ID> = []
        for session in tabs {
            guard !consumed.contains(session.id) else { continue }
            if let container = store.splitContainer(containing: session.id) {
                let members = tabs.filter { container.tree.contains($0.id) }
                members.forEach { consumed.insert($0.id) }
                entries.append(.splitGroup(container.id, members))
            } else {
                entries.append(.tab(session))
            }
        }
        return entries
    }

    /// Folders nest, so this recurses: a folder's children route back
    /// through displayEntry at the next depth. The folder branch is
    /// type-erased — the folder → children → folder cycle would otherwise
    /// have no finite opaque view type.
    @ViewBuilder
    private func displayEntry(_ entry: SidebarDisplayEntry, depth: Int) -> some View {
        switch entry {
        case .folder(let folder):
            AnyView(folderSection(folder, depth: depth))
        default:
            tabEntry(entry)
        }
    }

    @ViewBuilder
    private func tabEntry(_ entry: SidebarDisplayEntry) -> some View {
        switch entry {
        case .tab(let session):
            sessionRow(session)
        case .splitGroup(let containerID, let members):
            splitGroup(containerID, members)
        case .folder:
            // displayEntry routes folders to folderSection before this;
            // groupedTabEntries (the ephemeral zone) never emits them.
            EmptyView()
        }
    }

    /// A split container in the sidebar: member tabs stacked flat (in
    /// creation order, regardless of split geometry) inside a slightly
    /// darker, bordered group. Rows inside are ordinary session rows —
    /// selection, badges, hover close, and renames all keep working.
    private func splitGroup(_ containerID: SplitContainer.ID, _ members: [TerminalSession]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(members) { session in
                sessionRow(session)
            }
        }
        .padding(.horizontal, 3)
        // The first row's own top gap doubles as the group's top inset;
        // mirror it below so the border wraps evenly.
        .padding(.bottom, SpacePage.rowGap)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: Theme.dynamic(
                    dark: NSColor(white: 0, alpha: 0.22),
                    light: NSColor(white: 0, alpha: 0.05)
                )))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.ink.opacity(0.09), lineWidth: 1)
        )
        .padding(.top, SpacePage.rowGap)
        .geometryGroup()
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
            ForEach(groupedTabEntries(space.ephemeralSessions)) { entry in
                tabEntry(entry)
            }

            Button {
                store.createSession(inSpace: space.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text("New Terminal")
                        .font(PaletteFont.primary(.regular))
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
                .font(PaletteFont.primary(.regular))
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

    private func folderSection(_ folder: TerminalFolder, depth: Int) -> some View {
        let isExpanded = !store.collapsedFolderIDs.contains(folder.id)
        let isHovered = hoveredFolderID == folder.id
        let isRenaming = renamingFolderID == folder.id
        // Dragged rows hovering the row's middle land inside the folder.
        let isDropInto = dropProposal?.indicator == .folderHighlight(folder.id)
        // A collapsed folder still shows its active tab: the selected row —
        // from anywhere in the collapsed subtree — peeks out under the
        // folder so the current tab never vanishes from the sidebar.
        // Selecting a tab elsewhere retracts it.
        let peekingSession = isExpanded
            ? nil
            : folder.allSessions.first { $0.id == store.selection }

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
                        .font(PaletteFont.primary(.medium))
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
                        .font(PaletteFont.primary(.medium))
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
                // when idle. Gated off during rename too,
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
            // twice in the tree. Subfolders recurse through displayEntry at
            // the next depth.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(displayEntries(for: folder.items.excludingSession(peekingSession?.id))) { entry in
                    displayEntry(entry, depth: depth + 1)
                }
            }
            .padding(.leading, Self.childIndent(at: depth))
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
                    .padding(.leading, Self.childIndent(at: depth))
                    .padding(.trailing, 6)
            }
        }
        .geometryGroup()
    }

    /// Per-level child indentation. The model's nesting depth is uncapped,
    /// but rows would get unusably narrow if the indent kept growing, so
    /// levels past the fourth stop indenting visually.
    private static func childIndent(at depth: Int) -> CGFloat {
        depth < 4 ? 14 : 0
    }

    /// A dropped folder reopens if it was expanded before its drag
    /// collapsed it.
    private func restoreDraggedFolderExpansion(_ folderID: TerminalFolder.ID) {
        withAnimation(.easeOut(duration: 0.15)) {
            store.restoreFolderExpansionAfterDrag(folderID)
        }
    }

    /// `activeSubtitle` marks a row of the Active list: a second line under
    /// the title, and no drag. Without it the row is the tree's, untouched.
    @ViewBuilder
    private func sessionRow(_ session: TerminalSession, activeSubtitle: String? = nil) -> some View {
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
                if session.isSleeping {
                    // Sleeping tab: the moon takes the badge slot. Process
                    // detection died with the shell, and the dormant badge
                    // machinery is paused while the tab sleeps, so nothing
                    // below can claim it.
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(isSelected ? 0.7 : 0.4))
                } else if let process = session.runningProcess {
                    ProcessBadgeView(process: process, isSelected: isSelected)
                } else if agentSessions.dormantAgent(forTab: session.id) != nil,
                          GhosttySurfaceManager.shared.existingView(for: session.id) == nil {
                    // An agent session lives here but isn't running yet
                    // (eager sweep hasn't reached it, or it's past the warm
                    // cap). After a relaunch such a tab is effectively
                    // sleeping — it resumes on first visit — so it wears
                    // the same moon as an explicit sleep; a tinted agent
                    // mark here read as a third state. The moon clears the
                    // moment the restore is consumed or the Settings
                    // toggle flips (the store publishes both); the flip to
                    // the full-color badge rides on process detection
                    // updating the session once the resume command runs.
                    // A tab that already has a surface is live, whatever
                    // the restore bookkeeping still says — a moon over a
                    // running shell would be a plain lie.
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(isSelected ? 0.7 : 0.4))
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

            if let activeSubtitle {
                VStack(alignment: .leading, spacing: 1) {
                    sessionRowTitle(session, isSelected: isSelected, isRenaming: isRenaming)

                    Text(activeSubtitle)
                        .font(PaletteFont.secondary(.regular))
                        .tracking(PaletteFont.tracking)
                        .foregroundStyle(Theme.text(0.38))
                        .lineLimit(1)
                }
            } else {
                sessionRowTitle(session, isSelected: isSelected, isRenaming: isRenaming)
            }

            Spacer(minLength: 0)
            if hoveredSessionID == session.id && !isRenaming {
                // Hover-revealed action on the tab row; same frame and
                // insets as the folder header's trailing icons. An awake
                // pinned tab is put to sleep (−) instead of closed; a
                // sleeping row (and any unpinned tab) gets the × that
                // really removes it — a pinned tab's exit is two deliberate
                // steps, − to sleep and then × to close. The button's own
                // tooltip wins over the sleeping row's wake tooltip while
                // the pointer is on it (innermost help applies).
                let sleeps = store.isPinned(session.id) && !session.isSleeping
                HoverIconButton(
                    help: sleeps ? "Put to Sleep" : "Close Tab",
                    size: 24,
                    idleTint: 0.5,
                    washOpacity: 0.09,
                    action: {
                        // The row's tap gesture fires from this same click,
                        // right after this action returns; claim the click
                        // so it can't also select the row. Set BEFORE the
                        // confirmation, because the alert runs a nested
                        // modal loop and the tap lands on the way out of
                        // it either way — declining a close must not leave
                        // the user on the tab they declined to close.
                        consumedClickSessionID = session.id
                        if sleeps {
                            requestSleep(session)
                        } else {
                            requestClose([session.id])
                        }
                    }
                ) {
                    Image(systemName: sleeps ? "minus" : "xmark")
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
        .modifier(SleepingRowHelp(isSleeping: session.isSleeping))
        .modifier(RowPressScale())
        .onHover { hovering in
            if hovering {
                hoveredSessionID = session.id
            } else if hoveredSessionID == session.id {
                hoveredSessionID = nil
                // Leaving the row ends any click it was still holding —
                // the hover button is gone with the hover, so nothing is
                // coming to consume it.
                if consumedClickSessionID == session.id {
                    consumedClickSessionID = nil
                }
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
        .modifier(OptionalRowDrag(isEnabled: activeSubtitle == nil, data: {
            let payload = SidebarDragPayload.tabs(Array(contextTargets(for: session)))
            beginDragTracking(payload)
            return NSItemProvider(object: payload.stringValue as NSString)
        }, preview: {
            sessionDragPreview(session)
        }))
        .contextMenu {
            contextMenu(for: session)
        }
        .background {
            if activeSubtitle == nil {
                rowFrameReporter(session.id)
            }
        }
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

    @ViewBuilder
    private func sessionRowTitle(_ session: TerminalSession, isSelected: Bool, isRenaming: Bool) -> some View {
        if isRenaming {
            TextField("", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(PaletteFont.primary(.regular))
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
                .font(PaletteFont.primary(.regular))
                .tracking(PaletteFont.tracking)
                // Sleeping rows ghost toward the background.
                .foregroundStyle(Theme.text(
                    session.isSleeping ? (isSelected ? 0.55 : 0.38) : (isSelected ? 0.95 : 0.62)
                ))
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
        store.toggleFolderExpansion(folder.id)
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

        if !space.allFolders.isEmpty {
            // Every folder at every depth, in visual order — nested
            // folders are reachable move targets too.
            Menu("Move to Folder") {
                ForEach(space.allFolders) { folder in
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

        // Sleep mirrors the row's − affordance, and covers multi-selects —
        // bulk-parking a batch of pinned agent tabs is the obvious use.
        // Wake keys off the sleeping state alone, so a sleeping tab that
        // was unpinned still offers it.
        let sleepTargets = targets.filter { id in
            store.isPinned(id) && store.sessions.first { $0.id == id }?.isSleeping == false
        }
        if !sleepTargets.isEmpty {
            Button(
                sleepTargets.count > 1 ? "Put \(sleepTargets.count) Tabs to Sleep" : "Put to Sleep",
                systemImage: "moon.zzz"
            ) {
                requestSleep(sleepTargets)
            }
        }
        if targets.count == 1, session.isSleeping {
            Button("Wake", systemImage: "sun.max") {
                store.wake(sessionID: session.id)
            }
        }

        Divider()

        Button("Close\(plural)", systemImage: "xmark") {
            requestClose(targets)
        }
    }

    /// The − affordance (row button, context menu, bulk): an idle group
    /// sleeps instantly; one whose agent looks busy gets the shared
    /// confirmation first — one alert covering the whole group.
    private func requestSleep(_ sessionIDs: Set<TerminalSession.ID>) {
        guard SleepConfirmation.consentsToSleep(store, sessionIDs: sessionIDs) else { return }
        store.putToSleep(sessionIDs: sessionIDs)
    }

    private func requestSleep(_ session: TerminalSession) {
        requestSleep([session.id])
    }

    /// The × affordance and the context menu's Close (single or bulk):
    /// same shape as requestSleep, but the confirmation is opt-in and
    /// warns about what the close destroys.
    private func requestClose(_ sessionIDs: Set<TerminalSession.ID>) {
        guard CloseConfirmation.consentsToClose(store, sessionIDs: sessionIDs) else { return }
        store.close(sessionIDs: sessionIDs)
    }

    private func handleTap(_ session: TerminalSession) {
        // The row tap fires alongside the hover button's action, from the
        // same click. Whether the button's gesture ACTUALLY happened is the
        // only honest test — the old guard inferred it from the session
        // having been destroyed, which silently stopped being true the day
        // the close grew a cancellable confirmation.
        if consumedClickSessionID == session.id {
            consumedClickSessionID = nil
            return
        }
        // A row whose session vanished under it has nothing to select.
        guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        cancelRenames()
        let flags = NSEvent.modifierFlags

        if flags.contains(.command) {
            if store.multiSelection.contains(session.id) {
                store.multiSelection.remove(session.id)
            } else {
                store.multiSelection.insert(session.id)
            }
            // ⌘-click is gathering a set, not visiting a tab — like
            // shift-click, it must not wake a sleeping row it touches.
            store.setSelection(session.id, waking: false)
        } else if flags.contains(.shift), let anchor = store.selection {
            let order = visibleOrder()
            if let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: session.id) {
                store.multiSelection.formUnion(order[min(from, to)...max(from, to)])
            }
        } else {
            store.pickPane(session.id)
        }
    }

    private func contextTargets(for session: TerminalSession) -> Set<TerminalSession.ID> {
        store.multiSelection.count > 1 && store.multiSelection.contains(session.id)
            ? store.multiSelection
            : [session.id]
    }

    /// Visible tab order for shift-click ranges; in the tree, derived from
    /// the same flatten as drop projection, so the two can never drift.
    private func visibleOrder() -> [TerminalSession.ID] {
        store.sidebarViewMode == .active
            ? displayedActiveSessions.map(\.id)
            : flatRows.filter { $0.kind == .tab }.map(\.id)
    }

    // MARK: - Drag and drop

    private static let dropSpaceName = "sidebarDropSpace"

    /// The uniform gap between all sidebar rows.
    private static let rowGap: CGFloat = 4

    /// The sidebar's visual order, flattened; shared by drop projection and
    /// selection ranges. Passes the split containers so the flatten hoists
    /// group members exactly as `pinnedEntries`/`groupedTabEntries` render
    /// them — the two orders must never diverge.
    private var flatRows: [SidebarFlatRow] {
        flattenSidebar(
            space: space,
            collapsedFolderIDs: store.collapsedFolderIDs,
            selection: store.selection,
            splitContainers: store.splitContainers
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
            // visible: open the folder it ended up in, and every collapsed
            // ancestor above it.
            if case .tabs(let ids) = payload, let first = ids.first,
               let landedPath = store.spaces
                   .compactMap({ $0.pinnedItems.folderPath(containingSession: first) })
                   .first {
                store.expandFolders(landedPath)
            }
        }
        return true
    }
}

/// A row's drag source, absent from the Active list where nothing reorders.
private struct OptionalRowDrag<Preview: View>: ViewModifier {
    let isEnabled: Bool
    let data: () -> NSItemProvider
    let preview: () -> Preview

    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrag(data, preview: preview)
        } else {
            content
        }
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
            // the app theme via the asset catalog.
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

/// Attaches the wake tooltip only while the row sleeps: `.help` isn't
/// documented to suppress an empty string's bubble, so awake rows get no
/// tooltip registered at all.
private struct SleepingRowHelp: ViewModifier {
    let isSleeping: Bool

    func body(content: Content) -> some View {
        if isSleeping {
            content.help("Sleeping — click to wake")
        } else {
            content
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

/// A space's mark. `isActive: false` only ever appears in the pill, whose
/// other cells must still read clearly beside the thumb.
struct SpaceIndicatorIcon: View {
    let icon: SidebarSpace.Icon
    let isActive: Bool
    var size: CGFloat = 18

    private static let inactiveOpacity: Double = 0.75

    var body: some View {
        switch icon {
        case .dot:
            Circle()
                .fill(Theme.ink.opacity(isActive ? 0.85 : Self.inactiveOpacity))
                .frame(width: size * 0.36, height: size * 0.36)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.61, weight: .medium))
                .foregroundStyle(Theme.text(isActive ? 0.9 : Self.inactiveOpacity))
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: size * 0.67))
                .opacity(isActive ? 1 : Self.inactiveOpacity)
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
/// springs back on release. Tracked with a never-completing long press
/// (`minimumDuration: .infinity`), NOT a zero-distance DragGesture: a
/// pending long press leaves the event stream unclaimed, so `.onDrag` can
/// still start a drag-to-reorder session — a `DragGesture(minimumDistance:
/// 0)` recognizes at mouse-down, claims the whole mouse-drag sequence, and
/// no drag can ever begin. Straying past 2pt fails the press, so the dip
/// resets the instant a drag takes over and never follows it; a failed
/// press can't re-engage until the next mouse-down.
private struct RowPressScale: ViewModifier {
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.12), value: pressed)
            .onLongPressGesture(
                minimumDuration: .infinity,
                maximumDistance: 2,
                perform: {},
                onPressingChanged: { pressed = $0 }
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
