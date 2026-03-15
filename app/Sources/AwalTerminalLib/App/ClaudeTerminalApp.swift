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

        let controller = TerminalWindowController(isInitialTab: true)
        TerminalWindowTracker.shared.register(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        QuickTerminalController.shared.unregisterHotKey()
        unregisterVoiceHotKey()
        VoiceInputController.shared.stop()
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

        RegistryManager.shared.syncAll(registries: config.aiComponentRegistries, force: true) { results in
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

    // MARK: - Voice Input

    private var voicePTTHotKeyRef: EventHotKeyRef?
    private var voicePTTEventHandler: EventHandlerRef?
    private var isPTTPressed = false

    @objc func toggleVoiceInput(_ sender: Any?) {
        VoiceInputController.shared.toggle()
    }

    @objc func setVoiceModePTT(_ sender: Any?) {
        VoiceInputController.shared.mode = .pushToTalk
        VoiceInputController.shared.stop()
    }

    @objc func setVoiceModeContinuous(_ sender: Any?) {
        VoiceInputController.shared.mode = .continuous
        VoiceInputController.shared.stop()
        VoiceInputController.shared.isEnabled = true
        VoiceInputController.shared.startContinuous()
    }

    @objc func setVoiceModeWakeWord(_ sender: Any?) {
        VoiceInputController.shared.mode = .wakeWord
        VoiceInputController.shared.stop()
        VoiceInputController.shared.isEnabled = true
        VoiceInputController.shared.startContinuous()
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
                    guard VoiceInputController.shared.isEnabled,
                          VoiceInputController.shared.mode == .pushToTalk else { return }
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
        if menuItem.action == #selector(toggleVoiceInput(_:)) {
            menuItem.state = VoiceInputController.shared.state != .idle ? .on : .off
        }
        let currentMode = VoiceInputController.shared.mode
        if menuItem.action == #selector(setVoiceModePTT(_:)) {
            menuItem.state = currentMode == .pushToTalk ? .on : .off
        }
        if menuItem.action == #selector(setVoiceModeContinuous(_:)) {
            return false
        }
        if menuItem.action == #selector(setVoiceModeWakeWord(_:)) {
            return false
        }
        return true
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Awal Terminal")
        appMenu.addItem(withTitle: "About Awal Terminal", action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Awal Terminal", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Model Settings…", action: #selector(TerminalWindowController.openSettings(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Awal Terminal", action: #selector(confirmQuit(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Shell menu — creating and closing sessions
        let shellMenuItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")

        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(TerminalWindowController.newTab(_:)), keyEquivalent: "t")
        shellMenu.addItem(newTabItem)

        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(TerminalWindowController.closeTab(_:)), keyEquivalent: "w")
        shellMenu.addItem(closeTabItem)

        let renameTabItem = NSMenuItem(title: "Rename Tab…", action: #selector(TerminalWindowController.renameTab(_:)), keyEquivalent: "r")
        renameTabItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(renameTabItem)

        // Split panes disabled — black screen bug after tab switch (Auto Layout vs frame-based conflict)
        shellMenu.addItem(NSMenuItem.separator())

        let splitRightItem = NSMenuItem(title: "Split Right", action: nil, keyEquivalent: "")
        splitRightItem.isEnabled = false
        shellMenu.addItem(splitRightItem)

        let splitDownItem = NSMenuItem(title: "Split Down", action: nil, keyEquivalent: "")
        splitDownItem.isEnabled = false
        shellMenu.addItem(splitDownItem)

        let closePaneItem = NSMenuItem(title: "Close Pane", action: nil, keyEquivalent: "")
        closePaneItem.isEnabled = false
        shellMenu.addItem(closePaneItem)

        shellMenu.addItem(NSMenuItem.separator())
        shellMenu.addItem(withTitle: "Manage Worktrees…", action: #selector(showManageWorktrees(_:)), keyEquivalent: "")

        shellMenuItem.submenu = shellMenu
        mainMenu.addItem(shellMenuItem)

        // Edit menu — text operations
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(NSMenuItem.separator())

        let findItem = NSMenuItem(title: "Find…", action: #selector(TerminalWindowController.findInTerminal(_:)), keyEquivalent: "f")
        editMenu.addItem(findItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu — UI panel toggles
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let sidePanelItem = NSMenuItem(title: "AI Side Panel", action: #selector(TerminalWindowController.toggleAISidePanel(_:)), keyEquivalent: "i")
        sidePanelItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(sidePanelItem)

        let quickTermItem = NSMenuItem(title: "Quick Terminal", action: #selector(toggleQuickTerminal(_:)), keyEquivalent: "`")
        quickTermItem.keyEquivalentModifierMask = [.control]
        viewMenu.addItem(quickTermItem)

        viewMenu.addItem(NSMenuItem.separator())

        let dangerItem = NSMenuItem(title: "Danger Mode", action: #selector(toggleDangerMode(_:)), keyEquivalent: "")
        dangerItem.target = self
        viewMenu.addItem(dangerItem)

        let notifItem = NSMenuItem(title: "Notifications", action: #selector(toggleNotifications(_:)), keyEquivalent: "")
        viewMenu.addItem(notifItem)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // AI Components menu
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

        let importExportItem = NSMenuItem(title: "Import & Export...", action: #selector(showImportExport(_:)), keyEquivalent: "")
        aiCompMenu.addItem(importExportItem)

        aiCompMenu.addItem(NSMenuItem.separator())

        aiCompMenuItem.submenu = aiCompMenu
        mainMenu.addItem(aiCompMenuItem)

        // Voice menu
        let voiceMenuItem = NSMenuItem()
        let voiceMenu = NSMenu(title: "Voice")

        let toggleVoiceItem = NSMenuItem(title: "Toggle Voice Input", action: #selector(toggleVoiceInput(_:)), keyEquivalent: "")
        voiceMenu.addItem(toggleVoiceItem)

        voiceMenu.addItem(NSMenuItem.separator())

        let pttItem = NSMenuItem(title: "Push-to-Talk Mode", action: #selector(setVoiceModePTT(_:)), keyEquivalent: "")
        pttItem.target = self
        voiceMenu.addItem(pttItem)

        let continuousItem = NSMenuItem(title: "Continuous Mode", action: #selector(setVoiceModeContinuous(_:)), keyEquivalent: "")
        continuousItem.target = self
        continuousItem.isEnabled = false
        voiceMenu.addItem(continuousItem)

        let wakeWordItem = NSMenuItem(title: "Wake Word Mode", action: #selector(setVoiceModeWakeWord(_:)), keyEquivalent: "")
        wakeWordItem.target = self
        wakeWordItem.isEnabled = false
        voiceMenu.addItem(wakeWordItem)

        voiceMenuItem.submenu = voiceMenu
        mainMenu.addItem(voiceMenuItem)

        // Window menu — window management and navigation
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

        windowMenu.addItem(NSMenuItem.separator())

        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(TerminalWindowController.selectNextTab(_:)), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(TerminalWindowController.selectPreviousTab(_:)), keyEquivalent: "[")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(prevTabItem)

        // Disabled — see split pane bug in Shell menu
        let nextPaneItem = NSMenuItem(title: "Next Pane", action: nil, keyEquivalent: "")
        nextPaneItem.isEnabled = false
        windowMenu.addItem(nextPaneItem)

        let prevPaneItem = NSMenuItem(title: "Previous Pane", action: nil, keyEquivalent: "")
        prevPaneItem.isEnabled = false
        windowMenu.addItem(prevPaneItem)

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
        "split_right": "Split Right",
        "split_down": "Split Down",
        "close_pane": "Close Pane",
        "next_pane": "Next Pane",
        "prev_pane": "Previous Pane",
        "toggle_side_panel": "AI Side Panel",
        "quick_terminal": "Quick Terminal",
        "settings": "Preferences…",
        "manage_components": "Manage Components...",
        "sync_components": "Sync Now",
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
