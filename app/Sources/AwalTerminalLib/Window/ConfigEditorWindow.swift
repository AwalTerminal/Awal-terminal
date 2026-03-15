import AppKit

// MARK: - Theme

enum Theme {
    static let windowBg = NSColor(red: 22.0/255.0, green: 22.0/255.0, blue: 22.0/255.0, alpha: 1)
    static let editorBg = NSColor(red: 30.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1)
    static let accent = NSColor(red: 45.0/255.0, green: 127.0/255.0, blue: 212.0/255.0, alpha: 1)
    static let accentSelection = NSColor(red: 45.0/255.0, green: 127.0/255.0, blue: 212.0/255.0, alpha: 0.15)
    static let barBorder = NSColor(white: 1, alpha: 0.06)
    static let textSelection = NSColor(red: 45.0/255.0, green: 127.0/255.0, blue: 212.0/255.0, alpha: 0.4)

    static let stringColor = NSColor(red: 143.0/255.0, green: 217.0/255.0, blue: 143.0/255.0, alpha: 1)
    static let numberColor = NSColor(red: 217.0/255.0, green: 166.0/255.0, blue: 89.0/255.0, alpha: 1)
    static let boolColor = NSColor(red: 140.0/255.0, green: 166.0/255.0, blue: 242.0/255.0, alpha: 1)
    static let nullColor = NSColor(white: 0.35, alpha: 1)
    static let containerColor = NSColor(white: 0.45, alpha: 1)
    static let keyColor = NSColor.white

    static let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let barFont = NSFont.systemFont(ofSize: 11, weight: .medium)
}

// MARK: - Node-associated controls

private class NodeTextField: NSTextField {
    weak var node: ConfigNode?
}

private class NodeButton: NSButton {
    weak var node: ConfigNode?
}

// MARK: - Custom Row View

private class ConfigRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.accentSelection.setFill()
        bounds.fill()
    }

    override func drawSeparator(in dirtyRect: NSRect) {
        let sep = NSRect(x: 0, y: bounds.maxY - 0.5, width: bounds.width, height: 0.5)
        NSColor(white: 1, alpha: 0.04).setFill()
        sep.fill()
    }
}

// MARK: - ConfigEditorWindow

class ConfigEditorWindow: NSWindowController, NSWindowDelegate {

    // Singleton
    private static var shared: ConfigEditorWindow?

    // Current state
    private var currentModel: LLMModel
    private var currentProfileName: String = "Default"
    private var isDirty = false

    // Structured mode
    private var rootNode: ConfigNode?
    private var outlineView: NSOutlineView!
    private var outlineScroll: NSScrollView!
    private var emptyLabel: NSTextField!

    // Raw / fallback text mode
    private let textView = NSTextView()
    private var textScroll: NSScrollView!
    private var isTextMode = false


    // UI bars
    private var tabBar: LLMTabBar!
    private var profileBar: ProfileBar!
    private var barView: NSView!
    private var rawToggle: NSButton!
    private var addButton: NSButton!
    private var removeButton: NSButton!

    // MARK: - Show (Entry Point)

    static func show(activeModelName: String) {
        // Find model; fall back to first configurable
        let model = ModelCatalog.configurable.first { $0.name == activeModelName }
            ?? ModelCatalog.configurable.first!

        if let existing = shared {
            existing.switchToModel(model)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.runModal(for: existing.window!)
            return
        }

        let controller = ConfigEditorWindow(model: model)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: controller.window!)
    }

    // MARK: - Init

    private init(model: LLMModel) {
        self.currentModel = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Settings"
        window.center()
        window.minSize = NSSize(width: 500, height: 400)
        window.backgroundColor = Theme.windowBg
        window.isOpaque = true

        super.init(window: window)
        window.delegate = self

        setupUI()
        loadModel(model)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Tab bar (36px)
        tabBar = LLMTabBar()
        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabBar)

        // Profile bar (32px)
        profileBar = ProfileBar()
        profileBar.delegate = self
        profileBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(profileBar)

        // Editor button bar (32px)
        barView = NSView()
        barView.translatesAutoresizingMaskIntoConstraints = false
        barView.wantsLayer = true
        barView.layer?.backgroundColor = Theme.windowBg.cgColor
        contentView.addSubview(barView)

        let barSep = NSView()
        barSep.translatesAutoresizingMaskIntoConstraints = false
        barSep.wantsLayer = true
        barSep.layer?.backgroundColor = Theme.barBorder.cgColor
        barView.addSubview(barSep)

        addButton = makeBarButton(title: "Add", image: "plus", action: #selector(addNode(_:)))
        removeButton = makeBarButton(title: "Remove", image: "minus", action: #selector(removeNode(_:)))
        rawToggle = makeBarButton(title: "Raw JSON", image: "curlybraces", action: #selector(toggleRawJSON(_:)))

        barView.addSubview(addButton)
        barView.addSubview(removeButton)
        barView.addSubview(rawToggle)

        // Outline view
        outlineView = NSOutlineView()
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.backgroundColor = Theme.editorBg
        outlineView.rowHeight = 28
        outlineView.intercellSpacing = NSSize(width: 4, height: 0)
        outlineView.indentationPerLevel = 20
        outlineView.headerView = nil
        outlineView.floatsGroupRows = false

        let keyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        keyColumn.title = "Key"
        keyColumn.width = 280
        keyColumn.minWidth = 140
        outlineView.addTableColumn(keyColumn)

        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valueColumn.title = "Value"
        valueColumn.width = 460
        valueColumn.minWidth = 120
        outlineView.addTableColumn(valueColumn)

        outlineView.outlineTableColumn = keyColumn
        outlineView.delegate = self
        outlineView.dataSource = self

        outlineScroll = NSScrollView()
        outlineScroll.hasVerticalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.borderType = .noBorder
        outlineScroll.drawsBackground = true
        outlineScroll.backgroundColor = Theme.editorBg
        outlineScroll.documentView = outlineView
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(outlineScroll)

        // Empty label
        emptyLabel = NSTextField(labelWithString: "Empty config. Press + to add a key.")
        emptyLabel.font = Theme.monoFont
        emptyLabel.textColor = NSColor(white: 0.4, alpha: 1)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        contentView.addSubview(emptyLabel)

        // Text view (raw JSON / YAML fallback)
        textScroll = NSScrollView()
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .noBorder
        textScroll.drawsBackground = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textScroll)

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = Theme.monoFont
        textView.textColor = NSColor.white
        textView.backgroundColor = Theme.editorBg
        textView.insertionPointColor = NSColor.white
        textView.selectedTextAttributes = [
            .backgroundColor: Theme.textSelection,
            .foregroundColor: NSColor.white,
        ]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textScroll.documentView = textView
        textScroll.isHidden = true

        NSLayoutConstraint.activate([
            // Tab bar
            tabBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 36),

            // Profile bar
            profileBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            profileBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            profileBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            profileBar.heightAnchor.constraint(equalToConstant: 32),

            // Editor bar
            barView.topAnchor.constraint(equalTo: profileBar.bottomAnchor),
            barView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            barView.heightAnchor.constraint(equalToConstant: 32),

            barSep.leadingAnchor.constraint(equalTo: barView.leadingAnchor),
            barSep.trailingAnchor.constraint(equalTo: barView.trailingAnchor),
            barSep.bottomAnchor.constraint(equalTo: barView.bottomAnchor),
            barSep.heightAnchor.constraint(equalToConstant: 1),

            addButton.leadingAnchor.constraint(equalTo: barView.leadingAnchor, constant: 10),
            addButton.centerYAnchor.constraint(equalTo: barView.centerYAnchor),

            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 2),
            removeButton.centerYAnchor.constraint(equalTo: barView.centerYAnchor),

            rawToggle.trailingAnchor.constraint(equalTo: barView.trailingAnchor, constant: -10),
            rawToggle.centerYAnchor.constraint(equalTo: barView.centerYAnchor),

            // Editor area
            outlineScroll.topAnchor.constraint(equalTo: barView.bottomAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            outlineScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            textScroll.topAnchor.constraint(equalTo: barView.bottomAnchor),
            textScroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            textScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: outlineScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: outlineScroll.centerYAnchor),
        ])
    }

    private func makeBarButton(title: String, image: String, action: Selector) -> NSButton {
        let btn = NSButton(title: " \(title)", target: self, action: action)
        btn.bezelStyle = .recessed
        btn.isBordered = false
        btn.font = Theme.barFont
        btn.contentTintColor = NSColor(white: 0.65, alpha: 1)
        if let img = NSImage(systemSymbolName: image, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            btn.image = img.withSymbolConfiguration(config)
            btn.imagePosition = .imageLeading
        }
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    // MARK: - Model / Profile Loading

    private func loadModel(_ model: LLMModel) {
        currentModel = model
        ProfileStore.shared.ensureProfiles(for: model)

        tabBar.selectModel(named: model.name)
        currentProfileName = ProfileStore.shared.activeProfileName(for: model)

        reloadProfileBar()
        loadCurrentProfile()
        updateSubtitle()
    }

    private func switchToModel(_ model: LLMModel) {
        if model.name == currentModel.name { return }
        if isDirty {
            promptSaveThen { [weak self] in
                self?.loadModel(model)
            }
            return
        }
        loadModel(model)
    }

    private func switchToProfile(_ name: String) {
        if name == currentProfileName { return }
        if isDirty {
            promptSaveThen { [weak self] in
                self?.currentProfileName = name
                self?.reloadProfileBar()
                self?.loadCurrentProfile()
                self?.updateSubtitle()
            }
            return
        }
        currentProfileName = name
        reloadProfileBar()
        loadCurrentProfile()
        updateSubtitle()
    }

    private func reloadProfileBar() {
        let profiles = ProfileStore.shared.profiles(for: currentModel)
        let active = ProfileStore.shared.activeProfileName(for: currentModel)
        profileBar.reload(profiles: profiles, selectedName: currentProfileName, activeName: active)
    }

    private func updateSubtitle() {
        window?.subtitle = "\(currentModel.name) — \(currentProfileName)"
    }

    // MARK: - Load Profile Content

    private func loadCurrentProfile() {
        let content = ProfileStore.shared.loadProfileContent(for: currentModel, name: currentProfileName) ?? ""

        // Reset to structured mode
        isTextMode = false
        outlineScroll.isHidden = false
        textScroll.isHidden = true
        addButton.isEnabled = true
        removeButton.isEnabled = true
        rawToggle.isEnabled = true
        rawToggle.title = " Raw JSON"

        let ext = currentModel.configExtension ?? "json"
        if ext == "yml" || ext == "yaml" {
            enterTextMode(content: content)
        } else if let data = content.data(using: .utf8),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: data) {
            rootNode = ConfigNode.fromJSON(json, key: "Root")
            outlineView.reloadData()
            expandTopLevel()
            updateEmptyState()
        } else if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rootNode = ConfigNode(key: "Root", value: .object)
            outlineView.reloadData()
            updateEmptyState()
        } else {
            enterTextMode(content: content)
        }

        isDirty = false
        window?.isDocumentEdited = false
    }

    private func enterTextMode(content: String) {
        isTextMode = true
        textView.string = content
        outlineScroll.isHidden = true
        emptyLabel.isHidden = true
        textScroll.isHidden = false
        addButton.isEnabled = false
        removeButton.isEnabled = false
        rawToggle.isEnabled = false
        rawToggle.title = " Text Mode"
    }

    private func updateEmptyState() {
        let empty = rootNode?.children.isEmpty ?? true
        emptyLabel.isHidden = !empty
    }

    private func expandTopLevel() {
        guard let root = rootNode else { return }
        for child in root.children {
            if child.isContainer {
                outlineView.expandItem(child)
            }
        }
    }

    // MARK: - Save

    @objc func saveDocument(_ sender: Any?) {
        let content: String
        if isTextMode {
            content = textView.string
        } else if let root = rootNode, let json = ConfigNode.prettyJSON(from: root) {
            content = json + "\n"
        } else {
            return
        }

        // Save to profile file
        ProfileStore.shared.saveProfile(for: currentModel, name: currentProfileName, content: content)

        // If this profile is active, also write to the real config path
        let activeName = ProfileStore.shared.activeProfileName(for: currentModel)
        if currentProfileName == activeName, let realPath = currentModel.expandedConfigPath {
            let dir = (realPath as NSString).deletingLastPathComponent
            let fm = FileManager.default
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            try? content.write(toFile: realPath, atomically: true, encoding: .utf8)
        }

        isDirty = false
        window?.isDocumentEdited = false
    }

    // MARK: - Dirty Prompt

    private func promptSaveThen(completion: @escaping () -> Void) {
        guard let win = window else { completion(); return }
        let alert = NSAlert.branded()
        alert.messageText = "Save changes to \(currentProfileName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: win) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.saveDocument(nil)
                completion()
            case .alertSecondButtonReturn:
                self?.isDirty = false
                self?.window?.isDocumentEdited = false
                completion()
            default:
                break // Cancel — do nothing
            }
        }
    }

    // MARK: - Add Node

    @objc private func addNode(_ sender: Any?) {
        guard !isTextMode, let root = rootNode else { return }

        let selectedRow = outlineView.selectedRow
        var target: ConfigNode = root
        if selectedRow >= 0, let node = outlineView.item(atRow: selectedRow) as? ConfigNode {
            if node.isContainer {
                target = node
            } else if let parent = node.parent {
                target = parent
            }
        }

        let alert = NSAlert.branded()
        alert.messageText = "Add Key"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))

        let nameField = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        nameField.placeholderString = "Key name"
        nameField.font = Theme.monoFont

        let typePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        typePopup.addItems(withTitles: ["String", "Number", "Boolean", "Null", "Object", "Array"])
        typePopup.font = Theme.barFont

        container.addSubview(nameField)
        container.addSubview(typePopup)
        alert.accessoryView = container

        if case .array = target.value {
            nameField.stringValue = "\(target.children.count)"
            nameField.isEditable = false
            nameField.textColor = NSColor.secondaryLabelColor
        }

        guard let win = window else { return }
        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let self = self else { return }

            let key: String
            if case .array = target.value {
                key = "\(target.children.count)"
            } else {
                key = nameField.stringValue
                if key.isEmpty { return }
            }

            let newValue: ConfigNode.ValueType
            switch typePopup.indexOfSelectedItem {
            case 0: newValue = .string("")
            case 1: newValue = .number(NSNumber(value: 0))
            case 2: newValue = .bool(false)
            case 3: newValue = .null
            case 4: newValue = .object
            case 5: newValue = .array
            default: newValue = .string("")
            }

            let child = ConfigNode(key: key, value: newValue)
            target.addChild(child)

            self.outlineView.reloadData()
            self.outlineView.expandItem(target)
            self.markDirty()
            self.updateEmptyState()
        }
    }

    // MARK: - Remove Node

    @objc private func removeNode(_ sender: Any?) {
        guard !isTextMode else { return }
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0, let node = outlineView.item(atRow: selectedRow) as? ConfigNode else { return }
        guard let parent = node.parent else { return }
        guard let index = parent.children.firstIndex(where: { $0 === node }) else { return }

        parent.removeChild(at: index)
        outlineView.reloadData()
        markDirty()
        updateEmptyState()
    }

    // MARK: - Raw JSON Toggle

    @objc private func toggleRawJSON(_ sender: Any?) {
        guard !isTextMode else { return }

        if textScroll.isHidden {
            if let root = rootNode, let json = ConfigNode.prettyJSON(from: root) {
                textView.string = json
            }
            outlineScroll.isHidden = true
            emptyLabel.isHidden = true
            textScroll.isHidden = false
            rawToggle.title = " Tree View"
            addButton.isEnabled = false
            removeButton.isEnabled = false
        } else {
            let text = textView.string
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                rootNode = ConfigNode.fromJSON(json, key: "Root")
                outlineView.reloadData()
                expandTopLevel()
            }
            outlineScroll.isHidden = false
            textScroll.isHidden = true
            rawToggle.title = " Raw JSON"
            addButton.isEnabled = true
            removeButton.isEnabled = true
            updateEmptyState()
        }
    }

    // MARK: - Dirty Tracking

    private func markDirty() {
        isDirty = true
        window?.isDocumentEdited = true
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        ConfigEditorWindow.shared = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isDirty {
            let alert = NSAlert.branded()
            alert.messageText = "Save changes?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                saveDocument(nil)
                return true
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }
        return true
    }
}

// MARK: - LLMTabBarDelegate

extension ConfigEditorWindow: LLMTabBarDelegate {
    func tabBar(_ tabBar: LLMTabBar, didSelectModel model: LLMModel) {
        switchToModel(model)
    }
}

// MARK: - ProfileBarDelegate

extension ConfigEditorWindow: ProfileBarDelegate {
    func profileBarDidSelectProfile(_ bar: ProfileBar, name: String) {
        switchToProfile(name)
    }

    func profileBarDidRequestNew(_ bar: ProfileBar) {
        guard let win = window else { return }
        let alert = NSAlert.branded()
        alert.messageText = "New Profile"
        alert.informativeText = "Enter a name for the new profile:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Profile name"
        field.font = Theme.monoFont
        alert.accessoryView = field

        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let self = self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }

            ProfileStore.shared.createProfile(for: self.currentModel, name: name)
            self.currentProfileName = name
            self.reloadProfileBar()
            self.loadCurrentProfile()
            self.updateSubtitle()
        }
    }

    func profileBarDidRequestRename(_ bar: ProfileBar) {
        guard let win = window else { return }
        let alert = NSAlert.branded()
        alert.messageText = "Rename Profile"
        alert.informativeText = "Enter a new name for \"\(currentProfileName)\":"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = currentProfileName
        field.font = Theme.monoFont
        alert.accessoryView = field

        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let self = self else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != self.currentProfileName else { return }

            ProfileStore.shared.renameProfile(for: self.currentModel, oldName: self.currentProfileName, newName: newName)
            self.currentProfileName = newName
            self.reloadProfileBar()
            self.updateSubtitle()
        }
    }

    func profileBarDidRequestDelete(_ bar: ProfileBar) {
        guard let win = window else { return }
        let profiles = ProfileStore.shared.profiles(for: currentModel)
        guard profiles.count > 1 else { return }

        let alert = NSAlert.branded()
        alert.messageText = "Delete \"\(currentProfileName)\"?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let self = self else { return }

            ProfileStore.shared.deleteProfile(for: self.currentModel, name: self.currentProfileName)
            self.currentProfileName = ProfileStore.shared.activeProfileName(for: self.currentModel)
            self.reloadProfileBar()
            self.loadCurrentProfile()
            self.updateSubtitle()
        }
    }

    func profileBarDidRequestActivate(_ bar: ProfileBar) {
        // Save current content first if dirty
        if isDirty {
            saveDocument(nil)
        }
        ProfileStore.shared.activateProfile(for: currentModel, name: currentProfileName)
        reloadProfileBar()
    }
}

// MARK: - NSOutlineViewDataSource

extension ConfigEditorWindow: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootNode?.children.count ?? 0
        }
        guard let node = item as? ConfigNode else { return 0 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootNode!.children[index]
        }
        return (item as! ConfigNode).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ConfigNode else { return false }
        return node.isContainer
    }
}

// MARK: - NSOutlineViewDelegate

extension ConfigEditorWindow: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        return ConfigRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ConfigNode, let column = tableColumn else { return nil }

        if column.identifier.rawValue == "key" {
            return makeKeyCell(for: node)
        } else {
            return makeValueCell(for: node)
        }
    }

    private func makeKeyCell(for node: ConfigNode) -> NSView {
        let field = NSTextField()
        field.stringValue = node.key
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.font = Theme.monoFont
        field.textColor = Theme.keyColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func makeValueCell(for node: ConfigNode) -> NSView {
        switch node.value {
        case .bool(let b):
            let btn = NodeButton(checkboxWithTitle: b ? "true" : "false", target: self, action: #selector(boolToggled(_:)))
            btn.state = b ? .on : .off
            btn.node = node
            btn.contentTintColor = Theme.boolColor
            btn.font = Theme.monoFont
            return btn

        case .string(let s):
            let field = NodeTextField()
            field.stringValue = s
            field.isEditable = true
            field.isBordered = false
            field.drawsBackground = false
            field.font = Theme.monoFont
            field.textColor = Theme.stringColor
            field.lineBreakMode = .byTruncatingTail
            field.node = node
            field.target = self
            field.action = #selector(stringEdited(_:))
            return field

        case .number(let n):
            let field = NodeTextField()
            field.stringValue = n.stringValue
            field.isEditable = true
            field.isBordered = false
            field.drawsBackground = false
            field.font = Theme.monoFont
            field.textColor = Theme.numberColor
            field.lineBreakMode = .byTruncatingTail
            field.node = node
            field.target = self
            field.action = #selector(numberEdited(_:))
            return field

        case .null:
            let field = NSTextField(labelWithString: "null")
            field.font = Theme.monoFont
            field.textColor = Theme.nullColor
            return field

        case .object:
            let field = NSTextField(labelWithString: "{ \(node.children.count) keys }")
            field.font = Theme.monoFont
            field.textColor = Theme.containerColor
            return field

        case .array:
            let field = NSTextField(labelWithString: "[ \(node.children.count) items ]")
            field.font = Theme.monoFont
            field.textColor = Theme.containerColor
            return field
        }
    }

    // MARK: - Editing Callbacks

    @objc private func boolToggled(_ sender: NSButton) {
        guard let btn = sender as? NodeButton, let node = btn.node else { return }
        let newVal = sender.state == .on
        node.value = .bool(newVal)
        btn.title = newVal ? "true" : "false"
        markDirty()
    }

    @objc private func stringEdited(_ sender: NSTextField) {
        guard let field = sender as? NodeTextField, let node = field.node else { return }
        node.value = .string(field.stringValue)
        markDirty()
    }

    @objc private func numberEdited(_ sender: NSTextField) {
        guard let field = sender as? NodeTextField, let node = field.node else { return }
        let text = field.stringValue
        if let intVal = Int(text) {
            node.value = .number(NSNumber(value: intVal))
        } else if let dblVal = Double(text) {
            node.value = .number(NSNumber(value: dblVal))
        }
        markDirty()
    }
}

// MARK: - NSTextViewDelegate (raw JSON / fallback text)

extension ConfigEditorWindow: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        markDirty()
    }
}
