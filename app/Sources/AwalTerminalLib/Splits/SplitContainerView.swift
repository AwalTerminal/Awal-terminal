import AppKit

class SplitContainerView: NSView, NSSplitViewDelegate {

    private(set) var rootNode: SplitNode
    private(set) var focusedTerminal: TerminalView

    var onFocusChanged: ((_ terminal: TerminalView) -> Void)?

    init(rootTerminal: TerminalView) {
        self.rootNode = .leaf(rootTerminal)
        self.focusedTerminal = rootTerminal
        super.init(frame: .zero)
        wantsLayer = true
        rebuild()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Public API

    func splitFocused(direction: SplitDirection, newTerminal: TerminalView) {
        rootNode = rootNode.splitLeaf(target: focusedTerminal, direction: direction, newTerminal: newTerminal)
        rebuild()
        setFocused(newTerminal)
    }

    /// Close focused pane. Returns true if there are remaining panes, false if the last pane was closed.
    func closeFocused() -> Bool {
        let leaves = rootNode.allLeaves()
        guard leaves.count > 1 else { return false }

        let target = focusedTerminal
        target.cleanup()
        guard let newRoot = rootNode.removeLeaf(target: target) else { return false }
        rootNode = newRoot

        // Focus next available pane
        let remaining = rootNode.allLeaves()
        if let next = remaining.first {
            rebuild()
            setFocused(next)
        }

        return true
    }

    /// Cleanup all terminal panes (call before removing the tab).
    func cleanupAllTerminals() {
        for terminal in rootNode.allLeaves() {
            terminal.cleanup()
        }
    }

    func focusNext() {
        let leaves = rootNode.allLeaves()
        guard leaves.count > 1 else { return }
        if let idx = leaves.firstIndex(where: { $0 === focusedTerminal }) {
            let next = leaves[(idx + 1) % leaves.count]
            setFocused(next)
        }
    }

    func focusPrevious() {
        let leaves = rootNode.allLeaves()
        guard leaves.count > 1 else { return }
        if let idx = leaves.firstIndex(where: { $0 === focusedTerminal }) {
            let prev = leaves[(idx - 1 + leaves.count) % leaves.count]
            setFocused(prev)
        }
    }

    func setFocused(_ terminal: TerminalView) {
        let old = focusedTerminal
        focusedTerminal = terminal

        let showBorder = rootNode.allLeaves().count > 1
        old.setFocused(false)
        terminal.setFocused(showBorder)

        window?.makeFirstResponder(terminal)
        onFocusChanged?(terminal)
    }

    // MARK: - Rebuild View Hierarchy

    func rebuild() {
        // Remove all subviews
        subviews.forEach { $0.removeFromSuperview() }

        let built = buildView(from: rootNode)
        built.translatesAutoresizingMaskIntoConstraints = false
        addSubview(built)

        NSLayoutConstraint.activate([
            built.leadingAnchor.constraint(equalTo: leadingAnchor),
            built.trailingAnchor.constraint(equalTo: trailingAnchor),
            built.topAnchor.constraint(equalTo: topAnchor),
            built.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func buildView(from node: SplitNode) -> NSView {
        switch node {
        case .leaf(let terminal):
            terminal.translatesAutoresizingMaskIntoConstraints = false
            return terminal

        case .split(let direction, let first, let second):
            let splitView = NSSplitView()
            splitView.translatesAutoresizingMaskIntoConstraints = false
            splitView.isVertical = (direction == .horizontal) // NSSplitView.isVertical means side-by-side
            splitView.dividerStyle = .thin
            splitView.delegate = self

            let firstView = buildView(from: first)
            let secondView = buildView(from: second)

            splitView.addSubview(firstView)
            splitView.addSubview(secondView)

            return splitView
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return proposedMinimumPosition + 100
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return proposedMaximumPosition - 100
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let subviews = splitView.subviews
        guard subviews.count == 2 else {
            splitView.adjustSubviews()
            return
        }
        let dividerThickness = splitView.dividerThickness
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let available = total - dividerThickness
        let half = floor(available / 2)

        if splitView.isVertical {
            subviews[0].frame = NSRect(x: 0, y: 0, width: half, height: splitView.bounds.height)
            subviews[1].frame = NSRect(x: half + dividerThickness, y: 0, width: available - half, height: splitView.bounds.height)
        } else {
            subviews[0].frame = NSRect(x: 0, y: 0, width: splitView.bounds.width, height: half)
            subviews[1].frame = NSRect(x: 0, y: half + dividerThickness, width: splitView.bounds.width, height: available - half)
        }
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        return true
    }
}
