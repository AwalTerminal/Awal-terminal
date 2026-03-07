import AppKit
import CAwalTerminal

class SearchBarView: NSView, NSTextFieldDelegate {

    var onClose: (() -> Void)?
    var onSearchChanged: ((String) -> Void)?
    var onNextMatch: (() -> Void)?
    var onPrevMatch: (() -> Void)?

    private let searchField: NSTextField = {
        let field = NSTextField()
        field.placeholderString = "Search…"
        field.font = NSFont.systemFont(ofSize: 12)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        return field
    }()

    private let matchLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor(white: 0.5, alpha: 1)
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        return label
    }()

    private let prevButton: NSButton = {
        let btn = NSButton(title: "↑", target: nil, action: nil)
        btn.isBordered = false
        btn.setButtonType(.momentaryChange)
        btn.font = NSFont.systemFont(ofSize: 14)
        btn.contentTintColor = NSColor(white: 0.6, alpha: 1)
        return btn
    }()

    private let nextButton: NSButton = {
        let btn = NSButton(title: "↓", target: nil, action: nil)
        btn.isBordered = false
        btn.setButtonType(.momentaryChange)
        btn.font = NSFont.systemFont(ofSize: 14)
        btn.contentTintColor = NSColor(white: 0.6, alpha: 1)
        return btn
    }()

    private let closeButton: NSButton = {
        let btn = NSButton(title: "×", target: nil, action: nil)
        btn.isBordered = false
        btn.setButtonType(.momentaryChange)
        btn.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        btn.contentTintColor = NSColor(white: 0.5, alpha: 1)
        return btn
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 0.95).cgColor
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.1).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6

        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(matchLabel)

        prevButton.target = self
        prevButton.action = #selector(prevClicked)
        prevButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(prevButton)

        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nextButton)

        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),

            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 200),

            matchLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            matchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            prevButton.leadingAnchor.constraint(equalTo: matchLabel.trailingAnchor, constant: 4),
            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 24),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 24),

            closeButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    func activate() {
        searchField.stringValue = ""
        matchLabel.stringValue = ""
        window?.makeFirstResponder(searchField)
    }

    func setQuery(_ query: String) {
        searchField.stringValue = query
        onSearchChanged?(query)
    }

    func updateMatchCount(current: Int, total: Int) {
        if total == 0 {
            matchLabel.stringValue = searchField.stringValue.isEmpty ? "" : "No matches"
        } else {
            matchLabel.stringValue = "\(current)/\(total)"
        }
    }

    @objc private func prevClicked() { onPrevMatch?() }
    @objc private func nextClicked() { onNextMatch?() }
    @objc private func closeClicked() { onClose?() }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        onSearchChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            // Enter -> next match
            if NSEvent.modifierFlags.contains(.shift) {
                onPrevMatch?()
            } else {
                onNextMatch?()
            }
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            // Escape -> close
            onClose?()
            return true
        }
        return false
    }
}
