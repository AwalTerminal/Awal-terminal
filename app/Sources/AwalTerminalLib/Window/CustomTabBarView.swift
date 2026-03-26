import AppKit

extension Notification.Name {
    static let tabBarOrientationDidChange = Notification.Name("tabBarOrientationDidChange")
}

protocol CustomTabBarDelegate: AnyObject {
    func tabBar(_ tabBar: CustomTabBarView, didSelectTabAt index: Int)
    func tabBar(_ tabBar: CustomTabBarView, didCloseTabAt index: Int)
    func tabBarDidRequestNewTab(_ tabBar: CustomTabBarView)
    func tabBar(_ tabBar: CustomTabBarView, didDoubleClickTabAt index: Int)
    func tabBar(_ tabBar: CustomTabBarView, didRightClickTabAt index: Int, location: NSPoint)
    func tabBar(_ tabBar: CustomTabBarView, didReorderTabFrom fromIndex: Int, to toIndex: Int)
    func tabBar(_ tabBar: CustomTabBarView, didTearOffTabAt index: Int, screenPoint: NSPoint)
    func tabBar(_ tabBar: CustomTabBarView, didToggleGroupCollapse groupID: UUID)
    func tabBar(_ tabBar: CustomTabBarView, didDragTab fromIndex: Int, intoGroup groupID: UUID)
    func tabBar(_ tabBar: CustomTabBarView, didDragTabOutOfGroup fromIndex: Int)
    func tabBar(_ tabBar: CustomTabBarView, didRenameGroup groupID: UUID, to name: String)
    func tabBar(_ tabBar: CustomTabBarView, didChangeGroupColor groupID: UUID, to color: NSColor?)
    func tabBar(_ tabBar: CustomTabBarView, didRightClickGroup groupID: UUID, location: NSPoint)
}

/// Display metadata for a single tab, computed by the controller.
struct TabDisplayInfo {
    let title: String
    let tabColor: NSColor?
    let isDangerMode: Bool
    let groupID: UUID?
    let groupColor: NSColor?
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
}

/// Display metadata for a tab group.
struct TabGroupDisplayInfo {
    let id: UUID
    let name: String
    let color: NSColor?
    let isCollapsed: Bool
    let tabCount: Int
}

final class CustomTabBarView: NSView {

    static let barHeight: CGFloat = 30.0
    static let sidebarWidth: CGFloat = 200.0

    weak var delegate: CustomTabBarDelegate?

    private(set) var selectedIndex: Int = 0
    private(set) var orientation: TabBarOrientation = .horizontal

    private var tabViews: [TabItemView] = []
    private var groupHeaderViews: [UUID: TabGroupHeaderView] = [:]
    private let stackView = NSStackView()
    private let scrollView = NSScrollView()
    /// Flipped container so vertical stack grows top-to-bottom.
    private let flippedDocumentView = FlippedView()
    private let addButton: NSButton = {
        let btn = NSButton(title: "+", target: nil, action: nil)
        btn.isBordered = false
        btn.setButtonType(.momentaryChange)
        btn.font = NSFont.systemFont(ofSize: 16, weight: .light)
        btn.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        return btn
    }()

    private let bgColor = AppConfig.shared.themeTabBarBg
    private let selectedBgColor = AppConfig.shared.themeTabActiveBg
    private let accentColor = AppConfig.shared.themeAccent

    // Drag-to-reorder state
    private var draggedTabIndex: Int?
    private var dragOrigin: NSPoint = .zero
    private let dragThreshold: CGFloat = 5.0

    // Drag ghost state
    private var dragGhostWindow: NSPanel?
    private var dragGhostTabSize: NSSize = .zero
    private var dragSourceView: TabItemView?
    private var mouseUpMonitor: Any?

    // Layout constraints for orientation switching
    private var borderView: NSView?
    private var stackClipConstraints: [NSLayoutConstraint] = []
    private var scrollConstraints: [NSLayoutConstraint] = []
    private var borderConstraints: [NSLayoutConstraint] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
        dragGhostWindow?.orderOut(nil)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = bgColor.cgColor

        stackView.spacing = 1
        stackView.translatesAutoresizingMaskIntoConstraints = false

        flippedDocumentView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // documentView is set in applyOrientation
        addSubview(scrollView)

        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.wantsLayer = true
        addButton.layer?.backgroundColor = bgColor.cgColor
        addButton.layer?.cornerRadius = 14
        addSubview(addButton)

        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        borderView = border

        applyOrientation(.horizontal)
    }

    func setOrientation(_ newOrientation: TabBarOrientation) {
        guard newOrientation != orientation else { return }
        applyOrientation(newOrientation)
    }

    private func applyOrientation(_ newOrientation: TabBarOrientation) {
        orientation = newOrientation

        // Deactivate old constraints
        NSLayoutConstraint.deactivate(stackClipConstraints)
        NSLayoutConstraint.deactivate(scrollConstraints)
        NSLayoutConstraint.deactivate(borderConstraints)

        guard let border = borderView else { return }

        switch newOrientation {
        case .horizontal:
            stackView.orientation = .horizontal
            stackView.alignment = .centerY
            scrollView.horizontalScrollElasticity = .allowed
            scrollView.verticalScrollElasticity = .none

            // In horizontal mode, use stackView directly as document view (no flip needed)
            stackView.removeFromSuperview()
            flippedDocumentView.removeFromSuperview()
            scrollView.documentView = stackView

            let clipView = scrollView.contentView
            stackClipConstraints = [
                stackView.topAnchor.constraint(equalTo: clipView.topAnchor),
                stackView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
                stackView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 12),
            ]

            scrollConstraints = [
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]

            borderConstraints = [
                border.leadingAnchor.constraint(equalTo: leadingAnchor),
                border.trailingAnchor.constraint(equalTo: trailingAnchor),
                border.bottomAnchor.constraint(equalTo: bottomAnchor),
                border.heightAnchor.constraint(equalToConstant: 1),
            ]

        case .vertical:
            stackView.orientation = .vertical
            stackView.alignment = .leading
            scrollView.horizontalScrollElasticity = .none
            scrollView.verticalScrollElasticity = .allowed

            // In vertical mode, wrap stack in flipped view so it grows top-to-bottom
            stackView.removeFromSuperview()
            flippedDocumentView.addSubview(stackView)
            scrollView.documentView = flippedDocumentView

            let docView = flippedDocumentView
            stackClipConstraints = [
                stackView.topAnchor.constraint(equalTo: docView.topAnchor),
                stackView.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
                docView.bottomAnchor.constraint(greaterThanOrEqualTo: stackView.bottomAnchor),
                docView.widthAnchor.constraint(equalToConstant: CustomTabBarView.sidebarWidth),
            ]

            scrollConstraints = [
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]

            borderConstraints = [
                border.topAnchor.constraint(equalTo: topAnchor),
                border.bottomAnchor.constraint(equalTo: bottomAnchor),
                border.trailingAnchor.constraint(equalTo: trailingAnchor),
                border.widthAnchor.constraint(equalToConstant: 1),
            ]
        }

        NSLayoutConstraint.activate(stackClipConstraints)
        NSLayoutConstraint.activate(scrollConstraints)
        NSLayoutConstraint.activate(borderConstraints)

        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateAddButtonPosition()
    }

    @objc private func addClicked() {
        delegate?.tabBarDidRequestNewTab(self)
    }

    // MARK: - Public API

    func reloadTabs(tabs: [TabDisplayInfo], selectedIndex: Int, groups: [TabGroupDisplayInfo] = []) {
        self.selectedIndex = selectedIndex

        // Remove old views
        for tv in tabViews {
            stackView.removeArrangedSubview(tv)
            tv.removeFromSuperview()
        }
        tabViews.removeAll()
        for (_, hv) in groupHeaderViews {
            stackView.removeArrangedSubview(hv)
            hv.removeFromSuperview()
        }
        groupHeaderViews.removeAll()

        // Build a set of collapsed group IDs
        let collapsedGroupIDs = Set(groups.filter { $0.isCollapsed }.map { $0.id })

        // Track which groups we've already inserted headers for
        var insertedGroups = Set<UUID>()

        for (i, info) in tabs.enumerated() {
            // Insert group header before the first tab of each group
            if let gid = info.groupID, info.isFirstInGroup {
                if let groupInfo = groups.first(where: { $0.id == gid }) {
                    let header = TabGroupHeaderView(
                        group: groupInfo,
                        orientation: orientation,
                        bgColor: bgColor
                    )
                    header.onToggleCollapse = { [weak self] groupID in
                        guard let self else { return }
                        self.delegate?.tabBar(self, didToggleGroupCollapse: groupID)
                    }
                    header.onRightClick = { [weak self] groupID, localLocation in
                        guard let self else { return }
                        let location = header.convert(localLocation, to: self)
                        self.delegate?.tabBar(self, didRightClickGroup: groupID, location: location)
                    }
                    // Add spacing before the pill
                    if let lastView = stackView.arrangedSubviews.last {
                        stackView.setCustomSpacing(6, after: lastView)
                    }
                    stackView.addArrangedSubview(header)
                    stackView.setCustomSpacing(2, after: header)
                    groupHeaderViews[gid] = header
                    insertedGroups.insert(gid)
                }
            }

            // Skip all tabs in collapsed groups
            if let gid = info.groupID, collapsedGroupIDs.contains(gid) {
                let tabItem = createTabItemView(info: info, index: i)
                tabItem.isHidden = true
                stackView.addArrangedSubview(tabItem)
                tabViews.append(tabItem)
                continue
            }

            let tabItem = createTabItemView(info: info, index: i)
            stackView.addArrangedSubview(tabItem)
            tabViews.append(tabItem)
        }

        stackView.needsLayout = true
        needsLayout = true
        scrollToSelectedTab()
    }

    private func createTabItemView(info: TabDisplayInfo, index: Int) -> TabItemView {
        let tabItem = TabItemView(
            title: info.title,
            isSelected: index == selectedIndex,
            selectedBgColor: selectedBgColor,
            accentColor: accentColor,
            bgColor: bgColor,
            tabColor: info.tabColor,
            isDangerMode: info.isDangerMode,
            orientation: orientation,
            groupColor: info.groupColor,
            isGrouped: info.groupID != nil
        )
        tabItem.index = index
        tabItem.onSelect = { [weak self] idx in
            guard let self else { return }
            self.delegate?.tabBar(self, didSelectTabAt: idx)
        }
        tabItem.onClose = { [weak self] idx in
            guard let self else { return }
            self.delegate?.tabBar(self, didCloseTabAt: idx)
        }
        tabItem.onDoubleClick = { [weak self] idx in
            guard let self else { return }
            self.delegate?.tabBar(self, didDoubleClickTabAt: idx)
        }
        tabItem.onRightClick = { [weak self] idx, location in
            guard let self else { return }
            let windowLocation = tabItem.convert(location, to: self)
            self.delegate?.tabBar(self, didRightClickTabAt: idx, location: windowLocation)
        }
        tabItem.onDragBegan = { [weak self] idx, point in
            self?.beginDrag(fromIndex: idx, point: point)
        }
        tabItem.onDragMoved = { [weak self] point in
            self?.updateDrag(point: point)
        }
        tabItem.onDragEnded = { [weak self] in
            self?.endDrag()
        }
        tabItem.onDragTornOff = { [weak self] idx, screenPoint in
            guard let self else { return }
            self.dismissDragGhost(animated: false)
            self.endDrag()
            self.delegate?.tabBar(self, didTearOffTabAt: idx, screenPoint: screenPoint)
        }
        tabItem.onDragSnapshot = { [weak self] image, screenPoint in
            self?.showDragGhost(image: image, screenPoint: screenPoint, tabSize: tabItem.bounds.size)
        }
        tabItem.onDragMovedScreen = { [weak self] screenPoint in
            self?.moveDragGhost(to: screenPoint)
        }
        return tabItem
    }

    private func scrollToSelectedTab() {
        guard selectedIndex >= 0 && selectedIndex < tabViews.count else { return }
        let tabView = tabViews[selectedIndex]
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateAddButtonPosition()
            let tabFrame = tabView.convert(tabView.bounds, to: self.stackView)
            self.scrollView.contentView.scrollToVisible(tabFrame)
        }
    }

    private func updateAddButtonPosition() {
        stackView.layoutSubtreeIfNeeded()
        let buttonSize: CGFloat = 28

        switch orientation {
        case .horizontal:
            var stackWidth: CGFloat = 0
            if let last = stackView.arrangedSubviews.last(where: { !$0.isHidden }) {
                stackWidth = last.frame.maxX
            }
            let maxX = bounds.width - 4 - buttonSize
            let buttonX = min(stackWidth + 4, maxX)
            let buttonY = round((bounds.height - buttonSize) / 2)
            addButton.frame = NSRect(x: buttonX, y: buttonY, width: buttonSize, height: buttonSize)
            scrollView.contentInsets.right = (stackWidth + buttonSize + 8 > bounds.width) ? (buttonSize + 8) : 0
            scrollView.contentInsets.bottom = 0

        case .vertical:
            let buttonX = round((bounds.width - buttonSize) / 2)
            let buttonY: CGFloat = 4
            addButton.frame = NSRect(x: buttonX, y: buttonY, width: buttonSize, height: buttonSize)
            scrollView.contentInsets.bottom = buttonSize + 8
            scrollView.contentInsets.right = 0
        }
    }

    func updateTitle(at index: Int, title: String) {
        guard index >= 0 && index < tabViews.count else { return }
        tabViews[index].updateTitle(title)
    }

    // MARK: - Drag-to-Reorder

    private func beginDrag(fromIndex: Int, point: NSPoint) {
        draggedTabIndex = fromIndex
        dragOrigin = point
        if fromIndex >= 0 && fromIndex < tabViews.count {
            dragSourceView = tabViews[fromIndex]
            dragSourceView?.alphaValue = 0.3
        }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.endDrag()
            return event
        }
    }

    private func updateDrag(point: NSPoint) {
        guard let fromIndex = draggedTabIndex, tabViews.count > 1 else { return }

        let localPoint = convert(point, from: nil)

        // Check if dragging over a group header
        for (groupID, headerView) in groupHeaderViews {
            let headerFrame = headerView.convert(headerView.bounds, to: self)
            if headerFrame.contains(localPoint) {
                delegate?.tabBar(self, didDragTab: fromIndex, intoGroup: groupID)
                return
            }
        }

        for (i, tv) in tabViews.enumerated() {
            guard !tv.isHidden else { continue }
            let tvFrame = tv.convert(tv.bounds, to: self)
            if tvFrame.contains(localPoint) && i != fromIndex {
                delegate?.tabBar(self, didReorderTabFrom: fromIndex, to: i)
                draggedTabIndex = i
                dragSourceView = tabViews[i]
                dragSourceView?.alphaValue = 0.3
                break
            }
        }
    }

    private func endDrag() {
        draggedTabIndex = nil
        dragSourceView?.alphaValue = 1.0
        dragSourceView = nil
        dismissDragGhost()
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
    }

    // MARK: - Drag Ghost

    private func showDragGhost(image: NSImage, screenPoint: NSPoint, tabSize: NSSize) {
        dismissDragGhost(animated: false)
        dragGhostTabSize = tabSize
        let ghostFrame = NSRect(
            x: screenPoint.x - tabSize.width / 2,
            y: screenPoint.y - tabSize.height / 2,
            width: tabSize.width,
            height: tabSize.height
        )
        let panel = NSPanel(
            contentRect: ghostFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.alphaValue = 0.85
        panel.ignoresMouseEvents = true

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: tabSize))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        panel.contentView = imageView

        panel.orderFront(nil)
        dragGhostWindow = panel
    }

    private func moveDragGhost(to screenPoint: NSPoint) {
        guard let ghost = dragGhostWindow else { return }
        let origin = NSPoint(
            x: screenPoint.x - dragGhostTabSize.width / 2,
            y: screenPoint.y - dragGhostTabSize.height / 2
        )
        ghost.setFrameOrigin(origin)
    }

    private func dismissDragGhost(animated: Bool = true) {
        guard let ghost = dragGhostWindow else { return }
        dragGhostWindow = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                ghost.animator().alphaValue = 0
            }, completionHandler: {
                ghost.orderOut(nil)
            })
        } else {
            ghost.orderOut(nil)
        }
    }
}

// MARK: - Flipped View (for top-to-bottom vertical stacking)

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Tab Group Header View

private class TabGroupHeaderView: NSView {

    var onToggleCollapse: ((UUID) -> Void)?
    var onRightClick: ((UUID, NSPoint) -> Void)?

    private let groupID: UUID
    private let nameLabel = NSTextField(labelWithString: "")
    private let chevron = NSTextField(labelWithString: "")
    private let isCollapsed: Bool
    private let groupColor: NSColor?
    private let orientation: TabBarOrientation
    private var headerBorderLayer: CALayer?

    init(group: TabGroupDisplayInfo, orientation: TabBarOrientation, bgColor: NSColor) {
        self.groupID = group.id
        self.isCollapsed = group.isCollapsed
        self.groupColor = group.color
        self.orientation = orientation
        super.init(frame: .zero)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)

        switch orientation {
        case .horizontal:
            setupHorizontalPill(group: group)
        case .vertical:
            setupVerticalRow(group: group, bgColor: bgColor)
        }

        // Add connecting border on the header itself
        let borderColor = (group.color ?? NSColor(white: 0.4, alpha: 1.0)).withAlphaComponent(0.85)
        let border = CALayer()
        border.backgroundColor = borderColor.cgColor
        wantsLayer = true
        layer?.addSublayer(border)
        headerBorderLayer = border
    }

    private func setupHorizontalPill(group: TabGroupDisplayInfo) {
        let pillColor = group.color ?? NSColor(white: 0.4, alpha: 1.0)
        layer?.backgroundColor = pillColor.withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = 6
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] // bottom only (layer coords)

        let displayName = isCollapsed ? "\(group.name) (\(group.tabCount))" : group.name
        nameLabel.stringValue = displayName
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CustomTabBarView.barHeight),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private var pillLayer: CALayer?

    private func setupVerticalRow(group: TabGroupDisplayInfo, bgColor: NSColor) {
        let pillColor = group.color ?? NSColor(white: 0.4, alpha: 1.0)

        // Inset colored pill sublayer
        let pill = CALayer()
        pill.backgroundColor = pillColor.withAlphaComponent(0.85).cgColor
        pill.cornerRadius = 6
        pill.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner] // left side only
        wantsLayer = true
        layer?.addSublayer(pill)
        pillLayer = pill

        chevron.stringValue = isCollapsed ? "\u{25B6}" : "\u{25BC}"
        chevron.font = NSFont.systemFont(ofSize: 8, weight: .medium)
        chevron.textColor = .white
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        let displayName = isCollapsed ? "\(group.name) (\(group.tabCount))" : group.name
        nameLabel.stringValue = displayName
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(equalToConstant: CustomTabBarView.sidebarWidth),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        if let pill = pillLayer {
            // Left inset only, flush right
            pill.frame = NSRect(x: 6, y: 0, width: bounds.width - 6, height: bounds.height)
        }
        if let border = headerBorderLayer {
            if orientation == .horizontal {
                border.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
            } else {
                border.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        onToggleCollapse?(groupID)
    }

    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onRightClick?(groupID, location)
    }

    override func mouseEntered(with event: NSEvent) {
        let pillColor = groupColor ?? NSColor(white: 0.4, alpha: 1.0)
        let target = pillLayer ?? layer
        target?.backgroundColor = pillColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        let pillColor = groupColor ?? NSColor(white: 0.4, alpha: 1.0)
        let target = pillLayer ?? layer
        target?.backgroundColor = pillColor.withAlphaComponent(0.85).cgColor
    }

}

// MARK: - Tab Item View

private class TabItemView: NSView {

    var index: Int = 0
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    var onRightClick: ((Int, NSPoint) -> Void)?
    var onDragBegan: ((Int, NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDragTornOff: ((Int, NSPoint) -> Void)?
    var onDragSnapshot: ((NSImage, NSPoint) -> Void)?
    var onDragMovedScreen: ((NSPoint) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton: NSButton = {
        let btn = NSButton(title: "\u{00D7}", target: nil, action: nil)
        btn.isBordered = false
        btn.setButtonType(.momentaryChange)
        btn.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        btn.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        return btn
    }()
    private let accentLine = NSView()
    private let isSelected: Bool
    private let selectedBgColor: NSColor
    private let accentColor: NSColor
    private let bgColor: NSColor
    private let tabColor: NSColor?
    private let effectiveBgColor: NSColor
    private let orientation: TabBarOrientation

    private var isDragging = false
    private var tornOff = false
    private var dragStartPoint: NSPoint = .zero
    private let dragThreshold: CGFloat = 5.0

    private let isDangerMode: Bool
    private var groupBorderLayer: CALayer?

    init(title: String, isSelected: Bool, selectedBgColor: NSColor, accentColor: NSColor, bgColor: NSColor, tabColor: NSColor? = nil, isDangerMode: Bool = false, orientation: TabBarOrientation = .horizontal, groupColor: NSColor? = nil, isGrouped: Bool = false) {
        self.isSelected = isSelected
        self.selectedBgColor = selectedBgColor
        self.accentColor = accentColor
        self.bgColor = bgColor
        self.tabColor = tabColor
        self.isDangerMode = isDangerMode
        self.orientation = orientation
        // Compute effective background: tab color tint, then subtle group tint
        var base = isSelected ? selectedBgColor : bgColor
        if isGrouped, let gc = groupColor {
            base = base.blended(withFraction: 0.08, of: gc) ?? base
        }
        if let tc = tabColor {
            base = base.blended(withFraction: 0.15, of: tc) ?? base
        }
        self.effectiveBgColor = base
        super.init(frame: .zero)
        setup(title: title)

        // Add group color border to visually connect tab to its group header
        if isGrouped, let gc = groupColor {
            let border = CALayer()
            border.backgroundColor = gc.withAlphaComponent(0.85).cgColor
            wantsLayer = true
            layer?.addSublayer(border)
            groupBorderLayer = border
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        if let border = groupBorderLayer {
            if orientation == .horizontal {
                // Top border
                border.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
            } else {
                // Right border
                border.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
            }
        }
    }

    private static func textColor(for bgColor: NSColor, isSelected: Bool, hasTabColor: Bool) -> NSColor {
        guard hasTabColor else {
            return isSelected ? NSColor(white: 0.85, alpha: 1.0) : NSColor(white: 0.5, alpha: 1.0)
        }
        let rgb = bgColor.usingColorSpace(.sRGB) ?? bgColor
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        let alpha: CGFloat = isSelected ? 0.85 : 0.6
        return luminance > 0.5
            ? NSColor(white: 0.0, alpha: alpha)
            : NSColor(white: 1.0, alpha: alpha)
    }

    private func setup(title: String) {
        wantsLayer = true
        layer?.backgroundColor = effectiveBgColor.cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = Self.textColor(for: effectiveBgColor, isSelected: isSelected, hasTabColor: tabColor != nil)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.stringValue = title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.alphaValue = 0
        addSubview(closeButton)

        accentLine.wantsLayer = true
        let dangerColor = NSColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 1.0)
        let lineColor = isDangerMode ? dangerColor : (tabColor ?? accentColor)
        accentLine.layer?.backgroundColor = isSelected ? lineColor.cgColor : (isDangerMode ? dangerColor.withAlphaComponent(0.5).cgColor : NSColor.clear.cgColor)
        accentLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentLine)

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)

        switch orientation {
        case .horizontal:
            NSLayoutConstraint.activate([
                widthAnchor.constraint(lessThanOrEqualToConstant: 180),
                widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
                heightAnchor.constraint(equalToConstant: CustomTabBarView.barHeight),

                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                closeButton.widthAnchor.constraint(equalToConstant: 18),
                closeButton.heightAnchor.constraint(equalToConstant: 18),

                accentLine.leadingAnchor.constraint(equalTo: leadingAnchor),
                accentLine.trailingAnchor.constraint(equalTo: trailingAnchor),
                accentLine.bottomAnchor.constraint(equalTo: bottomAnchor),
                accentLine.heightAnchor.constraint(equalToConstant: 2),
            ])

        case .vertical:
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: CustomTabBarView.sidebarWidth),
                heightAnchor.constraint(equalToConstant: CustomTabBarView.barHeight),

                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                closeButton.widthAnchor.constraint(equalToConstant: 18),
                closeButton.heightAnchor.constraint(equalToConstant: 18),

                // Accent line on left edge for vertical
                accentLine.leadingAnchor.constraint(equalTo: leadingAnchor),
                accentLine.topAnchor.constraint(equalTo: topAnchor),
                accentLine.bottomAnchor.constraint(equalTo: bottomAnchor),
                accentLine.widthAnchor.constraint(equalToConstant: 2),
            ])
        }
    }

    @objc private func closeClicked() {
        onClose?(index)
    }

    func updateTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = event.locationInWindow
        isDragging = false
        tornOff = false
        if event.clickCount == 2 {
            onDoubleClick?(index)
        } else {
            onSelect?(index)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let current = event.locationInWindow
        let dx = abs(current.x - dragStartPoint.x)
        let dy = abs(current.y - dragStartPoint.y)

        let dragAxis = orientation == .horizontal ? dx : dy
        let tearAxis = orientation == .horizontal ? dy : dx

        if !isDragging && !tornOff && dragAxis > dragThreshold {
            isDragging = true
            if let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) {
                cacheDisplay(in: bounds, to: bitmapRep)
                let image = NSImage(size: bounds.size)
                image.addRepresentation(bitmapRep)
                let screenOrigin = window?.convertPoint(toScreen: current) ?? .zero
                onDragSnapshot?(image, screenOrigin)
            }
            onDragBegan?(index, event.locationInWindow)
        }

        if isDragging || tornOff {
            if let screenPoint = window?.convertPoint(toScreen: current) {
                onDragMovedScreen?(screenPoint)
            }
        }

        if tearAxis > 30 && !tornOff {
            tornOff = true
            isDragging = false
            if let screenPoint = window?.convertPoint(toScreen: current) {
                onDragTornOff?(index, screenPoint)
            }
            return
        }

        if isDragging {
            onDragMoved?(event.locationInWindow)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            onDragEnded?()
            isDragging = false
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onRightClick?(index, location)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isSelected {
            if tabColor != nil {
                layer?.backgroundColor = (effectiveBgColor.blended(withFraction: 0.1, of: .white) ?? effectiveBgColor).cgColor
            } else {
                layer?.backgroundColor = NSColor(red: 30.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1.0).cgColor
            }
        }
        closeButton.alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        if !isSelected {
            layer?.backgroundColor = effectiveBgColor.cgColor
        }
        closeButton.alphaValue = 0
    }
}
