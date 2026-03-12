import AppKit

class StatusBarView: NSView {

    static let barHeight: CGFloat = 26.0

    // Callbacks
    var onFolderSelected: ((_ path: String) -> Void)?
    var onOpenFolderRequested: (() -> Void)?
    var onModelSelected: ((_ modelName: String) -> Void)?
    var onPathChanged: (() -> Void)?
    var onGitStatusChanged: ((_ changes: [GitFileChange]) -> Void)?

    private(set) var currentModelName: String = ""

    // Left: model | Center-left: path + git | Center-right: dimensions | Right: time
    private let modelButton: NSButton = {
        let btn = NSButton(title: "", target: nil, action: nil)
        btn.isBordered = false
        btn.setButtonType(.momentaryChange)
        return btn
    }()
    private let pathButton: NSButton = {
        let btn = NSButton(title: "", target: nil, action: nil)
        btn.isBordered = false
        btn.setButtonType(.momentaryChange)
        return btn
    }()
    private let gitLabel = NSTextField(labelWithString: "")
    private let aiComponentLabel: VoiceClickLabel = {
        let label = VoiceClickLabel(labelWithString: "")
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        return label
    }()
    private let cpuLabel = NSTextField(labelWithString: "")
    private let dimsLabel = NSTextField(labelWithString: "")
    private let tokensLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    private(set) var currentPath: String?

    /// Pause polling when this tab is in the background
    var isPaused: Bool = false

    private let generatingLabel = NSTextField(labelWithString: "")
    private var generatingTimer: Timer?
    private var generatingDotCount: Int = 0
    private var generatingWidthConstraint: NSLayoutConstraint!

    // Voice controls
    private let voiceButton: StatusBarButton = {
        let btn = StatusBarButton()
        btn.isBordered = false
        btn.setButtonType(.momentaryChange)
        btn.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Voice Input")
        btn.imagePosition = .imageOnly
        btn.contentTintColor = NSColor(white: 0.55, alpha: 1.0)
        btn.toolTip = "Voice Input (⌃⇧Space)"
        return btn
    }()
    private let pulsingDot: NSView = {
        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0).cgColor
        dot.layer?.cornerRadius = 3
        dot.isHidden = true
        return dot
    }()
    private let voiceWaveform = WaveformView(frame: .zero)

    var onVoiceToggle: (() -> Void)?

    private var sessionStart: Date = Date()
    private var updateTimer: Timer?
    private var shellPid: pid_t = 0

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
        layer?.backgroundColor = AppConfig.shared.themeStatusBarBg.cgColor

        let monoFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
        let dimColor = NSColor(white: 0.45, alpha: 1.0)
        let accentColor = AppConfig.shared.themeAccent
        let pathColor = NSColor(white: 0.55, alpha: 1.0)
        let branchColor = NSColor(red: 180.0/255.0, green: 142.0/255.0, blue: 255.0/255.0, alpha: 1.0)

        let labels: [NSTextField] = [gitLabel, cpuLabel, dimsLabel, tokensLabel, timeLabel]
        for label in labels {
            label.font = monoFont
            label.textColor = dimColor
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        // Model button styled like a label
        modelButton.font = monoFont
        modelButton.contentTintColor = accentColor
        modelButton.alignment = .left
        modelButton.translatesAutoresizingMaskIntoConstraints = false
        modelButton.target = self
        modelButton.action = #selector(modelClicked(_:))
        addSubview(modelButton)

        // Generating indicator (fixed-width, between model and sep1)
        generatingLabel.font = monoFont
        generatingLabel.textColor = NSColor(red: 120.0/255.0, green: 220.0/255.0, blue: 120.0/255.0, alpha: 1.0)
        generatingLabel.isEditable = false
        generatingLabel.isBordered = false
        generatingLabel.drawsBackground = false
        generatingLabel.alignment = .left
        generatingLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(generatingLabel)

        // Voice controls (between generating and sep1)
        voiceButton.translatesAutoresizingMaskIntoConstraints = false
        voiceButton.target = self
        voiceButton.action = #selector(voiceButtonClicked(_:))
        addSubview(voiceButton)

        pulsingDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pulsingDot)

        voiceWaveform.translatesAutoresizingMaskIntoConstraints = false
        addSubview(voiceWaveform)

        // Path button styled like a label
        pathButton.font = monoFont
        pathButton.contentTintColor = pathColor
        pathButton.alignment = .left
        pathButton.lineBreakMode = .byTruncatingMiddle
        pathButton.translatesAutoresizingMaskIntoConstraints = false
        pathButton.target = self
        pathButton.action = #selector(pathClicked(_:))
        addSubview(pathButton)

        gitLabel.textColor = branchColor

        // AI component indicator (between git and dims)
        aiComponentLabel.font = monoFont
        aiComponentLabel.textColor = NSColor(red: 100.0/255.0, green: 200.0/255.0, blue: 160.0/255.0, alpha: 1.0)
        aiComponentLabel.translatesAutoresizingMaskIntoConstraints = false
        aiComponentLabel.toolTip = "Click to view active AI components"
        aiComponentLabel.stringValue = "AI"
        aiComponentLabel.textColor = NSColor(white: 0.35, alpha: 1.0)
        aiComponentLabel.onClick = { [weak self] in
            self?.showAIComponentPopover()
        }
        addSubview(aiComponentLabel)

        // Separators: thin dots between sections
        let sep1 = makeSeparator()
        let sep2 = makeSeparator()
        let sep3 = makeSeparator()

        // Top border line
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            // Left: model
            modelButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            modelButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Generating dots (fixed width, collapses to 0 when idle)
            generatingLabel.leadingAnchor.constraint(equalTo: modelButton.trailingAnchor, constant: 2),
            generatingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Voice controls (after generating, before sep1)
            voiceButton.leadingAnchor.constraint(equalTo: generatingLabel.trailingAnchor, constant: 6),
            voiceButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            voiceButton.widthAnchor.constraint(equalToConstant: 20),
            voiceButton.heightAnchor.constraint(equalToConstant: 20),

            pulsingDot.leadingAnchor.constraint(equalTo: voiceButton.trailingAnchor, constant: -4),
            pulsingDot.topAnchor.constraint(equalTo: voiceButton.topAnchor, constant: -1),
            pulsingDot.widthAnchor.constraint(equalToConstant: 6),
            pulsingDot.heightAnchor.constraint(equalToConstant: 6),

            voiceWaveform.leadingAnchor.constraint(equalTo: voiceButton.trailingAnchor, constant: 4),
            voiceWaveform.centerYAnchor.constraint(equalTo: centerYAnchor),
            voiceWaveform.heightAnchor.constraint(equalToConstant: 14),
            voiceWaveform.widthAnchor.constraint(equalToConstant: 30),

            // Sep 1 chains off voice waveform
            sep1.leadingAnchor.constraint(equalTo: voiceWaveform.trailingAnchor, constant: 8),
            sep1.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Path (clickable button)
            pathButton.leadingAnchor.constraint(equalTo: sep1.trailingAnchor, constant: 10),
            pathButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathButton.widthAnchor.constraint(lessThanOrEqualToConstant: 300),

            // Git (right after path)
            gitLabel.leadingAnchor.constraint(equalTo: pathButton.trailingAnchor, constant: 8),
            gitLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // AI component indicator (right after git)
            aiComponentLabel.leadingAnchor.constraint(equalTo: gitLabel.trailingAnchor, constant: 8),
            aiComponentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Right side: time
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Sep 3 (before time)
            sep3.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -10),
            sep3.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Tokens (before sep3)
            tokensLabel.trailingAnchor.constraint(equalTo: sep3.leadingAnchor, constant: -10),
            tokensLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Sep 2 (before tokens)
            sep2.trailingAnchor.constraint(equalTo: tokensLabel.leadingAnchor, constant: -10),
            sep2.centerYAnchor.constraint(equalTo: centerYAnchor),

            // CPU (before sep2)
            cpuLabel.trailingAnchor.constraint(equalTo: sep2.leadingAnchor, constant: -10),
            cpuLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Dims (before CPU)
            dimsLabel.trailingAnchor.constraint(equalTo: cpuLabel.leadingAnchor, constant: -10),
            dimsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        generatingWidthConstraint = generatingLabel.widthAnchor.constraint(equalToConstant: 0)
        generatingWidthConstraint.isActive = true

        // Voice controls start hidden until a session is opened
        voiceButton.isHidden = true
        pulsingDot.isHidden = true
        voiceWaveform.isHidden = true

        modelButton.title = "Awal Terminal"

        // Poll cwd + git every 2 seconds
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            self.updateTime()
            self.pollCwdAndGit()
        }
    }

    private func makeSeparator() -> NSTextField {
        let sep = NSTextField(labelWithString: "|")
        sep.font = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
        sep.textColor = NSColor(white: 0.25, alpha: 1.0)
        sep.isEditable = false
        sep.isBordered = false
        sep.drawsBackground = false
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)
        return sep
    }

    @objc private func modelClicked(_ sender: NSButton) {
        let menu = NSMenu()

        for model in ModelCatalog.all {
            let title = model.name == "Shell" ? "Shell (plain terminal)" : model.name
            let item = NSMenuItem(title: title, action: #selector(modelItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.name
            if model.name == currentModelName {
                item.state = .on
            }
            menu.addItem(item)
        }

        let location = NSPoint(x: 0, y: sender.bounds.height)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func modelItemSelected(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        onModelSelected?(name)
    }

    @objc private func pathClicked(_ sender: NSButton) {
        let menu = NSMenu()

        let recents = WorkspaceStore.shared.recents()
        for ws in recents {
            let title = "\(shortenPath(ws.path)) — \(ws.lastModel)"
            let item = NSMenuItem(title: title, action: #selector(recentFolderSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ws.path
            menu.addItem(item)
        }

        if !recents.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        let openItem = NSMenuItem(title: "Open Folder...", action: #selector(openFolderClicked(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let location = NSPoint(x: 0, y: sender.bounds.height)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func recentFolderSelected(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onFolderSelected?(path)
    }

    @objc private func openFolderClicked(_ sender: NSMenuItem) {
        onOpenFolderRequested?()
    }

    func update(model: String, provider: String, cols: Int, rows: Int) {
        currentModelName = model.isEmpty ? "Shell" : model
        modelButton.title = currentModelName
        dimsLabel.stringValue = "\(cols)×\(rows)"
        updateTime()
        pollCwdAndGit()
    }

    func setShellPid(_ pid: pid_t) {
        self.shellPid = pid
        pollCwdAndGit()
    }

    private func pollCwdAndGit() {
        guard shellPid > 0 else { return }

        // Get cwd of the shell process via /proc or lsof
        let pid = shellPid
        let isClaudeSession = currentModelName == "Claude"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fgPid = self?.findForegroundProcess(pid) ?? pid
            // Get cwd from procfs (macOS: use proc_pidinfo or lsof)
            let cwd = self?.getCwdOfPid(fgPid) ?? ""
            let gitResult = self?.getGitInfo(cwd: cwd) ?? (label: "", changes: [])
            let cpuUsage = self?.getProcessCPU(pid: fgPid) ?? 0.0

            // Update token tracking for Claude sessions
            if isClaudeSession {
                TokenTracker.shared.update(projectPath: cwd.isEmpty ? nil : cwd)
            }
            let tokenDisplay = isClaudeSession ? TokenTracker.shared.displayString : ""

            DispatchQueue.main.async {
                let oldPath = self?.currentPath
                self?.currentPath = cwd.isEmpty ? nil : cwd
                self?.pathButton.title = self?.shortenPath(cwd) ?? ""
                self?.gitLabel.stringValue = gitResult.label
                self?.tokensLabel.stringValue = tokenDisplay
                self?.updateCPULabel(cpuUsage)
                self?.onGitStatusChanged?(gitResult.changes)
                if self?.currentPath != oldPath {
                    self?.onPathChanged?()
                }
            }
        }
    }

    private func findForegroundProcess(_ pid: pid_t) -> pid_t {
        // Walk the process tree to find the deepest child
        var current = pid
        for _ in 0..<10 { // max depth to avoid infinite loops
            let child = findChildProcess(current)
            if child <= 0 || child == current { break }
            current = child
        }
        return current
    }

    private func findChildProcess(_ ppid: pid_t) -> pid_t {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", "\(ppid)"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice

        do {
            try pgrep.run()
            pgrep.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Take the last child PID (usually the foreground process)
            if let lastLine = output.split(separator: "\n").last,
               let childPid = Int32(lastLine.trimmingCharacters(in: .whitespaces)) {
                return childPid
            }
        } catch {}
        return -1
    }

    private func getCwdOfPid(_ pid: pid_t) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.split(separator: "\n") {
                if line.hasPrefix("n/") {
                    return String(line.dropFirst(1))
                }
            }
        } catch {}
        return ""
    }

    private func getGitInfo(cwd: String) -> (label: String, changes: [GitFileChange]) {
        guard !cwd.isEmpty else { return ("", []) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return ("", []) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !branch.isEmpty else { return ("", []) }

            // Get short status
            let statusProc = Process()
            statusProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            statusProc.arguments = ["-C", cwd, "status", "--porcelain"]
            let statusPipe = Pipe()
            statusProc.standardOutput = statusPipe
            statusProc.standardError = FileHandle.nullDevice
            try statusProc.run()
            statusProc.waitUntilExit()
            let statusData = statusPipe.fileHandleForReading.readDataToEndOfFile()
            let statusStr = String(data: statusData, encoding: .utf8) ?? ""
            let parsed = GitFileChange.parseGitStatus(statusStr)

            if parsed.count > 0 {
                return ("\(branch) *\(parsed.count)", parsed)
            } else {
                return ("\(branch)", [])
            }
        } catch {}
        return ("", [])
    }

    private func getProcessCPU(pid: pid_t) -> Double {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "%cpu="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Double(output) ?? 0.0
        } catch {
            return 0.0
        }
    }

    private func updateCPULabel(_ cpu: Double) {
        if shellPid <= 0 {
            cpuLabel.stringValue = ""
            return
        }
        let rounded = Int(cpu.rounded())
        cpuLabel.stringValue = "CPU \(rounded)%"
        if cpu >= 75 {
            cpuLabel.textColor = NSColor(red: 1.0, green: 0.4, blue: 0.3, alpha: 1.0)
        } else if cpu >= 25 {
            cpuLabel.textColor = NSColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1.0)
        } else {
            cpuLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        }
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func updateTime() {
        let elapsed = Int(Date().timeIntervalSince(sessionStart))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        if h > 0 {
            timeLabel.stringValue = String(format: "%d:%02d:%02d", h, m, s)
        } else {
            timeLabel.stringValue = String(format: "%d:%02d", m, s)
        }
    }

    func resetSession() {
        sessionStart = Date()
    }

    // MARK: - Voice Controls

    func setVoiceState(_ state: VoiceInputController.State) {
        switch state {
        case .idle:
            voiceButton.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Voice Input")
            voiceButton.contentTintColor = NSColor(white: 0.55, alpha: 1.0)
            stopPulsingDot()
            voiceWaveform.stopAnimating()
            voiceWaveform.isHidden = true
        case .listening:
            voiceButton.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Listening")
            voiceButton.contentTintColor = NSColor(red: 120.0/255.0, green: 220.0/255.0, blue: 120.0/255.0, alpha: 1.0)
            stopPulsingDot()
            voiceWaveform.isHidden = true
            voiceWaveform.stopAnimating()
        case .recording:
            voiceButton.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
            voiceButton.contentTintColor = NSColor(red: 255.0/255.0, green: 80.0/255.0, blue: 80.0/255.0, alpha: 1.0)
            startPulsingDot()
            voiceWaveform.isHidden = false
            voiceWaveform.startAnimating()
        case .processing:
            voiceButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Processing")
            voiceButton.contentTintColor = NSColor(red: 255.0/255.0, green: 200.0/255.0, blue: 50.0/255.0, alpha: 1.0)
            stopPulsingDot()
            voiceWaveform.stopAnimating()
            voiceWaveform.isHidden = true
        }
    }

    func setVoiceVisible(_ visible: Bool) {
        voiceButton.isHidden = !visible
        if !visible {
            pulsingDot.isHidden = true
            voiceWaveform.isHidden = true
        }
    }

    func setVoiceAudioLevel(_ level: Float) {
        voiceWaveform.audioLevel = level
    }

    @objc private func voiceButtonClicked(_ sender: NSButton) {
        onVoiceToggle?()
    }

    private func startPulsingDot() {
        pulsingDot.isHidden = false
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.2
        anim.duration = 0.6
        anim.autoreverses = true
        anim.repeatCount = .infinity
        pulsingDot.layer?.add(anim, forKey: "pulsing")
    }

    private func stopPulsingDot() {
        pulsingDot.isHidden = true
        pulsingDot.layer?.removeAnimation(forKey: "pulsing")
    }

    private var flashTimer: Timer?
    private var savedDimsText: String = ""

    func showFlash(_ message: String) {
        flashTimer?.invalidate()
        savedDimsText = dimsLabel.stringValue
        dimsLabel.stringValue = message
        dimsLabel.textColor = NSColor(red: 120.0/255.0, green: 220.0/255.0, blue: 120.0/255.0, alpha: 1.0)
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.dimsLabel.stringValue = self?.savedDimsText ?? ""
            self?.dimsLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        }
    }

    // MARK: - AI Components Display

    private var activeAIComponentDetails: [(name: String, source: String, stack: String, type: ComponentType, key: String)] = []

    func setAIComponentInfo(
        stacks: Set<String>,
        skillCount: Int,
        ruleCount: Int = 0,
        promptCount: Int = 0,
        agentCount: Int = 0,
        mcpServerCount: Int = 0,
        components: [(name: String, source: String, stack: String, type: ComponentType, key: String)]
    ) {
        activeAIComponentDetails = components
        let total = skillCount + ruleCount + promptCount + agentCount + mcpServerCount
        if total > 0 {
            let stackNames = stacks.sorted().joined(separator: ", ")
            // Build a breakdown of non-zero counts
            var parts: [String] = []
            if skillCount > 0 { parts.append("\(skillCount) skills") }
            if ruleCount > 0 { parts.append("\(ruleCount) rules") }
            if promptCount > 0 { parts.append("\(promptCount) prompts") }
            if agentCount > 0 { parts.append("\(agentCount) agents") }
            if mcpServerCount > 0 { parts.append("\(mcpServerCount) MCP") }

            let summary: String
            if parts.count <= 2 {
                summary = parts.joined(separator: ", ")
            } else {
                summary = "\(total) components"
            }
            aiComponentLabel.stringValue = "\(stackNames) · \(summary)"
            aiComponentLabel.textColor = NSColor(red: 100.0/255.0, green: 200.0/255.0, blue: 160.0/255.0, alpha: 1.0)
        } else {
            aiComponentLabel.stringValue = "AI"
            aiComponentLabel.textColor = NSColor(white: 0.35, alpha: 1.0)
        }
    }

    func clearAIComponentInfo() {
        activeAIComponentDetails = []
        aiComponentLabel.stringValue = "AI"
        aiComponentLabel.textColor = NSColor(white: 0.35, alpha: 1.0)
    }

    private weak var activePopover: NSPopover?

    private func showAIComponentPopover() {
        // Toggle behavior — close if already open
        if let existing = activePopover {
            existing.performClose(nil)
            activePopover = nil
            return
        }

        let controller = AIComponentPopoverController(
            components: activeAIComponentDetails
        )
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        popover.contentSize = controller.view.frame.size
        popover.show(relativeTo: aiComponentLabel.bounds, of: aiComponentLabel, preferredEdge: .maxY)
        activePopover = popover
    }

    func setGenerating(_ generating: Bool) {
        if generating {
            generatingDotCount = 0
            generatingWidthConstraint.constant = 22
            generatingLabel.stringValue = "."
            generatingTimer?.invalidate()
            generatingTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.generatingDotCount = (self.generatingDotCount + 1) % 4
                let dots = ["", ".", "..", "..."]
                self.generatingLabel.stringValue = dots[self.generatingDotCount]
            }
        } else {
            generatingTimer?.invalidate()
            generatingTimer = nil
            generatingWidthConstraint.constant = 0
            generatingLabel.stringValue = ""
        }
    }
}

// MARK: - AI Component Popover

class AIComponentPopoverController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let allComponents: [(name: String, source: String, stack: String, type: ComponentType, key: String)]
    private var populatedTypes: [ComponentType] = []
    private var currentItems: [(name: String, source: String, stack: String)] = []

    private let segmentedControl = NSSegmentedControl()
    private let tableView = NSTableView()

    init(components: [(name: String, source: String, stack: String, type: ComponentType, key: String)]) {
        self.allComponents = components
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // Build populated types first to compute size
        let grouped = Dictionary(grouping: allComponents) { $0.type }
        let typeOrder: [ComponentType] = [.skill, .rule, .prompt, .agent, .mcpServer, .hook]
        populatedTypes = typeOrder.filter { grouped[$0] != nil && !grouped[$0]!.isEmpty }

        // Compute max item count across tabs for dynamic height
        let maxItems = populatedTypes.map { grouped[$0]?.count ?? 0 }.max() ?? 0
        let rowHeight: CGFloat = 22
        let tableHeight = max(CGFloat(maxItems) * rowHeight + 4, 60) // min 60
        let popoverHeight = min(10 + 24 + 8 + tableHeight + 8 + 30 + 10, 400) // clamp

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: popoverHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor
        self.view = container

        // Segmented control
        segmentedControl.segmentCount = populatedTypes.count
        for (i, type) in populatedTypes.enumerated() {
            let count = grouped[type]?.count ?? 0
            segmentedControl.setLabel("\(type.pluralLabel.capitalized) (\(count))", forSegment: i)
            segmentedControl.setWidth(0, forSegment: i)
        }
        segmentedControl.segmentStyle = .texturedRounded
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged(_:))
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(segmentedControl)

        // Table view
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 300
        nameCol.resizingMask = .autoresizingMask
        tableView.addTableColumn(nameCol)

        let sourceCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceCol.title = "Source / Stack"
        sourceCol.width = 180
        sourceCol.resizingMask = .userResizingMask
        tableView.addTableColumn(sourceCol)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.delegate = self
        tableView.dataSource = self

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        // "Manage Components..." button
        let manageButton = NSButton(title: "Manage Components...", target: self, action: #selector(manageClicked(_:)))
        manageButton.translatesAutoresizingMaskIntoConstraints = false
        manageButton.bezelStyle = .rounded
        container.addSubview(manageButton)

        // Empty state label (shown when no components)
        if populatedTypes.isEmpty {
            segmentedControl.isHidden = true
            let emptyLabel = NSTextField(labelWithString: "No components loaded")
            emptyLabel.font = .systemFont(ofSize: 12)
            emptyLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
            emptyLabel.alignment = .center
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -20),
            ])
        }

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

            segmentedControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            segmentedControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            scrollView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: manageButton.topAnchor, constant: -8),

            manageButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            manageButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        // Select first tab
        if !populatedTypes.isEmpty {
            segmentedControl.selectedSegment = 0
            selectType(at: 0)
        }
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        selectType(at: sender.selectedSegment)
    }

    private func selectType(at index: Int) {
        guard index >= 0 && index < populatedTypes.count else { return }
        let type = populatedTypes[index]
        currentItems = allComponents.filter { $0.type == type }.map { (name: $0.name, source: $0.source, stack: $0.stack) }
        tableView.reloadData()
    }

    @objc private func closeClicked(_ sender: NSButton) {
        view.window?.close()
    }

    @objc private func manageClicked(_ sender: NSButton) {
        // Close popover first, then open manager
        if let popover = view.window?.parent as? NSPanel {
            popover.close()
        }
        // Walk up to find the popover and close it
        view.window?.close()
        AIComponentsManagerWindow.show()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        currentItems.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < currentItems.count else { return nil }
        let item = currentItems[row]

        let cell = NSTextField(labelWithString: "")
        cell.font = .systemFont(ofSize: 12)
        cell.lineBreakMode = .byTruncatingTail
        cell.drawsBackground = false
        cell.isBordered = false

        switch tableColumn?.identifier.rawValue {
        case "name":
            cell.stringValue = item.name
            cell.textColor = NSColor(white: 0.85, alpha: 1.0)
        case "source":
            cell.stringValue = "\(item.source) / \(item.stack)"
            cell.textColor = NSColor(white: 0.5, alpha: 1.0)
        default:
            break
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        22
    }
}

/// NSButton that refuses first responder so clicking it doesn't steal focus from the terminal.
class StatusBarButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Clickable NSTextField — fires `onClick` on mouse down.
class VoiceClickLabel: NSTextField {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
