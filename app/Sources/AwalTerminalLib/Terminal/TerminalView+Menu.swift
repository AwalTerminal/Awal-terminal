import AppKit
import CAwalTerminal

extension TerminalView {

    // MARK: - Menu Entry Building

    func buildMenuEntries() {
        menuEntries = []

        switch menuPhase {
        case .main:
            // Restore previous session entry
            if let saved = WindowStateStore.load() {
                let count = saved.tabs.count
                let ago = Self.timeAgoString(from: saved.savedAt)
                let models = Self.restoreSummary(from: saved)
                menuEntries.append(.restoreSession(tabCount: count, timeAgo: ago, models: models))
                menuEntries.append(.separator)
            }

            let recents = WorkspaceStore.shared.recents().filter { !$0.path.contains("/.git/awal-worktrees/") }
            if !recents.isEmpty {
                menuEntries.append(.sectionHeader("Recent Workspaces"))
                for ws in recents {
                    menuEntries.append(.recentWorkspace(ws))
                }
                menuEntries.append(.separator)
            }

            menuEntries.append(.sectionHeader("New Session"))
            for item in modelItems {
                menuEntries.append(.modelItem(item))
            }
            menuEntries.append(.separator)
            menuEntries.append(.resumeSessionsLink)
            menuEntries.append(.separator)
            menuEntries.append(.openFolder)

        case .pickModel:
            for item in modelItems {
                menuEntries.append(.modelItem(item))
            }

        case .pickFolder:
            let recents = WorkspaceStore.shared.recents()
            // Deduplicate folder paths
            var seen = Set<String>()
            var folders: [String] = []
            for ws in recents {
                if seen.insert(ws.path).inserted {
                    folders.append(ws.path)
                }
            }
            if !folders.isEmpty {
                menuEntries.append(.sectionHeader("Recent Folders"))
                for path in folders {
                    menuEntries.append(.recentFolder(path))
                }
                menuEntries.append(.separator)
            }
            menuEntries.append(.openFolder)

        case .resumeSessions:
            menuEntries.append(.sectionHeader("Resume Session"))
            menuEntries.append(.loadingIndicator("Loading sessions..."))
        }
    }

    func isSelectable(_ entry: MenuEntry) -> Bool {
        switch entry {
        case .sectionHeader, .separator, .loadingIndicator:
            return false
        case .restoreSession:
            return true
        default:
            return true
        }
    }

    func moveSelection(by delta: Int) {
        let count = menuEntries.count
        guard count > 0 else { return }

        var next = menuSelection
        for _ in 0..<count {
            next = (next + delta + count) % count
            if isSelectable(menuEntries[next]) {
                menuSelection = next
                return
            }
        }
    }

    func moveToFirstSelectable() {
        for (i, entry) in menuEntries.enumerated() {
            if isSelectable(entry) {
                menuSelection = i
                return
            }
        }
    }

    // MARK: - TUI Menu

    func renderMenu() {
        guard let s = surface else { return }
        if menuEntries.isEmpty {
            buildMenuEntries()
            moveToFirstSelectable()
        }
        let cols = Int(termCols)
        let rows = Int(termRows)

        var out = ""
        out += "\u{1b}[2J"     // clear screen
        out += "\u{1b}[?25l"   // hide cursor
        out += "\u{1b}[H"      // home

        // ASCII art "AWAL"
        let artLines = [
            "  ████    ██      ██    ████    ██      ",
            "██    ██  ██      ██  ██    ██  ██      ",
            "████████  ██  ██  ██  ████████  ██      ",
            "██    ██  ██████████  ██    ██  ██      ",
            "██    ██  ████  ████  ██    ██  ████████"
        ]
        let artWidth = 40
        let useArt = cols >= artWidth + 4 && rows >= 20

        // Calculate total visible lines
        let titleLines = useArt ? artLines.count + 3 : 3
        let entryLines = menuEntries.count
        let hintLines = 2  // blank + hint
        let totalLines = titleLines + entryLines + hintLines
        let startRow = max(1, (rows - totalLines) / 2)

        // Subtitle text
        let subtitle: String
        switch menuPhase {
        case .main:
            subtitle = "Select a workspace"
        case .pickModel(let path):
            subtitle = "Select a model for \(shortenPath(path))"
        case .pickFolder(let model):
            subtitle = "Select a folder for \(model.name)"
        case .resumeSessions:
            subtitle = "Resume a previous session"
        }

        if useArt {
            // Render ASCII art in white shades
            let artPad = max(0, (cols - artWidth) / 2)
            for (lineIdx, artLine) in artLines.enumerated() {
                let row = startRow + lineIdx
                out += "\u{1b}[\(row);1H"
                out += String(repeating: " ", count: artPad)
                for (charIdx, ch) in artLine.enumerated() {
                    if ch == "█" {
                        let t = Double(charIdx) / Double(artWidth - 1)
                        let v = Int(255.0 - t * 105.0) // 255 → 150
                        out += "\u{1b}[38;2;\(v);\(v);\(v)m█"
                    } else {
                        out += " "
                    }
                }
                out += "\u{1b}[0m"
            }
            let subPad = max(0, (cols - subtitle.count) / 2)
            out += "\u{1b}[\(startRow + artLines.count + 1);1H"
            out += "\u{1b}[90m"
            out += String(repeating: " ", count: subPad) + subtitle
            out += "\u{1b}[0m"
        } else {
            // Fallback: simple text title
            let title = "Awal Terminal"
            let titlePad = max(0, (cols - title.count) / 2)
            out += "\u{1b}[\(startRow);1H"
            out += "\u{1b}[1;37m"
            out += String(repeating: " ", count: titlePad) + title
            out += "\u{1b}[0m"
            let subPad = max(0, (cols - subtitle.count) / 2)
            out += "\u{1b}[\(startRow + 1);1H"
            out += "\u{1b}[90m"
            out += String(repeating: " ", count: subPad) + subtitle
            out += "\u{1b}[0m"
        }

        // Menu entries
        let itemWidth = 44
        let itemStart = max(0, (cols - itemWidth) / 2)
        let itemPadStr = String(repeating: " ", count: itemStart)

        for (i, entry) in menuEntries.enumerated() {
            let row = startRow + titleLines + i
            out += "\u{1b}[\(row);1H"

            switch entry {
            case .sectionHeader(let text):
                out += itemPadStr
                out += "\u{1b}[1;90m"
                out += " \(text)"
                out += "\u{1b}[0m"

            case .separator:
                let sep = String(repeating: "─", count: itemWidth)
                out += "\u{1b}[90m"
                out += itemPadStr + sep
                out += "\u{1b}[0m"

            case .restoreSession(let tabCount, let timeAgo, let models):
                let isSelected = i == menuSelection
                let arrow = isSelected ? "▸" : " "
                let tabLabel = tabCount == 1 ? "1 tab" : "\(tabCount) tabs"
                let title = "Restore \(tabLabel)"
                let detail = "\(models) · \(timeAgo)"

                if isSelected {
                    let dismissHint = "d"
                    let pad = itemWidth - 4 - title.count - detail.count - dismissHint.count - 1
                    out += itemPadStr
                    out += "\u{1b}[48;2;39;174;96m"
                    out += "\u{1b}[1;37m"
                    out += " \(arrow) \(title)"
                    out += "\u{1b}[0;37m\u{1b}[48;2;39;174;96m"
                    out += String(repeating: " ", count: max(1, pad))
                    out += detail
                    out += "\u{1b}[90m\u{1b}[48;2;39;174;96m"
                    out += " \(dismissHint) "
                    out += "\u{1b}[0m"
                } else {
                    let pad = itemWidth - 4 - title.count - detail.count
                    out += itemPadStr
                    out += "\u{1b}[32m"
                    out += " \(arrow) \(title)"
                    out += "\u{1b}[90m"
                    out += String(repeating: " ", count: max(1, pad))
                    out += detail + " "
                    out += "\u{1b}[0m"
                }

            case .recentWorkspace(let ws):
                let isSelected = i == menuSelection
                let isPendingDelete = pendingDeleteIndex == i

                if isPendingDelete {
                    // Red confirmation row
                    let prompt = "Delete? y/n"
                    let maxPathLen = itemWidth - 4 - prompt.count
                    let truncPath = compactPath(ws.path, maxLen: maxPathLen)
                    let nameField = truncPath.padding(toLength: max(maxPathLen, 1), withPad: " ", startingAt: 0)
                    out += itemPadStr
                    out += "\u{1b}[48;2;180;40;40m"  // red bg
                    out += "\u{1b}[1;37m"
                    out += " ▸ \(nameField)"
                    out += "\u{1b}[0;37m"
                    out += "\u{1b}[48;2;180;40;40m"
                    out += " \(prompt) "
                    out += "\u{1b}[0m"
                } else {
                    let arrow = isSelected ? "▸" : " "
                    let modelStr = ws.lastModel

                    if isSelected {
                        // Show model name + dim ⌫ hint
                        let suffix = "\(modelStr) ⌫"
                        let maxPathLen = itemWidth - 6 - suffix.count
                        let truncPath = compactPath(ws.path, maxLen: maxPathLen)
                        let nameField = truncPath.padding(toLength: max(maxPathLen, 1), withPad: " ", startingAt: 0)
                        out += itemPadStr
                        out += "\u{1b}[48;2;45;127;212m"
                        out += "\u{1b}[1;37m"
                        out += " \(arrow) \(nameField)"
                        out += "\u{1b}[0;37m"
                        out += "\u{1b}[48;2;45;127;212m"
                        out += " \(modelStr)"
                        out += "\u{1b}[90m"
                        out += "\u{1b}[48;2;45;127;212m"
                        out += " ⌫ "
                        out += "\u{1b}[0m"
                    } else {
                        let maxPathLen = itemWidth - 6 - modelStr.count
                        let truncPath = compactPath(ws.path, maxLen: maxPathLen)
                        let nameField = truncPath.padding(toLength: max(maxPathLen, 1), withPad: " ", startingAt: 0)
                        out += itemPadStr
                        out += "\u{1b}[37m"
                        out += " \(arrow) \(nameField)"
                        out += "\u{1b}[90m"
                        out += " \(modelStr) "
                        out += "\u{1b}[0m"
                    }
                }

            case .recentFolder(let path):
                let isSelected = i == menuSelection
                let arrow = isSelected ? "▸" : " "
                let maxPathLen = itemWidth - 4
                let truncPath = compactPath(path, maxLen: maxPathLen)

                if isSelected {
                    let nameField = truncPath.padding(toLength: max(maxPathLen, 1), withPad: " ", startingAt: 0)
                    out += itemPadStr
                    out += "\u{1b}[48;2;45;127;212m"
                    out += "\u{1b}[1;37m"
                    out += " \(arrow) \(nameField)"
                    out += " "
                    out += "\u{1b}[0m"
                } else {
                    out += itemPadStr
                    out += "\u{1b}[37m"
                    out += " \(arrow) \(truncPath)"
                    out += "\u{1b}[0m"
                }

            case .modelItem(let item):
                let isSelected = i == menuSelection
                let arrow = isSelected ? "▸" : " "
                let nameField = item.name.padding(toLength: 14, withPad: " ", startingAt: 0)
                let providerField = item.provider

                if isSelected {
                    out += itemPadStr
                    out += "\u{1b}[48;2;45;127;212m"
                    out += "\u{1b}[1;37m"
                    out += " \(arrow) \(nameField)"
                    out += "\u{1b}[0;37m"
                    out += "\u{1b}[48;2;45;127;212m"
                    let provPad = itemWidth - 4 - nameField.count - providerField.count
                    out += String(repeating: " ", count: max(1, provPad))
                    out += providerField + " "
                    out += "\u{1b}[0m"
                } else {
                    out += itemPadStr
                    out += "\u{1b}[37m"
                    out += " \(arrow) \(nameField)"
                    out += "\u{1b}[90m"
                    let provPad = itemWidth - 4 - nameField.count - providerField.count
                    out += String(repeating: " ", count: max(1, provPad))
                    out += providerField + " "
                    out += "\u{1b}[0m"
                }

            case .openFolder:
                let isSelected = i == menuSelection
                let arrow = isSelected ? "▸" : " "
                let text = "Open Folder..."

                if isSelected {
                    out += itemPadStr
                    out += "\u{1b}[48;2;45;127;212m"
                    out += "\u{1b}[1;37m"
                    out += " \(arrow) \(text)"
                    let pad = itemWidth - 4 - text.count
                    out += String(repeating: " ", count: max(1, pad))
                    out += " "
                    out += "\u{1b}[0m"
                } else {
                    out += itemPadStr
                    out += "\u{1b}[37m"
                    out += " \(arrow) \(text)"
                    out += "\u{1b}[0m"
                }

            case .resumeSessionsLink:
                let isSelected = i == menuSelection
                let arrow = isSelected ? "▸" : " "
                let text = "Resume Session"
                let suffix = "▸"

                if isSelected {
                    let pad = itemWidth - 4 - text.count - suffix.count
                    out += itemPadStr
                    out += "\u{1b}[48;2;45;127;212m"
                    out += "\u{1b}[1;37m"
                    out += " \(arrow) \(text)"
                    out += String(repeating: " ", count: max(1, pad))
                    out += suffix + " "
                    out += "\u{1b}[0m"
                } else {
                    out += itemPadStr
                    out += "\u{1b}[37m"
                    out += " \(arrow) \(text)"
                    let pad = itemWidth - 4 - text.count - suffix.count
                    out += String(repeating: " ", count: max(1, pad))
                    out += "\u{1b}[90m\(suffix)"
                    out += "\u{1b}[0m"
                }

            case .resumeSession(let entry):
                let isSelected = i == menuSelection
                let arrow = isSelected ? "▸" : " "
                let modelField = entry.modelName.padding(toLength: 8, withPad: " ", startingAt: 0)
                let summaryStr = entry.summary

                if isSelected {
                    let pad = itemWidth - 4 - 8 - summaryStr.count
                    out += itemPadStr
                    out += "\u{1b}[48;2;45;127;212m"
                    out += "\u{1b}[1;37m"
                    out += " \(arrow) \(modelField)"
                    out += "\u{1b}[0;37m\u{1b}[48;2;45;127;212m"
                    out += summaryStr
                    out += String(repeating: " ", count: max(1, pad))
                    out += " "
                    out += "\u{1b}[0m"
                } else {
                    out += itemPadStr
                    out += "\u{1b}[37m"
                    out += " \(arrow) \(modelField)"
                    out += "\u{1b}[90m"
                    out += summaryStr
                    out += "\u{1b}[0m"
                }

            case .loadingIndicator(let text):
                out += itemPadStr
                out += "\u{1b}[90m"
                out += " \(text)"
                out += "\u{1b}[0m"
            }
        }

        // Footer hint
        let hint: String
        switch menuPhase {
        case .main:
            hint = "↑↓/jk Navigate  ⏎ Select  ⌫ Delete  o Open  Esc Shell"
        case .pickModel:
            hint = "↑↓/jk Navigate  ⏎ Select  Esc Back"
        case .pickFolder:
            hint = "↑↓/jk Navigate  ⏎ Select  o Open  Esc Back"
        case .resumeSessions:
            hint = "↑↓/jk Navigate  ⏎ Select  Esc Back"
        }
        let hintPad = max(0, (cols - hint.count) / 2)
        let hintRow = startRow + titleLines + menuEntries.count + 1
        out += "\u{1b}[\(hintRow);1H"
        out += "\u{1b}[90m"
        out += String(repeating: " ", count: hintPad) + hint
        out += "\u{1b}[0m"

        // Feed to parser
        let bytes = Array(out.utf8)
        bytes.withUnsafeBufferPointer { ptr in
            at_surface_feed_bytes(s, ptr.baseAddress!, UInt32(ptr.count))
        }

        menuRendered = true
        updateCellBuffer()
        needsRender = true
    }

    func handleSelection() {
        guard menuSelection < menuEntries.count else { return }

        let entry = menuEntries[menuSelection]
        switch entry {
        case .restoreSession:
            onRestoreSession?()
            return

        case .recentWorkspace(let ws):
            let model = modelItems.first { $0.name == ws.lastModel } ?? modelItems[0]
            launchSession(model: model, workingDir: ws.path, dangerMode: AppConfig.shared.dangerModeEnabled)

        case .modelItem(let item):
            switch menuPhase {
            case .main:
                if item.command.isEmpty {
                    // Shell → launch immediately
                    launchSession(model: item, workingDir: nil)
                } else {
                    // LLM → pick a folder first
                    menuPhase = .pickFolder(item)
                    buildMenuEntries()
                    moveToFirstSelectable()
                    renderMenu()
                }
            case .pickModel(let folder):
                launchSession(model: item, workingDir: folder, dangerMode: AppConfig.shared.dangerModeEnabled)
            case .pickFolder, .resumeSessions:
                break
            }

        case .recentFolder(let path):
            if case .pickFolder(let model) = menuPhase {
                launchSession(model: model, workingDir: path, dangerMode: AppConfig.shared.dangerModeEnabled)
            }

        case .openFolder:
            showFolderPicker()

        case .resumeSessionsLink:
            showResumeSessionFolderPicker()

        case .resumeSession(let entry):
            launchResumeSession(entry)

        default:
            break
        }
    }

    func showResumeSessionFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select a project folder to find sessions"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        menuPhase = .resumeSessions
        isLoadingResumeSessions = true
        loadingPhase = 0
        buildMenuEntries()
        renderMenu()
        loadResumableSessionsAsync(projectPath: url.path)
    }

    func loadResumableSessionsAsync(projectPath: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = SessionManager.shared.discoverResumableSessions(for: projectPath)
            DispatchQueue.main.async {
                guard let self = self, case .resumeSessions = self.menuPhase else { return }
                self.isLoadingResumeSessions = false
                self.menuEntries.removeAll()
                if entries.isEmpty {
                    self.menuEntries.append(.sectionHeader("No sessions found"))
                } else {
                    let headerPath = self.compactPath(projectPath, maxLen: 30)
                    self.menuEntries.append(.sectionHeader("Resume Session · \(headerPath)"))
                    for entry in entries {
                        self.menuEntries.append(.resumeSession(entry))
                    }
                }
                self.moveToFirstSelectable()
                self.renderMenu()
            }
        }
    }

    func launchResumeSession(_ entry: SessionManager.ResumeEntry) {
        guard let model = modelItems.first(where: { $0.name == entry.modelName }) else { return }

        let cmd: String
        if entry.isInteractive {
            cmd = model.resumeCommand ?? model.command
        } else if let sid = entry.sessionId, let resumeCmd = model.resumeCommand {
            cmd = "\(resumeCmd) \(sid)"
        } else {
            cmd = model.command
        }

        launchSession(model: model, workingDir: entry.projectPath, commandOverride: cmd)
    }

    func launchSession(model: MenuItem, workingDir: String?, commandOverride: String? = nil, dangerMode: Bool = false) {
        // Skip workspace resolution for restored sessions (avoid worktree prompts)
        if skipWorkspaceResolution {
            skipWorkspaceResolution = false
            launchSessionDirect(model: model, workingDir: workingDir, commandOverride: commandOverride, dangerMode: dangerMode)
            return
        }
        // If a workspace resolution callback is set and we have a working dir, let the controller
        // resolve the directory first (e.g., to create a git worktree for isolation).
        if let dir = workingDir, let callback = onWorkspacePicked {
            callback(dir) { [weak self] resolvedDir in
                self?.launchSessionDirect(model: model, workingDir: resolvedDir, commandOverride: commandOverride, dangerMode: dangerMode)
            }
            return
        }
        launchSessionDirect(model: model, workingDir: workingDir, commandOverride: commandOverride, dangerMode: dangerMode)
    }

    func launchSessionDirect(model: MenuItem, workingDir: String?, commandOverride: String? = nil, dangerMode: Bool = false) {
        guard let s = surface else { return }

        activeModelName = model.name
        activeProvider = model.provider
        isRemoteControlActive = false
        remoteControlURL = nil
        if let s = surface { at_surface_clear_remote_control(s) }
        appState = .terminal
        menuRenderPending = false
        deferredMenuRender?.cancel()
        deferredMenuRender = nil

        // Clear screen, show cursor, reset
        let reset = "\u{1b}[2J\u{1b}[H\u{1b}[?25h\u{1b}[0m"
        let resetBytes = Array(reset.utf8)
        resetBytes.withUnsafeBufferPointer { ptr in
            at_surface_feed_bytes(s, ptr.baseAddress!, UInt32(ptr.count))
        }

        updateCellBuffer()
        needsRender = true
        isWaitingForOutput = true
        loadingPhase = 0

        recalculateGridSize()
        showLoadingMessage(model: model.name)

        // Save workspace (skip worktree paths to avoid polluting recent list)
        if let dir = workingDir, !dir.contains("/.git/awal-worktrees/") {
            WorkspaceStore.shared.save(path: dir, model: model.name)
        }

        // Inject AI components in background (non-blocking — process launches immediately)
        lastAIComponentContext = nil
        postSessionHooks = []
        beforeCommitHooks = []
        lastWorkingDir = workingDir
        if let dir = workingDir, AppConfig.shared.aiComponentsEnabled {
            let modelName = model.name
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let aiComponentContext = AIComponentInjector.inject(
                    modelName: modelName,
                    projectPath: dir
                )
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.lastAIComponentContext = aiComponentContext
                    if let ctx = aiComponentContext {
                        self.postSessionHooks = ctx.postSessionHooks
                        self.beforeCommitHooks = ctx.beforeCommitHooks
                        for hookURL in ctx.preSessionHooks {
                            self.executeHookScript(hookURL, workingDir: dir)
                        }
                    }
                }
            }
        }

        // Build the full command to execute
        var modelCmd = commandOverride ?? model.command
        if commandOverride == nil, !modelCmd.isEmpty, let bin = model.binaryName, let install = model.installCommand {
            modelCmd = "command -v \(bin) >/dev/null 2>&1 || { echo \"Installing \(model.name)...\"; \(install); } && \(model.command)"
        }

        // Danger mode: append skip-permissions flag if supported
        isDangerMode = dangerMode
        if dangerMode, commandOverride == nil, let flag = model.dangerFlag, !flag.isEmpty {
            modelCmd += " \(flag)"
        }

        // Remote control: append --remote-control flag if supported
        if AppConfig.shared.remoteControlEnabled, commandOverride == nil,
           let flag = model.remoteControlFlag, !flag.isEmpty {
            modelCmd += " \(flag)"
        }

        let hasCommand = !modelCmd.isEmpty

        if hasCommand {
            // Spawn shell with -c to run the command directly (no interactive prompt)
            var parts: [String] = []
            if let dir = workingDir {
                parts.append("cd \"\(dir)\"")
            }
            parts.append(modelCmd)
            let fullCmd = parts.joined(separator: " && ")

            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let result = shell.withCString { shellPtr in
                fullCmd.withCString { cmdPtr in
                    at_surface_spawn_command(s, shellPtr, cmdPtr)
                }
            }
            if result != 0 {
                debugLog("Failed to spawn command, falling back to shell")
                spawnShell()
            }
        } else {
            // Plain shell (no model command)
            spawnShell()
            if let dir = workingDir {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let s = self?.surface else { return }
                    let cmd = "cd \"\(dir)\"\n"
                    let cmdBytes = Array(cmd.utf8)
                    cmdBytes.withUnsafeBufferPointer { ptr in
                        _ = at_surface_key_event(s, ptr.baseAddress!, UInt32(ptr.count))
                    }
                }
            }
        }

        setupPtyReader()
        onSessionChanged?(model.name, model.provider, Int(termCols), Int(termRows))
    }

    func showLoadingMessage(model: String) {
        guard let s = surface else { return }
        let rows = Int(termRows)
        let cols = Int(termCols)
        guard rows > 2, cols > 10 else { return }

        let spinnerChars: [Character] = ["◐", "◓", "◑", "◒"]
        let modelLower = model.lowercased()

        let modelMessages: [((String) -> Bool, [String])] = [
            ({ $0.contains("gemini") }, [
                "Waking up Gemini...",
                "Consulting the oracle...",
                "Polishing the crystal ball...",
            ]),
            ({ $0.contains("claude") }, [
                "Summoning Claude...",
                "Brewing some intelligence...",
                "Stretching neurons...",
            ]),
            ({ $0.contains("codex") || $0.contains("openai") }, [
                "Booting Codex...",
                "Calibrating synapses...",
                "Warming up the engines...",
            ]),
        ]

        let genericMessages = [
            "Brewing some intelligence...",
            "Stretching neurons...",
            "Consulting the oracle...",
            "Calibrating synapses...",
        ]

        var message = genericMessages.randomElement()!
        for (matches, messages) in modelMessages {
            if matches(modelLower) {
                message = messages.randomElement()!
                break
            }
        }

        loadingMessageText = message
        let spinner = spinnerChars[0]
        let fullText = "\(spinner)  \(message)"
        let textLen = fullText.count

        let row = rows / 2
        let col = max(1, (cols - textLen) / 2)
        loadingSpinnerRow = row
        loadingSpinnerCol = col

        // Position cursor and write dim text: \e[{row};{col}H\e[2m{text}\e[0m
        let ansi = "\u{1b}[\(row);\(col)H\u{1b}[2m\(fullText)\u{1b}[0m"
        let bytes = Array(ansi.utf8)
        bytes.withUnsafeBufferPointer { ptr in
            at_surface_feed_bytes(s, ptr.baseAddress!, UInt32(ptr.count))
        }
        updateCellBuffer()
        needsRender = true
    }

    func showFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Select a workspace folder"

        guard let window = self.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if case .pickFolder(let model) = self?.menuPhase {
                self?.launchSession(model: model, workingDir: url.path, dangerMode: AppConfig.shared.dangerModeEnabled)
            } else {
                self?.menuPhase = .pickModel(url.path)
                self?.buildMenuEntries()
                self?.moveToFirstSelectable()
                self?.renderMenu()
            }
        }
    }

    func changeDirectory(_ path: String) {
        guard let s = surface, appState == .terminal else { return }
        let cmd = "cd \"\(path)\"\n"
        let cmdBytes = Array(cmd.utf8)
        cmdBytes.withUnsafeBufferPointer { ptr in
            _ = at_surface_key_event(s, ptr.baseAddress!, UInt32(ptr.count))
        }
    }

    func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Compact path: abbreviates intermediate directories to fit within `maxLen`.
    /// Example: ~/Projects/Workspace/Code/awal-terminal → ~/P…/W…/Code/awal-terminal
    static func timeAgoString(from date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }

    static func restoreSummary(from state: SavedWindowState) -> String {
        // Collect unique model names preserving order
        var seen = Set<String>()
        var models: [String] = []
        for tab in state.tabs {
            if case .leaf(let pane) = tab.splitTree {
                let name = pane.modelName.isEmpty ? "Shell" : pane.modelName
                if seen.insert(name).inserted { models.append(name) }
            }
        }
        return models.joined(separator: ", ")
    }

    func compactPath(_ path: String, maxLen: Int) -> String {
        let shortened = shortenPath(path)
        if shortened.count <= maxLen { return shortened }

        let components = shortened.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 2 else {
            return String(shortened.prefix(maxLen - 1)) + "…"
        }

        // Try last 2 components: ~/…/parent/last
        if components.count >= 3 {
            let last2 = components.suffix(2).joined(separator: "/")
            let candidate = "~/…/" + last2
            if candidate.count <= maxLen { return candidate }
        }

        // Try last component only: ~/…/last
        let last = components.last!
        let candidate = "~/…/" + last
        if candidate.count <= maxLen { return candidate }

        // Final fallback: hard-truncate
        return String(shortened.prefix(maxLen - 1)) + "…"
    }

    // MARK: - Return to Menu

    func returnToMenu() {
        appState = .menu
        menuPhase = .main
        menuRendered = false
        menuSelection = 0
        activeModelName = ""
        activeProvider = ""

        readSource?.cancel()
        readSource = nil
        processSource?.cancel()
        processSource = nil

        if let s = surface {
            let reset = "\u{1b}[2J\u{1b}[H\u{1b}[?25h\u{1b}[0m"
            let resetBytes = Array(reset.utf8)
            resetBytes.withUnsafeBufferPointer { ptr in
                at_surface_feed_bytes(s, ptr.baseAddress!, UInt32(ptr.count))
            }
        }

        buildMenuEntries()
        renderMenu()
    }
}
