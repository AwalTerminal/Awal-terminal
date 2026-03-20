import AppKit

/// Popup view showing autocomplete suggestions below the cursor.
class CompletionPopupView: NSView {

    var onAccept: ((Completion) -> Void)?
    var onDismiss: (() -> Void)?

    private(set) var completions: [Completion] = []
    private(set) var selectedIndex: Int = 0
    private(set) var isVisible: Bool = false

    private let maxVisibleRows = 8
    private let rowHeight: CGFloat = 24
    private let popupWidth: CGFloat = 320

    private var rows: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.98).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -4)
        isHidden = true
    }

    /// Pass through mouse events to the terminal view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    /// Show completions at the given position (in superview coordinates).
    func show(completions: [Completion], at point: NSPoint) {
        guard !completions.isEmpty else {
            hide()
            return
        }
        self.completions = completions
        self.selectedIndex = 0
        self.isVisible = true

        let visibleCount = min(completions.count, maxVisibleRows)
        let height = CGFloat(visibleCount) * rowHeight + 4 // 2px padding top/bottom

        frame = NSRect(x: point.x, y: point.y - height, width: popupWidth, height: height)

        rebuildRows()
        isHidden = false
    }

    func hide() {
        isHidden = true
        isVisible = false
        completions = []
        rows.forEach { $0.removeFromSuperview() }
        rows = []
    }

    func selectNext() {
        guard !completions.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % completions.count
        rebuildRows()
    }

    func selectPrevious() {
        guard !completions.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + completions.count) % completions.count
        rebuildRows()
    }

    func acceptSelected() {
        let snapshot = completions
        let index = selectedIndex
        guard index >= 0, index < snapshot.count else { return }
        let completion = snapshot[index]
        hide()
        onAccept?(completion)
    }

    var selectedCompletion: Completion? {
        guard selectedIndex >= 0, selectedIndex < completions.count else { return nil }
        return completions[selectedIndex]
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []

        let visibleCount = min(completions.count, maxVisibleRows)
        for i in 0..<visibleCount {
            let row = createRow(for: completions[i], selected: i == selectedIndex)
            row.frame = NSRect(x: 2, y: bounds.height - CGFloat(i + 1) * rowHeight - 2, width: popupWidth - 4, height: rowHeight)
            addSubview(row)
            rows.append(row)
        }
    }

    private func createRow(for completion: Completion, selected: Bool) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        if selected {
            row.layer?.backgroundColor = NSColor(red: 45/255, green: 127/255, blue: 212/255, alpha: 0.4).cgColor
            row.layer?.cornerRadius = 4
        }

        let iconLabel = NSTextField(labelWithString: completion.icon == "folder" ? "📁" : completion.icon == "clock" ? "🕐" : "📄")
        iconLabel.font = NSFont.systemFont(ofSize: 12)
        iconLabel.frame = NSRect(x: 8, y: 2, width: 20, height: 20)
        row.addSubview(iconLabel)

        let nameLabel = NSTextField(labelWithString: completion.display)
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nameLabel.textColor = selected ? .white : NSColor(white: 0.85, alpha: 1)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.frame = NSRect(x: 32, y: 2, width: 200, height: 20)
        row.addSubview(nameLabel)

        let detailLabel = NSTextField(labelWithString: completion.detail)
        detailLabel.font = NSFont.systemFont(ofSize: 10)
        detailLabel.textColor = NSColor(white: 0.5, alpha: 1)
        detailLabel.alignment = .right
        detailLabel.frame = NSRect(x: 240, y: 3, width: 70, height: 18)
        row.addSubview(detailLabel)

        return row
    }
}
