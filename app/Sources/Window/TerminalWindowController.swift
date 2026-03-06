import AppKit
import CAwalTerminal

class TerminalWindowController: NSWindowController, NSWindowDelegate, CustomTabBarDelegate {

    private let tabBar = CustomTabBarView()
    private let contentArea = NSView()

    private(set) var tabs: [TabState] = []
    private(set) var activeTabIndex: Int = 0

    private var activeTab: TabState { tabs[activeTabIndex] }

    init(isInitialTab: Bool = true, model: LLMModel? = nil, workingDir: String? = nil) {
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
        window.backgroundColor = AppConfig.shared.themeTabBarBg
        window.isOpaque = true
        window.minSize = NSSize(width: 800, height: 500)

        // Disable native tabs
        window.tabbingMode = .disallowed

        super.init(window: window)
        window.delegate = self

        // Layout: tabBar at top, contentArea fills the rest
        let container = NSView()
        container.wantsLayer = true

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        contentArea.wantsLayer = true

        container.addSubview(tabBar)
        container.addSubview(contentArea)

        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: CustomTabBarView.barHeight),

            contentArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentArea.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window.contentView = container

        // Create the first tab
        let tab = createTabState(isInitialTab: isInitialTab, model: model, workingDir: workingDir)
        tabs.append(tab)
        activeTabIndex = 0
        installTab(tab)
        reloadTabBar()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Tab State Creation

    private func createTabState(isInitialTab: Bool, model: LLMModel? = nil, workingDir: String? = nil) -> TabState {
        let rootTerminal: TerminalView
        if isInitialTab {
            rootTerminal = TerminalView(frame: .zero)
        } else {
            let m = model ?? ModelCatalog.find("Shell")!
            rootTerminal = TerminalView.createTerminalPane(model: m, workingDir: workingDir)
        }

        let splitContainer = SplitContainerView(rootTerminal: rootTerminal)
        let statusBar = StatusBarView()
        let aiSidePanel = AISidePanelView()
        aiSidePanel.hide() // Hidden by default
        let tab = TabState(splitContainer: splitContainer, statusBar: statusBar, aiSidePanel: aiSidePanel)

        wireTerminalCallbacks(rootTerminal, tab: tab)
        wireSplitContainer(splitContainer, tab: tab)
        wireStatusBar(statusBar, tab: tab)

        return tab
    }

    // MARK: - Tab Installation (swap views in/out)

    private func installTab(_ tab: TabState) {
        // Clear content area
        contentArea.subviews.forEach { $0.removeFromSuperview() }

        tab.splitContainer.translatesAutoresizingMaskIntoConstraints = false
        tab.statusBar.translatesAutoresizingMaskIntoConstraints = false
        tab.aiSidePanel.translatesAutoresizingMaskIntoConstraints = false

        contentArea.addSubview(tab.splitContainer)
        contentArea.addSubview(tab.statusBar)
        contentArea.addSubview(tab.aiSidePanel)

        // Side panel clips content when collapsed to 0 width
        tab.aiSidePanel.wantsLayer = true
        tab.aiSidePanel.layer?.masksToBounds = true

        let widthConstraint = tab.aiSidePanel.widthAnchor.constraint(
            equalToConstant: tab.aiSidePanel.isPanelVisible ? AISidePanelView.defaultWidth : 0
        )
        tab.sidePanelWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            tab.statusBar.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            tab.statusBar.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            tab.statusBar.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            tab.statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.barHeight),

            // AI Side Panel on the right
            tab.aiSidePanel.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            tab.aiSidePanel.topAnchor.constraint(equalTo: contentArea.topAnchor),
            tab.aiSidePanel.bottomAnchor.constraint(equalTo: tab.statusBar.topAnchor),
            widthConstraint,

            // Terminal fills the remaining space
            tab.splitContainer.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            tab.splitContainer.trailingAnchor.constraint(equalTo: tab.aiSidePanel.leadingAnchor),
            tab.splitContainer.topAnchor.constraint(equalTo: contentArea.topAnchor),
            tab.splitContainer.bottomAnchor.constraint(equalTo: tab.statusBar.topAnchor),
        ])

        window?.makeFirstResponder(tab.splitContainer.focusedTerminal)
        updateWindowTitle()
        tab.statusBar.isPaused = false
    }

    private func uninstallTab(_ tab: TabState) {
        tab.splitContainer.removeFromSuperview()
        tab.statusBar.removeFromSuperview()
        tab.aiSidePanel.removeFromSuperview()
        tab.statusBar.isPaused = true
    }

    // MARK: - Tab Bar

    private func reloadTabBar() {
        let titles = tabs.map { $0.title }
        tabBar.reloadTabs(titles: titles, selectedIndex: activeTabIndex)
    }

    private func updateWindowTitle() {
        window?.title = activeTab.title
    }

    // MARK: - Tab Management

    @objc func newTab(_ sender: Any?) {
        let tab = createTabState(isInitialTab: true)
        tabs.append(tab)
        switchToTab(at: tabs.count - 1)
    }

    @objc func closeTab(_ sender: Any?) {
        closeTab(at: activeTabIndex)
    }

    func closeTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        if tabs.count == 1 {
            // Last tab — close the window
            window?.performClose(nil)
            return
        }

        let tab = tabs.remove(at: index)
        uninstallTab(tab)

        // Select adjacent tab
        let newIndex: Int
        if index >= tabs.count {
            newIndex = tabs.count - 1
        } else {
            newIndex = index
        }
        activeTabIndex = newIndex
        installTab(activeTab)
        reloadTabBar()
    }

    func switchToTab(at index: Int) {
        guard index >= 0 && index < tabs.count && index != activeTabIndex else { return }

        uninstallTab(activeTab)
        activeTabIndex = index
        installTab(activeTab)
        reloadTabBar()
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        let next = (activeTabIndex + 1) % tabs.count
        switchToTab(at: next)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        let prev = (activeTabIndex - 1 + tabs.count) % tabs.count
        switchToTab(at: prev)
    }

    // MARK: - CustomTabBarDelegate

    func tabBar(_ tabBar: CustomTabBarView, didSelectTabAt index: Int) {
        switchToTab(at: index)
    }

    func tabBar(_ tabBar: CustomTabBarView, didCloseTabAt index: Int) {
        closeTab(at: index)
    }

    func tabBarDidRequestNewTab(_ tabBar: CustomTabBarView) {
        newTab(nil)
    }

    func tabBar(_ tabBar: CustomTabBarView, didDoubleClickTabAt index: Int) {
        renameTab(at: index)
    }

    func tabBar(_ tabBar: CustomTabBarView, didRightClickTabAt index: Int, location: NSPoint) {
        let menu = NSMenu()

        let renameItem = NSMenuItem(title: "Rename…", action: #selector(contextRename(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.tag = index
        menu.addItem(renameItem)

        menu.addItem(NSMenuItem.separator())

        let closeItem = NSMenuItem(title: "Close", action: #selector(contextClose(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.tag = index
        menu.addItem(closeItem)

        if tabs.count > 1 {
            let closeOthersItem = NSMenuItem(title: "Close Others", action: #selector(contextCloseOthers(_:)), keyEquivalent: "")
            closeOthersItem.target = self
            closeOthersItem.tag = index
            menu.addItem(closeOthersItem)
        }

        menu.popUp(positioning: nil, at: location, in: tabBar)
    }

    func tabBar(_ tabBar: CustomTabBarView, didReorderTabFrom fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0 && fromIndex < tabs.count,
              toIndex >= 0 && toIndex < tabs.count else { return }

        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: toIndex)

        // Update active index to follow the active tab
        if activeTabIndex == fromIndex {
            activeTabIndex = toIndex
        } else if fromIndex < activeTabIndex && toIndex >= activeTabIndex {
            activeTabIndex -= 1
        } else if fromIndex > activeTabIndex && toIndex <= activeTabIndex {
            activeTabIndex += 1
        }
        reloadTabBar()
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        renameTab(at: sender.tag)
    }

    @objc private func contextClose(_ sender: NSMenuItem) {
        closeTab(at: sender.tag)
    }

    @objc private func contextCloseOthers(_ sender: NSMenuItem) {
        let keepIndex = sender.tag
        let keepTab = tabs[keepIndex]
        // Uninstall the currently displayed tab
        uninstallTab(activeTab)
        tabs = [keepTab]
        activeTabIndex = 0
        installTab(keepTab)
        reloadTabBar()
    }

    // MARK: - Rename Tab

    @objc func renameTab(_ sender: Any?) {
        renameTab(at: activeTabIndex)
    }

    private func renameTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        let tab = tabs[index]

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = tab.title
        alert.accessoryView = input

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                let newTitle = input.stringValue
                if !newTitle.isEmpty {
                    tab.customTitle = newTitle
                    self.reloadTabBar()
                    self.updateWindowTitle()
                }
            } else if response == .alertThirdButtonReturn {
                tab.customTitle = nil
                self.reloadTabBar()
                self.updateWindowTitle()
            }
        }
    }

    // MARK: - Terminal Callback Wiring

    private func wireTerminalCallbacks(_ terminal: TerminalView, tab: TabState) {
        terminal.onSessionChanged = { [weak self, weak tab] model, provider, cols, rows in
            guard let self, let tab else { return }
            tab.statusBar.resetSession()
            tab.statusBar.update(model: model, provider: provider, cols: cols, rows: rows)
            tab.aiSidePanel.setModel(model)
            tab.aiSidePanel.resetSession()
            // Enable AI analysis for LLM sessions (not plain Shell)
            let isAI = !model.isEmpty && model != "Shell"
            if let surface = terminal.surfacePointer {
                at_surface_set_ai_analysis(surface, isAI)
            }
            self.reloadTabBar()
            self.updateWindowTitle()
        }
        terminal.onShellSpawned = { [weak tab] pid in
            tab?.statusBar.setShellPid(pid)
        }
        terminal.onFocused = { [weak tab] tv in
            tab?.splitContainer.setFocused(tv)
        }
        terminal.onTerminalIdle = { [weak terminal, weak tab] in
            guard let terminal else { return }
            NotificationManager.shared.notifyIdleIfNeeded(modelName: terminal.activeModelName)
            // Update side panel with latest analyzer data
            tab?.aiSidePanel.updateFromSurface(terminal.surfacePointer)
            // Update token display from TokenTracker
            tab?.aiSidePanel.updateTokenDisplay(
                input: TokenTracker.shared.totalInput,
                output: TokenTracker.shared.totalOutput
            )
        }
        terminal.onGeneratingChanged = { [weak terminal, weak tab] isGenerating in
            guard let terminal, let tab else { return }
            if isGenerating {
                tab.statusBar.setGenerating(true)
                tab.aiSidePanel.setGenerating(true, surface: terminal.surfacePointer, phaseText: terminal.generationPhase)
            } else {
                tab.statusBar.setGenerating(false)
                tab.aiSidePanel.setGenerating(false)
            }
        }
    }

    private func wireSplitContainer(_ splitContainer: SplitContainerView, tab: TabState) {
        splitContainer.onFocusChanged = { [weak self, weak tab] terminal in
            guard let self, let tab else { return }
            self.handleFocusChanged(terminal, tab: tab)
        }
    }

    private func wireStatusBar(_ statusBar: StatusBarView, tab: TabState) {
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
            self?.reloadTabBar()
            self?.updateWindowTitle()
        }
        statusBar.onGitStatusChanged = { [weak tab] changes in
            tab?.aiSidePanel.updateGitChanges(changes)
        }
    }

    private func handleFocusChanged(_ terminal: TerminalView, tab: TabState) {
        if !terminal.activeModelName.isEmpty {
            tab.statusBar.update(
                model: terminal.activeModelName,
                provider: terminal.activeProvider,
                cols: 0, rows: 0
            )
        }
        if let s = terminal.surfacePointer {
            let pid = at_surface_get_child_pid(s)
            if pid > 0 {
                tab.statusBar.setShellPid(pid_t(pid))
            }
        }
        reloadTabBar()
        updateWindowTitle()
    }

    // MARK: - Split Actions

    @objc func splitRight(_ sender: Any?) {
        performSplit(direction: .horizontal)
    }

    @objc func splitDown(_ sender: Any?) {
        performSplit(direction: .vertical)
    }

    private func performSplit(direction: SplitDirection) {
        let tab = activeTab
        let focused = tab.splitContainer.focusedTerminal
        let model = focused.currentModel ?? ModelCatalog.find("Shell")!
        let dir = tab.statusBar.currentPath

        let newTerminal = TerminalView.createTerminalPane(model: model, workingDir: dir)
        wireTerminalCallbacks(newTerminal, tab: tab)
        tab.splitContainer.splitFocused(direction: direction, newTerminal: newTerminal)
    }

    @objc func closePane(_ sender: Any?) {
        let hasRemaining = activeTab.splitContainer.closeFocused()
        if !hasRemaining {
            closeTab(at: activeTabIndex)
        }
    }

    // MARK: - Focus Actions

    @objc func focusNextPane(_ sender: Any?) {
        activeTab.splitContainer.focusNext()
    }

    @objc func focusPreviousPane(_ sender: Any?) {
        activeTab.splitContainer.focusPrevious()
    }

    // MARK: - Search

    @objc func findInTerminal(_ sender: Any?) {
        activeTab.splitContainer.focusedTerminal.toggleSearch()
    }

    // MARK: - Model Selection

    private func openTabWithModel(_ modelName: String) {
        guard let model = ModelCatalog.find(modelName) else { return }

        let focused = activeTab.splitContainer.focusedTerminal
        if focused.activeModelName == modelName || (modelName == "Shell" && focused.activeModelName.isEmpty) {
            return
        }

        let dir = activeTab.statusBar.currentPath
        let tab = createTabState(isInitialTab: false, model: model, workingDir: dir)
        tabs.append(tab)
        switchToTab(at: tabs.count - 1)
    }

    // MARK: - AI Side Panel

    @objc func toggleAISidePanel(_ sender: Any?) {
        let tab = activeTab
        tab.aiSidePanel.toggle()

        let targetWidth: CGFloat = tab.aiSidePanel.isPanelVisible ? AISidePanelView.defaultWidth : 0
        tab.sidePanelWidthConstraint?.constant = targetWidth

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            self.contentArea.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Settings

    @objc func openSettings(_ sender: Any?) {
        let focused = activeTab.splitContainer.focusedTerminal
        let modelName = focused.activeModelName.isEmpty ? "Claude" : focused.activeModelName
        ConfigEditorWindow.show(activeModelName: modelName)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
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
        let tab = activeTab
        let focused = tab.splitContainer.focusedTerminal
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
        let tab = activeTab
        let focused = tab.splitContainer.focusedTerminal

        focused.changeDirectory(path)

        let currentModel = focused.activeModelName.isEmpty ? "Shell" : focused.activeModelName
        WorkspaceStore.shared.save(path: path, model: currentModel)
        reloadTabBar()
        updateWindowTitle()
    }

    private func openNewSession(with path: String) {
        let focused = activeTab.splitContainer.focusedTerminal
        let model = focused.currentModel ?? ModelCatalog.find("Shell")!

        let tab = createTabState(isInitialTab: false, model: model, workingDir: path)
        tabs.append(tab)
        switchToTab(at: tabs.count - 1)
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
