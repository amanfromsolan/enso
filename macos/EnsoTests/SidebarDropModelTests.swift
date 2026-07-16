import CoreGraphics
import Foundation
import Testing
@testable import Enso

/// Projection-model coverage: flatten ordering, the drag payload codec, and
/// the resolver's mapping from pointer positions to drop proposals.
struct SidebarDropModelTests {
    // Fixture: loose pinned [A, B], folder F [f1, f2] (expanded), folder G
    // [g1] (collapsed), ephemeral [e1, e2].
    private struct Fixture {
        let space: SidebarSpace
        let a: UUID, b: UUID
        let f1: UUID, f2: UUID, g1: UUID
        let e1: UUID, e2: UUID
        let folderF: UUID, folderG: UUID
    }

    private func makeFixture() -> Fixture {
        func session(_ name: String) -> TerminalSession {
            TerminalSession(title: name, workingDirectory: "/tmp")
        }
        let a = session("A"), b = session("B")
        let f1 = session("f1"), f2 = session("f2"), g1 = session("g1")
        let e1 = session("e1"), e2 = session("e2")
        let folderF = TerminalFolder(title: "F", sessions: [f1, f2])
        let folderG = TerminalFolder(title: "G", sessions: [g1])
        let space = SidebarSpace(
            name: "Main",
            pinnedFolders: [folderF, folderG],
            pinnedSessions: [a, b],
            ephemeralSessions: [e1, e2]
        )
        return Fixture(
            space: space,
            a: a.id, b: b.id, f1: f1.id, f2: f2.id, g1: g1.id, e1: e1.id, e2: e2.id,
            folderF: folderF.id, folderG: folderG.id
        )
    }

    /// 30pt rows from y=40 (optionally gapped), child rows indented 14pt,
    /// a 17pt divider between the zones — a simplified but faithful layout.
    private func layout(
        _ rows: [SidebarFlatRow],
        gap: CGFloat = 0
    ) -> (frames: [UUID: CGRect], divider: CGRect) {
        var frames: [UUID: CGRect] = [:]
        var y: CGFloat = 40
        for row in rows where row.zone == .pinned {
            let x: CGFloat = row.depth == 1 ? 24 : 10
            frames[row.id] = CGRect(x: x, y: y, width: 244 - x, height: 30)
            y += 30 + gap
        }
        let divider = CGRect(x: 10, y: y, width: 234, height: 17)
        y += 17
        for row in rows where row.zone == .ephemeral {
            frames[row.id] = CGRect(x: 10, y: y, width: 234, height: 30)
            y += 30 + gap
        }
        return (frames, divider)
    }

    private func makeResolver(
        _ fixture: Fixture,
        collapsed: Set<UUID>,
        selection: UUID? = nil
    ) -> SidebarDropResolver {
        let rows = flattenSidebar(
            space: fixture.space, collapsedFolderIDs: collapsed, selection: selection
        )
        let (frames, divider) = layout(rows)
        return SidebarDropResolver(rows: rows, rowFrames: frames, dividerFrame: divider)
    }

    private func target(
        _ resolver: SidebarDropResolver,
        y: CGFloat,
        dragging: SidebarDragPayload,
        delta: CGFloat = 0
    ) -> SidebarDropTarget? {
        resolver.resolve(
            at: CGPoint(x: 120, y: y), dragging: dragging, horizontalDelta: delta
        ).proposal?.target
    }

    private func resolution(
        _ resolver: SidebarDropResolver,
        y: CGFloat,
        dragging: SidebarDragPayload,
        delta: CGFloat = 0
    ) -> SidebarDropResolution {
        resolver.resolve(at: CGPoint(x: 120, y: y), dragging: dragging, horizontalDelta: delta)
    }

    // MARK: Flatten

    @Test func flattenOrdersLooseThenFoldersThenEphemeral() {
        let fx = makeFixture()
        let rows = flattenSidebar(space: fx.space, collapsedFolderIDs: [fx.folderG], selection: nil)
        #expect(rows.map(\.id) == [fx.a, fx.b, fx.folderF, fx.f1, fx.f2, fx.folderG, fx.e1, fx.e2])
        #expect(rows[3].parentFolderID == fx.folderF)
        #expect(rows[5].kind == .folder(collapsed: true))
        #expect(rows[6].zone == .ephemeral)
    }

    @Test func flattenPeeksTheCollapsedFolderActiveTab() {
        let fx = makeFixture()
        let rows = flattenSidebar(
            space: fx.space, collapsedFolderIDs: [fx.folderG], selection: fx.g1
        )
        #expect(rows.map(\.id) == [
            fx.a, fx.b, fx.folderF, fx.f1, fx.f2, fx.folderG, fx.g1, fx.e1, fx.e2
        ])
        #expect(rows[6].parentFolderID == fx.folderG)
    }

    @Test func flattenHidesCollapsedFolderChildren() {
        let fx = makeFixture()
        let rows = flattenSidebar(
            space: fx.space, collapsedFolderIDs: [fx.folderF, fx.folderG], selection: fx.a
        )
        #expect(rows.map(\.id) == [fx.a, fx.b, fx.folderF, fx.folderG, fx.e1, fx.e2])
    }

    // MARK: Payload codec

    @Test func payloadCodecRoundTripsLegacyFormats() {
        let ids = [UUID(), UUID()]
        let tabs = SidebarDragPayload.tabs(ids)
        #expect(tabs.stringValue == "\(ids[0].uuidString),\(ids[1].uuidString)")
        #expect(SidebarDragPayload(string: tabs.stringValue) == tabs)

        let folderID = UUID()
        let folder = SidebarDragPayload.folder(folderID)
        #expect(folder.stringValue == "folder:\(folderID.uuidString)")
        #expect(SidebarDragPayload(string: folder.stringValue) == folder)

        #expect(SidebarDragPayload(string: "garbage") == nil)
        #expect(SidebarDragPayload(string: "folder:nope") == nil)
    }

    @Test func payloadDecodeMergesItemsAndPrefersFolders() {
        let a = UUID(), b = UUID(), folderID = UUID()
        #expect(
            SidebarDragPayload.decode(items: [a.uuidString, b.uuidString])
                == .tabs([a, b])
        )
        #expect(
            SidebarDragPayload.decode(items: [a.uuidString, "folder:\(folderID.uuidString)"])
                == .folder(folderID)
        )
        #expect(SidebarDragPayload.decode(items: ["junk"]) == nil)
    }

    // MARK: Tab projection — loose pinned rows
    // Layout: A 40–70, B 70–100, F 100–130, f1 130–160, f2 160–190,
    // G 190–220, divider 220–237 (boundary 228.5), e1 237–267, e2 267–297.

    @Test func tabOverRowTopHalfLandsBeforeIt() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG])
        #expect(target(resolver, y: 48, dragging: .tabs([fx.e2])) == .insertBefore(fx.a))
        #expect(target(resolver, y: 75, dragging: .tabs([fx.e2])) == .insertBefore(fx.b))
    }

    @Test func tabOverRowBottomHalfLandsAfterIt() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG])
        // Bottom of A: before B.
        #expect(target(resolver, y: 65, dragging: .tabs([fx.e2])) == .insertBefore(fx.b))
        // Bottom of B, next is a folder: loose, right before that folder.
        #expect(target(resolver, y: 88, dragging: .tabs([fx.e2])) == .insertLooseBefore(fx.folderF))
    }

    @Test func tabProjectionOntoFolderRowSplitsByZones() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG])
        // Top quarter of F with a loose tab above: loose, before F.
        #expect(target(resolver, y: 103, dragging: .tabs([fx.e2])) == .insertLooseBefore(fx.folderF))
        // Middle of F: into the folder, with the row highlight.
        let middle = resolution(resolver, y: 115, dragging: .tabs([fx.e2]))
        #expect(middle.proposal?.target == .intoFolder(fx.folderF))
        #expect(middle.proposal?.indicator == .folderHighlight(fx.folderF))
        // Bottom quarter of expanded F: before its first child.
        #expect(target(resolver, y: 127, dragging: .tabs([fx.e2])) == .insertBefore(fx.f1))
    }

    @Test func tabGapClosingAFolderPicksDepthByDragDelta() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG])
        // The gap after F's last child, before G. No horizontal travel:
        // loose between the folders (the less-destructive default).
        let loose = resolution(resolver, y: 185, dragging: .tabs([fx.e2]))
        #expect(loose.proposal?.target == .insertLooseBefore(fx.folderG))
        // The line previews depth 0: full width, not the child indent.
        #expect(loose.proposal?.indicator == .line(y: 190, minX: 14, maxX: 240))

        // Dragged rightward by at least half the indent: nested into F,
        // child-depth line.
        let nested = resolution(resolver, y: 185, dragging: .tabs([fx.e2]), delta: 14)
        #expect(nested.proposal?.target == .appendToFolder(fx.folderF))
        #expect(nested.proposal?.indicator == .line(y: 190, minX: 28, maxX: 240))

        // Top quarter of G resolves the same gap.
        #expect(target(resolver, y: 193, dragging: .tabs([fx.e2]), delta: 14) == .appendToFolder(fx.folderF))
        #expect(target(resolver, y: 193, dragging: .tabs([fx.e2])) == .insertLooseBefore(fx.folderG))
    }

    @Test func tabOverCollapsedFolderDropsInto() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG])
        #expect(target(resolver, y: 205, dragging: .tabs([fx.e2])) == .intoFolder(fx.folderG))
        // Collapsed folders have no before-first-child edge.
        #expect(target(resolver, y: 218, dragging: .tabs([fx.e2])) == .intoFolder(fx.folderG))
    }

    @Test func tabBelowTheLastFolderPicksDepthByDragDelta() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG])
        // Dragged rightward: the gap below the last (collapsed) folder
        // extends it.
        #expect(target(resolver, y: 225, dragging: .tabs([fx.e2]), delta: 14) == .appendToFolder(fx.folderG))
        // No travel: loose tab at the end of the pinned zone.
        #expect(target(resolver, y: 225, dragging: .tabs([fx.e2])) == .appendToPinned)
    }

    @Test func tabInEphemeralZoneInsertsByRowAndAppendsAtEnd() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG])
        // Just past the divider midline: before the first ephemeral row.
        #expect(target(resolver, y: 230, dragging: .tabs([fx.a])) == .insertBefore(fx.e1))
        #expect(target(resolver, y: 260, dragging: .tabs([fx.a])) == .insertBefore(fx.e2))
        #expect(target(resolver, y: 290, dragging: .tabs([fx.a])) == .appendToEphemeral)
        // Way below the rows, over the new-terminal button and spacer.
        #expect(target(resolver, y: 500, dragging: .tabs([fx.a])) == .appendToEphemeral)
    }

    @Test func tabDropOnItsOwnSlotIsANoOpNotForbidden() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG])
        // Both halves of the dragged row read as a quiet no-op — no
        // indicator, but no forbidden cursor either.
        #expect(resolution(resolver, y: 48, dragging: .tabs([fx.a])) == .noOp)
        #expect(resolution(resolver, y: 65, dragging: .tabs([fx.a])) == .noOp)
        // Top half of the row below the dragged one is the same slot.
        #expect(resolution(resolver, y: 75, dragging: .tabs([fx.a])) == .noOp)
        // The end of the ephemeral list, dragging its last tab.
        #expect(resolution(resolver, y: 290, dragging: .tabs([fx.e2])) == .noOp)
        // An adjacent multi-selection dropped onto its own block.
        #expect(resolution(resolver, y: 75, dragging: .tabs([fx.a, fx.b])) == .noOp)
        // But a real move nearby still proposes.
        #expect(target(resolver, y: 48, dragging: .tabs([fx.b])) == .insertBefore(fx.a))
    }

    @Test func peekingTabActsAsItsFolderChild() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG], selection: fx.g1)
        // g1 peeks at 220–250.
        #expect(target(resolver, y: 225, dragging: .tabs([fx.e2])) == .insertBefore(fx.g1))
        #expect(target(resolver, y: 245, dragging: .tabs([fx.e2]), delta: 14) == .appendToFolder(fx.folderG))
        #expect(target(resolver, y: 245, dragging: .tabs([fx.e2])) == .appendToPinned)
    }

    @Test func insertionLineCarriesTheTargetDepth() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG])
        // Before loose tab A: full width at depth 0 (row x=10, inset 4).
        let loose = resolution(resolver, y: 48, dragging: .tabs([fx.e2]))
        #expect(loose.proposal?.indicator == .line(y: 40, minX: 14, maxX: 240))
        // Before child f1: indented to child depth (row x=24).
        let child = resolution(resolver, y: 135, dragging: .tabs([fx.e2]))
        #expect(child.proposal?.indicator == .line(y: 130, minX: 28, maxX: 240))
    }

    // MARK: Folder projection

    @Test func folderDragOrdersByPinnedItemGroups() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG])
        // Groups (mid): A 55, B 85, F 145 (spans 100–190), G 205.
        // Folders can land between loose tabs now.
        #expect(target(resolver, y: 45, dragging: .folder(fx.folderG)) == .insertFolderBefore(fx.a))
        #expect(target(resolver, y: 65, dragging: .folder(fx.folderG)) == .insertFolderBefore(fx.b))
        #expect(target(resolver, y: 120, dragging: .folder(fx.folderG)) == .insertFolderBefore(fx.folderF))
        // Past the last group's midline: the end of the pinned zone.
        #expect(target(resolver, y: 215, dragging: .folder(fx.folderF)) == .appendFolder)
    }

    @Test func folderDragOwnSlotIsSuppressed() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG])
        // Before itself.
        #expect(target(resolver, y: 120, dragging: .folder(fx.folderF)) == nil)
        // Right after itself.
        #expect(target(resolver, y: 160, dragging: .folder(fx.folderF)) == nil)
        #expect(target(resolver, y: 160, dragging: .folder(fx.folderG)) == nil)
        #expect(target(resolver, y: 215, dragging: .folder(fx.folderG)) == nil)
    }

    @Test func folderDragIsRejectedFromTheEphemeralZone() {
        let fx = makeFixture()
        let resolver = makeResolver(fx, collapsed: [fx.folderG])
        // Forbidden, unlike a no-op own slot.
        #expect(resolution(resolver, y: 250, dragging: .folder(fx.folderF)) == .invalid)
        #expect(resolution(resolver, y: 500, dragging: .folder(fx.folderF)) == .invalid)
    }

    @Test func uniformRowGapsResolveAmbiguityByDelta() {
        // Rows separated by the real 8pt gap: the gap above a loose tab
        // that follows a folder's children is the ambiguous slot.
        let fx = makeFixture()
        let rows = flattenSidebar(space: fx.space, collapsedFolderIDs: [fx.folderG], selection: nil)
        let (frames, divider) = layout(rows, gap: 8)
        let resolver = SidebarDropResolver(rows: rows, rowFrames: frames, dividerFrame: divider)
        // Layout: f2 192–222, G 230–260. Pointer in the 8pt gap at y=226.
        #expect(
            resolver.resolve(at: CGPoint(x: 120, y: 226), dragging: .tabs([fx.e2]), horizontalDelta: 14)
                .proposal?.target == .appendToFolder(fx.folderF)
        )
        #expect(
            resolver.resolve(at: CGPoint(x: 120, y: 226), dragging: .tabs([fx.e2]), horizontalDelta: 0)
                .proposal?.target == .insertLooseBefore(fx.folderG)
        )
    }

    // MARK: Interleaved pinned items

    @Test func flattenFollowsInterleavedPinnedOrder() {
        let a = TerminalSession(title: "a", workingDirectory: "/tmp")
        let b = TerminalSession(title: "b", workingDirectory: "/tmp")
        let f1 = TerminalSession(title: "f1", workingDirectory: "/tmp")
        let folder = TerminalFolder(title: "F", sessions: [f1])
        let space = SidebarSpace(
            name: "Main",
            pinnedItems: [.tab(a), .folder(folder), .tab(b)]
        )
        let rows = flattenSidebar(space: space, collapsedFolderIDs: [], selection: nil)
        #expect(rows.map(\.id) == [a.id, folder.id, f1.id, b.id])
        #expect(rows[3].parentFolderID == nil)
    }

    @Test func tabGapBetweenFolderAndLooseTabPicksDepthByPointerX() {
        // Layout: a 40–70, F 70–100, f1 100–130, b 130–160.
        let a = TerminalSession(title: "a", workingDirectory: "/tmp")
        let b = TerminalSession(title: "b", workingDirectory: "/tmp")
        let f1 = TerminalSession(title: "f1", workingDirectory: "/tmp")
        let e1 = TerminalSession(title: "e1", workingDirectory: "/tmp")
        let folder = TerminalFolder(title: "F", sessions: [f1])
        let space = SidebarSpace(
            name: "Main",
            pinnedItems: [.tab(a), .folder(folder), .tab(b)],
            ephemeralSessions: [e1]
        )
        let rows = flattenSidebar(space: space, collapsedFolderIDs: [], selection: nil)
        let (frames, divider) = layout(rows)
        let resolver = SidebarDropResolver(rows: rows, rowFrames: frames, dividerFrame: divider)

        // The gap after f1, before loose tab b: dragged rightward nests
        // into F, otherwise lands loosely before b.
        #expect(
            resolver.resolve(at: CGPoint(x: 120, y: 125), dragging: .tabs([e1.id]), horizontalDelta: 14)
                .proposal?.target == .appendToFolder(folder.id)
        )
        #expect(
            resolver.resolve(at: CGPoint(x: 120, y: 125), dragging: .tabs([e1.id]), horizontalDelta: 0)
                .proposal?.target == .insertBefore(b.id)
        )
    }

    // MARK: Gap-free adjustment

    /// Opens a drop gap above the given row the way the live layout does:
    /// that row and everything below it (divider included) shift down.
    private func openGap(
        above rowID: UUID,
        height: CGFloat,
        frames: [UUID: CGRect],
        divider: CGRect
    ) -> (frames: [UUID: CGRect], divider: CGRect) {
        guard let gapTop = frames[rowID]?.minY else { return (frames, divider) }
        var shifted = frames
        for (id, frame) in shifted where frame.minY >= gapTop - 0.5 {
            shifted[id] = frame.offsetBy(dx: 0, dy: height)
        }
        let dividerShifted = divider.minY >= gapTop - 0.5
            ? divider.offsetBy(dx: 0, dy: height)
            : divider
        return (shifted, dividerShifted)
    }

    @Test func gapAdjustmentReconstructsGapFreeGeometry() {
        let fx = makeFixture()
        let rows = flattenSidebar(space: fx.space, collapsedFolderIDs: [fx.folderG], selection: nil)
        let (frames, divider) = layout(rows)
        // Gap open above B: B and everything below sit 30pt lower live.
        let gapped = openGap(above: fx.b, height: 30, frames: frames, divider: divider)

        let adjusted = removingSidebarDropGap(
            above: fx.b,
            gapHeight: 30,
            rowFrames: gapped.frames,
            dividerFrame: gapped.divider,
            pointerY: 55
        )
        #expect(adjusted.rowFrames == frames)
        #expect(adjusted.dividerFrame == divider)
        // Pointer above the gap is untouched.
        #expect(adjusted.pointerY == 55)
    }

    @Test func gapAdjustmentMapsThePointerIntoGapFreeSpace() {
        let fx = makeFixture()
        let rows = flattenSidebar(space: fx.space, collapsedFolderIDs: [fx.folderG], selection: nil)
        let (frames, divider) = layout(rows)
        let gapped = openGap(above: fx.b, height: 30, frames: frames, divider: divider)
        // Live: gap spans 70–100, B sits at 100–130.

        // Below the gap: shifts up with the content.
        #expect(removingSidebarDropGap(
            above: fx.b, gapHeight: 30,
            rowFrames: gapped.frames, dividerFrame: gapped.divider, pointerY: 115
        ).pointerY == 85)
        // Inside the open gap: pins to the slot boundary it represents,
        // so hovering the gap keeps proposing the same insertion.
        #expect(removingSidebarDropGap(
            above: fx.b, gapHeight: 30,
            rowFrames: gapped.frames, dividerFrame: gapped.divider, pointerY: 85
        ).pointerY == 69)
    }

    @Test func gapAdjustedResolutionIsStableWhileTheGapIsOpen() {
        let fx = makeFixture()
        let rows = flattenSidebar(space: fx.space, collapsedFolderIDs: [fx.folderG], selection: nil)
        let (frames, divider) = layout(rows)

        // Gap-free: hovering B's top half proposes inserting before B,
        // which opens a gap above B.
        let before = SidebarDropResolver(rows: rows, rowFrames: frames, dividerFrame: divider)
            .resolve(at: CGPoint(x: 120, y: 75), dragging: .tabs([fx.e2]), horizontalDelta: 0)
        #expect(before.proposal?.target == .insertBefore(fx.b))
        #expect(before.proposal?.gapRowID == fx.b)

        // With the gap open, the same live pointer position — now inside
        // the gap — must resolve to the same proposal, not oscillate.
        let gapped = openGap(above: fx.b, height: 30, frames: frames, divider: divider)
        let adjusted = removingSidebarDropGap(
            above: fx.b, gapHeight: 30,
            rowFrames: gapped.frames, dividerFrame: gapped.divider, pointerY: 75
        )
        let after = SidebarDropResolver(
            rows: rows, rowFrames: adjusted.rowFrames, dividerFrame: adjusted.dividerFrame
        ).resolve(
            at: CGPoint(x: 120, y: adjusted.pointerY), dragging: .tabs([fx.e2]), horizontalDelta: 0
        )
        #expect(after.proposal?.target == .insertBefore(fx.b))
    }

    @Test func gapAdjustmentWithUnknownRowIsIdentity() {
        let fx = makeFixture()
        let rows = flattenSidebar(space: fx.space, collapsedFolderIDs: [fx.folderG], selection: nil)
        let (frames, divider) = layout(rows)
        let adjusted = removingSidebarDropGap(
            above: UUID(), gapHeight: 30,
            rowFrames: frames, dividerFrame: divider, pointerY: 105
        )
        #expect(adjusted.rowFrames == frames)
        #expect(adjusted.dividerFrame == divider)
        #expect(adjusted.pointerY == 105)
    }

    // MARK: Persistence migration

    /// The exact two-array shape the old model persisted.
    private struct LegacyShapedSpace: Encodable {
        let id: UUID
        var name: String
        var icon: SidebarSpace.Icon
        var pinnedFolders: [TerminalFolder]
        var pinnedSessions: [TerminalSession]
        var ephemeralSessions: [TerminalSession]
        var lastSelection: UUID?
    }

    @Test func decodingLegacyTwoArrayStateMigratesLooseTabsFirst() throws {
        let loose = TerminalSession(title: "loose", workingDirectory: "/tmp")
        let f1 = TerminalSession(title: "f1", workingDirectory: "/tmp")
        let folder = TerminalFolder(title: "F", sessions: [f1])
        let ephemeral = TerminalSession(title: "e", workingDirectory: "/tmp")
        let legacy = LegacyShapedSpace(
            id: UUID(),
            name: "Main",
            icon: .dot,
            pinnedFolders: [folder],
            pinnedSessions: [loose],
            ephemeralSessions: [ephemeral],
            lastSelection: loose.id
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(SidebarSpace.self, from: data)

        // The old visual order — loose tabs above all folders — verbatim.
        #expect(decoded.pinnedItems.map(\.id) == [loose.id, folder.id])
        #expect(decoded.pinnedSessions.map(\.id) == [loose.id])
        #expect(decoded.pinnedFolders.map(\.id) == [folder.id])
        #expect(decoded.ephemeralSessions.map(\.id) == [ephemeral.id])
        #expect(decoded.lastSelection == loose.id)
    }

    @Test func newStateRoundTripsAndDualWritesLegacyKeysForOlderBuilds() throws {
        let a = TerminalSession(title: "a", workingDirectory: "/tmp")
        let b = TerminalSession(title: "b", workingDirectory: "/tmp")
        let f1 = TerminalSession(title: "f1", workingDirectory: "/tmp")
        let folder = TerminalFolder(title: "F", sessions: [f1])
        let space = SidebarSpace(
            name: "Main",
            pinnedItems: [.folder(folder), .tab(a), .tab(b)]
        )

        let data = try JSONEncoder().encode(space)
        // New builds read the interleaved order back verbatim.
        let decoded = try JSONDecoder().decode(SidebarSpace.self, from: data)
        #expect(decoded.pinnedItems.map(\.id) == [folder.id, a.id, b.id])

        // A rollback to the two-array build must still decode: the legacy
        // keys are dual-written (order degrades to tabs-first at worst,
        // but nothing is lost).
        struct LegacyBuildSpace: Decodable {
            let id: UUID
            var name: String
            var icon: SidebarSpace.Icon
            var pinnedFolders: [TerminalFolder]
            var pinnedSessions: [TerminalSession]
            var ephemeralSessions: [TerminalSession]
            var lastSelection: UUID?
        }
        let legacy = try JSONDecoder().decode(LegacyBuildSpace.self, from: data)
        #expect(legacy.pinnedSessions.map(\.id) == [a.id, b.id])
        #expect(legacy.pinnedFolders.map(\.id) == [folder.id])
        #expect(legacy.pinnedFolders.first?.sessions.map(\.id) == [f1.id])
    }
}

/// The store's single drop-commit point: anchor targets dispatch onto the
/// existing mutations, so pin/unpin/move semantics ride along.
@MainActor
struct SidebarDropStoreApplyTests {
    private func session(_ name: String) -> TerminalSession {
        TerminalSession(title: name, workingDirectory: "/tmp")
    }

    @Test func dropTargetsDispatchToAnchorMutations() {
        let a = session("a"), f1 = session("f1"), e1 = session("e1")
        let folder = TerminalFolder(title: "F", sessions: [f1])
        let space = SidebarSpace(
            name: "Main", pinnedFolders: [folder], pinnedSessions: [a], ephemeralSessions: [e1]
        )
        let store = TerminalSessionStore(spaces: [space], persistToDisk: false)

        // Ephemeral tab pinned loose at the end of the pinned zone — after
        // the folder, now that loose tabs and folders interleave.
        store.applySidebarDrop(.tabs([e1.id]), target: .appendToPinned, inSpace: space.id)
        #expect(store.spaces[0].pinnedItems.map(\.id) == [a.id, folder.id, e1.id])

        // Loose tab into a folder.
        store.applySidebarDrop(.tabs([a.id]), target: .intoFolder(folder.id), inSpace: space.id)
        #expect(store.spaces[0].pinnedFolders[0].sessions.map(\.id) == [f1.id, a.id])

        // Reorder within the folder via an anchor.
        store.applySidebarDrop(.tabs([a.id]), target: .insertBefore(f1.id), inSpace: space.id)
        #expect(store.spaces[0].pinnedFolders[0].sessions.map(\.id) == [a.id, f1.id])

        // Folder tab unpinned to the ephemeral zone.
        store.applySidebarDrop(.tabs([f1.id]), target: .appendToEphemeral, inSpace: space.id)
        #expect(store.spaces[0].ephemeralSessions.map(\.id) == [f1.id])
    }

    @Test func looseTabsInterleaveWithFolders() {
        let a = session("a"), f1 = session("f1")
        let folder = TerminalFolder(title: "F", sessions: [f1])
        let space = SidebarSpace(
            name: "Main", pinnedFolders: [folder], pinnedSessions: [a]
        )
        let store = TerminalSessionStore(spaces: [space], persistToDisk: false)
        #expect(store.spaces[0].pinnedItems.map(\.id) == [a.id, folder.id])

        // Loose tab moved below the folder.
        store.applySidebarDrop(.tabs([a.id]), target: .appendToPinned, inSpace: space.id)
        #expect(store.spaces[0].pinnedItems.map(\.id) == [folder.id, a.id])

        // And back above it, as a loose tab — not into the folder.
        store.applySidebarDrop(.tabs([a.id]), target: .insertLooseBefore(folder.id), inSpace: space.id)
        #expect(store.spaces[0].pinnedItems.map(\.id) == [a.id, folder.id])
        #expect(store.spaces[0].pinnedFolders[0].sessions.map(\.id) == [f1.id])

        // A folder can anchor on a loose tab.
        store.applySidebarDrop(.folder(folder.id), target: .insertFolderBefore(a.id), inSpace: space.id)
        #expect(store.spaces[0].pinnedItems.map(\.id) == [folder.id, a.id])

        // Deleting a folder dissolves it in place.
        store.deleteFolder(folder.id)
        #expect(store.spaces[0].pinnedItems.map(\.id) == [f1.id, a.id])
    }

    @Test func folderTargetsReorderAndMismatchedPairsNoOp() {
        let f1 = session("f1"), g1 = session("g1")
        let folderF = TerminalFolder(title: "F", sessions: [f1])
        let folderG = TerminalFolder(title: "G", sessions: [g1])
        let space = SidebarSpace(name: "Main", pinnedFolders: [folderF, folderG])
        let store = TerminalSessionStore(spaces: [space], persistToDisk: false)

        store.applySidebarDrop(.folder(folderG.id), target: .insertFolderBefore(folderF.id), inSpace: space.id)
        #expect(store.spaces[0].pinnedFolders.map(\.id) == [folderG.id, folderF.id])

        store.applySidebarDrop(.folder(folderG.id), target: .appendFolder, inSpace: space.id)
        #expect(store.spaces[0].pinnedFolders.map(\.id) == [folderF.id, folderG.id])

        // A folder payload against a tab target is a stale/foreign drop: no-op.
        store.applySidebarDrop(.folder(folderF.id), target: .insertBefore(g1.id), inSpace: space.id)
        #expect(store.spaces[0].pinnedFolders.map(\.id) == [folderF.id, folderG.id])
        #expect(store.spaces[0].pinnedFolders[1].sessions.map(\.id) == [g1.id])
    }
}
