#if DEBUG
import AppKit

/// A debug-only log console panel displayed at the bottom of the terminal window.
final class DebugConsoleView: NSView {
    static let defaultHeight: CGFloat = 200.0
    private static let maxLines = 10_000

    private(set) var isPanelVisible = false

    private let headerStack = NSStackView()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        observer = NotificationCenter.default.addObserver(
            forName: DebugLogCollector.logDidAppend,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let entry = notification.userInfo?["entry"] as? String {
                self?.appendLog(entry)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Visibility

    func toggle() {
        isPanelVisible ? hide() : show()
    }

    func show() {
        isPanelVisible = true
        // Load existing entries
        let existing = DebugLogCollector.shared.entries
        if !existing.isEmpty && (textView.string.isEmpty) {
            let text = existing.joined(separator: "\n") + "\n"
            textView.textStorage?.append(NSAttributedString(string: text, attributes: Self.textAttributes))
            scrollToBottom()
        }
    }

    func hide() {
        isPanelVisible = false
    }

    // MARK: - Log Management

    func appendLog(_ entry: String) {
        guard isPanelVisible else { return }

        let shouldAutoScroll = isScrolledToBottom
        textView.textStorage?.append(NSAttributedString(string: entry + "\n", attributes: Self.textAttributes))
        trimIfNeeded()

        if shouldAutoScroll {
            scrollToBottom()
        }
    }

    func clear() {
        textView.string = ""
        DebugLogCollector.shared.clear()
    }

    func copyAll() {
        let text = textView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Private

    private var isScrolledToBottom: Bool {
        let visibleRect = scrollView.contentView.bounds
        let contentHeight = scrollView.documentView?.frame.height ?? 0
        return visibleRect.maxY >= contentHeight - 20
    }

    private func scrollToBottom() {
        let length = textView.string.count
        textView.scrollRangeToVisible(NSRange(location: length, length: 0))
    }

    private func trimIfNeeded() {
        let lines = textView.string.components(separatedBy: "\n")
        guard lines.count > Self.maxLines else { return }
        let trimCount = lines.count / 2
        let trimmedLines = Array(lines.dropFirst(trimCount))
        let newText = trimmedLines.joined(separator: "\n")
        textView.string = ""
        textView.textStorage?.append(NSAttributedString(string: newText, attributes: Self.textAttributes))
        DebugLogCollector.shared.entries = Array(DebugLogCollector.shared.entries.dropFirst(trimCount))
    }

    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(white: 0.78, alpha: 1.0),
    ]

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1.0).cgColor

        translatesAutoresizingMaskIntoConstraints = false

        // Header
        let titleLabel = NSTextField(labelWithString: "Debug Console")
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.6, alpha: 1.0)

        let clearButton = makeButton(title: "Clear", action: #selector(clearAction))
        let copyButton = makeButton(title: "Copy", action: #selector(copyAction))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8
        headerStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(spacer)
        headerStack.addArrangedSubview(clearButton)
        headerStack.addArrangedSubview(copyButton)
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        // Separator
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.1).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Scroll view + text view
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.backgroundColor = NSColor(white: 0.1, alpha: 1.0)
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerStack)
        addSubview(separator)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerStack.heightAnchor.constraint(equalToConstant: 26),

            separator.topAnchor.constraint(equalTo: headerStack.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .recessed
        button.isBordered = true
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        return button
    }

    @objc private func clearAction() { clear() }
    @objc private func copyAction() { copyAll() }
}
#endif
