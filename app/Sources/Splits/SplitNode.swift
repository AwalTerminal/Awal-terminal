import AppKit

enum SplitDirection {
    case horizontal // left | right
    case vertical   // top / bottom
}

indirect enum SplitNode {
    case leaf(TerminalView)
    case split(SplitDirection, SplitNode, SplitNode)

    /// Replace a target leaf with a split containing old leaf + new terminal.
    func splitLeaf(target: TerminalView, direction: SplitDirection, newTerminal: TerminalView) -> SplitNode {
        switch self {
        case .leaf(let view):
            if view === target {
                return .split(direction, .leaf(view), .leaf(newTerminal))
            }
            return self

        case .split(let dir, let first, let second):
            return .split(dir,
                          first.splitLeaf(target: target, direction: direction, newTerminal: newTerminal),
                          second.splitLeaf(target: target, direction: direction, newTerminal: newTerminal))
        }
    }

    /// Remove a target leaf and promote its sibling. Returns nil if this node is the target leaf itself.
    func removeLeaf(target: TerminalView) -> SplitNode? {
        switch self {
        case .leaf(let view):
            return view === target ? nil : self

        case .split(let dir, let first, let second):
            let newFirst = first.removeLeaf(target: target)
            let newSecond = second.removeLeaf(target: target)

            if newFirst == nil { return newSecond }
            if newSecond == nil { return newFirst }

            return .split(dir, newFirst!, newSecond!)
        }
    }

    /// Ordered list of all terminal views (left-to-right / top-to-bottom).
    func allLeaves() -> [TerminalView] {
        switch self {
        case .leaf(let view):
            return [view]
        case .split(_, let first, let second):
            return first.allLeaves() + second.allLeaves()
        }
    }
}
