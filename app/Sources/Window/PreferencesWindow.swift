import AppKit

/// General app-wide preferences window with tabs for Theme, Font, and Keybindings.
class PreferencesWindow: NSWindowController, NSWindowDelegate {

    private static var shared: PreferencesWindow?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PreferencesWindow()
        shared = controller
        controller.showWindow(nil)
    }

    private let tabView = NSTabView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.center()
        window.isReleasedWhenClosed = false
        if AppIcon.image != nil { window.representedURL = nil }

        super.init(window: window)
        window.delegate = self

        setupTabs()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
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

        tabView.addTabViewItem(createThemeTab())
        tabView.addTabViewItem(createFontTab())
        tabView.addTabViewItem(createKeybindingsTab())
        tabView.addTabViewItem(createVoiceTab())
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
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
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
        updateConfigValue(key: key, value: "\"\(hex)\"")
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

        let familyField = NSTextField(string: config.fontFamily.isEmpty ? "(system monospace)" : config.fontFamily)
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
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
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
        updateConfigValue(key: "font.family", value: "\"\(family)\"")
    }

    @objc private func fontSizeChanged(_ sender: NSStepper) {
        let size = Int(sender.doubleValue)
        // Update the display field
        if let sizeField = sender.superview?.subviews
            .compactMap({ $0 as? NSTextField })
            .first(where: { $0.identifier?.rawValue == "fontSizeDisplay" }) {
            sizeField.stringValue = "\(size)"
        }
        updateConfigValue(key: "font.size", value: "\(size)")
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
        ]

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 6

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
            row.height = 26
        }

        grid.column(at: 2).width = 140

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
            removeConfigValue(key: "keybindings.\(action)")
        } else {
            updateConfigValue(key: "keybindings.\(action)", value: "\"\(value)\"")
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

        // Mode picker
        let modeLabel = NSTextField(labelWithString: "Mode")
        modeLabel.font = .systemFont(ofSize: 13)
        let modePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        modePicker.addItems(withTitles: ["Push-to-Talk", "Continuous", "Wake Word"])
        switch config.voiceMode {
        case "continuous": modePicker.selectItem(at: 1)
        case "wake_word": modePicker.selectItem(at: 2)
        default: modePicker.selectItem(at: 0)
        }
        modePicker.target = self
        modePicker.action = #selector(voiceModeChanged(_:))
        grid.addRow(with: [modeLabel, modePicker])

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

        // Wake word
        let wakeLabel = NSTextField(labelWithString: "Wake Word")
        wakeLabel.font = .systemFont(ofSize: 13)
        let wakeField = NSTextField(string: config.voiceWakeWord)
        wakeField.font = .systemFont(ofSize: 13)
        wakeField.identifier = NSUserInterfaceItemIdentifier("voice.wake_word")
        wakeField.target = self
        wakeField.action = #selector(voiceFieldChanged(_:))
        grid.addRow(with: [wakeLabel, wakeField])

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
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
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
        updateConfigValue(key: "voice.enabled", value: sender.state == .on ? "true" : "false")
    }

    @objc private func voiceModeChanged(_ sender: NSPopUpButton) {
        let modes = ["push_to_talk", "continuous", "wake_word"]
        let value = modes[sender.indexOfSelectedItem]
        updateConfigValue(key: "voice.mode", value: "\"\(value)\"")
    }

    @objc private func voiceModelChanged(_ sender: NSPopUpButton) {
        let model = ModelDownloadManager.availableModels[sender.indexOfSelectedItem]
        updateConfigValue(key: "voice.whisper_model", value: "\"\(model)\"")
    }

    @objc private func voiceVadChanged(_ sender: NSSlider) {
        updateConfigValue(key: "voice.vad_threshold", value: String(format: "%.3f", sender.doubleValue))
    }

    @objc private func voiceFieldChanged(_ sender: NSTextField) {
        guard let key = sender.identifier?.rawValue else { return }
        updateConfigValue(key: key, value: "\"\(sender.stringValue)\"")
    }

    @objc private func voiceAutoEnterChanged(_ sender: NSButton) {
        updateConfigValue(key: "voice.dictation_auto_enter", value: sender.state == .on ? "true" : "false")
    }

    @objc private func voiceAutoSpaceChanged(_ sender: NSButton) {
        updateConfigValue(key: "voice.dictation_auto_space", value: sender.state == .on ? "true" : "false")
    }

    // MARK: - Config File Helpers

    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/awal")
    private static let configFile = configDir.appendingPathComponent("config.toml")

    /// Update or insert a key in the TOML config file.
    private func updateConfigValue(key: String, value: String) {
        try? FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)

        let contents = (try? String(contentsOf: Self.configFile, encoding: .utf8)) ?? ""
        var lines = contents.components(separatedBy: "\n")

        // Parse dotted key into section + field
        let parts = key.split(separator: ".", maxSplits: 1)
        let section = parts.count > 1 ? String(parts[0]) : ""
        let field = parts.count > 1 ? String(parts[1]) : key

        // Find the section and update or insert
        var sectionIdx: Int? = nil
        var fieldIdx: Int? = nil

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[\(section)]" {
                sectionIdx = i
            }
            if sectionIdx != nil && (trimmed.hasPrefix("\(field) =") || trimmed.hasPrefix("\(field)=")) {
                fieldIdx = i
                break
            }
            // Stop if we hit another section
            if sectionIdx != nil && i > sectionIdx! && trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                break
            }
        }

        if let fi = fieldIdx {
            lines[fi] = "\(field) = \(value)"
        } else if let si = sectionIdx {
            lines.insert("\(field) = \(value)", at: si + 1)
        } else {
            // Add new section
            if !lines.last!.isEmpty { lines.append("") }
            lines.append("[\(section)]")
            lines.append("\(field) = \(value)")
        }

        let output = lines.joined(separator: "\n")
        try? output.write(to: Self.configFile, atomically: true, encoding: .utf8)
    }

    private func removeConfigValue(key: String) {
        guard let contents = try? String(contentsOf: Self.configFile, encoding: .utf8) else { return }
        let parts = key.split(separator: ".", maxSplits: 1)
        let field = parts.count > 1 ? String(parts[1]) : key

        var lines = contents.components(separatedBy: "\n")
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("\(field) =") || trimmed.hasPrefix("\(field)=")
        }
        let output = lines.joined(separator: "\n")
        try? output.write(to: Self.configFile, atomically: true, encoding: .utf8)
    }

    private func colorToHex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int(c.redComponent * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
