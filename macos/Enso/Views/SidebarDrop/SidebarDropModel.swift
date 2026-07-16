import CoreGraphics
import Foundation

// Pure drag-and-drop projection for the sidebar: one flatten function, one
// resolver that maps a pointer location to a single drop proposal, and one
// payload codec. No SwiftUI in here — everything is unit-testable.

// MARK: - Payload

/// What a sidebar drag carries. The wire format (an NSItemProvider string)
/// stays the legacy one — comma-joined session UUIDs, or "folder:" + UUID —
/// so in-flight drags across app versions keep decoding.
enum SidebarDragPayload: Equatable {
    case tabs([TerminalSession.ID])
    case folder(TerminalFolder.ID)

    private static let folderPrefix = "folder:"

    var stringValue: String {
        switch self {
        case .tabs(let ids):
            return ids.map(\.uuidString).joined(separator: ",")
        case .folder(let id):
            return Self.folderPrefix + id.uuidString
        }
    }

    init?(string: String) {
        if string.hasPrefix(Self.folderPrefix) {
            guard let id = UUID(uuidString: String(string.dropFirst(Self.folderPrefix.count))) else {
                return nil
            }
            self = .folder(id)
        } else {
            let ids = string.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return nil }
            self = .tabs(ids)
        }
    }

    /// Merges a multi-item drop into one payload; a folder item wins.
    static func decode(items: [String]) -> SidebarDragPayload? {
        let payloads = items.compactMap(SidebarDragPayload.init(string:))
        for payload in payloads {
            if case .folder = payload { return payload }
        }
        let tabs: [TerminalSession.ID] = payloads.flatMap { payload -> [TerminalSession.ID] in
            if case .tabs(let ids) = payload { return ids }
            return []
        }
        return tabs.isEmpty ? nil : .tabs(tabs)
    }
}

// MARK: - Flatten

/// One row of the flattened sidebar, in exact visual order.
struct SidebarFlatRow: Equatable, Identifiable {
    enum Kind: Equatable {
        case folder(collapsed: Bool)
        case tab
    }

    enum Zone: Equatable {
        case pinned
        case ephemeral
    }

    let id: UUID
    let kind: Kind
    let parentFolderID: TerminalFolder.ID?
    let zone: Zone

    var depth: Int { parentFolderID == nil ? 0 : 1 }
}

/// The single source of the sidebar's visible order: selection ranges and
/// drop projection both derive from this, so they can never drift from what
/// renders. Collapsed folders contribute only their own row, plus the active
/// tab that peeks out beneath them.
func flattenSidebar(
    space: SidebarSpace,
    collapsedFolderIDs: Set<TerminalFolder.ID>,
    selection: TerminalSession.ID?
) -> [SidebarFlatRow] {
    var rows: [SidebarFlatRow] = []
    for item in space.pinnedItems {
        switch item {
        case .tab(let session):
            rows.append(SidebarFlatRow(id: session.id, kind: .tab, parentFolderID: nil, zone: .pinned))
        case .folder(let folder):
            let collapsed = collapsedFolderIDs.contains(folder.id)
            rows.append(SidebarFlatRow(
                id: folder.id, kind: .folder(collapsed: collapsed), parentFolderID: nil, zone: .pinned
            ))
            if !collapsed {
                for session in folder.sessions {
                    rows.append(SidebarFlatRow(
                        id: session.id, kind: .tab, parentFolderID: folder.id, zone: .pinned
                    ))
                }
            } else if let selection, folder.sessions.contains(where: { $0.id == selection }) {
                rows.append(SidebarFlatRow(
                    id: selection, kind: .tab, parentFolderID: folder.id, zone: .pinned
                ))
            }
        }
    }
    for session in space.ephemeralSessions {
        rows.append(SidebarFlatRow(id: session.id, kind: .tab, parentFolderID: nil, zone: .ephemeral))
    }
    return rows
}

// MARK: - Proposal

/// Where a drop will land, expressed as anchors into the current model —
/// never as raw indices, so the commit stays correct after the dragged rows
/// are removed from their old positions.
enum SidebarDropTarget: Equatable {
    // Tab payloads.
    case insertBefore(TerminalSession.ID)
    /// A loose pinned tab immediately before the given folder.
    case insertLooseBefore(TerminalFolder.ID)
    /// A loose pinned tab at the end of the pinned zone.
    case appendToPinned
    case appendToFolder(TerminalFolder.ID)
    /// Same mutation as `appendToFolder`; distinct so feedback can highlight
    /// the folder row instead of drawing an insertion line.
    case intoFolder(TerminalFolder.ID)
    case appendToEphemeral
    // Folder payloads. The anchor is any pinned item — loose tab or folder —
    // since folders interleave freely with loose tabs.
    case insertFolderBefore(UUID)
    case appendFolder
}

struct SidebarDropProposal: Equatable {
    enum Indicator: Equatable {
        /// Insertion line in the drop container's coordinate space; the X
        /// span carries the target depth's indentation.
        case line(y: CGFloat, minX: CGFloat, maxX: CGFloat)
        case folderHighlight(TerminalFolder.ID)
    }

    var target: SidebarDropTarget
    var indicator: Indicator
    /// The visible row sitting directly below the insertion line, if any:
    /// the row that parts downward to open the drop gap. Nil for
    /// end-of-zone lines and folder highlights.
    var gapRowID: UUID?

    init(target: SidebarDropTarget, indicator: Indicator, gapRowID: UUID? = nil) {
        self.target = target
        self.indicator = indicator
        self.gapRowID = gapRowID
    }
}

/// What a pointer position means for the drag in flight. `noOp` is a valid
/// position whose commit would change nothing (the dragged rows' own slot):
/// no indicator, but no forbidden cursor either.
enum SidebarDropResolution: Equatable {
    case proposal(SidebarDropProposal)
    case noOp
    case invalid

    var proposal: SidebarDropProposal? {
        if case .proposal(let proposal) = self { return proposal }
        return nil
    }

    var isInvalid: Bool { self == .invalid }
}

// MARK: - Gap-free geometry

/// Reconstructs the gap-free geometry the resolver must see while a drop gap
/// is open. The open gap shifts live row frames; resolving against shifted
/// frames would move the gap, shift the frames again, and oscillate. So the
/// gap row and everything below it slide back up by the gap height, and the
/// pointer maps into the same space — a pointer inside the open gap pins to
/// the slot boundary the gap represents.
func removingSidebarDropGap(
    above gapRowID: UUID,
    gapHeight: CGFloat,
    rowFrames: [UUID: CGRect],
    dividerFrame: CGRect?,
    pointerY: CGFloat
) -> (rowFrames: [UUID: CGRect], dividerFrame: CGRect?, pointerY: CGFloat) {
    guard let gapFrame = rowFrames[gapRowID] else {
        return (rowFrames, dividerFrame, pointerY)
    }
    // The gap row's live top is the gap's bottom edge: the gap opens as
    // padding directly above it.
    let gapBottom = gapFrame.minY
    var frames = rowFrames
    for (id, frame) in frames where frame.minY >= gapBottom - 0.5 {
        frames[id] = frame.offsetBy(dx: 0, dy: -gapHeight)
    }
    var divider = dividerFrame
    if let dividerFrame, dividerFrame.minY >= gapBottom - 0.5 {
        divider = dividerFrame.offsetBy(dx: 0, dy: -gapHeight)
    }
    var y = pointerY
    if y >= gapBottom {
        y -= gapHeight
    } else if y > gapBottom - gapHeight {
        // Inside the open gap: the slot boundary itself.
        y = gapBottom - gapHeight - 1
    }
    return (frames, divider, y)
}

// MARK: - Resolver

/// Maps a pointer location to exactly one drop proposal (or nil for invalid
/// positions). Rows keep flatten order; geometry only decides which row/gap
/// the pointer is in, while adjacency semantics stay structural.
///
/// Loose tabs and folders interleave freely, so the gap that closes a
/// folder (after its last visible child, or after a childless folder row)
/// has two valid depths for a dragged tab. The pointer's X offset picks —
/// dnd-kit's projection collapsed to our two levels: inside the child
/// indentation nests into the folder, left of it outdents to a loose tab.
struct SidebarDropResolver {
    struct FramedRow {
        let row: SidebarFlatRow
        let frame: CGRect
    }

    private let pinnedRows: [FramedRow]
    private let ephemeralRows: [FramedRow]
    private let dividerFrame: CGRect?
    /// Pointer above this Y belongs to the pinned zone, below to ephemeral.
    private let zoneBoundaryY: CGFloat

    /// Child rows sit 14pt in from their folder; used to synthesize a
    /// child-depth line under a folder row with no visible children.
    private static let childIndent: CGFloat = 14
    /// Insertion lines inset 4pt from the anchor row's edges, matching the
    /// old indicator style.
    private static let lineInset: CGFloat = 4

    init(rows: [SidebarFlatRow], rowFrames: [UUID: CGRect], dividerFrame: CGRect?) {
        let framed = rows.compactMap { row in
            rowFrames[row.id].map { FramedRow(row: row, frame: $0) }
        }
        pinnedRows = framed.filter { $0.row.zone == .pinned }
        ephemeralRows = framed.filter { $0.row.zone == .ephemeral }
        self.dividerFrame = dividerFrame

        if let dividerFrame {
            zoneBoundaryY = dividerFrame.midY
        } else if let lastPinned = pinnedRows.last, let firstEphemeral = ephemeralRows.first {
            zoneBoundaryY = (lastPinned.frame.maxY + firstEphemeral.frame.minY) / 2
        } else if let firstEphemeral = ephemeralRows.first {
            zoneBoundaryY = firstEphemeral.frame.minY
        } else if let lastPinned = pinnedRows.last {
            zoneBoundaryY = lastPinned.frame.maxY
        } else {
            zoneBoundaryY = 0
        }
    }

    /// `horizontalDelta` is the pointer's X travel since the drag entered
    /// the sidebar; ambiguous gaps use it to pick between nesting into a
    /// folder (dragged right) and staying loose at space level (default).
    func resolve(
        at location: CGPoint,
        dragging payload: SidebarDragPayload,
        horizontalDelta: CGFloat
    ) -> SidebarDropResolution {
        switch payload {
        case .folder(let id):
            return folderResolution(y: location.y, draggedFolder: id)
        case .tabs(let ids):
            let proposal = location.y < zoneBoundaryY
                ? pinnedTabProposal(at: location, horizontalDelta: horizontalDelta)
                : ephemeralTabProposal(y: location.y)
            // The dragged rows' own slot: a drop would change nothing, so
            // show nothing — but it isn't a forbidden position either.
            if isNoOpTarget(proposal.target, draggedIDs: Set(ids)) {
                return .noOp
            }
            return .proposal(proposal)
        }
    }

    // MARK: Tabs

    private func ephemeralTabProposal(y: CGFloat) -> SidebarDropProposal {
        if let hit = ephemeralRows.first(where: { y < $0.frame.midY }) {
            return SidebarDropProposal(
                target: .insertBefore(hit.row.id),
                indicator: line(at: hit.frame.minY, spanning: hit.frame),
                gapRowID: hit.row.id
            )
        }
        if let last = ephemeralRows.last {
            return SidebarDropProposal(
                target: .appendToEphemeral,
                indicator: line(at: last.frame.maxY, spanning: last.frame)
            )
        }
        // Empty ephemeral list: the landing line hugs the divider.
        let anchor = dividerFrame ?? .zero
        return SidebarDropProposal(
            target: .appendToEphemeral,
            indicator: line(at: anchor.maxY, spanning: anchor)
        )
    }

    private func pinnedTabProposal(at location: CGPoint, horizontalDelta: CGFloat) -> SidebarDropProposal {
        let y = location.y
        guard let index = pinnedRows.firstIndex(where: { y < $0.frame.maxY }) else {
            // Below every pinned row: the end of the zone.
            guard !pinnedRows.isEmpty else {
                let anchor = dividerFrame ?? .zero
                return SidebarDropProposal(
                    target: .appendToPinned,
                    indicator: line(at: anchor.minY, spanning: anchor)
                )
            }
            return tabGapProposal(after: pinnedRows.count - 1, horizontalDelta: horizontalDelta)
        }

        let hit = pinnedRows[index]
        let fraction = (y - hit.frame.minY) / max(hit.frame.height, 1)

        switch hit.row.kind {
        case .tab:
            // The uniform gap above a row is the gap after its predecessor,
            // where both depths may be valid.
            if fraction < 0, index > 0 {
                return tabGapProposal(after: index - 1, horizontalDelta: horizontalDelta)
            }
            if fraction < 0.5 {
                return SidebarDropProposal(
                    target: .insertBefore(hit.row.id),
                    indicator: line(at: hit.frame.minY, spanning: hit.frame),
                    gapRowID: hit.row.id
                )
            }
            return tabGapProposal(after: index, horizontalDelta: horizontalDelta)

        case .folder(let collapsed):
            if fraction < 0.25 {
                // The gap above a folder belongs to whatever ends there.
                guard index > 0 else {
                    // Very top of the zone: loose, before this folder.
                    return SidebarDropProposal(
                        target: .insertLooseBefore(hit.row.id),
                        indicator: line(at: hit.frame.minY, spanning: hit.frame),
                        gapRowID: hit.row.id
                    )
                }
                return tabGapProposal(after: index - 1, horizontalDelta: horizontalDelta)
            }
            if !collapsed, fraction >= 0.75,
               index + 1 < pinnedRows.count,
               pinnedRows[index + 1].row.parentFolderID == hit.row.id {
                // The expanded folder's trailing edge: before its first child.
                let child = pinnedRows[index + 1]
                return SidebarDropProposal(
                    target: .insertBefore(child.row.id),
                    indicator: line(at: child.frame.minY, spanning: child.frame),
                    gapRowID: child.row.id
                )
            }
            return SidebarDropProposal(
                target: .intoFolder(hit.row.id),
                indicator: .folderHighlight(hit.row.id)
            )
        }
    }

    /// The insertion point in the gap immediately after the given pinned
    /// row. Where the gap closes a folder, both depths are valid: dragging
    /// rightward by at least half the indentation nests into the folder,
    /// anything else stays loose (the less-destructive default). The
    /// insertion line previews the choice either way.
    private func tabGapProposal(after index: Int, horizontalDelta: CGFloat) -> SidebarDropProposal {
        let hit = pinnedRows[index]
        let next = index + 1 < pinnedRows.count ? pinnedRows[index + 1] : nil
        let gapY = hit.frame.maxY

        // The folder this gap could extend, if any: the row's own folder,
        // or the folder row itself when it has no visible children.
        let folderID: TerminalFolder.ID? = {
            switch hit.row.kind {
            case .folder: return hit.row.id
            case .tab: return hit.row.parentFolderID
            }
        }()

        // Interior gap — the next row belongs to the same folder: depth 1
        // only, before that row.
        if let folderID, let next, next.row.parentFolderID == folderID {
            return SidebarDropProposal(
                target: .insertBefore(next.row.id),
                indicator: line(at: next.frame.minY, spanning: next.frame),
                gapRowID: next.row.id
            )
        }

        guard let folderID else {
            return looseTabProposal(before: next, at: gapY, span: hit.frame)
        }
        let folderFrame = frame(of: folderID) ?? hit.frame
        if horizontalDelta >= Self.childIndent / 2 {
            return SidebarDropProposal(
                target: .appendToFolder(folderID),
                indicator: line(at: gapY, spanning: childSpan(of: folderFrame)),
                gapRowID: next?.row.id
            )
        }
        return looseTabProposal(before: next, at: gapY, span: folderFrame)
    }

    /// A depth-0 (loose tab) insertion at the given gap.
    private func looseTabProposal(
        before next: FramedRow?,
        at y: CGFloat,
        span: CGRect
    ) -> SidebarDropProposal {
        guard let next else {
            return SidebarDropProposal(
                target: .appendToPinned,
                indicator: line(at: y, spanning: span)
            )
        }
        switch next.row.kind {
        case .folder:
            return SidebarDropProposal(
                target: .insertLooseBefore(next.row.id),
                indicator: line(at: y, spanning: next.frame),
                gapRowID: next.row.id
            )
        case .tab:
            // Only a loose tab can follow here — a folder child would have
            // been the interior-gap case.
            return SidebarDropProposal(
                target: .insertBefore(next.row.id),
                indicator: line(at: y, spanning: next.frame),
                gapRowID: next.row.id
            )
        }
    }

    // MARK: Folders

    private func folderResolution(y: CGFloat, draggedFolder: TerminalFolder.ID) -> SidebarDropResolution {
        // Folders are pinned-only.
        guard y < zoneBoundaryY else { return .invalid }

        // Each top-level pinned item projects as one group: a loose tab is
        // its own row, a folder is its row plus visible children. A dragged
        // folder slots between groups.
        var groups: [(id: UUID, frame: CGRect)] = []
        for framed in pinnedRows {
            if framed.row.parentFolderID == nil {
                groups.append((id: framed.row.id, frame: framed.frame))
            } else if let last = groups.indices.last {
                groups[last].frame = groups[last].frame.union(framed.frame)
            }
        }

        guard !groups.isEmpty else {
            // Empty pinned zone: the only slot is the zone itself.
            let anchor = dividerFrame ?? .zero
            return .proposal(SidebarDropProposal(
                target: .appendFolder,
                indicator: line(at: anchor.minY, spanning: anchor)
            ))
        }

        let index = groups.firstIndex(where: { y < $0.frame.midY }) ?? groups.count
        // The dragged folder's own slot (before or right after itself).
        if index < groups.count, groups[index].id == draggedFolder { return .noOp }
        if index > 0, groups[index - 1].id == draggedFolder { return .noOp }

        if index < groups.count {
            let target = groups[index]
            return .proposal(SidebarDropProposal(
                target: .insertFolderBefore(target.id),
                indicator: line(at: target.frame.minY, spanning: target.frame),
                gapRowID: target.id
            ))
        }
        let last = groups[groups.count - 1]
        return .proposal(SidebarDropProposal(
            target: .appendFolder,
            indicator: line(at: last.frame.maxY, spanning: last.frame)
        ))
    }

    // MARK: No-op detection

    /// Whether committing the target would rebuild the exact current order —
    /// the dragged tabs already sit contiguously at the landing slot.
    private func isNoOpTarget(_ target: SidebarDropTarget, draggedIDs: Set<TerminalSession.ID>) -> Bool {
        guard !draggedIDs.isEmpty else { return false }
        switch target {
        case .insertBefore(let anchor):
            if draggedIDs.contains(anchor) { return true }
            let zone = ephemeralRows.contains(where: { $0.row.id == anchor }) ? ephemeralRows : pinnedRows
            guard let anchorIndex = zone.firstIndex(where: { $0.row.id == anchor }) else { return false }
            return draggedFillSlot(
                endingAt: anchorIndex - 1, in: zone,
                container: zone[anchorIndex].row.parentFolderID, draggedIDs: draggedIDs
            )
        case .insertLooseBefore(let folderID):
            guard let index = pinnedRows.firstIndex(where: { $0.row.id == folderID }) else { return false }
            return draggedFillSlot(endingAt: index - 1, in: pinnedRows, container: nil, draggedIDs: draggedIDs)
        case .appendToFolder(let folderID), .intoFolder(let folderID):
            // Hidden children of a collapsed folder can reorder on append,
            // so only an expanded folder's trailing slot is a true no-op.
            guard let folderRow = pinnedRows.first(where: { $0.row.id == folderID }),
                  folderRow.row.kind == .folder(collapsed: false),
                  let lastChildIndex = pinnedRows.lastIndex(where: { $0.row.parentFolderID == folderID }) else {
                return false
            }
            return draggedFillSlot(
                endingAt: lastChildIndex, in: pinnedRows, container: folderID, draggedIDs: draggedIDs
            )
        case .appendToPinned:
            return draggedFillSlot(
                endingAt: pinnedRows.count - 1, in: pinnedRows, container: nil, draggedIDs: draggedIDs
            )
        case .appendToEphemeral:
            return draggedFillSlot(
                endingAt: ephemeralRows.count - 1, in: ephemeralRows, container: nil, draggedIDs: draggedIDs
            )
        default:
            return false
        }
    }

    /// True when the rows walking upward from `end` are exactly the dragged
    /// tabs, all in the given container — i.e. the dragged set already
    /// occupies the landing slot contiguously.
    private func draggedFillSlot(
        endingAt end: Int,
        in zone: [FramedRow],
        container: TerminalFolder.ID?,
        draggedIDs: Set<TerminalSession.ID>
    ) -> Bool {
        var remaining = draggedIDs
        var index = end
        while index >= 0,
              remaining.contains(zone[index].row.id),
              zone[index].row.kind == .tab,
              zone[index].row.parentFolderID == container {
            remaining.remove(zone[index].row.id)
            index -= 1
        }
        return remaining.isEmpty
    }

    // MARK: Indicator geometry

    private func frame(of rowID: UUID) -> CGRect? {
        pinnedRows.first { $0.row.id == rowID }?.frame
    }

    private func line(at y: CGFloat, spanning frame: CGRect) -> SidebarDropProposal.Indicator {
        .line(y: y, minX: frame.minX + Self.lineInset, maxX: frame.maxX - Self.lineInset)
    }

    private func childSpan(of folderFrame: CGRect) -> CGRect {
        CGRect(
            x: folderFrame.minX + Self.childIndent,
            y: folderFrame.minY,
            width: max(folderFrame.width - Self.childIndent, 0),
            height: folderFrame.height
        )
    }
}
