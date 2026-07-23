import Foundation
import Testing
@testable import Enso

/// The split-tree model: pure structure operations (insert, remove,
/// ratio) plus the store-level behavior — splitting creates a real
/// adjacent tab, closing dissolves, moving a pane out leaves the split.
struct SplitTreeTests {
    private let a = TerminalSession.ID()
    private let b = TerminalSession.ID()
    private let c = TerminalSession.ID()

    @Test func insertingSplitsTargetLeafWithNewPaneSecond() throws {
        let tree = SplitNode.leaf(a)
        let split = try #require(tree.inserting(b, splitting: a, direction: .horizontal))
        guard case .split(let branch) = split else {
            Issue.record("expected a split root")
            return
        }
        #expect(branch.direction == .horizontal)
        #expect(branch.ratio == 0.5)
        #expect(branch.first == .leaf(a))
        #expect(branch.second == .leaf(b))
    }

    @Test func insertingIntoNestedSplitGrowsInPlace() throws {
        let tree = try #require(
            SplitNode.leaf(a).inserting(b, splitting: a, direction: .horizontal)
        )
        // Split pane B downward: only B's leaf becomes a vertical split.
        let grown = try #require(tree.inserting(c, splitting: b, direction: .vertical))
        #expect(grown.leafIDs == [a, b, c])
        guard case .split(let root) = grown, case .split(let second) = root.second else {
            Issue.record("expected nested split under the root's second child")
            return
        }
        #expect(root.first == .leaf(a))
        #expect(second.direction == .vertical)
        #expect(second.first == .leaf(b))
        #expect(second.second == .leaf(c))
    }

    @Test func removingLeafCollapsesSiblingIntoParent() throws {
        let tree = try #require(
            SplitNode.leaf(a).inserting(b, splitting: a, direction: .horizontal)?
                .inserting(c, splitting: b, direction: .vertical)
        )
        let removed = try #require(tree.removing(b))
        #expect(removed.leafIDs == [a, c])
        // The nested split dissolved; c absorbed its whole region.
        guard case .split(let root) = removed else {
            Issue.record("expected the root split to survive")
            return
        }
        #expect(root.second == .leaf(c))
    }

    @Test func removingLastLeafEmptiesTree() {
        #expect(SplitNode.leaf(a).removing(a) == nil)
    }

    @Test func updatingRatioFollowsPathAndClamps() throws {
        let tree = try #require(
            SplitNode.leaf(a).inserting(b, splitting: a, direction: .horizontal)?
                .inserting(c, splitting: b, direction: .vertical)
        )
        let nested = SplitPath().appending(.second)
        let updated = tree.updatingRatio(at: nested, to: 0.99)
        guard case .split(let root) = updated, case .split(let second) = root.second else {
            Issue.record("expected structure preserved")
            return
        }
        #expect(root.ratio == 0.5)
        #expect(second.ratio == SplitBranch.maxRatio)
    }

    @Test func staleRatioPathIsANoOp() throws {
        let tree = try #require(
            SplitNode.leaf(a).inserting(b, splitting: a, direction: .horizontal)
        )
        let stale = SplitPath().appending(.first).appending(.second)
        #expect(tree.updatingRatio(at: stale, to: 0.8) == tree)
    }
}

@MainActor
struct SplitStoreTests {
    private func makeStore(sessions: [TerminalSession]) -> TerminalSessionStore {
        TerminalSessionStore(
            spaces: [SidebarSpace(name: "Main", ephemeralSessions: sessions)],
            persistToDisk: false
        )
    }

    @Test func splittingCreatesAdjacentTabInheritingWorkingDirectory() {
        let source = TerminalSession(title: "src", workingDirectory: "/tmp")
        let other = TerminalSession(title: "other", workingDirectory: "~")
        let store = makeStore(sessions: [source, other])
        store.selection = source.id

        store.splitSelection(direction: .horizontal)

        let container = store.splitContainer(containing: source.id)
        #expect(container != nil)
        #expect(container?.memberIDs.count == 2)
        // The new pane is a real tab: selected, inheriting the cwd, and
        // sitting immediately after its source row (before "other").
        let newID = container?.memberIDs.last
        #expect(store.selection == newID)
        #expect(store.selectedSession?.workingDirectory == "/tmp")
        let order = store.activeSpace.sessions.map(\.id)
        #expect(order == [source.id, newID, other.id].compactMap { $0 })
    }

    @Test func splittingAPaneAppendsAfterLastMember() {
        let source = TerminalSession(title: "src", workingDirectory: "/tmp")
        let other = TerminalSession(title: "other", workingDirectory: "~")
        let store = makeStore(sessions: [source, other])
        store.selection = source.id

        store.splitSelection(direction: .horizontal)
        // Focus back on the FIRST pane, then split again: the new row must
        // land after the container's last member, not right after pane 1.
        store.selection = source.id
        store.splitSelection(direction: .vertical)

        let container = store.splitContainer(containing: source.id)
        #expect(container?.memberIDs.count == 3)
        let members = Set(container?.memberIDs ?? [])
        let order = store.activeSpace.sessions.map(\.id)
        // All three members sit adjacent before "other".
        #expect(Set(order.prefix(3)) == members)
        #expect(order.last == other.id)
    }

    @Test func closingPaneDissolvesDownToPlainTab() {
        let source = TerminalSession(title: "src", workingDirectory: "/tmp")
        let store = makeStore(sessions: [source])
        store.selection = source.id
        store.splitSelection(direction: .horizontal)
        let newID = store.splitContainer(containing: source.id)!.memberIDs.last!

        store.close(sessionID: newID)

        // One member left: the container dissolves entirely.
        #expect(store.splitContainer(containing: source.id) == nil)
        #expect(store.splitContainers.isEmpty)
    }

    @Test func closingFocusedPaneFocusesNearestSurvivingMember() {
        let source = TerminalSession(title: "src", workingDirectory: "/tmp")
        let outsider = TerminalSession(title: "out", workingDirectory: "~")
        let store = makeStore(sessions: [source, outsider])
        store.selection = source.id
        store.splitSelection(direction: .horizontal)
        store.splitSelection(direction: .vertical)
        let members = store.splitContainer(containing: source.id)!.memberIDs
        #expect(members.count == 3)

        // Close the LAST member while it's focused: generic next-row
        // fallback would leave the container (next row is "outsider"), but
        // split closes stay inside — the nearest member wins.
        store.selection = members[2]
        store.close(sessionID: members[2])
        #expect(store.selection == members[1])
    }

    @Test func movingPaneOutLeavesTheSplit() {
        let source = TerminalSession(title: "src", workingDirectory: "/tmp")
        let store = makeStore(sessions: [source])
        store.selection = source.id
        store.splitSelection(direction: .horizontal)
        let newID = store.splitContainer(containing: source.id)!.memberIDs.last!

        // Pinning relocates the row; the pane exits its container, which
        // dissolves at one member.
        store.pin([newID], inSpace: store.activeSpaceID)

        #expect(store.splitContainers.isEmpty)
        #expect(store.sessions.count == 2)
    }

    @Test func deletingSpaceDropsItsContainers() {
        let source = TerminalSession(title: "src", workingDirectory: "/tmp")
        let store = TerminalSessionStore(
            spaces: [
                SidebarSpace(name: "Main", ephemeralSessions: [source]),
                SidebarSpace(
                    name: "Other",
                    ephemeralSessions: [TerminalSession(title: "keep", workingDirectory: "~")]
                ),
            ],
            persistToDisk: false
        )
        store.selection = source.id
        store.splitSelection(direction: .horizontal)
        #expect(store.splitContainers.count == 1)

        store.deleteSpace(store.spaces[0].id)
        #expect(store.splitContainers.isEmpty)
    }
}
