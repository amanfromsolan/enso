import CoreGraphics
import Foundation

// Pure drag-and-drop projection for the sidebar: one flatten function, one
// resolver that maps a pointer location to a single drop proposal, and one
// payload codec. No SwiftUI in here — everything is unit-testable.

// MARK: - Payload

/// What a sidebar drag carries. The wire format (an NSItemProvider string)
/// stays the legacy one — comma-joined session UUIDs, "folder:" + UUID, or
/// "space:" + UUID — so in-flight drags across app versions keep decoding.
enum SidebarDragPayload: Equatable {
    case tabs([TerminalSession.ID])
    case folder(TerminalFolder.ID)
    case space(SidebarSpace.ID)

    private static let folderPrefix = "folder:"
    private static let spacePrefix = "space:"

    var stringValue: String {
        switch self {
        case .tabs(let ids):
            return ids.map(\.uuidString).joined(separator: ",")
        case .folder(let id):
            return Self.folderPrefix + id.uuidString
        case .space(let id):
            return Self.spacePrefix + id.uuidString
        }
    }

    init?(string: String) {
        if string.hasPrefix(Self.folderPrefix) {
            guard let id = UUID(uuidString: String(string.dropFirst(Self.folderPrefix.count))) else {
                return nil
            }
            self = .folder(id)
        } else if string.hasPrefix(Self.spacePrefix) {
            guard let id = UUID(uuidString: String(string.dropFirst(Self.spacePrefix.count))) else {
                return nil
            }
            self = .space(id)
        } else {
            let ids = string.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return nil }
            self = .tabs(ids)
        }
    }

    /// Merges a multi-item drop into one payload; a folder or space item wins.
    static func decode(items: [String]) -> SidebarDragPayload? {
        let payloads = items.compactMap(SidebarDragPayload.init(string:))
        for payload in payloads {
            if case .folder = payload { return payload }
            if case .space = payload { return payload }
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
    /// The split container this row is a member of, when it renders inside
    /// a split group's run; the resolver treats a run as one unit for tabs
    /// dragged in from outside it.
    let splitContainerID: SplitContainer.ID?
    /// Real tree depth: 0 for top-level rows, +1 per enclosing folder.
    /// Uncapped — the view caps only the visual indent, never the model.
    let depth: Int
}

/// The single source of the sidebar's visible order: selection ranges and
/// drop projection both derive from this, so they can never drift from what
/// renders. Collapsed folders contribute only their own row, plus the active
/// tab that peeks out beneath them (from anywhere in the collapsed subtree).
/// Split-container members are hoisted to the first member's position within
/// their item list — the exact grouping the sidebar's display entries
/// render — so the flatten can never disagree with the group boxes on
/// screen, even when members drifted apart in the model.
func flattenSidebar(
    space: SidebarSpace,
    collapsedFolderIDs: Set<TerminalFolder.ID>,
    selection: TerminalSession.ID?,
    splitContainers: [SplitContainer]
) -> [SidebarFlatRow] {
    var rows: [SidebarFlatRow] = []

    func containerOf(_ sessionID: TerminalSession.ID) -> SplitContainer? {
        splitContainers.first { $0.tree.contains(sessionID) }
    }

    /// Appends one ordered item list, recursing into expanded folders.
    /// Tabs group against the list's WHOLE run of direct tabs, not a
    /// contiguous slice: a split group whose members drifted apart in the
    /// model (even across an intervening folder) still flattens as one run
    /// at the first member's position, exactly as the view hoists it.
    func appendItems(
        _ items: [SidebarPinnedItem],
        parentFolderID: TerminalFolder.ID?,
        depth: Int,
        zone: SidebarFlatRow.Zone
    ) {
        let directTabs = items.compactMap { item -> TerminalSession? in
            if case .tab(let session) = item { return session }
            return nil
        }
        var consumed: Set<TerminalSession.ID> = []
        for item in items {
            switch item {
            case .tab(let session):
                guard !consumed.contains(session.id) else { continue }
                guard let container = containerOf(session.id) else {
                    rows.append(SidebarFlatRow(
                        id: session.id, kind: .tab, parentFolderID: parentFolderID,
                        zone: zone, splitContainerID: nil, depth: depth
                    ))
                    continue
                }
                for member in directTabs.filter({ container.tree.contains($0.id) }) {
                    consumed.insert(member.id)
                    rows.append(SidebarFlatRow(
                        id: member.id, kind: .tab, parentFolderID: parentFolderID,
                        zone: zone, splitContainerID: container.id, depth: depth
                    ))
                }
            case .folder(let folder):
                let collapsed = collapsedFolderIDs.contains(folder.id)
                rows.append(SidebarFlatRow(
                    id: folder.id, kind: .folder(collapsed: collapsed),
                    parentFolderID: parentFolderID,
                    zone: zone, splitContainerID: nil, depth: depth
                ))
                if !collapsed {
                    appendItems(
                        folder.items, parentFolderID: folder.id, depth: depth + 1, zone: zone
                    )
                } else if let selection, folder.allSessions.contains(where: { $0.id == selection }) {
                    // The selection peeks out of a collapsed folder no
                    // matter how deep it nests. The peeking row renders as
                    // a lone session row outside any group chrome, so it
                    // carries no run membership.
                    rows.append(SidebarFlatRow(
                        id: selection, kind: .tab, parentFolderID: folder.id,
                        zone: zone, splitContainerID: nil, depth: depth + 1
                    ))
                }
            }
        }
    }

    appendItems(space.pinnedItems, parentFolderID: nil, depth: 0, zone: .pinned)
    appendItems(
        space.ephemeralSessions.map(SidebarPinnedItem.tab),
        parentFolderID: nil, depth: 0, zone: .ephemeral
    )
    return rows
}

// MARK: - Proposal

/// Where a drop will land, expressed as anchors into the current model —
/// never as raw indices, so the commit stays correct after the dragged rows
/// are removed from their old positions.
enum SidebarDropTarget: Equatable {
    // Tab payloads.
    case insertBefore(TerminalSession.ID)
    /// A tab immediately before the given folder row, as its sibling — at
    /// the top level for a top-level folder, inside the parent folder for
    /// a nested one.
    case insertLooseBefore(TerminalFolder.ID)
    /// A loose pinned tab at the end of the pinned zone.
    case appendToPinned
    /// Appended at the end of the folder's children; the folder may nest
    /// at any depth. Also used by folder payloads for the trailing gap of
    /// an expanded folder (the dragged folder nests as its last child).
    case appendToFolder(TerminalFolder.ID)
    /// Same mutation as `appendToFolder`; distinct so feedback can highlight
    /// the folder row instead of drawing an insertion line. For folder
    /// payloads this is the nesting drop: the dragged folder becomes the
    /// target's last child.
    case intoFolder(TerminalFolder.ID)
    case appendToEphemeral
    // Folder payloads. The anchor is any item — tab or folder, at any
    // depth — since folders interleave freely with tabs and nest.
    case insertFolderBefore(UUID)
    /// At the end of the space's top-level pinned items.
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

// MARK: - Resolver

/// Maps a pointer location to exactly one drop proposal (or nil for invalid
/// positions). Rows keep flatten order; geometry only decides which row/gap
/// the pointer is in, while adjacency semantics stay structural.
///
/// Tabs and folders interleave freely and folders nest, so the gap that
/// closes one or more folders (after a subtree's last visible row, or
/// after a childless folder row) has several valid depths. The pointer's
/// X offset picks — dnd-kit's projection: each childIndent of rightward
/// travel nests one level deeper, no travel keeps the shallowest landing.
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

    /// Child rows sit 14pt in from their folder, per nesting level; used
    /// to synthesize a child-depth line under a folder row with no visible
    /// children, and as the rightward-travel step that picks a deeper
    /// landing in an ambiguous gap.
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
        case .space:
            // Spaces reorder in the indicator bar, never into a tab list.
            return .invalid
        case .folder(let id):
            return folderResolution(
                at: location, draggedFolder: id, horizontalDelta: horizontalDelta
            )
        case .tabs(let ids):
            var proposal = location.y < zoneBoundaryY
                ? pinnedTabProposal(at: location, horizontalDelta: horizontalDelta)
                : ephemeralTabProposal(y: location.y)
            proposal = snappingToSplitRunBoundary(
                proposal, y: location.y, horizontalDelta: horizontalDelta, draggedIDs: Set(ids)
            )
            // The dragged rows' own slot: a drop would change nothing, so
            // show nothing — but it isn't a forbidden position either.
            if isNoOpTarget(proposal.target, draggedIDs: Set(ids)) {
                return .noOp
            }
            return .proposal(proposal)
        }
    }

    // MARK: Split-group runs

    /// A split group's rows act as one unit for tabs from outside it: a
    /// proposal that would land between two members snaps to the nearest
    /// run boundary (the pointer's half of the run decides which), so a
    /// drop can never interleave strangers into a split group. The group's
    /// own members keep the interior slots — reordering within the group
    /// stays valid. Mirrors the store's anchor snapping in
    /// `insert(_:before:)`, so the previewed line and the commit agree.
    private func snappingToSplitRunBoundary(
        _ proposal: SidebarDropProposal,
        y: CGFloat,
        horizontalDelta: CGFloat,
        draggedIDs: Set<TerminalSession.ID>
    ) -> SidebarDropProposal {
        guard case .insertBefore(let anchorID) = proposal.target else { return proposal }
        let isPinned = pinnedRows.contains { $0.row.id == anchorID }
        let zone = isPinned ? pinnedRows : ephemeralRows
        guard let index = zone.firstIndex(where: { $0.row.id == anchorID }),
              let containerID = zone[index].row.splitContainerID else { return proposal }

        // The contiguous run around the anchor sharing its container
        // (flatten hoists members adjacent, so this is the whole group).
        var start = index
        while start > 0, zone[start - 1].row.splitContainerID == containerID { start -= 1 }
        var end = index
        while end + 1 < zone.count, zone[end + 1].row.splitContainerID == containerID { end += 1 }

        // Members shuffling among themselves keep the interior slot; the
        // slot before the run's first row already IS a boundary.
        if draggedIDs.allSatisfy({ id in zone[start...end].contains { $0.row.id == id } }) {
            return proposal
        }
        guard index > start else { return proposal }

        let runFrame = zone[start].frame.union(zone[end].frame)
        if y < runFrame.midY {
            return SidebarDropProposal(
                target: .insertBefore(zone[start].row.id),
                indicator: line(at: zone[start].frame.minY, spanning: zone[start].frame)
            )
        }
        if isPinned {
            // The pinned gap logic already knows what follows the run — a
            // sibling row, a folder edge, or the end of the zone.
            return tabGapProposal(after: end, horizontalDelta: horizontalDelta)
        }
        if end + 1 < zone.count {
            return SidebarDropProposal(
                target: .insertBefore(zone[end + 1].row.id),
                indicator: line(at: zone[end + 1].frame.minY, spanning: zone[end + 1].frame)
            )
        }
        return SidebarDropProposal(
            target: .appendToEphemeral,
            indicator: line(at: zone[end].frame.maxY, spanning: zone[end].frame)
        )
    }

    // MARK: Tabs

    private func ephemeralTabProposal(y: CGFloat) -> SidebarDropProposal {
        if let hit = ephemeralRows.first(where: { y < $0.frame.midY }) {
            return SidebarDropProposal(
                target: .insertBefore(hit.row.id),
                indicator: line(at: hit.frame.minY, spanning: hit.frame)
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
                    indicator: line(at: hit.frame.minY, spanning: hit.frame)
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
                        indicator: line(at: hit.frame.minY, spanning: hit.frame)
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
                    indicator: line(at: child.frame.minY, spanning: child.frame)
                )
            }
            return SidebarDropProposal(
                target: .intoFolder(hit.row.id),
                indicator: .folderHighlight(hit.row.id)
            )
        }
    }

    // MARK: Gap projection

    /// One landing slot in the gap immediately after a pinned row: the
    /// receiving container, the row the drop lands before (nil to append at
    /// the container's end), and the preview line at the landing depth.
    private struct GapSlot {
        /// nil for the space's top level.
        let parentFolderID: TerminalFolder.ID?
        let nextRow: SidebarFlatRow?
        let depth: Int
        let indicator: SidebarDropProposal.Indicator
    }

    /// The chain of open folders a row sits in, outermost first — its
    /// ancestors, plus the row itself when it is a folder row with no
    /// visible children (the gap after it can append INTO it). Chain[d - 1]
    /// is the folder that owns depth-d landings at a gap closing this row.
    private func parentChain(endingAt row: SidebarFlatRow) -> [TerminalFolder.ID] {
        var chain: [TerminalFolder.ID] = []
        var parentID = row.parentFolderID
        while let id = parentID {
            chain.insert(id, at: 0)
            parentID = frameRow(id)?.row.parentFolderID
        }
        if case .folder = row.kind { chain.append(row.id) }
        return chain
    }

    /// Whether the row lives anywhere inside the given folder's visible
    /// subtree (the folder's own row excluded).
    private func isInSubtree(_ row: SidebarFlatRow, of folderID: TerminalFolder.ID) -> Bool {
        var parentID = row.parentFolderID
        while let id = parentID {
            if id == folderID { return true }
            parentID = frameRow(id)?.row.parentFolderID
        }
        return false
    }

    /// Resolves the gap after the given pinned row to one landing depth.
    /// A gap that closes one or more folders is ambiguous — every folder
    /// ending there, plus the container of whatever follows, is valid —
    /// and the pointer's rightward travel picks: each childIndent of
    /// travel nests one level deeper (dnd-kit's projection generalized
    /// from the old two-level version), clamped to the depths the gap
    /// actually offers. No travel keeps the shallowest, least-destructive
    /// landing. `maxAllowedDepth` lets folder drags fence off their own
    /// subtree. The insertion line previews the chosen depth either way.
    private func gapSlot(
        after index: Int, horizontalDelta: CGFloat, maxAllowedDepth: Int? = nil
    ) -> GapSlot {
        let hit = pinnedRows[index]
        let next = index + 1 < pinnedRows.count ? pinnedRows[index + 1] : nil
        let gapY = hit.frame.maxY

        // chain.count is the deepest landing this gap offers: for a tab
        // that's its own container; for a folder row with no visible
        // children, one level inside it; for an expanded folder row, the
        // slot before its first child (whose depth the next row pins).
        let chain = parentChain(endingAt: hit.row)
        var maxDepth = chain.count
        if let maxAllowedDepth { maxDepth = min(maxDepth, maxAllowedDepth) }
        let minDepth = next?.row.depth ?? 0
        let steps = max(0, Int(((horizontalDelta + Self.childIndent / 2) / Self.childIndent)
            .rounded(.down)))
        let depth = max(minDepth, min(maxDepth, minDepth + steps))

        if depth == minDepth, let next {
            // Landing right before the following row, in its container.
            return GapSlot(
                parentFolderID: next.row.parentFolderID,
                nextRow: next.row,
                depth: depth,
                indicator: line(at: next.frame.minY, spanning: next.frame)
            )
        }
        if depth >= 1 {
            // Appending at the end of a folder this gap closes.
            let parent = chain[depth - 1]
            let parentFrame = frame(of: parent) ?? hit.frame
            return GapSlot(
                parentFolderID: parent,
                nextRow: nil,
                depth: depth,
                indicator: line(at: gapY, spanning: childSpan(of: parentFrame))
            )
        }
        // The end of the pinned zone's top level.
        let span = chain.first.flatMap { frame(of: $0) } ?? hit.frame
        return GapSlot(
            parentFolderID: nil,
            nextRow: nil,
            depth: 0,
            indicator: line(at: gapY, spanning: span)
        )
    }

    /// The tab-payload proposal for a resolved gap slot.
    private func tabGapProposal(after index: Int, horizontalDelta: CGFloat) -> SidebarDropProposal {
        let slot = gapSlot(after: index, horizontalDelta: horizontalDelta)
        if let next = slot.nextRow {
            switch next.kind {
            case .folder:
                return SidebarDropProposal(
                    target: .insertLooseBefore(next.id), indicator: slot.indicator
                )
            case .tab:
                return SidebarDropProposal(
                    target: .insertBefore(next.id), indicator: slot.indicator
                )
            }
        }
        if let parent = slot.parentFolderID {
            return SidebarDropProposal(
                target: .appendToFolder(parent), indicator: slot.indicator
            )
        }
        return SidebarDropProposal(target: .appendToPinned, indicator: slot.indicator)
    }

    // MARK: Folders

    /// Folder drags mirror the tab projection row-for-row — insert before
    /// a row, nest into a folder's trailing gap by dragging rightward, or
    /// drop onto a folder row's middle to nest inside it — with one hard
    /// fence: no landing inside the dragged folder's own subtree ever
    /// resolves (into itself, its descendants, or before an anchor that
    /// would leave with it). Those positions read as the quiet no-op, not
    /// the forbidden cursor, matching the own-slot treatment.
    private func folderResolution(
        at location: CGPoint,
        draggedFolder: TerminalFolder.ID,
        horizontalDelta: CGFloat
    ) -> SidebarDropResolution {
        // Folders are pinned-only.
        guard location.y < zoneBoundaryY else { return .invalid }
        let y = location.y

        guard !pinnedRows.isEmpty else {
            // Empty pinned zone: the only slot is the zone itself.
            let anchor = dividerFrame ?? .zero
            return .proposal(SidebarDropProposal(
                target: .appendFolder,
                indicator: line(at: anchor.minY, spanning: anchor)
            ))
        }

        guard let index = pinnedRows.firstIndex(where: { y < $0.frame.maxY }) else {
            // Below every pinned row: the gap closing the last one.
            return folderGapResolution(
                after: pinnedRows.count - 1, draggedFolder: draggedFolder,
                horizontalDelta: horizontalDelta
            )
        }

        let hit = pinnedRows[index]
        let fraction = (y - hit.frame.minY) / max(hit.frame.height, 1)
        let hitIsDragged = hit.row.id == draggedFolder
            || isInSubtree(hit.row, of: draggedFolder)

        switch hit.row.kind {
        case .tab:
            if fraction < 0.5 {
                guard index > 0 else {
                    // Very top of the zone, only reachable for rows outside
                    // the dragged subtree (a subtree row always has the
                    // dragged folder's row above it).
                    return .proposal(SidebarDropProposal(
                        target: .insertFolderBefore(hit.row.id),
                        indicator: line(at: hit.frame.minY, spanning: hit.frame)
                    ))
                }
                return folderGapResolution(
                    after: index - 1, draggedFolder: draggedFolder,
                    horizontalDelta: horizontalDelta
                )
            }
            return folderGapResolution(
                after: index, draggedFolder: draggedFolder, horizontalDelta: horizontalDelta
            )

        case .folder(let collapsed):
            if fraction < 0.25 {
                guard index > 0 else {
                    return hit.row.id == draggedFolder
                        ? .noOp
                        : .proposal(SidebarDropProposal(
                            target: .insertFolderBefore(hit.row.id),
                            indicator: line(at: hit.frame.minY, spanning: hit.frame)
                        ))
                }
                return folderGapResolution(
                    after: index - 1, draggedFolder: draggedFolder,
                    horizontalDelta: horizontalDelta
                )
            }
            // The dragged folder's own row (or a descendant folder's):
            // nesting here would create a cycle, so nothing resolves.
            if hitIsDragged { return .noOp }
            if !collapsed, fraction >= 0.75,
               index + 1 < pinnedRows.count,
               pinnedRows[index + 1].row.parentFolderID == hit.row.id {
                // The expanded folder's trailing edge: before its first child.
                let child = pinnedRows[index + 1]
                if child.row.id == draggedFolder { return .noOp }
                return .proposal(SidebarDropProposal(
                    target: .insertFolderBefore(child.row.id),
                    indicator: line(at: child.frame.minY, spanning: child.frame)
                ))
            }
            return .proposal(SidebarDropProposal(
                target: .intoFolder(hit.row.id),
                indicator: .folderHighlight(hit.row.id)
            ))
        }
    }

    /// The folder-payload resolution for the gap after a pinned row. Depths
    /// inside the dragged subtree are fenced off via the chain cap; the
    /// dragged folder's own depth right after its subtree is its own slot
    /// (a no-op), while shallower depths there un-nest it in place.
    private func folderGapResolution(
        after index: Int,
        draggedFolder: TerminalFolder.ID,
        horizontalDelta: CGFloat
    ) -> SidebarDropResolution {
        let hit = pinnedRows[index]
        let next = index + 1 < pinnedRows.count ? pinnedRows[index + 1] : nil
        let hitInDragged = hit.row.id == draggedFolder
            || isInSubtree(hit.row, of: draggedFolder)

        // Gaps interior to the dragged subtree offer nothing — only the
        // gap that CLOSES it (nothing of the subtree follows) can, and
        // then only the un-nesting depths outside the subtree.
        if hitInDragged, let next,
           next.row.id == draggedFolder || isInSubtree(next.row, of: draggedFolder) {
            return .noOp
        }

        let chain = parentChain(endingAt: hit.row)
        // Depths at or below the dragged folder's own position in the
        // chain would nest it into itself or a descendant.
        let cap = chain.firstIndex(of: draggedFolder)
        let slot = gapSlot(after: index, horizontalDelta: horizontalDelta, maxAllowedDepth: cap)

        // Right after its own subtree at its own depth: the current slot.
        if hitInDragged, let draggedRow = frameRow(draggedFolder)?.row,
           slot.depth == draggedRow.depth {
            return .noOp
        }

        if let next = slot.nextRow {
            // Right before its own row: the current slot from above.
            if next.id == draggedFolder { return .noOp }
            return .proposal(SidebarDropProposal(
                target: .insertFolderBefore(next.id), indicator: slot.indicator
            ))
        }
        if let parent = slot.parentFolderID {
            return .proposal(SidebarDropProposal(
                target: .appendToFolder(parent), indicator: slot.indicator
            ))
        }
        return .proposal(SidebarDropProposal(target: .appendFolder, indicator: slot.indicator))
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
            // The landing container is the folder row's own: top level for
            // a top-level folder, its parent folder for a nested one.
            return draggedFillSlot(
                endingAt: index - 1, in: pinnedRows,
                container: pinnedRows[index].row.parentFolderID, draggedIDs: draggedIDs
            )
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

    // MARK: Row lookup & indicator geometry

    private func frameRow(_ rowID: UUID) -> FramedRow? {
        pinnedRows.first { $0.row.id == rowID }
    }

    private func frame(of rowID: UUID) -> CGRect? {
        frameRow(rowID)?.frame
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
