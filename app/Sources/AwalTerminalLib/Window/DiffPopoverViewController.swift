import AppKit

class DiffPopoverViewController: NSViewController {

    weak var parentPopover: NSPopover?

    private let headerLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    private static let maxLines = 5000
    private static let maxWidth: CGFloat = 500
    private static let maxHeight: CGFloat = 400
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
    private static let monoBoldFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .medium)

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.wantsLayer = true

        headerLabel.isEditable = false
        headerLabel.isBordered = false
        headerLabel.drawsBackground = false
        headerLabel.font = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .bold)
        headerLabel.textColor = NSColor(white: 0.8, alpha: 1.0)
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(closePopover)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(closeButton)

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor(red: 30.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1.0)
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            headerLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container
    }

    @objc private func closePopover() {
        parentPopover?.performClose(nil)
    }

    func loadDiff(filePath: String, status: GitFileChange.Status, cwd: String) {
        headerLabel.stringValue = filePath

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diffText = self?.runDiff(filePath: filePath, status: status, cwd: cwd) ?? ""
            DispatchQueue.main.async {
                self?.displayDiff(diffText)
            }
        }
    }

    private func runDiff(filePath: String, status: GitFileChange.Status, cwd: String) -> String {
        var result = ""

        if status == .untracked {
            result = runGit(args: ["-C", cwd, "diff", "--no-index", "--", "/dev/null", filePath], cwd: cwd)
        } else {
            result = runGit(args: ["-C", cwd, "diff", "HEAD", "--", filePath], cwd: cwd)
            if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = runGit(args: ["-C", cwd, "diff", "--cached", "--", filePath], cwd: cwd)
            }
        }

        // Strip diff header lines, keep only hunks
        let lines = result.components(separatedBy: "\n")
        var filtered: [String] = []
        var inHunk = false
        for line in lines {
            if line.hasPrefix("@@") {
                inHunk = true
            }
            if inHunk {
                filtered.append(line)
            }
        }

        // Truncate
        if filtered.count > Self.maxLines {
            return filtered.prefix(Self.maxLines).joined(separator: "\n") + "\n\n... truncated at \(Self.maxLines) lines ..."
        }
        return filtered.joined(separator: "\n")
    }

    private func runGit(args: [String], cwd: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func displayDiff(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let empty = NSAttributedString(
                string: "(no diff available)",
                attributes: [.font: Self.monoFont, .foregroundColor: NSColor(white: 0.5, alpha: 1.0)]
            )
            textView.textStorage?.setAttributedString(empty)
            preferredContentSize = NSSize(width: 300, height: 80)
            return
        }

        let attributed = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")

        let greenBg = NSColor(red: 40.0/255.0, green: 80.0/255.0, blue: 40.0/255.0, alpha: 0.4)
        let redBg = NSColor(red: 100.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 0.4)
        let greenText = NSColor(red: 120.0/255.0, green: 220.0/255.0, blue: 120.0/255.0, alpha: 1.0)
        let redText = NSColor(red: 240.0/255.0, green: 100.0/255.0, blue: 100.0/255.0, alpha: 1.0)
        let hunkText = NSColor(red: 100.0/255.0, green: 150.0/255.0, blue: 220.0/255.0, alpha: 1.0)
        let defaultText = NSColor(white: 0.7, alpha: 1.0)

        var maxLineWidth: CGFloat = 0

        for (i, line) in lines.enumerated() {
            var attrs: [NSAttributedString.Key: Any] = [.font: Self.monoFont]
            let suffix = (i < lines.count - 1) ? "\n" : ""

            if line.hasPrefix("@@") {
                // Format hunk header more readably: extract line numbers
                attrs[.foregroundColor] = hunkText
                attrs[.font] = Self.monoBoldFont
                let display = formatHunkHeader(line)
                attributed.append(NSAttributedString(string: display + suffix, attributes: attrs))
            } else if line.hasPrefix("+") {
                attrs[.foregroundColor] = greenText
                attrs[.backgroundColor] = greenBg
                attributed.append(NSAttributedString(string: line + suffix, attributes: attrs))
            } else if line.hasPrefix("-") {
                attrs[.foregroundColor] = redText
                attrs[.backgroundColor] = redBg
                attributed.append(NSAttributedString(string: line + suffix, attributes: attrs))
            } else {
                attrs[.foregroundColor] = defaultText
                attributed.append(NSAttributedString(string: line + suffix, attributes: attrs))
            }

            let measureLine = line.hasPrefix("@@") ? formatHunkHeader(line) : line
            let lineSize = (measureLine as NSString).size(withAttributes: [.font: Self.monoFont])
            maxLineWidth = max(maxLineWidth, lineSize.width)
        }

        textView.textStorage?.setAttributedString(attributed)

        // Auto-size
        let width = min(max(maxLineWidth + 30, 300), Self.maxWidth)
        let lineCount = min(lines.count, 30)
        let lineHeight: CGFloat = 15
        let contentHeight = CGFloat(lineCount) * lineHeight + 40
        let height = min(max(contentHeight, 100), Self.maxHeight)
        preferredContentSize = NSSize(width: width, height: height)
    }

    private func formatHunkHeader(_ line: String) -> String {
        // Turn "@@ -10,5 +12,8 @@ func foo()" into "Lines 12-19 func foo()"
        guard let atRange = line.range(of: "@@", options: .backwards) else { return line }

        let afterAt = String(line[atRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let hunkPart = String(line[line.startIndex..<atRange.upperBound])

        // Extract +start,count
        if let plusRange = hunkPart.range(of: #"\+(\d+)(?:,(\d+))?"#, options: .regularExpression) {
            let match = String(hunkPart[plusRange]).dropFirst() // drop "+"
            let parts = match.split(separator: ",")
            if let start = Int(parts[0]) {
                let count = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
                let end = start + max(count - 1, 0)
                let lineRange = count <= 1 ? "Line \(start)" : "Lines \(start)-\(end)"
                if afterAt.isEmpty {
                    return "\u{2500}\u{2500} \(lineRange) \u{2500}\u{2500}"
                }
                return "\u{2500}\u{2500} \(lineRange) \u{2022} \(afterAt) \u{2500}\u{2500}"
            }
        }

        return line
    }
}
