import AppKit
import CAwalTerminal

class TerminalWindowController: NSWindowController, NSWindowDelegate {

    private let statusBar = StatusBarView()
    let splitContainer: SplitContainerView
    let isInitialTab: Bool

    var inheritedModel: LLMModel?
    var inheritedWorkingDir: String?
    private var customTitle: String?

    init(isInitialTab: Bool = true, model: LLMModel? = nil, workingDir: String? = nil) {
        self.isInitialTab = isInitialTab
        self.inheritedModel = model
        self.inheritedWorkingDir = workingDir

        let rootTerminal: TerminalView
        if isInitialTab {
            // First tab shows the menu
            rootTerminal = TerminalView(frame: .zero)
        } else {
            // Subsequent tabs skip the menu and launch directly
            let m = model ?? ModelCatalog.find("Shell")!
            rootTerminal = TerminalView.createTerminalPane(model: m, workingDir: workingDir)
        }

        self.splitContainer = SplitContainerView(rootTerminal: rootTerminal)

        // Size to ~80% of the screen
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = max(1024, screenFrame.width * 0.8)
        let height = max(700, screenFrame.height * 0.8)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Awal Terminal"
        window.center()
        window.backgroundColor = NSColor(red: 22.0/255.0, green: 22.0/255.0, blue: 22.0/255.0, alpha: 1.0)
        window.isOpaque = true
        window.minSize = NSSize(width: 800, height: 500)

        // Enable native tabs
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "Awal Terminal Tabs"

        // Container with split container + status bar
        let container = NSView()
        container.wantsLayer = true

        splitContainer.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(splitContainer)
        container.addSubview(statusBar)

        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.barHeight),

            splitContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitContainer.topAnchor.constraint(equalTo: container.topAnchor),
            splitContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])

        window.contentView = container
        window.makeFirstResponder(rootTerminal)

        super.init(window: window)
        window.delegate = self

        // Wire terminal callbacks
        wireTerminalCallbacks(rootTerminal)

        // Wire split container focus changes
        splitContainer.onFocusChanged = { [weak self] terminal in
            self?.handleFocusChanged(terminal)
        }

        // Wire status bar folder switching
        statusBar.onFolderSelected = { [weak self] path in
            self?.switchFolder(to: path)
        }
        statusBar.onOpenFolderRequested = { [weak self] in
            self?.showFolderPicker()
        }
        statusBar.onModelSelected = { [weak self] modelName in
            self?.openTabWithModel(modelName)
        }
        statusBar.onPathChanged = { [weak self] in
            self?.updateTabTitle()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Terminal Callback Wiring

    func wireTerminalCallbacks(_ terminal: TerminalView) {
        terminal.onSessionChanged = { [weak self] model, provider, cols, rows in
            self?.statusBar.resetSession()
            self?.statusBar.update(model: model, provider: provider, cols: cols, rows: rows)
            self?.updateTabTitle()
        }
        terminal.onShellSpawned = { [weak self] pid in
            self?.statusBar.setShellPid(pid)
        }
        terminal.onFocused = { [weak self] tv in
            self?.splitContainer.setFocused(tv)
        }
    }

    private func updateTabTitle() {
        guard customTitle == nil else { return }

        let model = statusBar.currentModelName.isEmpty ? "Shell" : statusBar.currentModelName
        if let path = statusBar.currentPath {
            let folder = (path as NSString).lastPathComponent
            window?.title = "\(model) — \(folder)"
        } else {
            window?.title = model
        }
    }

    private func handleFocusChanged(_ terminal: TerminalView) {
        // Update status bar with the focused pane's info
        if !terminal.activeModelName.isEmpty {
            statusBar.update(
                model: terminal.activeModelName,
                provider: terminal.activeProvider,
                cols: 0, rows: 0
            )
        }
        if let s = terminal.surfacePointer {
            let pid = at_surface_get_child_pid(s)
            if pid > 0 {
                statusBar.trackTerminal(pid: pid_t(pid))
            }
        }
        updateTabTitle()
    }

    // MARK: - Tab Actions

    @objc func newTab(_ sender: Any?) {
        let newController = TerminalWindowController(
            isInitialTab: true
        )

        TerminalWindowTracker.shared.register(newController)
        window?.addTabbedWindow(newController.window!, ordered: .above)
        newController.showWindow(nil)
        newController.window?.makeKeyAndOrderFront(nil)
    }

    @objc func closeTab(_ sender: Any?) {
        window?.performClose(nil)
    }

    // MARK: - Split Actions

    @objc func splitRight(_ sender: Any?) {
        performSplit(direction: .horizontal)
    }

    @objc func splitDown(_ sender: Any?) {
        performSplit(direction: .vertical)
    }

    private func performSplit(direction: SplitDirection) {
        let focused = splitContainer.focusedTerminal
        let model = focused.currentModel ?? ModelCatalog.find("Shell")!
        let dir = statusBar.currentPath

        let newTerminal = TerminalView.createTerminalPane(model: model, workingDir: dir)
        wireTerminalCallbacks(newTerminal)
        splitContainer.splitFocused(direction: direction, newTerminal: newTerminal)
    }

    @objc func closePane(_ sender: Any?) {
        let hasRemaining = splitContainer.closeFocused()
        if !hasRemaining {
            window?.performClose(nil)
        }
    }

    // MARK: - Focus Actions

    @objc func focusNextPane(_ sender: Any?) {
        splitContainer.focusNext()
    }

    @objc func focusPreviousPane(_ sender: Any?) {
        splitContainer.focusPrevious()
    }

    // MARK: - Rename Tab

    @objc func renameTab(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = window?.title ?? ""
        alert.accessoryView = input

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                let newTitle = input.stringValue
                if !newTitle.isEmpty {
                    self?.customTitle = newTitle
                    self?.window?.title = newTitle
                }
            } else if response == .alertThirdButtonReturn {
                self?.customTitle = nil
                self?.updateTabTitle()
            }
        }
    }

    // MARK: - Model Selection

    private func openTabWithModel(_ modelName: String) {
        guard let model = ModelCatalog.find(modelName) else { return }

        let focused = splitContainer.focusedTerminal
        if focused.activeModelName == modelName || (modelName == "Shell" && focused.activeModelName.isEmpty) {
            return
        }

        let dir = statusBar.currentPath
        let newController = TerminalWindowController(
            isInitialTab: false,
            model: model,
            workingDir: dir
        )

        TerminalWindowTracker.shared.register(newController)
        window?.addTabbedWindow(newController.window!, ordered: .above)
        newController.showWindow(nil)
        newController.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Settings

    @objc func openSettings(_ sender: Any?) {
        let focused = splitContainer.focusedTerminal
        let modelName = focused.activeModelName.isEmpty ? "Claude" : focused.activeModelName
        ConfigEditorWindow.show(activeModelName: modelName)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // If this window has sibling tabs, detach and close only this tab
        if let tabbedWindows = sender.tabbedWindows, tabbedWindows.count > 1 {
            // Move to another tab first, then remove this one
            if let nextWindow = tabbedWindows.first(where: { $0 !== sender }) {
                nextWindow.makeKeyAndOrderFront(nil)
            }
            sender.orderOut(nil)
            TerminalWindowTracker.shared.remove(self)
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        TerminalWindowTracker.shared.remove(self)
    }

    func window(_ window: NSWindow, shouldPopUpDocumentPathMenu menu: NSMenu) -> Bool {
        return false
    }

    // MARK: - Folder Switching

    private func switchFolder(to path: String) {
        let focused = splitContainer.focusedTerminal
        let isLLMSession = !focused.activeModelName.isEmpty && focused.activeModelName != "Shell"

        if !isLLMSession {
            changeFolderInCurrentSession(path)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Open Folder"
        alert.informativeText = "A \(focused.activeModelName) session is running. How would you like to open this folder?"
        alert.addButton(withTitle: "New Tab")
        alert.addButton(withTitle: "Change in Session")
        alert.addButton(withTitle: "Cancel")

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.openNewSession(with: path)
            case .alertSecondButtonReturn:
                self?.changeFolderInCurrentSession(path)
            default:
                break
            }
        }
    }

    private func changeFolderInCurrentSession(_ path: String) {
        let focused = splitContainer.focusedTerminal

        focused.changeDirectory(path)

        let currentModel = focused.activeModelName.isEmpty ? "Shell" : focused.activeModelName
        WorkspaceStore.shared.save(path: path, model: currentModel)
        updateTabTitle()
    }

    private func openNewSession(with path: String) {
        let focused = splitContainer.focusedTerminal
        let model = focused.currentModel ?? ModelCatalog.find("Shell")!

        let newController = TerminalWindowController(
            isInitialTab: false,
            model: model,
            workingDir: path
        )
        TerminalWindowTracker.shared.register(newController)
        window?.addTabbedWindow(newController.window!, ordered: .above)
        newController.showWindow(nil)
        newController.window?.makeKeyAndOrderFront(nil)
    }

    private func showFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Select a workspace folder"

        guard let window = self.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.switchFolder(to: url.path)
        }
    }
}

