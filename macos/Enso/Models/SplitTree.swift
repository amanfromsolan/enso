import Foundation

/// How a split divides its region. Matches Ghostty's convention:
/// `horizontal` lays panes out left/right (⌘D "Split Right"),
/// `vertical` stacks them top/bottom (⇧⌘D "Split Down").
enum SplitDirection: String, Codable, Hashable {
    case horizontal
    case vertical
}

/// A binary split tree over sessions. Every leaf IS a real tab
/// (TerminalSession) — Enso has no hidden secondary surfaces, so the tree
/// stores only session IDs and the layout metadata between them.
indirect enum SplitNode: Codable, Hashable {
    case leaf(TerminalSession.ID)
    case split(SplitBranch)
}

struct SplitBranch: Codable, Hashable {
    var direction: SplitDirection
    /// The first child's share of the region, clamped to keep both panes
    /// usable. First = left for horizontal, top for vertical.
    var ratio: Double
    var first: SplitNode
    var second: SplitNode

    static let minRatio = 0.1
    static let maxRatio = 0.9

    static func clampRatio(_ ratio: Double) -> Double {
        min(Self.maxRatio, max(Self.minRatio, ratio))
    }
}

/// The address of a node inside the tree; the layout view carries one per
/// divider so a drag knows which split's ratio to move.
struct SplitPath: Codable, Hashable {
    enum Branch: Codable, Hashable {
        case first
        case second
    }

    var components: [Branch] = []

    func appending(_ branch: Branch) -> SplitPath {
        SplitPath(components: components + [branch])
    }
}

extension SplitNode {
    /// All member sessions, in-order (left-to-right, top-to-bottom).
    var leafIDs: [TerminalSession.ID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(let branch):
            return branch.first.leafIDs + branch.second.leafIDs
        }
    }

    func contains(_ id: TerminalSession.ID) -> Bool {
        switch self {
        case .leaf(let leafID):
            return leafID == id
        case .split(let branch):
            return branch.first.contains(id) || branch.second.contains(id)
        }
    }

    /// Replaces the target leaf with a split of (target, new). The new pane
    /// always lands second — to the right of / below the pane being split.
    /// Returns nil when the target isn't in this subtree.
    func inserting(
        _ newID: TerminalSession.ID,
        splitting targetID: TerminalSession.ID,
        direction: SplitDirection
    ) -> SplitNode? {
        switch self {
        case .leaf(let id):
            guard id == targetID else { return nil }
            return .split(SplitBranch(
                direction: direction,
                ratio: 0.5,
                first: .leaf(targetID),
                second: .leaf(newID)
            ))
        case .split(var branch):
            if let replaced = branch.first.inserting(newID, splitting: targetID, direction: direction) {
                branch.first = replaced
                return .split(branch)
            }
            if let replaced = branch.second.inserting(newID, splitting: targetID, direction: direction) {
                branch.second = replaced
                return .split(branch)
            }
            return nil
        }
    }

    /// Removes a leaf; the sibling absorbs the parent split's whole region.
    /// Returns nil when removing this node itself empties the subtree.
    func removing(_ id: TerminalSession.ID) -> SplitNode? {
        switch self {
        case .leaf(let leafID):
            return leafID == id ? nil : self
        case .split(var branch):
            if case .leaf(id) = branch.first {
                return branch.second
            }
            if case .leaf(id) = branch.second {
                return branch.first
            }
            branch.first = branch.first.removing(id) ?? branch.first
            branch.second = branch.second.removing(id) ?? branch.second
            return .split(branch)
        }
    }

    /// Rewrites the ratio of the split at the given path; a stale path
    /// (tree changed under a drag) is a no-op.
    func updatingRatio(at path: SplitPath, to ratio: Double) -> SplitNode {
        updatingRatio(components: path.components[...], to: SplitBranch.clampRatio(ratio))
    }

    private func updatingRatio(
        components: ArraySlice<SplitPath.Branch>,
        to ratio: Double
    ) -> SplitNode {
        guard case .split(var branch) = self else { return self }
        guard let head = components.first else {
            branch.ratio = ratio
            return .split(branch)
        }
        switch head {
        case .first:
            branch.first = branch.first.updatingRatio(components: components.dropFirst(), to: ratio)
        case .second:
            branch.second = branch.second.updatingRatio(components: components.dropFirst(), to: ratio)
        }
        return .split(branch)
    }
}

/// A sidebar container: the group of tabs participating in one split
/// layout. Membership is exactly the tree's leaves; the sidebar renders
/// members as a flat stack regardless of split geometry.
struct SplitContainer: Identifiable, Codable, Hashable {
    let id: UUID
    var tree: SplitNode

    init(id: UUID = UUID(), tree: SplitNode) {
        self.id = id
        self.tree = tree
    }

    var memberIDs: [TerminalSession.ID] {
        tree.leafIDs
    }
}
