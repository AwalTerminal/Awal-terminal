import AppKit

/// General app-wide preferences window with tabs for Theme, Font, Keybindings, and Voice.
class PreferencesWindow: NSWindowController, NSWindowDelegate {

    private static var shared: PreferencesWindow?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.runModal(for: existing.window!)
            return
        }
        let controller = PreferencesWindow()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: controller.window!)
    }

    private let tabView = NSTabView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBg
        if AppIcon.image != nil { window.representedURL = nil }

        super.init(window: window)
        window.delegate = self

        setupTabs()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        Self.shared = nil
    }

    // MARK: - Tabs

    private func setupTabs() {
        tabView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: window!.contentView!.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: window!.contentView!.bottomAnchor),
        ])

        tabView.addTabViewItem(createKeybindingsTab())
        tabView.addTabViewItem(createTabsTab())
        tabView.addTabViewItem(createRecordingTab())
        tabView.addTabViewItem(createVoiceTab())
        tabView.addTabViewItem(createFontTab())
        tabView.addTabViewItem(createThemeTab())
    }

    // MARK: - Theme Tab

    private func createThemeTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "theme")
        item.label = "Theme"

        let view = NSView()
        let config = AppConfig.shared

        let colorDefs: [(String, String, NSColor)] = [
            ("Background", "theme.bg", config.themeBg),
            ("Foreground", "theme.fg", config.themeFg),
            ("Cursor", "theme.cursor", config.themeCursor),
            ("Selection", "theme.selection", config.themeSelection),
            ("Accent", "theme.accent", config.themeAccent),
            ("Tab Bar", "theme.tab_bar_bg", config.themeTabBarBg),
            ("Active Tab", "theme.tab_active_bg", config.themeTabActiveBg),
            ("Status Bar", "theme.status_bar_bg", config.themeStatusBarBg),
        ]

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        grid.columnSpacing = 12
        grid.rowSpacing = 8

        for (label, key, color) in colorDefs {
            let labelField = NSTextField(labelWithString: label)
            labelField.font = .systemFont(ofSize: 13)

            let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
            well.color = color
            well.tag = colorDefs.firstIndex(where: { $0.1 == key }) ?? 0
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.identifier = NSUserInterfaceItemIdentifier(key)

            let row = grid.addRow(with: [labelField, well])
            row.height = 30
        }

        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
        ])

        let note = NSTextField(labelWithString: "Changes are saved to ~/.config/awal/config.toml\nRestart the app for changes to take effect.")
        note.font = Theme.captionFont
        note.textColor = Theme.textTertiary
        note.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        item.view = view
        return item
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let key = sender.identifier?.rawValue else { return }
        let hex = colorToHex(sender.color)
        ConfigWriter.updateValue(key: key, value: "\"\(hex)\"")
    }

    // MARK: - Tabs Tab

    private var paletteSwatchStack: NSStackView?

    private func createTabsTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "tabs")
        item.label = "Tabs"

        let view = NSView()
        let config = AppConfig.shared

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 10

        // Tab bar position
        let orientationLabel = NSTextField(labelWithString: "Tab Bar Position")
        orientationLabel.font = .systemFont(ofSize: 13)
        let orientationPopup = NSPopUpButton()
        orientationPopup.addItems(withTitles: ["Top", "Left Side"])
        orientationPopup.selectItem(at: config.tabsOrientation == .vertical ? 1 : 0)
        orientationPopup.target = self
        orientationPopup.action = #selector(tabsOrientationChanged(_:))
        grid.addRow(with: [orientationLabel, orientationPopup])

        // Confirm close toggle
        let confirmLabel = NSTextField(labelWithString: "Confirm Close")
        confirmLabel.font = .systemFont(ofSize: 13)
        let confirmCheck = NSButton(checkboxWithTitle: "Ask before closing a tab", target: self, action: #selector(tabsConfirmCloseChanged(_:)))
        confirmCheck.state = config.tabsConfirmClose ? .on : .off
        grid.addRow(with: [confirmLabel, confirmCheck])

        // Quit confirm toggle
        let quitConfirmLabel = NSTextField(labelWithString: "")
        quitConfirmLabel.font = .systemFont(ofSize: 13)
        let quitConfirmCheck = NSButton(checkboxWithTitle: "Ask before quitting", target: self, action: #selector(quitConfirmCloseChanged(_:)))
        quitConfirmCheck.state = config.quitConfirmClose ? .on : .off
        grid.addRow(with: [quitConfirmLabel, quitConfirmCheck])

        // Random colors toggle
        let enabledLabel = NSTextField(labelWithString: "Random Colors")
        enabledLabel.font = .systemFont(ofSize: 13)
        let enabledCheck = NSButton(checkboxWithTitle: "Assign a random color to each new tab", target: self, action: #selector(tabsRandomColorsChanged(_:)))
        enabledCheck.state = config.tabsRandomColors ? .on : .off
        grid.addRow(with: [enabledLabel, enabledCheck])

        // Palette swatches
        let swatchLabel = NSTextField(labelWithString: "Palette")
        swatchLabel.font = .systemFont(ofSize: 13)
        let swatchStack = NSStackView()
        swatchStack.orientation = .horizontal
        swatchStack.spacing = 4
        paletteSwatchStack = swatchStack
        updatePaletteSwatches(config: config)
        grid.addRow(with: [swatchLabel, swatchStack])

        // Custom palette field
        let paletteLabel = NSTextField(labelWithString: "Custom Palette")
        paletteLabel.font = .systemFont(ofSize: 13)
        let paletteField = NSTextField(string: "")
        paletteField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        paletteField.placeholderString = "e.g. #E55353, #3498DB, #27AE60"
        paletteField.identifier = NSUserInterfaceItemIdentifier("tabs.random_color_palette")
        paletteField.target = self
        paletteField.action = #selector(tabsPaletteChanged(_:))

        // Load existing palette string from config
        if let contents = try? String(contentsOf: ConfigWriter.configFile, encoding: .utf8) {
            let lines = contents.components(separatedBy: "\n")
            var inSection = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "[tabs]" { inSection = true; continue }
                if inSection && trimmed.hasPrefix("[") { break }
                if inSection && (trimmed.hasPrefix("random_color_palette =") || trimmed.hasPrefix("random_color_palette=")) {
                    var val = String(trimmed.split(separator: "=", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
                    if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                        val = String(val.dropFirst().dropLast())
                    }
                    paletteField.stringValue = val
                    break
                }
            }
        }

        grid.addRow(with: [paletteLabel, paletteField])
        grid.column(at: 1).width = 320

        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])

        let note = NSTextField(labelWithString: "Leave Custom Palette empty to use the default 8-color palette.\nChanges take effect for new tabs immediately.")
        note.font = Theme.captionFont
        note.textColor = Theme.textTertiary
        note.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        item.view = view
        return item
    }

    private func updatePaletteSwatches(config: AppConfig) {
        guard let stack = paletteSwatchStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let colors = config.tabsRandomColorPalette.isEmpty
            ? TerminalWindowController.defaultTabColorPalette
            : config.tabsRandomColorPalette

        for color in colors {
            let swatch = NSView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = color.cgColor
            swatch.layer?.cornerRadius = 3
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 18).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
            stack.addArrangedSubview(swatch)
        }
    }

    @objc private func tabsOrientationChanged(_ sender: NSPopUpButton) {
        let value = sender.indexOfSelectedItem == 1 ? "vertical" : "horizontal"
        ConfigWriter.updateValue(key: "tabs.orientation", value: value)
        AppConfig.reload()
        NotificationCenter.default.post(name: .tabBarOrientationDidChange, object: nil)
    }

    @objc private func tabsConfirmCloseChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        ConfigWriter.updateValue(key: "tabs.confirm_close", value: enabled ? "true" : "false")
        AppConfig.reload()
    }

    @objc private func quitConfirmCloseChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        ConfigWriter.updateValue(key: "quit.confirm_close", value: enabled ? "true" : "false")
        AppConfig.reload()
    }

    @objc private func tabsRandomColorsChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        ConfigWriter.updateValue(key: "tabs.random_colors", value: enabled ? "true" : "false")
        AppConfig.reload()
    }

    @objc private func tabsPaletteChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            ConfigWriter.removeValue(key: "tabs.random_color_palette")
        } else {
            ConfigWriter.updateValue(key: "tabs.random_color_palette", value: "\"\(value)\"")
        }
        AppConfig.reload()
        updatePaletteSwatches(config: AppConfig.shared)
    }

    // MARK: - Recording Tab

    private func createRecordingTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "recording")
        item.label = "Recording"

        let view = NSView()
        let config = AppConfig.shared

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 10

        // Max duration popup
        let durationLabel = NSTextField(labelWithString: "Max Duration")
        durationLabel.font = .systemFont(ofSize: 13)

        let durationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let options: [(String, Int)] = [
            ("1 minute", 60),
            ("2 minutes", 120),
            ("5 minutes", 300),
            ("10 minutes", 600),
            ("30 minutes", 1800),
            ("No limit", 0),
        ]
        for (title, _) in options {
            durationPopup.addItem(withTitle: title)
        }

        // Select current value
        let currentValue = config.recordingMaxDuration
        if let idx = options.firstIndex(where: { $0.1 == currentValue }) {
            durationPopup.selectItem(at: idx)
        } else {
            // Custom value not in presets — default to closest or "5 minutes"
            durationPopup.selectItem(at: 2)
        }

        durationPopup.target = self
        durationPopup.action = #selector(recordingMaxDurationChanged(_:))
        grid.addRow(with: [durationLabel, durationPopup])

        grid.column(at: 1).width = 200
        view.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])

        let note = NSTextField(labelWithString: "Recording will auto-stop when the max duration is reached.\nSet to \"No limit\" for unlimited recording.")
        note.font = Theme.captionFont
        note.textColor = Theme.textTertiary
        note.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        item.view = view
        return item
    }

    @objc private func recordingMaxDurationChanged(_ sender: NSPopUpButton) {
        let values = [60, 120, 300, 600, 1800, 0]
        let value = values[sender.indexOfSelectedItem]
        ConfigWriter.updateValue(key: "recording.max_duration", value: "\(value)")
        AppConfig.reload()
    }

    // MARK: - Font Tab

    private func createFontTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "font")
        item.label = "Font"

        let view = NSView()
        let config = AppConfig.shared

        // Font family
        let familyLabel = NSTextField(labelWithString: "Font Family:")
        familyLabel.font = .systemFont(ofSize: 13)
        familyLabel.translatesAutoresizingMaskIntoConstraints = false

        let familyField = NSTextField(string: config.fontFamily.isEmpty ? "JetBrains Mono (bundled)" : config.fontFamily)
        familyField.font = .systemFont(ofSize: 13)
        familyField.translatesAutoresizingMaskIntoConstraints = false
        familyField.identifier = NSUserInterfaceItemIdentifier("font.family")
        familyField.target = self
        familyField.action = #selector(fontFieldChanged(_:))

        // Font size
        let sizeLabel = NSTextField(labelWithString: "Font Size:")
        sizeLabel.font = .systemFont(ofSize: 13)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false

        let sizeStepper = NSStepper(frame: .zero)
        sizeStepper.minValue = 8
        sizeStepper.maxValue = 36
        sizeStepper.increment = 1
        sizeStepper.doubleValue = Double(config.fontSize)
        sizeStepper.translatesAutoresizingMaskIntoConstraints = false
        sizeStepper.target = self
        sizeStepper.action = #selector(fontSizeChanged(_:))

        let sizeField = NSTextField(string: "\(Int(config.fontSize))")
        sizeField.font = .systemFont(ofSize: 13)
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.isEditable = false
        sizeField.identifier = NSUserInterfaceItemIdentifier("fontSizeDisplay")

        // Preview
        let previewLabel = NSTextField(labelWithString: "Preview:")
        previewLabel.font = .systemFont(ofSize: 13)
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        let previewField = NSTextField(labelWithString: "AaBbCc 0Oo1Il => != ->")
        previewField.font = config.resolvedFont
        previewField.translatesAutoresizingMaskIntoConstraints = false
        previewField.identifier = NSUserInterfaceItemIdentifier("fontPreview")

        for v in [familyLabel, familyField, sizeLabel, sizeField, sizeStepper, previewLabel, previewField] {
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            familyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            familyLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            familyField.leadingAnchor.constraint(equalTo: familyLabel.trailingAnchor, constant: 12),
            familyField.centerYAnchor.constraint(equalTo: familyLabel.centerYAnchor),
            familyField.widthAnchor.constraint(equalToConstant: 200),

            sizeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sizeLabel.topAnchor.constraint(equalTo: familyLabel.bottomAnchor, constant: 16),
            sizeField.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 12),
            sizeField.centerYAnchor.constraint(equalTo: sizeLabel.centerYAnchor),
            sizeField.widthAnchor.constraint(equalToConstant: 40),
            sizeStepper.leadingAnchor.constraint(equalTo: sizeField.trailingAnchor, constant: 4),
            sizeStepper.centerYAnchor.constraint(equalTo: sizeLabel.centerYAnchor),

            previewLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            previewLabel.topAnchor.constraint(equalTo: sizeLabel.bottomAnchor, constant: 24),
            previewField.leadingAnchor.constraint(equalTo: previewLabel.trailingAnchor, constant: 12),
            previewField.centerYAnchor.constraint(equalTo: previewLabel.centerYAnchor),
        ])

        let note = NSTextField(labelWithString: "Changes are saved to ~/.config/awal/config.toml\nRestart the app for changes to take effect.")
        note.font = Theme.captionFont
        note.textColor = Theme.textTertiary
        note.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        item.view = view
        return item
    }

    @objc private func fontFieldChanged(_ sender: NSTextField) {
        let family = sender.stringValue
        ConfigWriter.updateValue(key: "font.family", value: "\"\(family)\"")
    }

    @objc private func fontSizeChanged(_ sender: NSStepper) {
        let size = Int(sender.doubleValue)
        // Update the display field
        if let sizeField = sender.superview?.subviews
            .compactMap({ $0 as? NSTextField })
            .first(where: { $0.identifier?.rawValue == "fontSizeDisplay" }) {
            sizeField.stringValue = "\(size)"
        }
        ConfigWriter.updateValue(key: "font.size", value: "\(size)")
    }

    // MARK: - Keybindings Tab

    private func createKeybindingsTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "keybindings")
        item.label = "Keybindings"

        let view = NSView()

        let actions: [(String, String, String)] = [
            ("new_tab", "New Tab", "cmd+t"),
            ("close_tab", "Close Tab", "cmd+w"),
            ("next_tab", "Next Tab", "cmd+shift+]"),
            ("prev_tab", "Previous Tab", "cmd+shift+["),
            ("rename_tab", "Rename Tab", "cmd+shift+r"),
            ("find", "Find", "cmd+f"),
            ("split_right", "Split Right", "cmd+d"),
            ("split_down", "Split Down", "cmd+shift+d"),
            ("close_pane", "Close Pane", "cmd+shift+w"),
            ("next_pane", "Next Pane", "cmd+]"),
            ("prev_pane", "Previous Pane", "cmd+["),
            ("toggle_side_panel", "AI Side Panel", "cmd+shift+i"),
            ("quick_terminal", "Quick Terminal", "ctrl+`"),
            ("settings", "Settings", "cmd+,"),
            ("create_tab_group", "New Tab Group", "cmd+shift+g"),
            ("toggle_group_collapse", "Toggle Group Collapse", "cmd+shift+."),
        ]

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 12

        // Header
        let hdrAction = NSTextField(labelWithString: "Action")
        hdrAction.font = .boldSystemFont(ofSize: 12)
        let hdrDefault = NSTextField(labelWithString: "Default")
        hdrDefault.font = .boldSystemFont(ofSize: 12)
        let hdrCustom = NSTextField(labelWithString: "Custom")
        hdrCustom.font = .boldSystemFont(ofSize: 12)
        grid.addRow(with: [hdrAction, hdrDefault, hdrCustom])

        let config = AppConfig.shared
        for (action, label, defaultKey) in actions {
            let actionLabel = NSTextField(labelWithString: label)
            actionLabel.font = .systemFont(ofSize: 13)

            let defaultLabel = NSTextField(labelWithString: defaultKey)
            defaultLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            defaultLabel.textColor = .secondaryLabelColor

            let customField = NSTextField(string: config.keybindings[action] ?? "")
            customField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            customField.placeholderString = defaultKey
            customField.identifier = NSUserInterfaceItemIdentifier("kb.\(action)")
            customField.target = self
            customField.action = #selector(keybindingChanged(_:))

            let row = grid.addRow(with: [actionLabel, defaultLabel, customField])
            row.height = 30
        }

        grid.column(at: 2).width = 160

        scrollView.documentView = grid
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        item.view = view
        return item
    }

    @objc private func keybindingChanged(_ sender: NSTextField) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("kb.") else { return }
        let action = String(id.dropFirst(3))
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            ConfigWriter.removeValue(key: "keybindings.\(action)")
        } else {
            ConfigWriter.updateValue(key: "keybindings.\(action)", value: "\"\(value)\"")
        }
    }

    // MARK: - Voice Tab

    private func createVoiceTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "voice")
        item.label = "Voice"

        let view = NSView()
        let config = AppConfig.shared

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 10

        // Enabled toggle
        let enabledLabel = NSTextField(labelWithString: "Enabled")
        enabledLabel.font = .systemFont(ofSize: 13)
        let enabledCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(voiceEnabledChanged(_:)))
        enabledCheck.state = config.voiceEnabled ? .on : .off
        grid.addRow(with: [enabledLabel, enabledCheck])

        // Mode (push-to-talk only)

        // Whisper model
        let modelLabel = NSTextField(labelWithString: "Whisper Model")
        modelLabel.font = .systemFont(ofSize: 13)
        let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        modelPicker.addItems(withTitles: ModelDownloadManager.availableModels)
        if let idx = ModelDownloadManager.availableModels.firstIndex(of: config.voiceWhisperModel) {
            modelPicker.selectItem(at: idx)
        }
        modelPicker.target = self
        modelPicker.action = #selector(voiceModelChanged(_:))
        grid.addRow(with: [modelLabel, modelPicker])

        // VAD threshold slider
        let vadLabel = NSTextField(labelWithString: "VAD Threshold")
        vadLabel.font = .systemFont(ofSize: 13)
        let vadSlider = NSSlider(value: Double(config.voiceVadThreshold), minValue: 0.005, maxValue: 0.1, target: self, action: #selector(voiceVadChanged(_:)))
        vadSlider.numberOfTickMarks = 10
        grid.addRow(with: [vadLabel, vadSlider])

        // PTT hotkey
        let hotkeyLabel = NSTextField(labelWithString: "Push-to-Talk Key")
        hotkeyLabel.font = .systemFont(ofSize: 13)
        let hotkeyField = NSTextField(string: config.voicePushToTalkKey)
        hotkeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hotkeyField.identifier = NSUserInterfaceItemIdentifier("voice.push_to_talk_key")
        hotkeyField.target = self
        hotkeyField.action = #selector(voiceFieldChanged(_:))
        grid.addRow(with: [hotkeyLabel, hotkeyField])

        // (Wake word and continuous modes removed)

        // Auto-enter
        let enterLabel = NSTextField(labelWithString: "Auto-Enter")
        enterLabel.font = .systemFont(ofSize: 13)
        let enterCheck = NSButton(checkboxWithTitle: "Append newline after dictation", target: self, action: #selector(voiceAutoEnterChanged(_:)))
        enterCheck.state = config.voiceDictationAutoEnter ? .on : .off
        grid.addRow(with: [enterLabel, enterCheck])

        // Auto-space
        let spaceLabel = NSTextField(labelWithString: "Auto-Space")
        spaceLabel.font = .systemFont(ofSize: 13)
        let spaceCheck = NSButton(checkboxWithTitle: "Add space between segments", target: self, action: #selector(voiceAutoSpaceChanged(_:)))
        spaceCheck.state = config.voiceDictationAutoSpace ? .on : .off
        grid.addRow(with: [spaceLabel, spaceCheck])

        grid.column(at: 1).width = 200
        view.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])

        let note = NSTextField(labelWithString: "Changes are saved to ~/.config/awal/config.toml\nRestart the app for changes to take effect.")
        note.font = Theme.captionFont
        note.textColor = Theme.textTertiary
        note.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        item.view = view
        return item
    }

    @objc private func voiceEnabledChanged(_ sender: NSButton) {
        ConfigWriter.updateValue(key: "voice.enabled", value: sender.state == .on ? "true" : "false")
    }

    // Voice mode is now push-to-talk only — no mode picker needed

    @objc private func voiceModelChanged(_ sender: NSPopUpButton) {
        let model = ModelDownloadManager.availableModels[sender.indexOfSelectedItem]
        ConfigWriter.updateValue(key: "voice.whisper_model", value: "\"\(model)\"")
    }

    @objc private func voiceVadChanged(_ sender: NSSlider) {
        ConfigWriter.updateValue(key: "voice.vad_threshold", value: String(format: "%.3f", sender.doubleValue))
    }

    @objc private func voiceFieldChanged(_ sender: NSTextField) {
        guard let key = sender.identifier?.rawValue else { return }
        ConfigWriter.updateValue(key: key, value: "\"\(sender.stringValue)\"")
    }

    @objc private func voiceAutoEnterChanged(_ sender: NSButton) {
        ConfigWriter.updateValue(key: "voice.dictation_auto_enter", value: sender.state == .on ? "true" : "false")
    }

    @objc private func voiceAutoSpaceChanged(_ sender: NSButton) {
        ConfigWriter.updateValue(key: "voice.dictation_auto_space", value: sender.state == .on ? "true" : "false")
    }

    // MARK: - Helpers

    private func colorToHex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int(c.redComponent * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
