import AppKit
import CAwalTerminal

class TerminalWindowController: NSWindowController, NSWindowDelegate, CustomTabBarDelegate {

    static let defaultTabColorPalette: [NSColor] = [
        NSColor(red: 0xE5/255.0, green: 0x53/255.0, blue: 0x53/255.0, alpha: 1),
        NSColor(red: 0xE8/255.0, green: 0x8A/255.0, blue: 0x3A/255.0, alpha: 1),
        NSColor(red: 0xD4/255.0, green: 0xAC/255.0, blue: 0x0D/255.0, alpha: 1),
        NSColor(red: 0x27/255.0, green: 0xAE/255.0, blue: 0x60/255.0, alpha: 1),
        NSColor(red: 0x34/255.0, green: 0x98/255.0, blue: 0xDB/255.0, alpha: 1),
        NSColor(red: 0x8E/255.0, green: 0x44/255.0, blue: 0xAD/255.0, alpha: 1),
        NSColor(red: 0xE8/255.0, green: 0x43/255.0, blue: 0x93/255.0, alpha: 1),
        NSColor(red: 0x1A/255.0, green: 0xBC/255.0, blue: 0x9C/255.0, alpha: 1),
    ]

    private let tabBar = CustomTabBarView()
    private let contentArea = NSView()
    private var sleepPreventionPopover: NSPopover?

    private(set) var tabs: [TabState] = []
    private(set) var activeTabIndex: Int = 0

    private var activeTab: TabState { tabs[activeTabIndex] }

    /// Flash a brief message on the active tab's status bar.
    func flashStatusBar(_ message: String) {
        guard !tabs.isEmpty else { return }
        activeTab.statusBar.showFlash(message)
    }

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
        window.backgroundColor = .clear
        window.isOpaque = false
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

        wireVoiceCallbacks()

        // Observe AI component sync changes
        componentObserver = NotificationCenter.default.addObserver(
            forName: RegistryManager.componentsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleComponentsDidChange(notification)
        }
    }

    deinit {
        if let observer = componentObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

        // Wire per-tab token tracker
        statusBar.tokenTracker = tab.tokenTracker
        aiSidePanel.tokenTracker = tab.tokenTracker

        if AppConfig.shared.tabsRandomColors {
            let palette = AppConfig.shared.tabsRandomColorPalette.isEmpty
                ? Self.defaultTabColorPalette
                : AppConfig.shared.tabsRandomColorPalette
            let neighborColor = tabs.last?.tabColor
            let candidates = palette.filter { $0 != neighborColor }
            tab.tabColor = (candidates.isEmpty ? palette : candidates).randomElement()
        }

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

        tab.sidePanelWidthConstraint?.isActive = false
        let widthConstraint = tab.aiSidePanel.widthAnchor.constraint(
            equalToConstant: tab.aiSidePanel.isPanelVisible ? AISidePanelView.defaultWidth : 0
        )
        tab.sidePanelWidthConstraint = widthConstraint

        // Determine the bottom anchor for the main content area (split container + side panel)
        #if DEBUG
        let console = tab.debugConsole
        console.translatesAutoresizingMaskIntoConstraints = false
        console.wantsLayer = true
        console.layer?.masksToBounds = true
        contentArea.addSubview(console)

        tab.debugConsoleHeightConstraint?.isActive = false
        let consoleHeight = console.isPanelVisible ? DebugConsoleView.defaultHeight : 0
        let heightConstraint = console.heightAnchor.constraint(equalToConstant: consoleHeight)
        tab.debugConsoleHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            console.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            console.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            console.bottomAnchor.constraint(equalTo: tab.statusBar.topAnchor),
            heightConstraint,
        ])

        let bottomAnchorTarget = console.topAnchor
        #else
        let bottomAnchorTarget = tab.statusBar.topAnchor
        #endif

        NSLayoutConstraint.activate([
            tab.statusBar.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            tab.statusBar.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            tab.statusBar.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            tab.statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.barHeight),

            // AI Side Panel on the right
            tab.aiSidePanel.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            tab.aiSidePanel.topAnchor.constraint(equalTo: contentArea.topAnchor),
            tab.aiSidePanel.bottomAnchor.constraint(equalTo: bottomAnchorTarget),
            widthConstraint,

            // Terminal fills the remaining space
            tab.splitContainer.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            tab.splitContainer.trailingAnchor.constraint(equalTo: tab.aiSidePanel.leadingAnchor),
            tab.splitContainer.topAnchor.constraint(equalTo: contentArea.topAnchor),
            tab.splitContainer.bottomAnchor.constraint(equalTo: bottomAnchorTarget),
        ])

        window?.makeFirstResponder(tab.splitContainer.focusedTerminal)
        updateWindowTitle()
        tab.statusBar.isPaused = false
    }

    private func uninstallTab(_ tab: TabState, cleanup: Bool = false) {
        if cleanup {
            tab.splitContainer.cleanupAllTerminals()
        }
        tab.splitContainer.removeFromSuperview()
        tab.statusBar.removeFromSuperview()
        tab.aiSidePanel.removeFromSuperview()
        #if DEBUG
        tab.debugConsole.removeFromSuperview()
        #endif
        tab.statusBar.isPaused = true
    }

    // MARK: - Tab Bar

    private func reloadTabBar() {
        let titles = tabs.map { $0.title }
        let colors = tabs.map { $0.tabColor }
        let dangers = tabs.map { $0.isDangerMode }
        tabBar.reloadTabs(titles: titles, selectedIndex: activeTabIndex, tabColors: colors, dangerFlags: dangers)
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

        if AppConfig.shared.tabsConfirmClose {
            let alert = NSAlert()
            alert.messageText = "Close this tab?"
            alert.informativeText = "The running process in this tab will be terminated."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        if tabs.count == 1 {
            // Last tab — close the window
            window?.performClose(nil)
            return
        }

        let tab = tabs[index]

        // Handle worktree cleanup with prompt if dirty
        cleanupWorktreeWithPrompt(for: tab) { [weak self] shouldClose in
            guard let self, shouldClose else { return }
            self.performCloseTab(at: index)
        }
    }

    private func performCloseTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        let closingActiveTab = (index == activeTabIndex)

        if closingActiveTab {
            // Uninstall the tab being closed with cleanup
            uninstallTab(tabs[index], cleanup: true)
            tabs.remove(at: index)
            activeTabIndex = min(index, tabs.count - 1)
            installTab(activeTab)
        } else {
            // Closing a background tab — cleanup its terminals
            tabs[index].splitContainer.cleanupAllTerminals()
            tabs.remove(at: index)
            // Adjust activeTabIndex if the removed tab was before it
            if index < activeTabIndex {
                activeTabIndex -= 1
            }
        }

        reloadTabBar()

        // Restore first responder — clicking the tab's close button steals it
        window?.makeFirstResponder(activeTab.splitContainer.focusedTerminal)
    }

    func switchToTab(at index: Int) {
        guard index >= 0 && index < tabs.count && index != activeTabIndex else { return }

        // Check if leaving a tab that's recording
        let isRecording = activeTab.splitContainer.focusedTerminal.sessionRecorder?.isRecording == true

        uninstallTab(activeTab)
        activeTabIndex = index
        installTab(activeTab)
        reloadTabBar()

        if isRecording {
            activeTab.statusBar.showFlash("⏸ Recording paused on other tab")
        }
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

        // Tab Color submenu
        let colorMenu = NSMenu(title: "Tab Color")
        let paletteNames = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink", "Teal"]
        let palette = zip(paletteNames, Self.defaultTabColorPalette).map { ($0, $1) }
        for (name, color) in palette {
            let item = NSMenuItem(title: name, action: #selector(contextSetTabColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = color
            // Color swatch
            let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                return true
            }
            item.image = swatch
            colorMenu.addItem(item)
        }
        colorMenu.addItem(NSMenuItem.separator())
        let customColorItem = NSMenuItem(title: "Custom…", action: #selector(contextCustomTabColor(_:)), keyEquivalent: "")
        customColorItem.target = self
        customColorItem.tag = index
        colorMenu.addItem(customColorItem)
        let clearColorItem = NSMenuItem(title: "Clear Color", action: #selector(contextClearTabColor(_:)), keyEquivalent: "")
        clearColorItem.target = self
        clearColorItem.tag = index
        colorMenu.addItem(clearColorItem)

        let colorMenuItem = NSMenuItem(title: "Tab Color", action: nil, keyEquivalent: "")
        colorMenuItem.submenu = colorMenu
        menu.addItem(colorMenuItem)

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
        if AppConfig.shared.tabsConfirmClose {
            let alert = NSAlert()
            alert.messageText = "Close other tabs?"
            alert.informativeText = "All tabs except the selected one will be closed."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close Others")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let keepIndex = sender.tag
        let keepTab = tabs[keepIndex]
        // Cleanup all tabs except the one being kept
        for (i, tab) in tabs.enumerated() where i != keepIndex {
            tab.splitContainer.cleanupAllTerminals()
            cleanupWorktree(for: tab, force: false)
        }
        // Uninstall the currently displayed tab
        uninstallTab(activeTab)
        tabs = [keepTab]
        activeTabIndex = 0
        installTab(keepTab)
        reloadTabBar()
    }

    @objc private func contextSetTabColor(_ sender: NSMenuItem) {
        guard sender.tag >= 0 && sender.tag < tabs.count,
              let color = sender.representedObject as? NSColor else { return }
        tabs[sender.tag].tabColor = color
        reloadTabBar()
    }

    @objc private func contextCustomTabColor(_ sender: NSMenuItem) {
        guard sender.tag >= 0 && sender.tag < tabs.count else { return }
        let tabIndex = sender.tag
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.color = tabs[tabIndex].tabColor ?? AppConfig.shared.themeAccent
        panel.showsAlpha = false
        panel.isContinuous = true

        // Use a helper to receive color changes
        let helper = ColorPanelHelper(tabIndex: tabIndex) { [weak self] idx, color in
            guard let self, idx >= 0, idx < self.tabs.count else { return }
            self.tabs[idx].tabColor = color
            self.reloadTabBar()
        }
        // Store reference so it isn't deallocated
        objc_setAssociatedObject(panel, "colorHelper", helper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        panel.setTarget(helper)
        panel.setAction(#selector(ColorPanelHelper.colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func contextClearTabColor(_ sender: NSMenuItem) {
        guard sender.tag >= 0 && sender.tag < tabs.count else { return }
        tabs[sender.tag].tabColor = nil
        reloadTabBar()
    }

    // MARK: - Rename Tab

    @objc func renameTab(_ sender: Any?) {
        renameTab(at: activeTabIndex)
    }

    private func renameTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        let tab = tabs[index]

        let alert = NSAlert.branded()
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
        terminal.onProcessExited = { [weak self, weak tab] in
            guard let self, let tab else { return }
            guard let model = terminal.currentModel, model.name != "Shell" else { return }
            if let index = self.tabs.firstIndex(where: { $0 === tab }) {
                self.closeTab(at: index)
            }
        }

        terminal.onWorkspacePicked = { [weak self, weak tab] dir, completion in
            guard let self, let tab else { completion(dir); return }
            self.resolveWorktreeForTab(tab, dir: dir, completion: completion)
        }

        terminal.onSessionChanged = { [weak self, weak terminal, weak tab] model, provider, cols, rows in
            guard let self, let terminal, let tab else { return }
            tab.hasSession = true
            tab.isDangerMode = terminal.isDangerMode
            tab.tokenTracker.reset()
            tab.sessionStartTime = Date()
            tab.statusBar.resetSession()
            tab.statusBar.update(model: model, provider: provider, cols: cols, rows: rows)
            tab.statusBar.setDangerMode(terminal.isDangerMode)
            if let wt = tab.worktreeInfo, !wt.isOriginal {
                tab.statusBar.setWorktreeIsolated(true)
            }
            tab.aiSidePanel.setModel(model)
            tab.aiSidePanel.setDangerMode(terminal.isDangerMode)
            tab.aiSidePanel.resetSession()
            // Enable AI analysis for LLM sessions (not plain Shell)
            let isAI = !model.isEmpty && model != "Shell"
            if let surface = terminal.surfacePointer {
                at_surface_set_ai_analysis(surface, isAI)
            }
            tab.statusBar.setVoiceVisible(true)
            // Auto-open AI side panel for LLM sessions (unless user manually closed it)
            if isAI && !tab.aiSidePanel.isPanelVisible && !tab.userClosedAIPanel {
                tab.aiSidePanel.toggle()
                tab.sidePanelWidthConstraint?.constant = AISidePanelView.defaultWidth
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.allowsImplicitAnimation = true
                    self.contentArea.layoutSubtreeIfNeeded()
                }
            }
            // Update AI component indicator
            if let ctx = terminal.lastAIComponentContext, ctx.totalCount > 0 {
                let components = AIComponentRegistry.shared.listActiveComponents(
                    stacks: ctx.detectedStacks,
                    registries: AppConfig.shared.aiComponentRegistries
                )
                tab.statusBar.setAIComponentInfo(
                    stacks: ctx.detectedStacks,
                    skillCount: ctx.skillCount,
                    ruleCount: ctx.ruleCount,
                    promptCount: ctx.promptCount,
                    agentCount: ctx.agentCount,
                    mcpServerCount: ctx.mcpServerCount,
                    components: components
                )
                tab.aiSidePanel.setAIComponentDetails(components)
                // Snapshot for sync change detection (captures state before auto-sync completes)
                self.syncChangeDetector.snapshot(
                    stacks: ctx.detectedStacks,
                    registries: AppConfig.shared.aiComponentRegistries
                )
            } else {
                tab.statusBar.clearAIComponentInfo()
            }
            // If remote control is enabled and this is a Claude session, show badge immediately
            if AppConfig.shared.remoteControlEnabled && model.lowercased().contains("claude") {
                tab.statusBar.setRemoteControl(true)
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
        terminal.onCopied = { [weak tab] in
            tab?.statusBar.showFlash("Copied!")
        }
        terminal.onTerminalIdle = { [weak terminal, weak tab] in
            guard let terminal else { return }
            NotificationManager.shared.notifyIdleIfNeeded(modelName: terminal.activeModelName)
            // Update side panel with latest analyzer data
            tab?.aiSidePanel.updateFromSurface(terminal.surfacePointer)
            // Update token display from per-tab TokenTracker
            if let tracker = tab?.tokenTracker {
                tab?.aiSidePanel.updateTokenDisplay(
                    input: tracker.currentInput,
                    output: tracker.totalOutput
                )
            }
        }
        terminal.onRemoteControlChanged = { [weak tab] active, url in
            guard let tab else { return }
            tab.statusBar.setRemoteControl(active)
            tab.remoteControlURL = url
        }
        tab.statusBar.onRemoteControlBadgeClicked = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.showRemoteControlPopover(for: tab)
        }
        terminal.onSleepPreventionChanged = { active in
            // Sleep prevention is system-wide — update all tabs in all windows
            for controller in TerminalWindowTracker.shared.allControllers {
                for tab in controller.tabs {
                    tab.statusBar.setAwake(active)
                    tab.isSleepPrevented = active
                }
            }
            if !active {
                StealthOverlayWindow.shared.dismiss()
            }
        }
        tab.statusBar.onAwakeBadgeClicked = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.showSleepPreventionPopover(for: tab)
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

        // Show AWAKE badge if sleep prevention is already active globally
        let globallyAwake = TerminalWindowTracker.shared.allControllers.contains { c in
            c.tabs.contains { $0.isSleepPrevented }
        }
        if globallyAwake {
            tab.statusBar.setAwake(true)
            tab.isSleepPrevented = true
        }
    }

    private func wireSplitContainer(_ splitContainer: SplitContainerView, tab: TabState) {
        splitContainer.onFocusChanged = { [weak self, weak tab] terminal in
            guard let self, let tab else { return }
            self.handleFocusChanged(terminal, tab: tab)
        }
    }

    private func wireStatusBar(_ statusBar: StatusBarView, tab: TabState) {
        statusBar.displayPathMapper = { [weak tab] cwd in
            guard let info = tab?.worktreeInfo, !info.isOriginal else { return cwd }
            // Map worktree path back to original repo path for display
            let worktreeRoot = info.worktreePath
            let repoRoot = info.repoRoot
            if cwd.hasPrefix(worktreeRoot) {
                let suffix = String(cwd.dropFirst(worktreeRoot.count))
                return repoRoot + suffix
            }
            // Also handle the .git/awal-worktrees/tab-xxx base path
            if cwd.contains("/.git/awal-worktrees/") {
                // Extract relative path after the worktree dir
                if let range = cwd.range(of: "/.git/awal-worktrees/") {
                    let afterWorktree = cwd[range.upperBound...]
                    // Skip the tab-uuid/ part
                    if let slashIdx = afterWorktree.firstIndex(of: "/") {
                        let relative = String(afterWorktree[afterWorktree.index(after: slashIdx)...])
                        return relative.isEmpty ? repoRoot : "\(repoRoot)/\(relative)"
                    }
                    return repoRoot
                }
            }
            return cwd
        }
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
        statusBar.onGitStatusChanged = { [weak tab, weak statusBar] changes in
            tab?.aiSidePanel.currentCwd = statusBar?.currentPath
            tab?.aiSidePanel.updateGitChanges(changes)
        }
        statusBar.onVoiceToggle = {
            VoiceInputController.shared.toggle()
        }
        statusBar.onScreenshotToSession = { [weak self] in
            self?.screenshotToSession(nil)
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

    // MARK: - Worktree Isolation

    private func resolveWorktreeForTab(_ tab: TabState, dir: String, completion: @escaping (String) -> Void) {
        guard AppConfig.shared.tabsWorktreeIsolation else {
            completion(dir)
            return
        }

        let manager = GitWorktreeManager.shared
        guard let repoRoot = manager.resolveRepoRoot(for: dir) else {
            // Not a git repo — proceed normally
            completion(dir)
            return
        }

        guard manager.isProjectAlreadyOpen(repoRoot: repoRoot) else {
            // First tab for this repo — register and proceed with original dir
            manager.registerOpen(repoRoot: repoRoot)
            tab.worktreeInfo = WorktreeInfo(
                repoRoot: repoRoot,
                worktreePath: dir,
                branchName: nil,
                isOriginal: true
            )
            return completion(dir)
        }

        // Project already open — prompt the user
        guard let window = self.window else {
            completion(dir)
            return
        }

        let defaultBranch = manager.resolveDefaultBranch(repoRoot: repoRoot)

        let alert = NSAlert.branded()
        alert.messageText = "This project is already open"
        alert.informativeText = "This project is already open in another tab. Isolate with a git worktree?"
        alert.addButton(withTitle: "From Current Branch")
        if let defaultBranch = defaultBranch {
            alert.addButton(withTitle: "From \(defaultBranch)")
        }
        alert.addButton(withTitle: "No")

        alert.beginSheetModal(for: window) { response in
            let noButton: NSApplication.ModalResponse = defaultBranch != nil
                ? .alertThirdButtonReturn
                : .alertSecondButtonReturn

            if response == noButton {
                // Declined — use shared directory
                manager.registerOpen(repoRoot: repoRoot)
                tab.worktreeInfo = WorktreeInfo(
                    repoRoot: repoRoot,
                    worktreePath: dir,
                    branchName: nil,
                    isOriginal: true
                )
                completion(dir)
                return
            }

            // Determine start point
            let startPoint: String? = (response == .alertSecondButtonReturn && defaultBranch != nil)
                ? defaultBranch
                : nil

            // Create worktree
            if let info = manager.createWorktree(repoRoot: repoRoot, subpath: dir, startPoint: startPoint) {
                manager.registerOpen(repoRoot: repoRoot)
                tab.worktreeInfo = info
                completion(info.worktreePath)
            } else {
                // Worktree creation failed — fall back to shared dir
                manager.registerOpen(repoRoot: repoRoot)
                tab.worktreeInfo = WorktreeInfo(
                    repoRoot: repoRoot,
                    worktreePath: dir,
                    branchName: nil,
                    isOriginal: true
                )
                completion(dir)
            }
        }
    }

    private func cleanupWorktree(for tab: TabState, force: Bool = false) {
        guard let info = tab.worktreeInfo, !info.isOriginal else {
            if let info = tab.worktreeInfo {
                GitWorktreeManager.shared.registerClose(repoRoot: info.repoRoot)
            }
            return
        }

        let manager = GitWorktreeManager.shared
        if force {
            manager.forceRemoveWorktree(info)
        } else {
            let result = manager.removeWorktree(info)
            switch result {
            case .kept:
                // Worktree is dirty — leave it (user chose to keep or we're silently closing)
                break
            case .removed, .failed:
                break
            }
        }
        manager.registerClose(repoRoot: info.repoRoot)
    }

    private func cleanupWorktreeWithPrompt(for tab: TabState, completion: @escaping (Bool) -> Void) {
        guard let info = tab.worktreeInfo, !info.isOriginal else {
            if let info = tab.worktreeInfo {
                GitWorktreeManager.shared.registerClose(repoRoot: info.repoRoot)
            }
            completion(true)
            return
        }

        let manager = GitWorktreeManager.shared
        let worktreeRoot = info.worktreeRoot

        if !manager.isDirty(worktreeRoot) {
            // Clean — silently remove
            manager.forceRemoveWorktree(info)
            manager.registerClose(repoRoot: info.repoRoot)
            completion(true)
            return
        }

        // Dirty — show dialog
        guard let window = self.window else {
            manager.registerClose(repoRoot: info.repoRoot)
            completion(true)
            return
        }

        let alert = NSAlert.branded()
        alert.messageText = "Worktree has uncommitted changes"
        alert.informativeText = "The worktree at \(info.branchName ?? worktreeRoot) has uncommitted changes."
        alert.addButton(withTitle: "Keep Worktree")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                // Keep worktree
                manager.registerClose(repoRoot: info.repoRoot)
                completion(true)
            case .alertSecondButtonReturn:
                // Discard changes
                manager.forceRemoveWorktree(info)
                manager.registerClose(repoRoot: info.repoRoot)
                completion(true)
            default:
                // Cancel
                completion(false)
            }
        }
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

    #if DEBUG
    @objc func toggleDebugConsole(_ sender: Any?) {
        let tab = activeTab
        tab.debugConsole.toggle()

        let targetHeight: CGFloat = tab.debugConsole.isPanelVisible ? DebugConsoleView.defaultHeight : 0
        tab.debugConsoleHeightConstraint?.constant = targetHeight

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            self.contentArea.layoutSubtreeIfNeeded()
        }
    }
    #endif

    @objc func toggleAISidePanel(_ sender: Any?) {
        let tab = activeTab
        guard tab.hasSession else { return }
        tab.aiSidePanel.toggle()
        tab.userClosedAIPanel = !tab.aiSidePanel.isPanelVisible

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

    // MARK: - Voice Input

    private let voiceController = VoiceInputController.shared
    private let voiceDispatcher = VoiceCommandDispatcher()
    private let transcriptionOverlay = TranscriptionOverlayView()
    private let syncChangeDetector = SyncChangeDetector()
    private var lastSyncChangeSummary: SyncChangeSummary?
    private var componentObserver: Any?
    private var manualSyncPending = false
    private var syncBannerView: SyncChangeBannerView?

    func wireVoiceCallbacks() {
        voiceController.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.activeTab.statusBar.setVoiceState(state)
            if state == .idle {
                self.transcriptionOverlay.dismiss()
            }
        }

        voiceController.onTranscription = { [weak self] result in
            guard let self, let window = self.window else { return }

            if result.isCommand, let action = result.action {
                self.voiceDispatcher.dispatch(action, windowController: self)
                self.transcriptionOverlay.showFinalResult(result.text, isCommand: true, in: window)
            } else {
                self.injectTextToFocusedTerminal(result.text)
                self.transcriptionOverlay.showFinalResult(result.text, isCommand: false, in: window)
            }
        }

        voiceController.onAudioLevel = { [weak self] level in
            self?.activeTab.statusBar.setVoiceAudioLevel(level)
        }

        voiceController.onPartialTranscription = { [weak self] text in
            guard let self, let window = self.window else { return }
            self.transcriptionOverlay.showTranscription(text, isCommand: false, in: window)
        }
    }

    @objc func screenshotToSession(_ sender: Any?) {
        activeTab.splitContainer.focusedTerminal.captureScreenshotAndPastePath()
    }

    /// Inject text into the focused terminal (used by voice dictation).
    func injectTextToFocusedTerminal(_ text: String) {
        let terminal = activeTab.splitContainer.focusedTerminal
        terminal.injectText(text)
    }

    /// Inject raw bytes into the focused terminal (used by voice commands).
    func injectBytesToFocusedTerminal(_ bytes: [UInt8]) {
        let terminal = activeTab.splitContainer.focusedTerminal
        guard let surface = terminal.surfacePointer else { return }
        bytes.withUnsafeBufferPointer { ptr in
            _ = at_surface_key_event(surface, ptr.baseAddress!, UInt32(ptr.count))
        }
    }

    /// Scroll the focused terminal viewport.
    func scrollFocusedTerminal(delta: Int32) {
        let terminal = activeTab.splitContainer.focusedTerminal
        guard let surface = terminal.surfacePointer else { return }
        at_surface_scroll_viewport(surface, delta)
    }

    /// Set search query in focused terminal's search bar.
    func setSearchQueryInFocusedTerminal(_ query: String) {
        activeTab.splitContainer.focusedTerminal.setSearchQuery(query)
    }

    // MARK: - Sync Change Notification

    /// Snapshot components before a manual sync so we can diff afterwards.
    func snapshotComponentsForSync() {
        manualSyncPending = true
        let stacks = collectActiveStacks()
        syncChangeDetector.snapshot(stacks: stacks, registries: AppConfig.shared.aiComponentRegistries)
    }

    private func handleComponentsDidChange(_ notification: Notification) {
        // Only one controller should handle this — pick the first one to avoid duplicates
        let firstController = NSApp.windows.compactMap { $0.windowController as? TerminalWindowController }.first
        guard firstController === self else { return }
        // Only show changes if a snapshot was taken (manual sync or session start)
        guard syncChangeDetector.hasSnapshot else { return }

        let stacks = collectActiveStacks()
        let summary = syncChangeDetector.computeChanges(
            stacks: stacks,
            registries: AppConfig.shared.aiComponentRegistries
        )
        guard summary.hasChanges else { return }
        lastSyncChangeSummary = summary

        let isManual = manualSyncPending
        manualSyncPending = false

        if isManual {
            SyncChangeDetailWindow.show(summary: summary)
        } else {
            showSyncBanner(summary: summary)
        }
    }

    private func showSyncBanner(summary: SyncChangeSummary) {
        // Dismiss any existing banner
        syncBannerView?.dismiss()
        syncBannerView = nil

        guard let container = window?.contentView else { return }

        let banner = SyncChangeBannerView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.configure(summary: summary)
        banner.onViewChanges = { [weak self, weak banner] in
            guard let self else { return }
            if let s = self.lastSyncChangeSummary {
                SyncChangeDetailWindow.show(summary: s)
            }
            banner?.dismiss()
            self.syncBannerView = nil
        }

        container.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            banner.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                           constant: -(StatusBarView.barHeight + 8)),
            banner.heightAnchor.constraint(equalToConstant: 36),
        ])

        syncBannerView = banner
        banner.showAnimated()
    }

    private func showRemoteControlPopover(for tab: TabState) {
        guard let url = tab.remoteControlURL else {
            tab.statusBar.showFlash("Waiting for remote control URL…")
            return
        }
        let controller = RemoteControlPopoverView(url: url)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.contentSize = controller.view.frame.size
        let badge = tab.statusBar.remoteControlBadgeView
        popover.show(relativeTo: badge.bounds, of: badge, preferredEdge: .maxY)
    }

    private func showSleepPreventionPopover(for tab: TabState) {
        let controller = SleepPreventionPopoverView(
            isActive: tab.isSleepPrevented,
            isRemoteControlLinked: tab.remoteControlURL != nil
        )
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.contentSize = controller.view.frame.size
        sleepPreventionPopover = popover
        let badge = tab.statusBar.awakeBadgeView
        popover.show(relativeTo: badge.bounds, of: badge, preferredEdge: .maxY)
    }

    private func collectActiveStacks() -> Set<String> {
        // Gather detected stacks from all tabs' focused terminals
        var stacks = Set<String>()
        for tab in tabs {
            if let ctx = tab.splitContainer.focusedTerminal.lastAIComponentContext {
                stacks.formUnion(ctx.detectedStacks)
            }
        }
        // Fall back to all known stacks if none detected
        if stacks.isEmpty {
            stacks = Set(ProjectDetector.builtInRules.keys)
        }
        return stacks
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // If this is the last window, show quit confirmation
        if TerminalWindowTracker.shared.count == 1 && AppConfig.shared.quitConfirmClose {
            let alert = NSAlert.branded()
            alert.messageText = "Quit Awal Terminal?"
            alert.informativeText = "All terminal sessions will be terminated."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // Cleanup all tabs before window closes
        for tab in tabs {
            tab.splitContainer.cleanupAllTerminals()
            cleanupWorktree(for: tab, force: false)
        }
        TerminalWindowTracker.shared.remove(self)
        if TerminalWindowTracker.shared.count == 0 {
            NSApp.terminate(nil)
        }
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

        let alert = NSAlert.branded()
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
        panel.canCreateDirectories = true
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

// MARK: - Color Panel Helper

private class ColorPanelHelper: NSObject {
    let tabIndex: Int
    let onChange: (Int, NSColor) -> Void

    init(tabIndex: Int, onChange: @escaping (Int, NSColor) -> Void) {
        self.tabIndex = tabIndex
        self.onChange = onChange
    }

    @objc func colorChanged(_ sender: NSColorPanel) {
        onChange(tabIndex, sender.color)
    }
}
