import AppKit
import CAwalTerminal

/// Side panel showing AI session context: tokens, cost, activity, file references.
class AISidePanelView: NSView {

    static let defaultWidth: CGFloat = 260.0
    static let minWidth: CGFloat = 200.0
    static let maxWidth: CGFloat = 400.0

    private(set) var isPanelVisible: Bool = false

    // Model pricing (per million tokens) — approximate
    private struct ModelPricing {
        let inputPerM: Double
        let outputPerM: Double
        let cacheReadPerM: Double
    }

    private static let pricing: [String: ModelPricing] = [
        "Claude": ModelPricing(inputPerM: 3.0, outputPerM: 15.0, cacheReadPerM: 0.30),
        "Gemini": ModelPricing(inputPerM: 1.25, outputPerM: 5.0, cacheReadPerM: 0.315),
        "Codex": ModelPricing(inputPerM: 2.50, outputPerM: 10.0, cacheReadPerM: 0.0),
    ]

    // UI elements
    private let headerLabel = NSTextField(labelWithString: "")
    private let separator1 = NSView()

    // Token section
    private let tokenSectionLabel = NSTextField(labelWithString: "Tokens")
    private let inputTokensLabel = NSTextField(labelWithString: "")
    private let outputTokensLabel = NSTextField(labelWithString: "")
    private let totalTokensLabel = NSTextField(labelWithString: "")
    private let costLabel = NSTextField(labelWithString: "")

    // Activity section
    private let activitySectionLabel = NSTextField(labelWithString: "Activity")
    private let toolCountLabel = NSTextField(labelWithString: "")
    private let codeBlockCountLabel = NSTextField(labelWithString: "")
    private let diffCountLabel = NSTextField(labelWithString: "")

    // Files section
    private let filesSectionLabel = NSTextField(labelWithString: "Files Referenced")
    private let filesStackView = NSStackView()

    // Elapsed time
    private let elapsedLabel = NSTextField(labelWithString: "")

    private var sessionStart: Date = Date()
    private var currentModel: String = ""
    private var updateTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        updateTimer?.invalidate()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 22/255, green: 22/255, blue: 22/255, alpha: 1).cgColor

        let monoFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
        let monoFontSmall = NSFont.monospacedSystemFont(ofSize: 10.0, weight: .regular)
        let sectionFont = NSFont.monospacedSystemFont(ofSize: 10.0, weight: .bold)
        let headerFont = NSFont.monospacedSystemFont(ofSize: 12.0, weight: .bold)
        let dimColor = NSColor(white: 0.45, alpha: 1.0)
        let textColor = NSColor(white: 0.7, alpha: 1.0)
        let accentColor = AppConfig.shared.themeAccent
        let sectionColor = NSColor(white: 0.5, alpha: 1.0)

        // Left border
        let leftBorder = NSView()
        leftBorder.wantsLayer = true
        leftBorder.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        leftBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leftBorder)

        // Header
        headerLabel.font = headerFont
        headerLabel.textColor = accentColor
        headerLabel.stringValue = "AI Context"
        configureLabel(headerLabel)

        // Separator
        separator1.wantsLayer = true
        separator1.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        separator1.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator1)

        // Token section
        tokenSectionLabel.font = sectionFont
        tokenSectionLabel.textColor = sectionColor
        configureLabel(tokenSectionLabel)

        for label in [inputTokensLabel, outputTokensLabel, totalTokensLabel, costLabel] {
            label.font = monoFont
            label.textColor = textColor
            configureLabel(label)
        }

        // Activity section
        activitySectionLabel.font = sectionFont
        activitySectionLabel.textColor = sectionColor
        configureLabel(activitySectionLabel)

        for label in [toolCountLabel, codeBlockCountLabel, diffCountLabel] {
            label.font = monoFont
            label.textColor = textColor
            configureLabel(label)
        }

        // Files section
        filesSectionLabel.font = sectionFont
        filesSectionLabel.textColor = sectionColor
        configureLabel(filesSectionLabel)

        filesStackView.orientation = .vertical
        filesStackView.alignment = .leading
        filesStackView.spacing = 2
        filesStackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filesStackView)

        // Elapsed time
        elapsedLabel.font = monoFontSmall
        elapsedLabel.textColor = dimColor
        configureLabel(elapsedLabel)

        // Layout
        let margin: CGFloat = 12.0
        let sectionGap: CGFloat = 16.0
        let itemGap: CGFloat = 4.0

        NSLayoutConstraint.activate([
            leftBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftBorder.topAnchor.constraint(equalTo: topAnchor),
            leftBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftBorder.widthAnchor.constraint(equalToConstant: 1),

            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: margin),

            separator1.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            separator1.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            separator1.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            separator1.heightAnchor.constraint(equalToConstant: 1),

            // Token section
            tokenSectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            tokenSectionLabel.topAnchor.constraint(equalTo: separator1.bottomAnchor, constant: sectionGap),

            inputTokensLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            inputTokensLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            inputTokensLabel.topAnchor.constraint(equalTo: tokenSectionLabel.bottomAnchor, constant: itemGap),

            outputTokensLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            outputTokensLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            outputTokensLabel.topAnchor.constraint(equalTo: inputTokensLabel.bottomAnchor, constant: itemGap),

            totalTokensLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            totalTokensLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            totalTokensLabel.topAnchor.constraint(equalTo: outputTokensLabel.bottomAnchor, constant: itemGap),

            costLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            costLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            costLabel.topAnchor.constraint(equalTo: totalTokensLabel.bottomAnchor, constant: itemGap),

            // Activity section
            activitySectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            activitySectionLabel.topAnchor.constraint(equalTo: costLabel.bottomAnchor, constant: sectionGap),

            toolCountLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            toolCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            toolCountLabel.topAnchor.constraint(equalTo: activitySectionLabel.bottomAnchor, constant: itemGap),

            codeBlockCountLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            codeBlockCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            codeBlockCountLabel.topAnchor.constraint(equalTo: toolCountLabel.bottomAnchor, constant: itemGap),

            diffCountLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            diffCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            diffCountLabel.topAnchor.constraint(equalTo: codeBlockCountLabel.bottomAnchor, constant: itemGap),

            // Files section
            filesSectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            filesSectionLabel.topAnchor.constraint(equalTo: diffCountLabel.bottomAnchor, constant: sectionGap),

            filesStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            filesStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            filesStackView.topAnchor.constraint(equalTo: filesSectionLabel.bottomAnchor, constant: itemGap),

            // Elapsed at bottom
            elapsedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            elapsedLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),
        ])

        // Update timer
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateElapsedTime()
        }

        // Set initial values
        updateTokenDisplay(input: 0, output: 0)
        updateActivityDisplay(tools: 0, codeBlocks: 0, diffs: 0)
        updateFileRefs([])
    }

    private func configureLabel(_ label: NSTextField) {
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
    }

    // MARK: - Public API

    func setModel(_ model: String) {
        currentModel = model
        headerLabel.stringValue = model.isEmpty ? "AI Context" : "\(model) Session"
    }

    func resetSession() {
        sessionStart = Date()
        updateTokenDisplay(input: 0, output: 0)
        updateActivityDisplay(tools: 0, codeBlocks: 0, diffs: 0)
        updateFileRefs([])
    }

    func updateTokenDisplay(input: Int, output: Int) {
        inputTokensLabel.stringValue = "  Input:  \(formatTokenCount(input))"
        outputTokensLabel.stringValue = "  Output: \(formatTokenCount(output))"
        let total = input + output
        totalTokensLabel.stringValue = "  Total:  \(formatTokenCount(total))"

        // Calculate cost
        let cost = estimateCost(model: currentModel, input: input, output: output)
        if cost > 0 {
            costLabel.stringValue = "  Cost:   $\(String(format: "%.4f", cost))"
            costLabel.textColor = cost > 1.0
                ? NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 1.0)
                : NSColor(white: 0.7, alpha: 1.0)
        } else {
            costLabel.stringValue = "  Cost:   —"
        }
    }

    func updateActivityDisplay(tools: Int, codeBlocks: Int, diffs: Int) {
        toolCountLabel.stringValue = "  Tool calls:  \(tools)"
        codeBlockCountLabel.stringValue = "  Code blocks: \(codeBlocks)"
        diffCountLabel.stringValue = "  Diffs:       \(diffs)"
    }

    func updateFileRefs(_ files: [String]) {
        // Remove old file labels
        filesStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if files.isEmpty {
            let noFiles = NSTextField(labelWithString: "  (none)")
            noFiles.font = NSFont.monospacedSystemFont(ofSize: 10.0, weight: .regular)
            noFiles.textColor = NSColor(white: 0.35, alpha: 1.0)
            noFiles.isEditable = false
            noFiles.isBordered = false
            noFiles.drawsBackground = false
            filesStackView.addArrangedSubview(noFiles)
            return
        }

        for file in files.prefix(20) {
            let label = NSTextField(labelWithString: "  \(shortenPath(file))")
            label.font = NSFont.monospacedSystemFont(ofSize: 10.0, weight: .regular)
            label.textColor = NSColor(red: 130/255, green: 170/255, blue: 255/255, alpha: 1.0)
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            filesStackView.addArrangedSubview(label)
        }

        if files.count > 20 {
            let moreLabel = NSTextField(labelWithString: "  +\(files.count - 20) more")
            moreLabel.font = NSFont.monospacedSystemFont(ofSize: 10.0, weight: .regular)
            moreLabel.textColor = NSColor(white: 0.4, alpha: 1.0)
            moreLabel.isEditable = false
            moreLabel.isBordered = false
            moreLabel.drawsBackground = false
            filesStackView.addArrangedSubview(moreLabel)
        }
    }

    /// Update from surface's analyzer data.
    func updateFromSurface(_ surface: OpaquePointer?) {
        guard let surface = surface else { return }

        var summary = CRegionSummary(
            tool_use_count: 0,
            code_block_count: 0,
            thinking_count: 0,
            diff_count: 0,
            file_ref_count: 0
        )
        at_surface_get_region_summary(surface, &summary)

        updateActivityDisplay(
            tools: Int(summary.tool_use_count),
            codeBlocks: Int(summary.code_block_count),
            diffs: Int(summary.diff_count)
        )

        // Get file refs
        var files: [String] = []
        for i in 0..<summary.file_ref_count {
            let cstr = at_surface_get_file_ref(surface, i)
            if let cstr = cstr {
                files.append(String(cString: cstr))
                at_free_string(cstr)
            }
        }
        updateFileRefs(files)
    }

    // MARK: - Visibility

    func show() {
        isPanelVisible = true
    }

    func hide() {
        isPanelVisible = false
    }

    func toggle() {
        isPanelVisible = !isPanelVisible
    }

    // MARK: - Helpers

    private func updateElapsedTime() {
        let elapsed = Int(Date().timeIntervalSince(sessionStart))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        if h > 0 {
            elapsedLabel.stringValue = "Elapsed: \(h)h \(m)m \(s)s"
        } else if m > 0 {
            elapsedLabel.stringValue = "Elapsed: \(m)m \(s)s"
        } else {
            elapsedLabel.stringValue = "Elapsed: \(s)s"
        }
    }

    private func estimateCost(model: String, input: Int, output: Int) -> Double {
        guard let pricing = Self.pricing[model] else { return 0 }
        let inputCost = Double(input) / 1_000_000.0 * pricing.inputPerM
        let outputCost = Double(output) / 1_000_000.0 * pricing.outputPerM
        return inputCost + outputCost
    }

    private func formatTokenCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            let value = Double(n) / 1_000_000.0
            return String(format: "%.1fM", value)
        } else if n >= 1_000 {
            let value = Double(n) / 1_000.0
            return String(format: "%.1fk", value)
        }
        return "\(n)"
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        // Just show filename for long paths
        if path.count > 40 {
            return (path as NSString).lastPathComponent
        }
        return path
    }
}
