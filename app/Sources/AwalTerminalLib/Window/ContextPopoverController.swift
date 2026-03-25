import AppKit

/// Popover showing detailed context/token usage when clicking the tokens label or context bar.
class ContextPopoverController: NSViewController {

    private let projectPath: String?
    private let components: [(name: String, source: String, stack: String, type: ComponentType, key: String)]
    private let tokenTracker: TokenTracker

    init(projectPath: String? = nil,
         components: [(name: String, source: String, stack: String, type: ComponentType, key: String)] = [],
         tokenTracker: TokenTracker = TokenTracker.shared) {
        self.projectPath = projectPath
        self.components = components
        self.tokenTracker = tokenTracker
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Snapshot of all context data gathered at popover-open time.
    private struct ContextSnapshot {
        let modelName: String
        let contextWindow: Int
        let currentInput: Int
        let fraction: Double
        let percent: Int

        // Category breakdown
        let memoryTokens: Int
        let componentTokens: Int
        let systemMessagesTokens: Int
        let freeSpace: Int
        let autocompactBuffer: Int

        // Memory files
        let memoryFiles: [(name: String, tokens: Int)]

        // Skills & rules
        let skills: [(name: String, tokens: Int)]

        // Session
        let turns: Int
        let totalOutput: Int
        let cost: Double
        let tools: [String]
    }

    private func gatherSnapshot() -> ContextSnapshot {
        let tracker = self.tokenTracker
        let modelName = tracker.modelUsed.isEmpty ? "—" : tracker.modelUsed
        let contextWindow = ModelCatalog.find("Claude")?.contextWindow ?? 200_000
        let currentInput = tracker.currentInput
        let fraction = contextWindow > 0
            ? min(Double(currentInput) / Double(contextWindow), 1.0) : 0.0
        let percent = Int(fraction * 100)

        // Discover memory files
        let memoryFiles = discoverMemoryFiles()
        let memoryTokens = memoryFiles.reduce(0) { $0 + $1.tokens }

        // Estimate component tokens (skills & rules)
        let skills = estimateComponentTokens()
        let componentTokens = skills.reduce(0) { $0 + $1.tokens }

        // Derived categories
        let autocompactBuffer = Int(Double(contextWindow) * 0.165)
        let freeSpace = max(contextWindow - currentInput - autocompactBuffer, 0)
        let systemMessages = max(currentInput - memoryTokens - componentTokens, 0)

        // Cost
        let cost = estimateCost(
            model: "Claude",
            inputFull: tracker.cumulativeInputFull,
            cacheRead: tracker.cumulativeCacheRead,
            output: tracker.totalOutput
        )

        return ContextSnapshot(
            modelName: modelName,
            contextWindow: contextWindow,
            currentInput: currentInput,
            fraction: fraction,
            percent: percent,
            memoryTokens: memoryTokens,
            componentTokens: componentTokens,
            systemMessagesTokens: systemMessages,
            freeSpace: freeSpace,
            autocompactBuffer: autocompactBuffer,
            memoryFiles: memoryFiles,
            skills: skills,
            turns: tracker.conversationTurns,
            totalOutput: tracker.totalOutput,
            cost: cost,
            tools: tracker.toolCalls
        )
    }

    /// Discover CLAUDE.md files and estimate their token counts.
    private func discoverMemoryFiles() -> [(name: String, tokens: Int)] {
        var files: [(name: String, tokens: Int)] = []
        let fm = FileManager.default

        // Project CLAUDE.md
        if let path = projectPath {
            let projectClaudeMd = (path as NSString).appendingPathComponent("CLAUDE.md")
            if let content = try? String(contentsOfFile: projectClaudeMd, encoding: .utf8) {
                files.append((name: "CLAUDE.md", tokens: content.count / 4))
            }
        }

        // User-level ~/.claude/CLAUDE.md
        let homeClaudeMd = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/CLAUDE.md").path
        if let content = try? String(contentsOfFile: homeClaudeMd, encoding: .utf8) {
            files.append((name: "~/.claude/CLAUDE.md", tokens: content.count / 4))
        }

        // Project-specific memory files in ~/.claude/projects/<hash>/
        if let path = projectPath,
           let claudeDir = TokenTracker.claudeProjectDir(for: path) {
            let memoryDir = claudeDir.appendingPathComponent("memory")
            if let memFiles = try? fm.contentsOfDirectory(atPath: memoryDir.path) {
                for file in memFiles where file.hasSuffix(".md") {
                    let filePath = memoryDir.appendingPathComponent(file).path
                    if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                        files.append((name: "memory/\(file)", tokens: content.count / 4))
                    }
                }
            }
        }

        return files
    }

    /// Estimate token counts for active skills and rules by reading their source files.
    private func estimateComponentTokens() -> [(name: String, tokens: Int)] {
        var result: [(name: String, tokens: Int)] = []

        for comp in components {
            // Parse key: "registryName/stack/type/slug"
            // The key uses the filesystem slug, while comp.name may be a display name
            let parts = comp.key.split(separator: "/")
            guard parts.count >= 4 else { continue }
            let registryName = String(parts[0])
            let stack = String(parts[1])
            let slug = String(parts[3])

            let regPath = RegistryManager.shared.registryPath(name: registryName)

            let typeDirName: String
            switch comp.type {
            case .skill: typeDirName = "skills"
            case .rule: typeDirName = "rules"
            case .prompt: typeDirName = "prompts"
            case .agent: typeDirName = "agents"
            case .mcpServer: typeDirName = "mcp-servers"
            case .hook: typeDirName = "hooks"
            }

            // Build candidate paths using the slug from the key
            let basePath: String
            if stack == "common" {
                basePath = "common/\(typeDirName)/\(slug)"
            } else {
                basePath = "stacks/\(stack)/\(typeDirName)/\(slug)"
            }

            var tokens = 0
            let dirPath = regPath.appendingPathComponent(basePath)

            // Try directory with known .md files inside
            let mdFiles = ["SKILL.md", "RULE.md", "PROMPT.md", "AGENT.md", "\(slug).md"]
            for mdFile in mdFiles {
                let filePath = dirPath.appendingPathComponent(mdFile).path
                if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                    tokens = content.count / 4
                    break
                }
            }

            // Try as a single .md file (e.g. rules/name.md)
            if tokens == 0 {
                let directPath = dirPath.path + ".md"
                if let content = try? String(contentsOfFile: directPath, encoding: .utf8) {
                    tokens = content.count / 4
                }
            }

            result.append((name: comp.name, tokens: tokens))
        }

        return result
    }

    override func loadView() {
        let snap = gatherSnapshot()

        let width: CGFloat = 340
        let monoFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
        let monoFontSmall = NSFont.monospacedSystemFont(ofSize: 10.0, weight: .regular)
        let sectionFont = NSFont.monospacedSystemFont(ofSize: 10.0, weight: .bold)
        let dimColor = NSColor(white: 0.5, alpha: 1.0)
        let textColor = NSColor(white: 0.78, alpha: 1.0)
        let sectionColor = NSColor(white: 0.55, alpha: 1.0)

        let container = NSView(frame: .zero)
        container.wantsLayer = true

        // Frosted glass background
        let vibrancy = NSVisualEffectView(frame: container.bounds)
        vibrancy.material = .popover
        vibrancy.blendingMode = .withinWindow
        vibrancy.state = .active
        vibrancy.autoresizingMask = [.width, .height]
        container.addSubview(vibrancy, positioned: .below, relativeTo: nil)

        var yOffset: CGFloat = 0
        let margin: CGFloat = 14
        let lineHeight: CGFloat = 18
        let sectionGap: CGFloat = 12

        func addLabel(_ text: String, font: NSFont = monoFont, color: NSColor = textColor) {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = color
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: yOffset),
            ])
            yOffset += lineHeight
        }

        func addSectionGap() { yOffset += sectionGap }
        func addSmallGap() { yOffset += 4 }

        // Title
        yOffset = 12
        addLabel("Context Usage", font: NSFont.monospacedSystemFont(ofSize: 12.0, weight: .bold),
                 color: AppConfig.shared.themeAccent)
        addSmallGap()

        // Close button
        let closeButton = NSButton(title: "", target: self, action: #selector(closeClicked(_:)))
        closeButton.bezelStyle = .circular
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])

        // Model + tokens summary
        addLabel("\(snap.modelName) · \(formatTokenCount(snap.currentInput)) / \(formatTokenCount(snap.contextWindow)) tokens (\(snap.percent)%)",
                 font: monoFontSmall, color: dimColor)
        addSmallGap()

        // Context bar
        let barHeight: CGFloat = 8
        let barBg = NSView()
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        barBg.layer?.cornerRadius = 4
        barBg.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(barBg)

        let barFill = NSView()
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 4
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barBg.addSubview(barFill)

        // Bar color
        let barColor: NSColor
        if snap.fraction < 0.5 {
            barColor = NSColor(red: 80.0/255.0, green: 200.0/255.0, blue: 120.0/255.0, alpha: 1.0)
        } else if snap.fraction < 0.8 {
            barColor = NSColor(red: 240.0/255.0, green: 200.0/255.0, blue: 60.0/255.0, alpha: 1.0)
        } else {
            barColor = NSColor(red: 240.0/255.0, green: 100.0/255.0, blue: 70.0/255.0, alpha: 1.0)
        }
        barFill.layer?.backgroundColor = barColor.cgColor

        // Percent label to the right of the bar
        let barPercentLabel = NSTextField(labelWithString: "\(snap.percent)%")
        barPercentLabel.font = monoFontSmall
        barPercentLabel.textColor = barColor
        barPercentLabel.isEditable = false
        barPercentLabel.isBordered = false
        barPercentLabel.drawsBackground = false
        barPercentLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(barPercentLabel)

        NSLayoutConstraint.activate([
            barBg.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            barBg.trailingAnchor.constraint(equalTo: barPercentLabel.leadingAnchor, constant: -8),
            barBg.topAnchor.constraint(equalTo: container.topAnchor, constant: yOffset),
            barBg.heightAnchor.constraint(equalToConstant: barHeight),

            barFill.leadingAnchor.constraint(equalTo: barBg.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barBg.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barBg.bottomAnchor),
            barFill.widthAnchor.constraint(equalTo: barBg.widthAnchor,
                                           multiplier: max(CGFloat(snap.fraction), 0.005)),

            barPercentLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            barPercentLabel.centerYAnchor.constraint(equalTo: barBg.centerYAnchor),
        ])
        yOffset += barHeight + 6

        addSectionGap()

        // Estimated usage by category
        addLabel("Estimated usage by category", font: sectionFont, color: sectionColor)
        addSmallGap()

        let ctxWindow = snap.contextWindow
        func pct(_ n: Int) -> String {
            guard ctxWindow > 0 else { return "0%" }
            let p = Double(n) / Double(ctxWindow) * 100.0
            return p < 0.05 ? "<0.1%" : String(format: "%.1f%%", p)
        }

        func categoryLine(_ symbol: String, _ label: String, _ tokens: Int) -> String {
            let tokenStr = formatTokenCount(tokens)
            let pctStr = pct(tokens)
            // Pad for alignment
            let padded = "\(symbol) \(label)".padding(toLength: 26, withPad: " ", startingAt: 0)
            return "\(padded) \(tokenStr.padding(toLength: 6, withPad: " ", startingAt: 0)) (\(pctStr))"
        }

        addLabel(categoryLine("\u{26C1}", "System + Messages:", snap.systemMessagesTokens),
                 font: monoFontSmall, color: textColor)
        addLabel(categoryLine("\u{26C1}", "Memory files:", snap.memoryTokens),
                 font: monoFontSmall, color: textColor)
        addLabel(categoryLine("\u{26C1}", "Skills & Rules:", snap.componentTokens),
                 font: monoFontSmall, color: textColor)
        addLabel(categoryLine("\u{26F6}", "Free space:", snap.freeSpace),
                 font: monoFontSmall, color: NSColor(red: 80.0/255.0, green: 200.0/255.0, blue: 120.0/255.0, alpha: 0.8))
        addLabel(categoryLine("\u{26DD}", "Autocompact buffer:", snap.autocompactBuffer),
                 font: monoFontSmall, color: dimColor)

        addSectionGap()

        // Memory files section
        if !snap.memoryFiles.isEmpty {
            addLabel("Memory files", font: sectionFont, color: sectionColor)
            addSmallGap()
            for file in snap.memoryFiles {
                addLabel("  \u{2514} \(file.name): \(formatTokenCount(file.tokens)) tokens",
                         font: monoFontSmall, color: textColor)
            }
            addSectionGap()
        }

        // Skills section — show all active components
        if !snap.skills.isEmpty {
            addLabel("Skills", font: sectionFont, color: sectionColor)
            addSmallGap()
            for skill in snap.skills {
                let tokenStr = skill.tokens > 0 ? "\(formatTokenCount(skill.tokens))" : "?"
                addLabel("  \u{2514} \(skill.name): \(tokenStr)",
                         font: monoFontSmall, color: textColor)
            }
            addSectionGap()
        }

        // Session section
        addLabel("Session", font: sectionFont, color: sectionColor)
        addSmallGap()
        addLabel("  Turns:   \(snap.turns)", font: monoFontSmall, color: textColor)
        addLabel("  Output:  \(formatTokenCount(snap.totalOutput)) tokens", font: monoFontSmall, color: textColor)

        let costStr = snap.cost > 0 ? "$\(String(format: "%.4f", snap.cost))" : "—"
        addLabel("  Cost:    \(costStr)", font: monoFontSmall,
                 color: snap.cost > 1.0 ? NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 1.0) : textColor)

        let toolsStr = snap.tools.isEmpty ? "—" : snap.tools.prefix(6).joined(separator: ", ")
            + (snap.tools.count > 6 ? " +\(snap.tools.count - 6)" : "")
        addLabel("  Tools:   \(toolsStr)", font: monoFontSmall, color: textColor)

        yOffset += 12 // bottom padding

        // Wrap in scroll view with max height
        let contentHeight = yOffset
        let maxHeight: CGFloat = 500
        let popoverHeight = min(contentHeight, maxHeight)

        container.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)

        if contentHeight > maxHeight {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: popoverHeight))
            scrollView.documentView = container
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            self.view = scrollView
            // Scroll to top so the popover opens at the beginning
            DispatchQueue.main.async {
                let topY = contentHeight - popoverHeight
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: topY))
            }
        } else {
            self.view = container
        }
    }

    @objc private func closeClicked(_ sender: NSButton) {
        view.window?.close()
    }

    private func formatTokenCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            let value = Double(n) / 1_000_000.0
            return value.truncatingRemainder(dividingBy: 1.0) < 0.05
                ? String(format: "%.0fM", value)
                : String(format: "%.1fM", value)
        } else if n >= 1_000 {
            let value = Double(n) / 1_000.0
            return value.truncatingRemainder(dividingBy: 1.0) < 0.05
                ? String(format: "%.0fk", value)
                : String(format: "%.1fk", value)
        }
        return "\(n)"
    }

    private func estimateCost(model: String, inputFull: Int, cacheRead: Int, output: Int) -> Double {
        TokenTracker.estimateCost(model: model, inputFull: inputFull, cacheRead: cacheRead, output: output)
    }
}
