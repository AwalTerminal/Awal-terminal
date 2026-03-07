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
    private let tokenUnavailableLabel = NSTextField(labelWithString: "")

    // Context window bar
    private let contextBarBackground = NSView()
    private let contextBarFill = NSView()
    private let contextPercentLabel = NSTextField(labelWithString: "")
    private var contextBarFillWidth: NSLayoutConstraint?

    // Activity section
    private let activitySectionLabel = NSTextField(labelWithString: "Activity")
    private let toolCountLabel = NSTextField(labelWithString: "")
    private let codeBlockCountLabel = NSTextField(labelWithString: "")
    private let diffCountLabel = NSTextField(labelWithString: "")

    // Files section
    private let filesSectionLabel = NSTextField(labelWithString: "Files Referenced")
    private let filesStackView = NSStackView()

    // Phase / generating indicator
    private let phaseLabel = NSTextField(labelWithString: "")
    private var generatingTimer: Timer?

    // Git Changes section
    private let gitSeparator = NSView()
    private let gitSectionLabel = NSTextField(labelWithString: "Changes")
    private let gitSummaryStack = NSStackView()
    private let gitScrollView = NSScrollView()
    private let gitOutlineView = NSOutlineView()
    private var gitTreeNodes: [GitTreeNode] = []
    private var gitLastPaths: Set<String> = []
    private var gitExpandedPaths: Set<String> = []

    // Diff popover
    var currentCwd: String?
    private var diffPopover: NSPopover?
    private var diffPopoverFilePath: String?

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
        generatingTimer?.invalidate()
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

        tokenUnavailableLabel.font = monoFontSmall
        tokenUnavailableLabel.textColor = dimColor
        tokenUnavailableLabel.isHidden = true
        configureLabel(tokenUnavailableLabel)

        // Context window bar
        contextBarBackground.wantsLayer = true
        contextBarBackground.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        contextBarBackground.layer?.cornerRadius = 3
        contextBarBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contextBarBackground)

        contextBarFill.wantsLayer = true
        contextBarFill.layer?.backgroundColor = NSColor(red: 80/255, green: 200/255, blue: 120/255, alpha: 1.0).cgColor
        contextBarFill.layer?.cornerRadius = 3
        contextBarFill.translatesAutoresizingMaskIntoConstraints = false
        contextBarBackground.addSubview(contextBarFill)

        contextPercentLabel.font = monoFontSmall
        contextPercentLabel.textColor = dimColor
        contextPercentLabel.alignment = .right
        configureLabel(contextPercentLabel)

        // Activity section
        activitySectionLabel.font = sectionFont
        activitySectionLabel.textColor = sectionColor
        configureLabel(activitySectionLabel)

        for label in [toolCountLabel, codeBlockCountLabel, diffCountLabel] {
            label.font = monoFont
            label.textColor = textColor
            configureLabel(label)
        }

        // Phase label (generating indicator)
        phaseLabel.font = monoFont
        phaseLabel.textColor = NSColor(red: 120/255, green: 220/255, blue: 120/255, alpha: 1.0)
        phaseLabel.isHidden = true
        configureLabel(phaseLabel)

        // Files section
        filesSectionLabel.font = sectionFont
        filesSectionLabel.textColor = sectionColor
        configureLabel(filesSectionLabel)

        filesStackView.orientation = .vertical
        filesStackView.alignment = .leading
        filesStackView.spacing = 2
        filesStackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filesStackView)

        // Git Changes section
        gitSeparator.wantsLayer = true
        gitSeparator.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        gitSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gitSeparator)

        gitSectionLabel.font = sectionFont
        gitSectionLabel.textColor = sectionColor
        configureLabel(gitSectionLabel)

        gitSummaryStack.orientation = .horizontal
        gitSummaryStack.spacing = 4
        gitSummaryStack.alignment = .centerY
        gitSummaryStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gitSummaryStack)

        // NSOutlineView in scroll view
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("GitFile"))
        column.isEditable = false
        gitOutlineView.addTableColumn(column)
        gitOutlineView.outlineTableColumn = column
        gitOutlineView.headerView = nil
        gitOutlineView.rowHeight = 22
        gitOutlineView.backgroundColor = .clear
        gitOutlineView.focusRingType = .none
        gitOutlineView.selectionHighlightStyle = .none
        gitOutlineView.intercellSpacing = NSSize(width: 0, height: 0)
        gitOutlineView.indentationPerLevel = 14
        gitOutlineView.dataSource = self
        gitOutlineView.delegate = self
        gitOutlineView.target = self
        gitOutlineView.action = #selector(gitOutlineClicked(_:))
        gitOutlineView.doubleAction = #selector(gitOutlineDoubleClicked(_:))

        gitScrollView.documentView = gitOutlineView
        gitScrollView.hasVerticalScroller = true
        gitScrollView.hasHorizontalScroller = false
        gitScrollView.autohidesScrollers = true
        gitScrollView.drawsBackground = false
        gitScrollView.borderType = .noBorder
        gitScrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gitScrollView)

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

            tokenUnavailableLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            tokenUnavailableLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            tokenUnavailableLabel.topAnchor.constraint(equalTo: tokenSectionLabel.bottomAnchor, constant: itemGap),

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

            // Context window bar
            contextPercentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            contextPercentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            contextPercentLabel.topAnchor.constraint(equalTo: costLabel.bottomAnchor, constant: 6),

            contextBarBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            contextBarBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            contextBarBackground.topAnchor.constraint(equalTo: contextPercentLabel.bottomAnchor, constant: 3),
            contextBarBackground.heightAnchor.constraint(equalToConstant: 6),

            contextBarFill.leadingAnchor.constraint(equalTo: contextBarBackground.leadingAnchor),
            contextBarFill.topAnchor.constraint(equalTo: contextBarBackground.topAnchor),
            contextBarFill.bottomAnchor.constraint(equalTo: contextBarBackground.bottomAnchor),

            // Activity section
            activitySectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            activitySectionLabel.topAnchor.constraint(equalTo: contextBarBackground.bottomAnchor, constant: sectionGap),

            toolCountLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            toolCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            toolCountLabel.topAnchor.constraint(equalTo: activitySectionLabel.bottomAnchor, constant: itemGap),

            codeBlockCountLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            codeBlockCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            codeBlockCountLabel.topAnchor.constraint(equalTo: toolCountLabel.bottomAnchor, constant: itemGap),

            diffCountLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            diffCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            diffCountLabel.topAnchor.constraint(equalTo: codeBlockCountLabel.bottomAnchor, constant: itemGap),

            // Phase label (generating indicator)
            phaseLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            phaseLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            phaseLabel.topAnchor.constraint(equalTo: diffCountLabel.bottomAnchor, constant: itemGap),

            // Files section
            filesSectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            filesSectionLabel.topAnchor.constraint(equalTo: phaseLabel.bottomAnchor, constant: sectionGap),

            filesStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            filesStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            filesStackView.topAnchor.constraint(equalTo: filesSectionLabel.bottomAnchor, constant: itemGap),

            // Git Changes section
            gitSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            gitSeparator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            gitSeparator.topAnchor.constraint(equalTo: filesStackView.bottomAnchor, constant: sectionGap),
            gitSeparator.heightAnchor.constraint(equalToConstant: 1),

            gitSectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            gitSectionLabel.topAnchor.constraint(equalTo: gitSeparator.bottomAnchor, constant: sectionGap),

            gitSummaryStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            gitSummaryStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -margin),
            gitSummaryStack.topAnchor.constraint(equalTo: gitSectionLabel.bottomAnchor, constant: 6),

            gitScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            gitScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            gitScrollView.topAnchor.constraint(equalTo: gitSummaryStack.bottomAnchor, constant: 6),
            gitScrollView.bottomAnchor.constraint(equalTo: elapsedLabel.topAnchor, constant: -8),

            // Elapsed at bottom
            elapsedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            elapsedLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),
        ])

        // Context bar fill width (starts at 0)
        contextBarFillWidth = contextBarFill.widthAnchor.constraint(equalToConstant: 0)
        contextBarFillWidth?.isActive = true

        // Hide context bar initially (shown when model has a context window)
        contextBarBackground.isHidden = true
        contextPercentLabel.isHidden = true

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

    /// Whether the current model supports token tracking (Claude only).
    private var hasTokenTracking: Bool { currentModel == "Claude" }

    func setModel(_ model: String) {
        currentModel = model
        headerLabel.stringValue = model.isEmpty ? "AI Context" : "\(model) Session"

        let showTokens = (model == "Claude")
        inputTokensLabel.isHidden = !showTokens
        outputTokensLabel.isHidden = !showTokens
        totalTokensLabel.isHidden = !showTokens
        costLabel.isHidden = !showTokens
        contextPercentLabel.isHidden = !showTokens
        contextBarBackground.isHidden = !showTokens

        let isLLM = !model.isEmpty && model != "Shell"
        if isLLM && !showTokens {
            tokenUnavailableLabel.isHidden = false
            tokenUnavailableLabel.stringValue = "  Token tracking is Claude-only"
        } else {
            tokenUnavailableLabel.isHidden = true
        }
    }

    func resetSession() {
        sessionStart = Date()
        updateTokenDisplay(input: 0, output: 0)
        updateActivityDisplay(tools: 0, codeBlocks: 0, diffs: 0)
        updateFileRefs([])
    }

    func updateTokenDisplay(input: Int, output: Int) {
        guard hasTokenTracking else { return }

        // input = current context usage (last turn's input tokens)
        // output = cumulative output tokens
        inputTokensLabel.stringValue = "  Input:  \(formatTokenCount(input))"
        outputTokensLabel.stringValue = "  Output: \(formatTokenCount(output))"
        let total = input + output
        totalTokensLabel.stringValue = "  Total:  \(formatTokenCount(total))"

        // Calculate cost using cumulative breakdown (full-rate vs cache-rate)
        let tracker = TokenTracker.shared
        let cost = estimateCost(
            model: currentModel,
            inputFull: tracker.cumulativeInputFull,
            cacheRead: tracker.cumulativeCacheRead,
            output: tracker.totalOutput
        )
        if cost > 0 {
            costLabel.stringValue = "  Cost:   $\(String(format: "%.4f", cost))"
            costLabel.textColor = cost > 1.0
                ? NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 1.0)
                : NSColor(white: 0.7, alpha: 1.0)
        } else {
            costLabel.stringValue = "  Cost:   —"
        }

        // Update context window bar using current context (last turn's input)
        updateContextBar(inputTokens: input)
    }

    private func updateContextBar(inputTokens: Int) {
        guard let model = ModelCatalog.find(currentModel),
              model.contextWindow > 0 else {
            contextBarBackground.isHidden = true
            contextPercentLabel.isHidden = true
            return
        }

        contextBarBackground.isHidden = false
        contextPercentLabel.isHidden = false

        let fraction = min(Double(inputTokens) / Double(model.contextWindow), 1.0)
        let percent = Int(fraction * 100)
        contextPercentLabel.stringValue = "  Context: \(percent)%"

        // Color coding
        let barColor: NSColor
        if fraction < 0.5 {
            barColor = NSColor(red: 80/255, green: 200/255, blue: 120/255, alpha: 1.0)
        } else if fraction < 0.8 {
            barColor = NSColor(red: 240/255, green: 200/255, blue: 60/255, alpha: 1.0)
        } else {
            barColor = NSColor(red: 240/255, green: 100/255, blue: 70/255, alpha: 1.0)
        }
        contextBarFill.layer?.backgroundColor = barColor.cgColor
        contextPercentLabel.textColor = barColor

        // Update fill width using proportional constraint
        contextBarFillWidth?.isActive = false
        if fraction > 0 {
            contextBarFillWidth = contextBarFill.widthAnchor.constraint(
                equalTo: contextBarBackground.widthAnchor, multiplier: CGFloat(fraction))
        } else {
            contextBarFillWidth = contextBarFill.widthAnchor.constraint(equalToConstant: 0)
        }
        contextBarFillWidth?.isActive = true
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

        let maxVisible = 2
        for file in files.prefix(maxVisible) {
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

        if files.count > maxVisible {
            let remaining = files.count - maxVisible
            let moreLabel = NSTextField(labelWithString: "  and \(remaining) more file\(remaining == 1 ? "" : "s")")
            moreLabel.font = NSFont.monospacedSystemFont(ofSize: 10.0, weight: .regular)
            moreLabel.textColor = NSColor(white: 0.4, alpha: 1.0)
            moreLabel.isEditable = false
            moreLabel.isBordered = false
            moreLabel.drawsBackground = false
            filesStackView.addArrangedSubview(moreLabel)
        }
    }

    func updateGitChanges(_ changes: [GitFileChange]) {
        let newPaths = Set(changes.map { $0.path })
        guard newPaths != gitLastPaths else { return }
        gitLastPaths = newPaths

        closeDiffPopover()

        // Save expanded state
        gitExpandedPaths = Set<String>()
        for node in allNodes(gitTreeNodes) where node.isDirectory {
            if gitOutlineView.isItemExpanded(node) {
                gitExpandedPaths.insert(node.fullPath)
            }
        }

        // Cap at 200 files
        let capped = changes.count > 200 ? Array(changes.prefix(200)) : changes
        gitTreeNodes = GitTreeNode.buildTree(from: capped)

        // Build summary badges
        gitSummaryStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var counts: [GitFileChange.Status: Int] = [:]
        for c in changes { counts[c.status, default: 0] += 1 }
        for s: GitFileChange.Status in [.modified, .added, .deleted, .renamed, .untracked] {
            if let n = counts[s], n > 0 {
                gitSummaryStack.addArrangedSubview(makeBadge(count: n, status: s))
            }
        }
        if changes.count > 200 {
            let more = NSTextField(labelWithString: "+\(changes.count - 200)")
            more.font = NSFont.monospacedSystemFont(ofSize: 9.0, weight: .regular)
            more.textColor = NSColor(white: 0.45, alpha: 1.0)
            more.isEditable = false
            more.isBordered = false
            more.drawsBackground = false
            gitSummaryStack.addArrangedSubview(more)
        }
        if changes.isEmpty {
            let clean = NSTextField(labelWithString: "clean")
            clean.font = NSFont.monospacedSystemFont(ofSize: 9.0, weight: .regular)
            clean.textColor = NSColor(white: 0.35, alpha: 1.0)
            clean.isEditable = false
            clean.isBordered = false
            clean.drawsBackground = false
            gitSummaryStack.addArrangedSubview(clean)
        }

        gitOutlineView.reloadData()

        // Restore expanded state
        for node in allNodes(gitTreeNodes) where node.isDirectory {
            if gitExpandedPaths.contains(node.fullPath) {
                gitOutlineView.expandItem(node)
            }
        }
    }

    private func makeBadge(count: Int, status: GitFileChange.Status) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 3
        container.layer?.backgroundColor = status.color.withAlphaComponent(0.15).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "\(count)\(status.label)")
        label.font = NSFont.monospacedSystemFont(ofSize: 9.0, weight: .medium)
        label.textColor = status.color
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])

        return container
    }

    @objc private func gitOutlineClicked(_ sender: Any) {
        guard let outlineView = sender as? NSOutlineView else { return }
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? GitTreeNode else { return }

        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            let filePath = node.fileChange?.path ?? node.fullPath
            let status = node.fileChange?.status ?? .modified

            // Toggle: if popover is open for the same file, dismiss it
            if diffPopover != nil && diffPopoverFilePath == filePath {
                closeDiffPopover()
                return
            }

            // Dismiss any existing popover before opening a new one
            closeDiffPopover()

            guard let cwd = currentCwd, !cwd.isEmpty else { return }

            let vc = DiffPopoverViewController()
            let popover = NSPopover()
            popover.contentViewController = vc
            popover.behavior = .applicationDefined
            popover.delegate = self
            popover.contentSize = NSSize(width: 400, height: 300)
            vc.parentPopover = popover

            diffPopover = popover
            diffPopoverFilePath = filePath

            let rowRect = outlineView.rect(ofRow: row)
            popover.show(relativeTo: rowRect, of: outlineView, preferredEdge: .minX)
            vc.loadDiff(filePath: filePath, status: status, cwd: cwd)
        }
    }

    @objc private func gitOutlineDoubleClicked(_ sender: Any) {
        guard let outlineView = sender as? NSOutlineView else { return }
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? GitTreeNode else { return }
        guard !node.isDirectory else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(node.fileChange?.path ?? node.fullPath, forType: .string)

        if let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) {
            rowView.wantsLayer = true
            rowView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                rowView.layer?.backgroundColor = nil
            }
        }
    }

    private func closeDiffPopover() {
        if let popover = diffPopover {
            popover.delegate = nil
            if popover.isShown {
                popover.performClose(nil)
            }
            diffPopover = nil
            diffPopoverFilePath = nil
        }
    }

    private func allNodes(_ nodes: [GitTreeNode]) -> [GitTreeNode] {
        var result: [GitTreeNode] = []
        for node in nodes {
            result.append(node)
            if node.isDirectory {
                result.append(contentsOf: allNodes(node.children))
            }
        }
        return result
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
                let file = String(cString: cstr)
                at_free_string(cstr)
                if file != "null" && !file.isEmpty {
                    files.append(file)
                }
            }
        }
        updateFileRefs(files)
    }

    func setGenerating(_ generating: Bool, surface: OpaquePointer? = nil, phaseText: String = "") {
        if generating {
            phaseLabel.isHidden = false
            phaseLabel.stringValue = "  \(phaseText)"
            generatingTimer?.invalidate()
            generatingTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                if let surface {
                    self.updateFromSurface(surface)
                }
                self.updateTokenDisplay(
                    input: TokenTracker.shared.currentInput,
                    output: TokenTracker.shared.totalOutput
                )
            }
        } else {
            phaseLabel.isHidden = true
            generatingTimer?.invalidate()
            generatingTimer = nil
        }
    }

    func updatePhase(_ text: String) {
        phaseLabel.stringValue = "  \(text)"
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

    private func estimateCost(model: String, inputFull: Int, cacheRead: Int, output: Int) -> Double {
        guard let pricing = Self.pricing[model] else { return 0 }
        let inputCost = Double(inputFull) / 1_000_000.0 * pricing.inputPerM
        let cacheCost = Double(cacheRead) / 1_000_000.0 * pricing.cacheReadPerM
        let outputCost = Double(output) / 1_000_000.0 * pricing.outputPerM
        return inputCost + cacheCost + outputCost
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

// MARK: - NSOutlineViewDataSource & NSOutlineViewDelegate

extension AISidePanelView: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? GitTreeNode {
            return node.children.count
        }
        return gitTreeNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? GitTreeNode {
            return node.children[index]
        }
        return gitTreeNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? GitTreeNode else { return false }
        return node.isDirectory
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? GitTreeNode else { return nil }

        let cellID = NSUserInterfaceItemIdentifier("GitCell")
        let cellView: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = cellID

            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyDown
            cellView.addSubview(iv)
            cellView.imageView = iv

            let tf = NSTextField(labelWithString: "")
            tf.isEditable = false
            tf.isBordered = false
            tf.drawsBackground = false
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(tf)
            cellView.textField = tf

            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cellView.leadingAnchor),
                iv.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 14),
                iv.heightAnchor.constraint(equalToConstant: 14),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor),
                tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        let monoFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)

        if node.isDirectory {
            let img = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            cellView.imageView?.image = img
            cellView.imageView?.contentTintColor = NSColor(red: 130/255, green: 170/255, blue: 255/255, alpha: 1.0)
            cellView.textField?.stringValue = "\(node.name)/"
            cellView.textField?.font = monoFont
            cellView.textField?.textColor = NSColor(white: 0.55, alpha: 1.0)
        } else if let change = node.fileChange {
            let status = change.status
            let symbolName = fileIcon(for: node.name, status: status)
            let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            cellView.imageView?.image = img
            cellView.imageView?.contentTintColor = status.color

            let attrStr = NSMutableAttributedString()
            attrStr.append(NSAttributedString(
                string: "\(status.label) ",
                attributes: [.foregroundColor: status.color, .font: monoFont]
            ))
            attrStr.append(NSAttributedString(
                string: node.name,
                attributes: [.foregroundColor: NSColor(white: 0.7, alpha: 1.0), .font: monoFont]
            ))
            cellView.textField?.attributedStringValue = attrStr
        }

        return cellView
    }

    private func fileIcon(for name: String, status: GitFileChange.Status) -> String {
        switch status {
        case .added:     return "doc.badge.plus"
        case .deleted:   return "doc.badge.minus"
        case .renamed:   return "doc.badge.arrow.up"
        default: break
        }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "rs", "py", "js", "ts", "go", "c", "h", "cpp", "java", "rb":
            return "doc.text"
        case "json", "toml", "yaml", "yml", "xml", "plist":
            return "doc.text.fill"
        case "png", "jpg", "jpeg", "svg", "icns", "gif":
            return "photo"
        case "md", "txt", "rtf":
            return "doc.plaintext"
        default:
            return "doc"
        }
    }
}

// MARK: - NSPopoverDelegate

extension AISidePanelView: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        diffPopover = nil
        diffPopoverFilePath = nil
    }
}
