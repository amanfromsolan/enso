import AppKit
import SwiftUI

// View-layer plumbing for the sidebar's centralized drag-and-drop: row frame
// collection, the drop delegate shim, and edge auto-scroll.

/// Row frames keyed by row ID, in the drop container's named coordinate
/// space. Frames are content-relative, so scrolling never churns them.
struct SidebarRowFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The pinned/ephemeral zone divider's frame; its midline splits the two
/// zones for drop resolution.
struct SidebarDividerFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// One drop delegate for the whole sidebar page. `dropUpdated` streams the
/// pointer location during hover — the projection needs it continuously,
/// which `.dropDestination`'s single drop-point callback can't provide.
struct SidebarSpaceDropDelegate: DropDelegate {
    /// Returns whether the location resolves to a valid proposal.
    let onUpdate: (CGPoint) -> Bool
    let onExited: () -> Void
    let onPerform: (DropInfo) -> Bool

    func dropEntered(info: DropInfo) {
        _ = onUpdate(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onUpdate(info.location)
            ? DropProposal(operation: .move)
            : DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) {
        onExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        onPerform(info)
    }
}

/// Edge auto-scroll during drags. SwiftUI's ScrollView offers no imperative
/// scrolling from a drop session, so a capture view hands the backing
/// NSScrollView to this driver and it nudges the clip view directly.
@MainActor
final class SidebarScrollDriver {
    weak var scrollView: NSScrollView?
    /// Fires after each auto-scroll step with the new offset-from-top, so
    /// the drop proposal can track content sliding under a still pointer.
    var onAutoScroll: ((CGFloat) -> Void)?

    static let edgeZone: CGFloat = 24
    private static let maxStep: CGFloat = 6

    private var timer: Timer?
    /// Signed points per tick; magnitude scales with how deep the pointer
    /// sits in the edge zone, so grazing the zone crawls instead of lurching.
    private var speed: CGFloat = 0

    /// Distance scrolled from the content's top, regardless of the document
    /// view's flippedness.
    var contentOffsetFromTop: CGFloat {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        let visible = scrollView.contentView.documentVisibleRect
        return document.isFlipped ? visible.minY : document.bounds.height - visible.maxY
    }

    /// Pointer position relative to the visible viewport's top.
    func viewportY(forContentY contentY: CGFloat) -> CGFloat {
        contentY - contentOffsetFromTop
    }

    func updateAutoScroll(pointerViewportY: CGFloat) {
        guard let scrollView else { return stop() }
        let height = scrollView.contentView.bounds.height
        let zone = Self.edgeZone
        if pointerViewportY < zone {
            let penetration = min(1, max(0, (zone - pointerViewportY) / zone))
            start(speed: -Self.maxStep * penetration)
        } else if pointerViewportY > height - zone {
            let penetration = min(1, max(0, (pointerViewportY - (height - zone)) / zone))
            start(speed: Self.maxStep * penetration)
        } else {
            stop()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        speed = 0
    }

    private func start(speed: CGFloat) {
        self.speed = speed
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let scrollView, let document = scrollView.documentView else { return stop() }
        let clip = scrollView.contentView
        let maxOffset = max(0, document.bounds.height - clip.bounds.height)
        let current = contentOffsetFromTop
        let next = min(maxOffset, max(0, current + speed))
        guard next != current else { return }
        var origin = clip.bounds.origin
        origin.y = document.isFlipped ? next : document.bounds.height - clip.bounds.height - next
        clip.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(clip)
        onAutoScroll?(next)
    }
}

extension NSItemProvider {
    /// The plain-text payload of a sidebar drag item, for
    /// `SidebarDragPayload.decode`.
    func sidebarDragString() async -> String? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? String)
            }
        }
    }
}

/// Invisible hook that finds the enclosing NSScrollView once the hierarchy
/// is realized and hands it to the driver.
struct SidebarScrollViewCapture: NSViewRepresentable {
    let driver: SidebarScrollDriver

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if driver.scrollView == nil {
                driver.scrollView = nsView.enclosingScrollView
            }
        }
    }
}
