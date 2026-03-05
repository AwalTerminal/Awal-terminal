import AppKit

protocol CustomTabBarDelegate: AnyObject {
    func tabBar(_ tabBar: CustomTabBarView, didSelectTabAt index: Int)
    func tabBar(_ tabBar: CustomTabBarView, didCloseTabAt index: Int)
    func tabBarDidRequestNewTab(_ tabBar: CustomTabBarView)
    func tabBar(_ tabBar: CustomTabBarView, didDoubleClickTabAt index: Int)
    func tabBar(_ tabBar: CustomTabBarView, didRightClickTabAt index: Int, location: NSPoint)
}

class CustomTabBarView: NSView {

    static let barHeight: CGFloat = 30.0

    weak var delegate: CustomTabBarDelegate?

    private(set) var selectedIndex: Int = 0
    private var tabViews: [TabItemView] = []
    private let stackView = NSStackView()
    private let addButton: NSButton = {
        let btn = NSButton(title: "+", target: nil, action: nil)
        btn.isBordered = false
        btn.setButtonType(.momentaryChange)
        btn.font = NSFont.systemFont(ofSize: 16, weight: .light)
        btn.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        return btn
    }()

    private let bgColor = NSColor(red: 22.0/255.0, green: 22.0/255.0, blue: 22.0/255.0, alpha: 1.0)
    private let selectedBgColor = NSColor(red: 35.0/255.0, green: 35.0/255.0, blue: 35.0/255.0, alpha: 1.0)
    private let accentColor = NSColor(red: 99.0/255.0, green: 102.0/255.0, blue: 241.0/255.0, alpha: 1.0)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = bgColor.cgColor

        stackView.orientation = .horizontal
        stackView.spacing = 1
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        // Bottom border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            addButton.leadingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: 4),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 28),
            addButton.heightAnchor.constraint(equalToConstant: 28),

            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @objc private func addClicked() {
        delegate?.tabBarDidRequestNewTab(self)
    }

    // MARK: - Public API

    func reloadTabs(titles: [String], selectedIndex: Int) {
        self.selectedIndex = selectedIndex

        // Remove old tab views
        for tv in tabViews {
            stackView.removeArrangedSubview(tv)
            tv.removeFromSuperview()
        }
        tabViews.removeAll()

        // Create new tab views
        for (i, title) in titles.enumerated() {
            let tabItem = TabItemView(
                title: title,
                isSelected: i == selectedIndex,
                selectedBgColor: selectedBgColor,
                accentColor: accentColor,
                bgColor: bgColor
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
            stackView.addArrangedSubview(tabItem)
            tabViews.append(tabItem)
        }
    }

    func updateTitle(at index: Int, title: String) {
        guard index >= 0 && index < tabViews.count else { return }
        tabViews[index].updateTitle(title)
    }
}

// MARK: - Tab Item View

private class TabItemView: NSView {

    var index: Int = 0
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    var onRightClick: ((Int, NSPoint) -> Void)?

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
    private let isSelected: Bool
    private let selectedBgColor: NSColor
    private let accentColor: NSColor
    private let bgColor: NSColor

    init(title: String, isSelected: Bool, selectedBgColor: NSColor, accentColor: NSColor, bgColor: NSColor) {
        self.isSelected = isSelected
        self.selectedBgColor = selectedBgColor
        self.accentColor = accentColor
        self.bgColor = bgColor
        super.init(frame: .zero)
        setup(title: title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup(title: String) {
        wantsLayer = true
        layer?.backgroundColor = isSelected ? selectedBgColor.cgColor : bgColor.cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = isSelected ? NSColor(white: 0.85, alpha: 1.0) : NSColor(white: 0.5, alpha: 1.0)
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
        accentLine.layer?.backgroundColor = isSelected ? accentColor.cgColor : NSColor.clear.cgColor
        accentLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentLine)

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
        if event.clickCount == 2 {
            onDoubleClick?(index)
        } else {
            onSelect?(index)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onRightClick?(index, location)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isSelected {
            layer?.backgroundColor = NSColor(red: 30.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1.0).cgColor
        }
        closeButton.alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        if !isSelected {
            layer?.backgroundColor = bgColor.cgColor
        }
        closeButton.alphaValue = 0
    }
}
