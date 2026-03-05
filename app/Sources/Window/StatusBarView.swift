import AppKit

class StatusBarView: NSView {

    static let barHeight: CGFloat = 26.0

    // Callbacks
    var onFolderSelected: ((_ path: String) -> Void)?
    var onOpenFolderRequested: (() -> Void)?
    var onModelSelected: ((_ modelName: String) -> Void)?
    var onPathChanged: (() -> Void)?

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
    private let dimsLabel = NSTextField(labelWithString: "")
    private let tokensLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    private(set) var currentPath: String?

    /// Pause polling when this tab is in the background
    var isPaused: Bool = false

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

        let labels: [NSTextField] = [gitLabel, dimsLabel, tokensLabel, timeLabel]
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

            // Sep 1
            sep1.leadingAnchor.constraint(equalTo: modelButton.trailingAnchor, constant: 10),
            sep1.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Path (clickable button)
            pathButton.leadingAnchor.constraint(equalTo: sep1.trailingAnchor, constant: 10),
            pathButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathButton.widthAnchor.constraint(lessThanOrEqualToConstant: 300),

            // Git (right after path)
            gitLabel.leadingAnchor.constraint(equalTo: pathButton.trailingAnchor, constant: 8),
            gitLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

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

            // Dims (before sep2)
            dimsLabel.trailingAnchor.constraint(equalTo: sep2.leadingAnchor, constant: -10),
            dimsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

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
            let item = NSMenuItem(title: shortenPath(ws.path), action: #selector(recentFolderSelected(_:)), keyEquivalent: "")
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

    func trackTerminal(pid: pid_t) {
        self.shellPid = pid
        pollCwdAndGit()
    }

    private func pollCwdAndGit() {
        guard shellPid > 0 else { return }

        // Get cwd of the shell process via /proc or lsof
        let pid = shellPid
        let isClaudeSession = currentModelName == "Claude"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Get cwd from procfs (macOS: use proc_pidinfo or lsof)
            let cwd = self?.getCwd(pid: pid) ?? ""
            let gitInfo = self?.getGitInfo(cwd: cwd) ?? ""

            // Update token tracking for Claude sessions
            if isClaudeSession {
                TokenTracker.shared.update(projectPath: cwd.isEmpty ? nil : cwd)
            }
            let tokenDisplay = isClaudeSession ? TokenTracker.shared.displayString : ""

            DispatchQueue.main.async {
                let oldPath = self?.currentPath
                self?.currentPath = cwd.isEmpty ? nil : cwd
                self?.pathButton.title = self?.shortenPath(cwd) ?? ""
                self?.gitLabel.stringValue = gitInfo
                self?.tokensLabel.stringValue = tokenDisplay
                if self?.currentPath != oldPath {
                    self?.onPathChanged?()
                }
            }
        }
    }

    private func getCwd(pid: pid_t) -> String {
        // Find the foreground (deepest child) process, then get its cwd
        let targetPid = findForegroundProcess(pid)
        return getCwdOfPid(targetPid)
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "pid=", "--ppid", "\(ppid)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        // pgrep is more reliable on macOS
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", "\(ppid)"]
        let pgrepPipe = Pipe()
        pgrep.standardOutput = pgrepPipe
        pgrep.standardError = FileHandle.nullDevice

        do {
            try pgrep.run()
            pgrep.waitUntilExit()
            let data = pgrepPipe.fileHandleForReading.readDataToEndOfFile()
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

    private func getGitInfo(cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }

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
            guard proc.terminationStatus == 0 else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !branch.isEmpty else { return "" }

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
            let changes = statusStr.split(separator: "\n").count

            if changes > 0 {
                return "\(branch) *\(changes)"
            } else {
                return "\(branch)"
            }
        } catch {}
        return ""
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
}
