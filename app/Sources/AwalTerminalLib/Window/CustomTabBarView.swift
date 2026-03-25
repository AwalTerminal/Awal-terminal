import AppKit

protocol CustomTabBarDelegate: AnyObject {
    func tabBar(_ tabBar: CustomTabBarView, didSelectTabAt index: Int)
    func tabBar(_ tabBar: CustomTabBarView, didCloseTabAt index: Int)
    func tabBarDidRequestNewTab(_ tabBar: CustomTabBarView)
    func tabBar(_ tabBar: CustomTabBarView, didDoubleClickTabAt index: Int)
    func tabBar(_ tabBar: CustomTabBarView, didRightClickTabAt index: Int, location: NSPoint)
    func tabBar(_ tabBar: CustomTabBarView, didReorderTabFrom fromIndex: Int, to toIndex: Int)
    func tabBar(_ tabBar: CustomTabBarView, didTearOffTabAt index: Int, screenPoint: NSPoint)
}

final class CustomTabBarView: NSView {

    static let barHeight: CGFloat = 30.0

    weak var delegate: CustomTabBarDelegate?

    private(set) var selectedIndex: Int = 0
    private var tabViews: [TabItemView] = []
    private let stackView = NSStackView()
    private let scrollView = NSScrollView()
    private let addButton: NSButton = {
        let btn = NSButton(title: "+", target: nil, action: nil)
        btn.isBordered = false
        btn.setButtonType(.momentaryChange)
        btn.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        btn.contentTintColor = NSColor(white: 0.85, alpha: 1.0)
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

        // Frosted glass background
        let vibrancy = NSVisualEffectView()
        vibrancy.material = .hudWindow
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vibrancy, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            vibrancy.leadingAnchor.constraint(equalTo: leadingAnchor),
            vibrancy.trailingAnchor.constraint(equalTo: trailingAnchor),
            vibrancy.topAnchor.constraint(equalTo: topAnchor),
            vibrancy.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stackView.orientation = .horizontal
        stackView.spacing = 1
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Wrap stackView in a scroll view for horizontal scrolling
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView
        addSubview(scrollView)

        // Pin stack view edges inside the scroll view's clip view
        let clipView = scrollView.contentView
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: clipView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
        ])

        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.wantsLayer = true
        addButton.layer?.backgroundColor = NSColor.clear.cgColor
        addButton.layer?.cornerRadius = 14
        // Position managed manually in layout()
        addSubview(addButton)

        // Bottom border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    override func layout() {
        super.layout()
        updateAddButtonPosition()
    }

    @objc private func addClicked() {
        delegate?.tabBarDidRequestNewTab(self)
    }

    // MARK: - Public API

    func reloadTabs(titles: [String], selectedIndex: Int, tabColors: [NSColor?] = [], dangerFlags: [Bool] = []) {
        self.selectedIndex = selectedIndex

        // Remove old tab views
        for tv in tabViews {
            stackView.removeArrangedSubview(tv)
            tv.removeFromSuperview()
        }
        tabViews.removeAll()

        // Create new tab views
        for (i, title) in titles.enumerated() {
            let tabColor = i < tabColors.count ? tabColors[i] : nil
            let isDanger = i < dangerFlags.count ? dangerFlags[i] : false
            let tabItem = TabItemView(
                title: title,
                isSelected: i == selectedIndex,
                selectedBgColor: selectedBgColor,
                accentColor: accentColor,
                bgColor: bgColor,
                tabColor: tabColor,
                isDangerMode: isDanger
            )
            tabItem.index = i
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
                // Dismiss ghost immediately — a real window replaces it
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
            stackView.addArrangedSubview(tabItem)
            tabViews.append(tabItem)
        }

        // Force layout to recalculate stack width before positioning the + button
        stackView.needsLayout = true
        needsLayout = true

        // Auto-scroll to the selected tab after layout
        scrollToSelectedTab()
    }

    private func scrollToSelectedTab() {
        guard selectedIndex >= 0 && selectedIndex < tabViews.count else { return }
        let tabView = tabViews[selectedIndex]
        // Delay to ensure layout is complete
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateAddButtonPosition()
            let tabFrame = tabView.convert(tabView.bounds, to: self.stackView)
            self.scrollView.contentView.scrollToVisible(tabFrame)
        }
    }

    private func updateAddButtonPosition() {
        stackView.layoutSubtreeIfNeeded()
        // Use the union of arranged subview frames for accurate width after add/remove
        var stackWidth: CGFloat = 0
        if let last = stackView.arrangedSubviews.last {
            stackWidth = last.frame.maxX
        }
        let buttonSize: CGFloat = 28
        let maxX = bounds.width - 4 - buttonSize
        let buttonX = min(stackWidth + 4, maxX)
        let buttonY = round((bounds.height - buttonSize) / 2)
        addButton.frame = NSRect(x: buttonX, y: buttonY, width: buttonSize, height: buttonSize)
        scrollView.contentInsets.right = (stackWidth + buttonSize + 8 > bounds.width) ? (buttonSize + 8) : 0
    }

    func updateTitle(at index: Int, title: String) {
        guard index >= 0 && index < tabViews.count else { return }
        tabViews[index].updateTitle(title)
    }

    // MARK: - Drag-to-Reorder

    private func beginDrag(fromIndex: Int, point: NSPoint) {
        draggedTabIndex = fromIndex
        dragOrigin = point
        // Fade the source tab to indicate it's being moved
        if fromIndex >= 0 && fromIndex < tabViews.count {
            dragSourceView = tabViews[fromIndex]
            dragSourceView?.alphaValue = 0.3
        }
        // Monitor for mouseUp to ensure cleanup even if the tab view is
        // replaced during reorder (removed views don't receive mouseUp)
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.endDrag()
            return event
        }
    }

    private func updateDrag(point: NSPoint) {
        guard let fromIndex = draggedTabIndex, tabViews.count > 1 else { return }

        // Find which tab the cursor is over
        let localPoint = convert(point, from: nil)
        for (i, tv) in tabViews.enumerated() {
            let tvFrame = tv.convert(tv.bounds, to: self)
            if tvFrame.contains(localPoint) && i != fromIndex {
                delegate?.tabBar(self, didReorderTabFrom: fromIndex, to: i)
                draggedTabIndex = i
                // Update source view reference after reorder
                dragSourceView = tabViews[i]
                dragSourceView?.alphaValue = 0.3
                break
            }
        }
    }

    private func endDrag() {
        draggedTabIndex = nil
        // Restore source tab opacity
        dragSourceView?.alphaValue = 1.0
        dragSourceView = nil
        // Fade out and dismiss ghost window
        dismissDragGhost()
        // Remove mouseUp monitor
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
    }

    // MARK: - Drag Ghost

    private func showDragGhost(image: NSImage, screenPoint: NSPoint, tabSize: NSSize) {
        // Clean up any leftover ghost from a previous drag
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
        let btn = NSButton(title: "×", target: nil, action: nil)
        btn.isBordered = false
        btn.setButtonType(.momentaryChange)
        btn.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        btn.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        return btn
    }()
    private let accentLine = NSView()
    private let glowView = NSView()
    private let isSelected: Bool
    private let selectedBgColor: NSColor
    private let accentColor: NSColor
    private let bgColor: NSColor
    private let tabColor: NSColor?
    private let effectiveBgColor: NSColor

    private var isDragging = false
    private var tornOff = false
    private var dragStartPoint: NSPoint = .zero
    private let dragThreshold: CGFloat = 5.0

    private let isDangerMode: Bool

    init(title: String, isSelected: Bool, selectedBgColor: NSColor, accentColor: NSColor, bgColor: NSColor, tabColor: NSColor? = nil, isDangerMode: Bool = false) {
        self.isSelected = isSelected
        self.selectedBgColor = selectedBgColor
        self.accentColor = accentColor
        self.bgColor = bgColor
        self.tabColor = tabColor
        self.isDangerMode = isDangerMode
        // Compute effective background with subtle color tint
        if let tc = tabColor {
            let base = isSelected ? selectedBgColor : bgColor
            self.effectiveBgColor = base.blended(withFraction: 0.15, of: tc) ?? base
        } else {
            self.effectiveBgColor = isSelected ? selectedBgColor : bgColor
        }
        super.init(frame: .zero)
        setup(title: title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
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

        // Active tab glow — gradient radiating upward from accent line
        glowView.wantsLayer = true
        glowView.translatesAutoresizingMaskIntoConstraints = false
        let gradientLayer = CAGradientLayer()
        gradientLayer.colors = [
            lineColor.withAlphaComponent(0.85).cgColor,
            lineColor.withAlphaComponent(0.0).cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        glowView.layer = gradientLayer
        glowView.isHidden = !isSelected
        addSubview(glowView, positioned: .below, relativeTo: accentLine)

        if isSelected {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.3
            pulse.toValue = 1.0
            pulse.duration = 2.0
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glowView.layer?.add(pulse, forKey: "glowPulse")
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)

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

            glowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glowView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glowView.heightAnchor.constraint(equalToConstant: 30),
        ])
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

        if !isDragging && !tornOff && dx > dragThreshold {
            isDragging = true
            // Capture snapshot of this tab for ghost preview
            if let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) {
                cacheDisplay(in: bounds, to: bitmapRep)
                let image = NSImage(size: bounds.size)
                image.addRepresentation(bitmapRep)
                let screenOrigin = window?.convertPoint(toScreen: current) ?? .zero
                onDragSnapshot?(image, screenOrigin)
            }
            onDragBegan?(index, event.locationInWindow)
        }

        // Send screen coordinates on every drag event
        if isDragging || tornOff {
            if let screenPoint = window?.convertPoint(toScreen: current) {
                onDragMovedScreen?(screenPoint)
            }
        }

        // Vertical tearoff: if dragged far enough vertically, tear off the tab
        if dy > 30 && !tornOff {
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
                // Slightly brighten the tinted background on hover
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
