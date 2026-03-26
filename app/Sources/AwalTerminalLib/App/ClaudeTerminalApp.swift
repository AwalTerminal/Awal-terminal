import AppKit
import Carbon
import CAwalTerminal

/// Centralized app icon accessor — works in both .app bundle and swift-run contexts.
enum AppIcon {
    static let image: NSImage? = {
        // 1. Try bundle (works in .app)
        if let icon = NSImage(named: "AppIcon"), icon.isValid {
            return icon
        }
        // 2. Fallback: load .icns from source tree (swift run)
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = execURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let icnsURL = dir.appendingPathComponent("app/Sources/AwalTerminalLib/App/Resources/AppIcon.icns")
            if FileManager.default.fileExists(atPath: icnsURL.path),
               let icon = NSImage(contentsOf: icnsURL) {
                return icon
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()
}

extension NSAlert {
    /// Creates an alert pre-configured with the Awal Terminal app icon.
    static func branded() -> NSAlert {
        let alert = NSAlert()
        if let icon = AppIcon.image {
            alert.icon = icon
        }
        return alert
    }
}

public class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    public func applicationDidFinishLaunching(_ notification: Notification) {
        at_init_logging()
        BundledFont.registerBundledFonts()

        // Always start with danger mode disabled
        if AppConfig.shared.dangerModeEnabled {
            ConfigWriter.updateValue(key: "ai_components.danger_mode", value: "false")
            AppConfig.reload()
        }

        if let icon = AppIcon.image {
            NSApp.applicationIconImage = icon
        }

        // Register the .app bundle with LaunchServices so macOS associates our
        // icon with the bundle identifier (needed for notification icons).
        if let bundleURL = Bundle.main.bundleURL as CFURL? {
            LSRegisterURL(bundleURL, true)
        }

        setupMainMenu()

        // Register global hotkeys
        QuickTerminalController.shared.registerHotKey()
        registerVoiceHotKey()

        // Stop voice input on sleep to release audio hardware
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            VoiceInputController.shared.stop()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { _ in
            VoiceInputController.shared.stop()
        }

        // Clean up orphaned worktrees from crashed sessions and start periodic cleanup
        GitWorktreeManager.shared.pruneOrphaned()
        GitWorktreeManager.shared.startPeriodicPrune()

        // Start automatic update checker
        UpdateChecker.shared.start()

        // Try restoring multi-window state first
        if let appState = WindowStateStore.loadAll(), !appState.isEmpty {
            for (i, savedState) in appState.enumerated() {
                let controller = TerminalWindowController(isInitialTab: true)
                TerminalWindowTracker.shared.register(controller)
                controller.showWindow(nil)
                if let frame = savedState.windowFrame {
                    controller.window?.setFrame(
                        NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                        display: true
                    )
                }
                controller.restoreFromSavedState(savedState)
                if i == 0 {
                    controller.window?.makeKeyAndOrderFront(nil)
                }
            }
        } else if let singleState = WindowStateStore.load() {
            // Legacy single-window restore
            let controller = TerminalWindowController(isInitialTab: true)
            TerminalWindowTracker.shared.register(controller)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.restoreFromSavedState(singleState)
        } else {
            let controller = TerminalWindowController(isInitialTab: true)
            TerminalWindowTracker.shared.register(controller)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = TerminalWindowController(isInitialTab: true)
        TerminalWindowTracker.shared.register(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Save all windows for session restore
        let states = TerminalWindowTracker.shared.allControllers.compactMap { $0.captureWindowState() }
        if !states.isEmpty {
            WindowStateStore.saveAll(states)
        }

        QuickTerminalController.shared.unregisterHotKey()
        unregisterVoiceHotKey()
        VoiceInputController.shared.stop()

        // Clean up screenshot temp files
        let tmpDir = NSTemporaryDirectory()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) {
            for file in files where file.hasPrefix("awal-screenshot-") && file.hasSuffix(".png") {
                try? FileManager.default.removeItem(atPath: tmpDir + file)
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @objc func confirmQuit(_ sender: Any?) {
        if AppConfig.shared.quitConfirmClose {
            let alert = NSAlert.branded()
            alert.messageText = "Quit Awal Terminal?"
            alert.informativeText = "All terminal sessions will be terminated."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        NSApp.terminate(nil)
    }

    @objc func showAboutPanel(_ sender: Any?) {
        AboutWindow.show()
    }

    @objc func showHelpWindow(_ sender: Any?) {
        HelpWindow.show()
    }

    @objc func showPreferences(_ sender: Any?) {
        PreferencesWindow.show()
    }

    @objc func showMissionControl(_ sender: Any?) {
        MissionControlWindow.toggle()
    }

    @objc private func showCommandPalette(_ sender: Any?) {
        CommandPaletteWindow.toggle()
    }

    @objc func toggleRemoteControl(_ sender: Any?) {
        let current = AppConfig.shared.remoteControlEnabled
        ConfigWriter.updateValue(key: "ai_components.remote_control", value: current ? "false" : "true")
        AppConfig.reload()
    }

    @objc func togglePreventSleep(_ sender: Any?) {
        let current = AppConfig.shared.preventSleep
        if current {
            // Block disable when any tab has active remote control
            for controller in TerminalWindowTracker.shared.allControllers {
                for tab in controller.tabs where tab.remoteControlURL != nil {
                    let alert = NSAlert.branded()
                    alert.messageText = "Cannot Disable Sleep Prevention"
                    alert.informativeText = "A remote control session is active. Sleep prevention must remain enabled while a remote session is connected."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
            }
        }
        ConfigWriter.updateValue(key: "system.prevent_sleep", value: current ? "false" : "true")
        AppConfig.reload()

        // Sync per-tab sleep prevention state with the new config value
        let newValue = AppConfig.shared.preventSleep
        for controller in TerminalWindowTracker.shared.allControllers {
            for tab in controller.tabs {
                tab.isSleepPrevented = newValue
                tab.statusBar.setAwake(newValue)
            }
        }
        if !newValue {
            StealthOverlayWindow.shared.dismiss()
        }
    }

    @objc func toggleStealthMode(_ sender: Any?) {
        if StealthOverlayWindow.shared.isActive {
            StealthOverlayWindow.shared.dismiss()
        } else {
            StealthOverlayWindow.shared.activate()
        }
    }

    @objc func toggleRecording(_ sender: Any?) {
        guard let controller = NSApp.keyWindow?.windowController as? TerminalWindowController else { return }
        let tab = controller.tabs[controller.activeTabIndex]
        let terminal = tab.splitContainer.focusedTerminal

        // Wire status bar feedback and auto-stop handler if not already done
        if terminal.sessionRecorder == nil {
            let recorder = SessionRecorder()
            wireRecorder(recorder, tab: tab, terminal: terminal)
            terminal.sessionRecorder = recorder
        } else if terminal.sessionRecorder?.onRecordingChanged == nil {
            wireRecorder(terminal.sessionRecorder!, tab: tab, terminal: terminal)
        }

        if let url = terminal.toggleRecording() {
            showExportPanel(url: url, tab: tab, controller: controller)
        } else {
            // Recording started
            controller.flashStatusBar("Recording started")
        }
    }

    private func wireRecorder(_ recorder: SessionRecorder, tab: TabState, terminal: TerminalView) {
        recorder.onRecordingChanged = { [weak tab, weak terminal] isRecording in
            tab?.statusBar.setRecording(isRecording)
            terminal?.setRecordingIndicatorVisible(isRecording)
        }
        recorder.onAutoStopped = { [weak self, weak tab] url in
            guard let tab else { return }
            guard let controller = tab.splitContainer.window?.windowController as? TerminalWindowController else { return }
            self?.showExportPanel(url: url, tab: tab, controller: controller)
        }
    }

    private func showExportPanel(url: URL, tab: TabState, controller: TerminalWindowController) {
        let panel = NSSavePanel()
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.gif]
        }
        let safeName = tab.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeName).gif"

        guard let window = controller.window else { return }
        panel.beginSheetModal(for: window) { [weak tab] result in
            guard result == .OK, let outputURL = panel.url else {
                // User cancelled — clean up temp recording
                try? FileManager.default.removeItem(at: url)
                return
            }

            // Create a renderer for export
            guard let device = MTLCreateSystemDefaultDevice() else {
                tab?.statusBar.showFlash("Export failed")
                try? FileManager.default.removeItem(at: url)
                return
            }

            let fontSize: CGFloat = 13.0
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            let cellWidth = font.advancement(forGlyph: font.glyph(withName: "M")).width
            let cellHeight = ceil(font.ascender - font.descender + font.leading)

            let renderer: MetalRenderer
            do {
                renderer = try MetalRenderer(
                    device: device,
                    font: font,
                    boldFont: boldFont,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight,
                    scale: 2.0
                )
            } catch {
                debugLog("GIF export: MetalRenderer init failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: url)
                return
            }

            tab?.statusBar.showFlash("Exporting…")

            SessionExporter.exportGIF(
                recordingPath: url.path,
                outputURL: outputURL,
                renderer: renderer,
                progress: { pct in
                    DispatchQueue.main.async {
                        let percent = Int(pct * 100)
                        if percent >= 99 {
                            tab?.statusBar.showFlash("Finalizing GIF…")
                        } else {
                            tab?.statusBar.showFlash("Exporting \(percent)%…")
                        }
                    }
                }
            ) { result in
                // Clean up temp recording
                try? FileManager.default.removeItem(at: url)

                switch result {
                case .success(let gifURL):
                    tab?.statusBar.showFlash("GIF exported!")
                    NSWorkspace.shared.activateFileViewerSelecting([gifURL])
                case .failure(let error):
                    let alert = NSAlert.branded()
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdateChecker.shared.checkNow { hasUpdate, error in
            if let error {
                let alert = NSAlert.branded()
                alert.messageText = "Update Check Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            UpdateChecker.shared.showUpdateAlert()
        }
    }

    @objc func toggleQuickTerminal(_ sender: Any?) {
        QuickTerminalController.shared.toggle()
    }

    @objc func toggleNotifications(_ sender: Any?) {
        NotificationManager.shared.isEnabled.toggle()
    }

    // MARK: - Worktrees

    @objc func showManageWorktrees(_ sender: Any?) {
        ManageWorktreesWindow.show()
    }

    // MARK: - AI Components

    @objc func showAIComponentsManager(_ sender: Any?) {
        AIComponentsManagerWindow.show()
    }

    @objc func syncAIComponentsNow(_ sender: Any?) {
        let config = AppConfig.shared

        // Snapshot components before sync for change detection
        let controller = NSApp.windows.compactMap { $0.windowController as? TerminalWindowController }.first
        controller?.snapshotComponentsForSync()

        // Listen for the components-changed notification to know if changes occurred
        var changesDetected = false
        let observer = NotificationCenter.default.addObserver(
            forName: RegistryManager.componentsDidChange, object: nil, queue: .main
        ) { _ in
            changesDetected = true
        }

        RegistryManager.shared.syncAll(registries: config.aiComponentRegistries.filter { $0.enabled }, force: true) { results in
            NotificationCenter.default.removeObserver(observer)

            let errors = results.compactMap { (name, result) -> String? in
                if case .failure(let err) = result { return "\(name): \(err.localizedDescription)" }
                return nil
            }
            if !errors.isEmpty {
                let alert = NSAlert.branded()
                alert.messageText = "Sync Errors"
                alert.informativeText = errors.joined(separator: "\n")
                alert.alertStyle = .warning
                alert.runModal()
            } else if !changesDetected {
                // No changes detected — show a brief flash
                if let controller = NSApp.keyWindow?.windowController as? TerminalWindowController {
                    controller.flashStatusBar("Components synced — no changes")
                }
            }
        }
    }

    @objc func toggleAIComponentsEnabled(_ sender: Any?) {
        let current = AppConfig.shared.aiComponentsEnabled
        ConfigWriter.updateValue(key: "ai_components.enabled", value: current ? "false" : "true")
        AppConfig.reload()
    }

    @objc func toggleAIComponentsAutoDetect(_ sender: Any?) {
        let current = AppConfig.shared.aiComponentsAutoDetect
        ConfigWriter.updateValue(key: "ai_components.auto_detect", value: current ? "false" : "true")
        AppConfig.reload()
    }

    @objc func toggleDangerMode(_ sender: Any?) {
        let current = AppConfig.shared.dangerModeEnabled
        let newValue = !current

        if newValue {
            // Show warning dialog every time before enabling
            let alert = NSAlert()
            alert.messageText = "Enable Danger Mode?"
            alert.informativeText = "This will skip all tool confirmation prompts in new AI sessions. The AI will be able to execute commands, edit files, and make changes without asking for permission.\n\nThis applies to new sessions only."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Enable Danger Mode")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
        }

        ConfigWriter.updateValue(key: "ai_components.danger_mode", value: newValue ? "true" : "false")
        AppConfig.reload()
    }

    @objc func showImportExport(_ sender: Any?) {
        ImportExportWindow.show()
    }

    // MARK: - Security

    @objc func toggleSecurityScan(_ sender: Any?) {
        let current = AppConfig.shared.aiComponentsSecurityScan
        ConfigWriter.updateValue(key: "ai_components.security_scan", value: current ? "false" : "true")
        AppConfig.reload()
    }

    @objc func toggleBlockCritical(_ sender: Any?) {
        let current = AppConfig.shared.aiComponentsBlockCritical
        ConfigWriter.updateValue(key: "ai_components.block_critical", value: current ? "false" : "true")
        AppConfig.reload()
    }

    @objc func toggleRequireHookApproval(_ sender: Any?) {
        let current = AppConfig.shared.aiComponentsRequireHookApproval
        ConfigWriter.updateValue(key: "ai_components.require_hook_approval", value: current ? "false" : "true")
        AppConfig.reload()
    }

    @objc func showAllSecurityFindings(_ sender: Any?) {
        let allFindings = RegistryManager.shared.scanResults.values.flatMap { $0 }
        AIComponentsManagerWindow.showSecurityFindings(allFindings)
    }

    @objc func editCustomSecurityRules(_ sender: Any?) {
        SecurityRulesEditorWindow.show()
    }

    // MARK: - Voice Input

    private var voicePTTHotKeyRef: EventHotKeyRef?
    private var voicePTTEventHandler: EventHandlerRef?
    private var isPTTPressed = false

    @objc func toggleVoiceInput(_ sender: Any?) {
        VoiceInputController.shared.toggle()
    }

    @objc func setVoiceModePTT(_ sender: Any?) {
        VoiceInputController.shared.stop()
    }

    func registerVoiceHotKey() {
        // Ctrl+Shift+Space — keycode 49 (Space)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4156_4F43), id: 2) // "AVOC"
        var ref: EventHotKeyRef?
        let modifiers: UInt32 = UInt32(controlKey | shiftKey)

        RegisterEventHotKey(UInt32(kVK_Space), modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        voicePTTHotKeyRef = ref

        // Install handler for both press and release
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var handlerRef: EventHandlerRef?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()

            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)

            // Only handle our voice hotkey (id=2)
            guard hkID.id == 2 else { return OSStatus(eventNotHandledErr) }

            let kind = Int(GetEventKind(event))
            DispatchQueue.main.async {
                if kind == kEventHotKeyPressed {
                    guard VoiceInputController.shared.isEnabled else { return }
                    delegate.isPTTPressed = true
                    VoiceInputController.shared.startPushToTalk()
                } else if kind == kEventHotKeyReleased {
                    guard delegate.isPTTPressed else { return }
                    delegate.isPTTPressed = false
                    VoiceInputController.shared.stopPushToTalk()
                }
            }
            return noErr
        }, eventTypes.count, &eventTypes, selfPtr, &handlerRef)
        voicePTTEventHandler = handlerRef
    }

    func unregisterVoiceHotKey() {
        if let ref = voicePTTHotKeyRef {
            UnregisterEventHotKey(ref)
            voicePTTHotKeyRef = nil
        }
        if let handler = voicePTTEventHandler {
            RemoveEventHandler(handler)
            voicePTTEventHandler = nil
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleNotifications(_:)) {
            menuItem.state = NotificationManager.shared.isEnabled ? .on : .off
        }
        if menuItem.action == #selector(toggleAIComponentsEnabled(_:)) {
            menuItem.state = AppConfig.shared.aiComponentsEnabled ? .on : .off
        }
        if menuItem.action == #selector(toggleAIComponentsAutoDetect(_:)) {
            menuItem.state = AppConfig.shared.aiComponentsAutoDetect ? .on : .off
        }
        if menuItem.action == #selector(toggleDangerMode(_:)) {
            menuItem.state = AppConfig.shared.dangerModeEnabled ? .on : .off
        }
        if menuItem.action == #selector(toggleSecurityScan(_:)) {
            menuItem.state = AppConfig.shared.aiComponentsSecurityScan ? .on : .off
        }
        if menuItem.action == #selector(toggleBlockCritical(_:)) {
            menuItem.state = AppConfig.shared.aiComponentsBlockCritical ? .on : .off
        }
        if menuItem.action == #selector(toggleRequireHookApproval(_:)) {
            menuItem.state = AppConfig.shared.aiComponentsRequireHookApproval ? .on : .off
        }
        if menuItem.action == #selector(showAllSecurityFindings(_:)) {
            let hasFindings = RegistryManager.shared.scanResults.values.contains { !$0.isEmpty }
            return hasFindings
        }
        if menuItem.action == #selector(toggleRemoteControl(_:)) {
            menuItem.state = AppConfig.shared.remoteControlEnabled ? .on : .off
        }
        if menuItem.action == #selector(togglePreventSleep(_:)) {
            menuItem.state = AppConfig.shared.preventSleep ? .on : .off
        }
        if menuItem.action == #selector(toggleStealthMode(_:)) {
            menuItem.state = StealthOverlayWindow.shared.isActive ? .on : .off
            let isSleepPrevented = TerminalWindowTracker.shared.allControllers.contains { controller in
                controller.tabs.contains { $0.isSleepPrevented }
            }
            return isSleepPrevented
        }
        if menuItem.action == #selector(toggleVoiceInput(_:)) {
            // Only enable voice input in LLM sessions (not plain Shell)
            if let controller = NSApp.keyWindow?.windowController as? TerminalWindowController {
                let model = controller.tabs[controller.activeTabIndex].statusBar.currentModelName
                if model.isEmpty || model == "Shell" {
                    return false
                }
            }
            menuItem.state = VoiceInputController.shared.state != .idle ? .on : .off
        }
        if menuItem.action == #selector(setVoiceModePTT(_:)) {
            menuItem.state = .on
        }
        return true
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (settings before hide)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Awal Terminal")
        appMenu.addItem(withTitle: "About Awal Terminal", action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Model Settings…", action: #selector(TerminalWindowController.openSettings(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Awal Terminal", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Awal Terminal", action: #selector(confirmQuit(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Shell menu — sessions and tab navigation
        let shellMenuItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")

        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        shellMenu.addItem(newWindowItem)

        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(TerminalWindowController.newTab(_:)), keyEquivalent: "t")
        shellMenu.addItem(newTabItem)

        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(TerminalWindowController.closeTab(_:)), keyEquivalent: "w")
        shellMenu.addItem(closeTabItem)

        let renameTabItem = NSMenuItem(title: "Rename Tab…", action: #selector(TerminalWindowController.renameTab(_:)), keyEquivalent: "r")
        renameTabItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(renameTabItem)

        shellMenu.addItem(NSMenuItem.separator())

        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(TerminalWindowController.selectNextTab(_:)), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(TerminalWindowController.selectPreviousTab(_:)), keyEquivalent: "[")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(prevTabItem)

        shellMenu.addItem(NSMenuItem.separator())

        let newGroupItem = NSMenuItem(title: "New Tab Group", action: #selector(TerminalWindowController.createGroupFromCurrentTab(_:)), keyEquivalent: "g")
        newGroupItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(newGroupItem)

        let toggleCollapseItem = NSMenuItem(title: "Toggle Group Collapse", action: #selector(TerminalWindowController.toggleCurrentGroupCollapse(_:)), keyEquivalent: ".")
        toggleCollapseItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(toggleCollapseItem)

        shellMenu.addItem(NSMenuItem.separator())
        shellMenu.addItem(withTitle: "Manage Worktrees…", action: #selector(showManageWorktrees(_:)), keyEquivalent: "")

        shellMenuItem.submenu = shellMenu
        mainMenu.addItem(shellMenuItem)

        // Edit menu — text operations with Undo/Redo
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())

        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        let copyMdItem = NSMenuItem(title: "Copy as Markdown", action: #selector(TerminalView.contextCopyAsMarkdown(_:)), keyEquivalent: "c")
        copyMdItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(copyMdItem)
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(NSMenuItem.separator())

        let findItem = NSMenuItem(title: "Find…", action: #selector(TerminalWindowController.findInTerminal(_:)), keyEquivalent: "f")
        editMenu.addItem(findItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu — pure visibility (panels and display)
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let paletteItem = NSMenuItem(title: "Command Palette", action: #selector(showCommandPalette(_:)), keyEquivalent: "p")
        paletteItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(paletteItem)

        let sidePanelItem = NSMenuItem(title: "AI Side Panel", action: #selector(TerminalWindowController.toggleAISidePanel(_:)), keyEquivalent: "i")
        sidePanelItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(sidePanelItem)

        let quickTermItem = NSMenuItem(title: "Quick Terminal", action: #selector(toggleQuickTerminal(_:)), keyEquivalent: "`")
        quickTermItem.keyEquivalentModifierMask = [.control]
        viewMenu.addItem(quickTermItem)

        let missionControlItem = NSMenuItem(title: "Mission Control", action: #selector(showMissionControl(_:)), keyEquivalent: "d")
        missionControlItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(missionControlItem)

        viewMenu.addItem(NSMenuItem.separator())

        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(TerminalWindowController.zoomIn(_:)), keyEquivalent: "=")
        zoomInItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zoomInItem)

        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(TerminalWindowController.zoomOut(_:)), keyEquivalent: "-")
        zoomOutItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zoomOutItem)

        let actualSizeItem = NSMenuItem(title: "Actual Size", action: #selector(TerminalWindowController.resetZoom(_:)), keyEquivalent: "0")
        actualSizeItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(actualSizeItem)

        viewMenu.addItem(NSMenuItem.separator())

        let fullScreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreenItem)

        #if DEBUG
        viewMenu.addItem(NSMenuItem.separator())
        let debugConsoleItem = NSMenuItem(title: "Debug Console", action: #selector(TerminalWindowController.toggleDebugConsole(_:)), keyEquivalent: "d")
        debugConsoleItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(debugConsoleItem)
        #endif

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Tools menu — actions, modes, and utilities
        let toolsMenuItem = NSMenuItem()
        let toolsMenu = NSMenu(title: "Tools")

        let screenshotItem = NSMenuItem(title: "Screenshot to Session", action: #selector(TerminalWindowController.screenshotToSession(_:)), keyEquivalent: "s")
        screenshotItem.keyEquivalentModifierMask = [.command, .shift]
        toolsMenu.addItem(screenshotItem)

        let recordItem = NSMenuItem(title: "Start/Stop Recording", action: #selector(toggleRecording(_:)), keyEquivalent: "r")
        recordItem.keyEquivalentModifierMask = [.command, .option, .shift]
        toolsMenu.addItem(recordItem)

        toolsMenu.addItem(NSMenuItem.separator())

        let toggleVoiceItem = NSMenuItem(title: "Voice Input", action: #selector(toggleVoiceInput(_:)), keyEquivalent: "")
        toolsMenu.addItem(toggleVoiceItem)

        let pttItem = NSMenuItem(title: "Push-to-Talk Mode", action: #selector(setVoiceModePTT(_:)), keyEquivalent: "")
        pttItem.target = self
        toolsMenu.addItem(pttItem)

        toolsMenu.addItem(NSMenuItem.separator())

        let dangerItem = NSMenuItem(title: "Danger Mode", action: #selector(toggleDangerMode(_:)), keyEquivalent: "")
        dangerItem.target = self
        toolsMenu.addItem(dangerItem)

        let remoteItem = NSMenuItem(title: "Remote Control (Claude only)", action: #selector(toggleRemoteControl(_:)), keyEquivalent: "")
        toolsMenu.addItem(remoteItem)

        let stealthItem = NSMenuItem(title: "Stealth Mode", action: #selector(toggleStealthMode(_:)), keyEquivalent: "s")
        stealthItem.keyEquivalentModifierMask = [.command, .shift, .option]
        stealthItem.target = self
        toolsMenu.addItem(stealthItem)

        toolsMenu.addItem(NSMenuItem.separator())

        let preventSleepItem = NSMenuItem(title: "Prevent Sleep", action: #selector(togglePreventSleep(_:)), keyEquivalent: "")
        toolsMenu.addItem(preventSleepItem)

        let notifItem = NSMenuItem(title: "Notifications", action: #selector(toggleNotifications(_:)), keyEquivalent: "")
        toolsMenu.addItem(notifItem)

        toolsMenuItem.submenu = toolsMenu
        mainMenu.addItem(toolsMenuItem)

        // AI Components menu (top-level)
        let aiCompMenuItem = NSMenuItem()
        let aiCompMenu = NSMenu(title: "AI Components")

        let manageItem = NSMenuItem(title: "Manage Components...", action: #selector(showAIComponentsManager(_:)), keyEquivalent: "")
        aiCompMenu.addItem(manageItem)

        let syncItem = NSMenuItem(title: "Sync Now", action: #selector(syncAIComponentsNow(_:)), keyEquivalent: "y")
        syncItem.keyEquivalentModifierMask = [.command, .shift]
        aiCompMenu.addItem(syncItem)

        aiCompMenu.addItem(NSMenuItem.separator())

        let enableItem = NSMenuItem(title: "Enable AI Components", action: #selector(toggleAIComponentsEnabled(_:)), keyEquivalent: "")
        enableItem.target = self
        aiCompMenu.addItem(enableItem)

        let autoDetectItem = NSMenuItem(title: "Auto-detect Project Type", action: #selector(toggleAIComponentsAutoDetect(_:)), keyEquivalent: "")
        autoDetectItem.target = self
        aiCompMenu.addItem(autoDetectItem)

        aiCompMenu.addItem(NSMenuItem.separator())

        // Security submenu
        let securityMenu = NSMenu(title: "Security")

        let scanItem = NSMenuItem(title: "Security Scanning", action: #selector(toggleSecurityScan(_:)), keyEquivalent: "")
        scanItem.target = self
        securityMenu.addItem(scanItem)

        let blockItem = NSMenuItem(title: "Block Critical Findings", action: #selector(toggleBlockCritical(_:)), keyEquivalent: "")
        blockItem.target = self
        securityMenu.addItem(blockItem)

        let hookApprovalItem = NSMenuItem(title: "Require Hook Approval", action: #selector(toggleRequireHookApproval(_:)), keyEquivalent: "")
        hookApprovalItem.target = self
        securityMenu.addItem(hookApprovalItem)

        securityMenu.addItem(NSMenuItem.separator())

        let viewFindingsItem = NSMenuItem(title: "View All Findings…", action: #selector(showAllSecurityFindings(_:)), keyEquivalent: "")
        viewFindingsItem.target = self
        securityMenu.addItem(viewFindingsItem)

        let editRulesItem = NSMenuItem(title: "Edit Custom Rules…", action: #selector(editCustomSecurityRules(_:)), keyEquivalent: "")
        editRulesItem.target = self
        securityMenu.addItem(editRulesItem)

        let securityMenuItem = NSMenuItem(title: "Security", action: nil, keyEquivalent: "")
        securityMenuItem.submenu = securityMenu
        aiCompMenu.addItem(securityMenuItem)

        aiCompMenu.addItem(NSMenuItem.separator())

        let importExportItem = NSMenuItem(title: "Import & Export...", action: #selector(showImportExport(_:)), keyEquivalent: "")
        aiCompMenu.addItem(importExportItem)

        aiCompMenuItem.submenu = aiCompMenu
        mainMenu.addItem(aiCompMenuItem)

        // Window menu — standard macOS window management
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")

        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // Help menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Awal Terminal Help", action: #selector(showHelpWindow(_:)), keyEquivalent: "?")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
        NSApplication.shared.helpMenu = helpMenu

        // Apply user-configured keybindings from TOML config
        applyKeybindings(mainMenu)
    }

    /// Map of action names to their menu item titles for keybinding lookup.
    private static let actionTitles: [String: String] = [
        "new_tab": "New Tab",
        "close_tab": "Close Tab",
        "next_tab": "Next Tab",
        "prev_tab": "Previous Tab",
        "rename_tab": "Rename Tab…",
        "find": "Find…",
        "toggle_side_panel": "AI Side Panel",
        "quick_terminal": "Quick Terminal",
        "settings": "Preferences…",
        "manage_components": "Manage Components...",
        "sync_components": "Sync Now",
        "mission_control": "Mission Control",
        "start_recording": "Start/Stop Recording",
        "remote_control": "Remote Control (Claude only)",
        "command_palette": "Command Palette",
        "stealth_mode": "Stealth Mode",
        "create_tab_group": "New Tab Group",
        "toggle_group_collapse": "Toggle Group Collapse",
    ]

    private func applyKeybindings(_ menu: NSMenu) {
        let bindings = AppConfig.shared.keybindings
        guard !bindings.isEmpty else { return }

        // Build a flat lookup of title -> menu item
        var itemsByTitle: [String: NSMenuItem] = [:]
        func collect(_ menu: NSMenu) {
            for item in menu.items {
                itemsByTitle[item.title] = item
                if let sub = item.submenu { collect(sub) }
            }
        }
        collect(menu)

        for (action, combo) in bindings {
            guard let title = Self.actionTitles[action],
                  let item = itemsByTitle[title],
                  let (key, mods) = AppConfig.parseKeybinding(combo) else { continue }
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
        }
    }
}
