import AppKit
import Metal
import QuartzCore
import CAwalTerminal

class TerminalView: NSView {

    // MARK: - Menu State

    private enum AppState {
        case menu
        case terminal
    }

    typealias MenuItem = LLMModel

    private enum MenuEntry {
        case sectionHeader(String)
        case separator
        case recentWorkspace(Workspace)
        case modelItem(MenuItem)
        case openFolder
    }

    private enum MenuPhase {
        case main
        case pickModel(String) // folder path selected via Open Folder
    }

    private var appState: AppState = .menu
    private var menuPhase: MenuPhase = .main
    private var menuSelection: Int = 0
    private var menuRendered: Bool = false
    private var menuEntries: [MenuEntry] = []

    private(set) var activeModelName: String = ""
    private(set) var activeProvider: String = ""

    // Callbacks for status bar updates
    var onSessionChanged: ((_ model: String, _ provider: String, _ cols: Int, _ rows: Int) -> Void)?
    var onShellSpawned: ((_ pid: pid_t) -> Void)?
    var onFocused: ((_ terminal: TerminalView) -> Void)?
    var onTerminalIdle: (() -> Void)?

    // Deferred launch for new panes (set before adding to window)
    var pendingLaunchModel: MenuItem?
    var pendingLaunchDir: String?

    var modelItems: [LLMModel] { ModelCatalog.all }

    // MARK: - Terminal Properties

    private var surface: OpaquePointer?
    private var readSource: DispatchSourceRead?
    private var displayLink: CVDisplayLink?

    private let cellWidth: CGFloat
    private let cellHeight: CGFloat
    private let font: NSFont
    private let boldFont: NSFont
    private let baselineOffset: CGFloat

    private var termCols: UInt32 = 80
    private var termRows: UInt32 = 24

    private var cellBuffer: [CCell] = []
    private var cursorRow: UInt32 = 0
    private var cursorCol: UInt32 = 0
    private var cursorVisible: Bool = true
    private var cursorBlinkOn: Bool = true
    private var cursorBlinkTimer: Timer?

    private var idleTimer: Timer?
    private var hadRecentOutput: Bool = false

    // MARK: - Metal Properties

    private var metalLayer: CAMetalLayer!
    private var renderer: MetalRenderer!
    private var needsRender: Bool = true
    private var currentScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0

    /// True when the user has manually scrolled up; suppresses auto-snap to bottom.
    private var userScrolledUp: Bool = false

    // MARK: - Search State

    private var searchBar: SearchBarView?
    private var searchResults: [(col: Int, row: Int32)] = []
    private var currentSearchIndex: Int = 0
    private var searchQueryLength: Int = 0

    // MARK: - AI Fold State

    /// Cached fold regions for rendering indicators.
    private var foldRegions: [FoldRegion] = []

    struct FoldRegion {
        let startRow: Int32
        let endRow: Int32
        let regionType: UInt8
        let collapsed: Bool
        let label: String
        let lineCount: UInt32
    }

    // MARK: - Init

    override init(frame: NSRect) {
        let config = AppConfig.shared
        self.font = config.resolvedFont
        self.boldFont = config.resolvedBoldFont

        // Cell size from CTFont: advance width + ascent/descent/leading
        let ctFont = self.font as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        var glyph: CGGlyph = 0
        var advance = CGSize.zero
        let mChar: UniChar = 0x4D // 'M'
        CTFontGetGlyphsForCharacters(ctFont, [mChar], &glyph, 1)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, [glyph], &advance, 1)
        self.cellWidth = ceil(advance.width)
        self.cellHeight = ceil(ascent + descent + leading)
        self.baselineOffset = descent

        super.init(frame: frame)

        wantsLayer = true

        surface = at_surface_new(termCols, termRows)
        cellBuffer = [CCell](repeating: CCell(), count: Int(termCols * termRows))

        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.cursorBlinkOn.toggle()
            self?.needsRender = true
        }

        setupDragAndDrop()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        cursorBlinkTimer?.invalidate()
        idleTimer?.invalidate()
        stopDisplayLink()
        if let source = readSource {
            source.cancel()
        }
        if let s = surface {
            at_surface_destroy(s)
        }
    }

    // MARK: - Layer Setup (Metal)

    override func makeBackingLayer() -> CALayer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.backgroundColor = AppConfig.shared.themeBg.cgColor

        self.metalLayer = layer
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.currentScale = scale
        self.renderer = MetalRenderer(
            device: device,
            font: font,
            boldFont: boldFont,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            scale: scale
        )

        return layer
    }

    // MARK: - Factory

    static func createTerminalPane(model: MenuItem, workingDir: String?) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.pendingLaunchModel = model
        view.pendingLaunchDir = workingDir
        view.appState = .terminal
        return view
    }

    // MARK: - Focus

    func setFocused(_ focused: Bool) {
        guard let layer = layer else { return }
        if focused {
            layer.borderWidth = 1.0
            layer.borderColor = NSColor(red: 79.0/255.0, green: 70.0/255.0, blue: 229.0/255.0, alpha: 1.0).cgColor
        } else {
            layer.borderWidth = 0.0
            layer.borderColor = nil
        }
    }

    var surfacePointer: OpaquePointer? { surface }

    var currentModel: LLMModel? {
        ModelCatalog.find(activeModelName)
    }

    // MARK: - View Lifecycle

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScale()
        recalculateGridSize()
        if appState == .menu && !menuRendered {
            buildMenuEntries()
            moveToFirstSelectable()
            renderMenu()
        }
        // Deferred launch happens in setFrameSize once we have real dimensions
        if window != nil {
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMetalLayerSize()
        recalculateGridSize()
        if appState == .menu {
            renderMenu()
        }
        // Deferred launch: wait until we have real dimensions so the PTY gets the correct size.
        // Post to next run loop iteration to ensure layout is fully complete.
        if appState == .terminal, pendingLaunchModel != nil, newSize.width > 0 && newSize.height > 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let model = self.pendingLaunchModel else { return }
                self.pendingLaunchModel = nil
                let dir = self.pendingLaunchDir
                self.pendingLaunchDir = nil
                self.recalculateGridSize()
                self.launchSession(model: model, workingDir: dir)
            }
        }
    }

    private func updateBackingScale() {
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer?.contentsScale = scale

        if scale != currentScale {
            currentScale = scale
            if let device = metalLayer?.device {
                renderer = MetalRenderer(
                    device: device,
                    font: font,
                    boldFont: boldFont,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight,
                    scale: scale
                )
            }
        }

        updateMetalLayerSize()
    }

    private func updateMetalLayerSize() {
        guard let layer = metalLayer else { return }
        let size = bounds.size
        guard size.width > 0 && size.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? layer.contentsScale
        layer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        needsRender = true
    }

    // MARK: - Menu Entry Building

    private func buildMenuEntries() {
        menuEntries = []

        switch menuPhase {
        case .main:
            let recents = WorkspaceStore.shared.recents()
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
            menuEntries.append(.openFolder)

        case .pickModel:
            for item in modelItems {
                menuEntries.append(.modelItem(item))
            }
        }
    }

    private func isSelectable(_ entry: MenuEntry) -> Bool {
        switch entry {
        case .sectionHeader, .separator:
            return false
        default:
            return true
        }
    }

    private func moveSelection(by delta: Int) {
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

    private func moveToFirstSelectable() {
        for (i, entry) in menuEntries.enumerated() {
            if isSelectable(entry) {
                menuSelection = i
                return
            }
        }
    }

    // MARK: - TUI Menu

    private func renderMenu() {
        guard let s = surface else { return }

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

            case .recentWorkspace(let ws):
                let isSelected = i == menuSelection
                let arrow = isSelected ? "▸" : " "
                let pathStr = shortenPath(ws.path)
                let modelStr = ws.lastModel
                let maxPathLen = itemWidth - 6 - modelStr.count
                let truncPath = pathStr.count > maxPathLen
                    ? String(pathStr.prefix(maxPathLen - 1)) + "…"
                    : pathStr
                let nameField = truncPath.padding(toLength: max(maxPathLen, 1), withPad: " ", startingAt: 0)

                if isSelected {
                    out += itemPadStr
                    out += "\u{1b}[48;2;79;70;229m"
                    out += "\u{1b}[1;37m"
                    out += " \(arrow) \(nameField)"
                    out += "\u{1b}[0;37m"
                    out += "\u{1b}[48;2;79;70;229m"
                    out += " \(modelStr) "
                    out += "\u{1b}[0m"
                } else {
                    out += itemPadStr
                    out += "\u{1b}[37m"
                    out += " \(arrow) \(nameField)"
                    out += "\u{1b}[90m"
                    out += " \(modelStr) "
                    out += "\u{1b}[0m"
                }

            case .modelItem(let item):
                let isSelected = i == menuSelection
                let arrow = isSelected ? "▸" : " "
                let nameField = item.name.padding(toLength: 14, withPad: " ", startingAt: 0)
                let providerField = item.provider

                if isSelected {
                    out += itemPadStr
                    out += "\u{1b}[48;2;79;70;229m"
                    out += "\u{1b}[1;37m"
                    out += " \(arrow) \(nameField)"
                    out += "\u{1b}[0;37m"
                    out += "\u{1b}[48;2;79;70;229m"
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
                    out += "\u{1b}[48;2;79;70;229m"
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
            }
        }

        // Footer hint
        let hint: String
        switch menuPhase {
        case .main:
            hint = "↑↓/jk Navigate  ⏎ Select  o Open Folder  Esc Shell"
        case .pickModel:
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

    private func handleSelection() {
        guard menuSelection < menuEntries.count else { return }

        let entry = menuEntries[menuSelection]
        switch entry {
        case .recentWorkspace(let ws):
            let model = modelItems.first { $0.name == ws.lastModel } ?? modelItems[0]
            launchSession(model: model, workingDir: ws.path)

        case .modelItem(let item):
            switch menuPhase {
            case .main:
                launchSession(model: item, workingDir: nil)
            case .pickModel(let folder):
                launchSession(model: item, workingDir: folder)
            }

        case .openFolder:
            showFolderPicker()

        default:
            break
        }
    }

    private func launchSession(model: MenuItem, workingDir: String?) {
        guard let s = surface else { return }

        activeModelName = model.name
        activeProvider = model.provider
        appState = .terminal

        // Clear screen, show cursor, reset
        let reset = "\u{1b}[2J\u{1b}[H\u{1b}[?25h\u{1b}[0m"
        let resetBytes = Array(reset.utf8)
        resetBytes.withUnsafeBufferPointer { ptr in
            at_surface_feed_bytes(s, ptr.baseAddress!, UInt32(ptr.count))
        }

        recalculateGridSize()

        // Save workspace
        if let dir = workingDir {
            WorkspaceStore.shared.save(path: dir, model: model.name)
        }

        // Build the full command to execute
        var modelCmd = model.command
        if !modelCmd.isEmpty, let bin = model.binaryName, let install = model.installCommand {
            modelCmd = "command -v \(bin) >/dev/null 2>&1 || { echo \"Installing \(model.name)...\"; \(install); } && \(model.command)"
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
                NSLog("Failed to spawn command, falling back to shell")
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
            self?.menuPhase = .pickModel(url.path)
            self?.buildMenuEntries()
            self?.moveToFirstSelectable()
            self?.renderMenu()
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

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Shell & PTY

    func spawnShell() {
        guard let s = surface else { return }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = shell.withCString { cstr in
            at_surface_spawn_shell(s, cstr)
        }

        if result != 0 {
            NSLog("Failed to spawn shell")
            return
        }

        setupPtyReader()
    }

    private func setupPtyReader() {
        guard let s = surface else { return }

        let fd = at_surface_get_fd(s)
        if fd < 0 {
            NSLog("Invalid PTY fd")
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readPTY()
        }
        source.setCancelHandler { }
        source.resume()
        self.readSource = source

        let childPid = at_surface_get_child_pid(s)
        if childPid > 0 {
            onShellSpawned?(pid_t(childPid))
        }
    }

    private func readPTY() {
        guard let s = surface else { return }

        var totalRead: Int32 = 0
        var iterations = 0
        while iterations < 64 {
            let n = at_surface_process_pty(s)
            if n <= 0 { break }
            totalRead += n
            iterations += 1
        }

        if totalRead > 0 {
            // Auto-snap to bottom only if the user hasn't manually scrolled up
            if !userScrolledUp {
                let offset = at_surface_get_viewport_offset(s)
                if offset > 0 {
                    at_surface_scroll_viewport(s, -offset)
                }
            }
            updateCellBuffer()
            needsRender = true
            hadRecentOutput = true
            resetIdleTimer()
        }
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.handleIdleTimeout()
        }
    }

    private func handleIdleTimeout() {
        guard hadRecentOutput, !activeModelName.isEmpty else { return }
        hadRecentOutput = false
        onTerminalIdle?()
    }

    // MARK: - Grid Size

    private func recalculateGridSize() {
        guard let s = surface else { return }

        let newCols = max(1, UInt32(bounds.width / cellWidth))
        let newRows = max(1, UInt32(bounds.height / cellHeight))

        if newCols != termCols || newRows != termRows {
            termCols = newCols
            termRows = newRows
            at_surface_resize(s, termCols, termRows)
            cellBuffer = [CCell](repeating: CCell(), count: Int(termCols * termRows))
            updateCellBuffer()
            needsRender = true
            if appState == .terminal {
                onSessionChanged?(activeModelName, activeProvider, Int(termCols), Int(termRows))
            }
        }
    }

    private func updateCellBuffer() {
        guard let s = surface else { return }

        let needed = Int(termCols * termRows)
        if cellBuffer.count < needed {
            cellBuffer = [CCell](repeating: CCell(), count: needed)
        }

        cellBuffer.withUnsafeMutableBufferPointer { ptr in
            _ = at_surface_read_cells(s, ptr.baseAddress!, UInt32(needed))
        }

        // Update fold regions from AI analyzer
        updateFoldRegions()

        var row: UInt32 = 0
        var col: UInt32 = 0
        var visible: Bool = true
        at_surface_get_cursor(s, &row, &col, &visible)
        cursorRow = row
        cursorCol = col
        cursorVisible = visible
    }

    private func updateFoldRegions() {
        guard let s = surface else {
            foldRegions = []
            return
        }

        let regionCount = at_surface_get_region_count(s)
        guard regionCount > 0 else {
            foldRegions = []
            return
        }

        let maxRegions = min(regionCount, 500)
        var cRegions = [COutputRegion](repeating: COutputRegion(
            start_row: 0, end_row: 0, region_type: 0, collapsed: 0, line_count: 0, label: nil
        ), count: Int(maxRegions))

        let count = cRegions.withUnsafeMutableBufferPointer { ptr in
            at_surface_get_regions(s, ptr.baseAddress!, maxRegions)
        }

        foldRegions = (0..<Int(count)).map { i in
            let r = cRegions[i]
            let label: String
            if let lbl = r.label {
                label = String(cString: lbl)
                at_free_string(lbl)
            } else {
                label = ""
            }
            return FoldRegion(
                startRow: r.start_row,
                endRow: r.end_row,
                regionType: r.region_type,
                collapsed: r.collapsed != 0,
                label: label,
                lineCount: r.line_count
            )
        }
    }

    /// Fold indicator spanning visible rows of a region.
    struct FoldIndicator {
        let startViewportRow: Int
        let endViewportRow: Int
        let collapsed: Bool
        let regionType: UInt8
        let label: String
    }

    /// Compute fold indicator ranges visible in the current viewport.
    private func computeFoldIndicators() -> [FoldIndicator] {
        guard let s = surface, !foldRegions.isEmpty else { return [] }

        let viewportOffset = Int(at_surface_get_viewport_offset(s))
        let scrollbackLen = Int(at_surface_get_scrollback_len(s))
        let rows = Int(termRows)

        var indicators: [FoldIndicator] = []

        for region in foldRegions {
            guard region.lineCount > 2 else { continue }

            // Only foldable region types
            switch region.regionType {
            case 1, 2, 3, 4, 7: break // ToolUse, ToolOutput, CodeBlock, Thinking, Diff
            default: continue
            }

            let regStart = Int(region.startRow)
            let regEnd = Int(region.endRow)

            // Convert absolute rows to viewport rows
            let vpStart: Int
            let vpEnd: Int
            if viewportOffset == 0 {
                vpStart = regStart
                vpEnd = regEnd
            } else {
                let viewportStart = scrollbackLen - viewportOffset
                vpStart = scrollbackLen + regStart - viewportStart
                vpEnd = scrollbackLen + regEnd - viewportStart
            }

            // Clip to visible range
            let clippedStart = max(0, vpStart)
            let clippedEnd = min(rows - 1, vpEnd)
            guard clippedStart <= clippedEnd else { continue }

            indicators.append(FoldIndicator(
                startViewportRow: clippedStart,
                endViewportRow: clippedEnd,
                collapsed: region.collapsed,
                regionType: region.regionType,
                label: region.label
            ))
        }

        return indicators
    }

    // MARK: - Metal Rendering (Display Link)

    private func renderFrame() {
        guard needsRender else { return }
        guard let layer = metalLayer else { return }
        let drawableSize = layer.drawableSize
        guard drawableSize.width > 0 && drawableSize.height > 0 else { return }
        guard let drawable = layer.nextDrawable() else { return }

        needsRender = false

        let viewportSize = layer.drawableSize

        // Compute visible search highlights
        let highlights = computeVisibleSearchHighlights()

        // Compute fold indicators
        let foldIndicators = computeFoldIndicators()

        cellBuffer.withUnsafeBufferPointer { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            renderer.render(
                cells: baseAddress,
                cellCount: cellBuffer.count,
                gridCols: Int(termCols),
                gridRows: Int(termRows),
                cursorRow: Int(cursorRow),
                cursorCol: Int(cursorCol),
                cursorVisible: cursorVisible,
                cursorBlinkOn: cursorBlinkOn,
                drawable: drawable,
                viewportSize: CGSize(width: viewportSize.width, height: viewportSize.height),
                scale: layer.contentsScale,
                searchHighlights: highlights.cells,
                currentHighlight: highlights.currentIndex,
                foldIndicators: foldIndicators
            )
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let dl = link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let view = Unmanaged<TerminalView>.fromOpaque(userInfo!).takeUnretainedValue()
            DispatchQueue.main.async {
                view.renderFrame()
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(dl, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(dl)
        self.displayLink = dl

        // Render the first frame immediately
        needsRender = true
        renderFrame()
    }

    private func stopDisplayLink() {
        if let dl = displayLink {
            CVDisplayLinkStop(dl)
            displayLink = nil
        }
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        switch appState {
        case .menu:
            handleMenuKey(event)
        case .terminal:
            handleTerminalKey(event)
        }
    }

    private func handleMenuKey(_ event: NSEvent) {
        switch event.keyCode {
        case 126: // Up arrow
            moveSelection(by: -1)
            renderMenu()
        case 125: // Down arrow
            moveSelection(by: 1)
            renderMenu()
        case 36: // Return
            handleSelection()
        case 53: // Escape
            switch menuPhase {
            case .main:
                // Launch Shell directly
                let shellItem = modelItems.last!
                launchSession(model: shellItem, workingDir: nil)
            case .pickModel:
                // Go back to main menu
                menuPhase = .main
                buildMenuEntries()
                moveToFirstSelectable()
                renderMenu()
            }
        default:
            if let chars = event.characters {
                switch chars {
                case "j":
                    moveSelection(by: 1)
                    renderMenu()
                case "k":
                    moveSelection(by: -1)
                    renderMenu()
                case "o":
                    if case .main = menuPhase {
                        showFolderPicker()
                    }
                default:
                    break
                }
            }
        }
    }

    private func handleTerminalKey(_ event: NSEvent) {
        guard let s = surface else { return }

        let bytes: [UInt8]

        if let chars = event.characters, !chars.isEmpty {
            let modFlags = event.modifierFlags
            let hasShift = modFlags.contains(.shift)
            let hasCtrl = modFlags.contains(.control)
            let hasAlt = modFlags.contains(.option)

            // xterm modifier parameter: 1=none, 2=Shift, 3=Alt, 5=Ctrl, etc.
            var modParam = 1
            if hasShift { modParam += 1 }
            if hasAlt { modParam += 2 }
            if hasCtrl { modParam += 4 }
            let hasMod = modParam > 1

            switch event.keyCode {
            case 36: bytes = [0x0D] // Return
            case 48: // Tab
                bytes = hasShift ? [0x1B, 0x5B, 0x5A] : [0x09]
            case 51: bytes = [0x7F] // Backspace
            case 53: bytes = [0x1B] // Escape
            case 123: // Left
                bytes = hasMod ? Array("\u{1b}[1;\(modParam)D".utf8) : [0x1B, 0x5B, 0x44]
            case 124: // Right
                bytes = hasMod ? Array("\u{1b}[1;\(modParam)C".utf8) : [0x1B, 0x5B, 0x43]
            case 125: // Down
                bytes = hasMod ? Array("\u{1b}[1;\(modParam)B".utf8) : [0x1B, 0x5B, 0x42]
            case 126: // Up
                bytes = hasMod ? Array("\u{1b}[1;\(modParam)A".utf8) : [0x1B, 0x5B, 0x41]
            case 115: // Home
                bytes = hasMod ? Array("\u{1b}[1;\(modParam)H".utf8) : [0x1B, 0x5B, 0x48]
            case 119: // End
                bytes = hasMod ? Array("\u{1b}[1;\(modParam)F".utf8) : [0x1B, 0x5B, 0x46]
            case 116: // PageUp
                bytes = hasMod ? Array("\u{1b}[5;\(modParam)~".utf8) : [0x1B, 0x5B, 0x35, 0x7E]
            case 121: // PageDown
                bytes = hasMod ? Array("\u{1b}[6;\(modParam)~".utf8) : [0x1B, 0x5B, 0x36, 0x7E]
            case 117: // Forward Delete
                bytes = hasMod ? Array("\u{1b}[3;\(modParam)~".utf8) : [0x1B, 0x5B, 0x33, 0x7E]
            // Function keys F1-F12
            case 122: bytes = hasMod ? Array("\u{1b}[1;\(modParam)P".utf8) : [0x1B, 0x4F, 0x50]
            case 120: bytes = hasMod ? Array("\u{1b}[1;\(modParam)Q".utf8) : [0x1B, 0x4F, 0x51]
            case 99:  bytes = hasMod ? Array("\u{1b}[1;\(modParam)R".utf8) : [0x1B, 0x4F, 0x52]
            case 118: bytes = hasMod ? Array("\u{1b}[1;\(modParam)S".utf8) : [0x1B, 0x4F, 0x53]
            case 96:  bytes = Array("\u{1b}[15\(hasMod ? ";\(modParam)" : "")~".utf8)  // F5
            case 97:  bytes = Array("\u{1b}[17\(hasMod ? ";\(modParam)" : "")~".utf8)  // F6
            case 98:  bytes = Array("\u{1b}[18\(hasMod ? ";\(modParam)" : "")~".utf8)  // F7
            case 100: bytes = Array("\u{1b}[19\(hasMod ? ";\(modParam)" : "")~".utf8)  // F8
            case 101: bytes = Array("\u{1b}[20\(hasMod ? ";\(modParam)" : "")~".utf8)  // F9
            case 109: bytes = Array("\u{1b}[21\(hasMod ? ";\(modParam)" : "")~".utf8)  // F10
            case 103: bytes = Array("\u{1b}[23\(hasMod ? ";\(modParam)" : "")~".utf8)  // F11
            case 111: bytes = Array("\u{1b}[24\(hasMod ? ";\(modParam)" : "")~".utf8)  // F12
            default:
                if hasCtrl {
                    if let firstChar = chars.unicodeScalars.first {
                        let value = firstChar.value
                        if value >= 0x61 && value <= 0x7A {
                            bytes = [UInt8(value - 0x60)]
                        } else if value >= 0x41 && value <= 0x5A {
                            bytes = [UInt8(value - 0x40)]
                        } else {
                            bytes = Array(chars.utf8)
                        }
                    } else {
                        return
                    }
                } else if hasAlt {
                    let charBytes = Array(chars.utf8)
                    bytes = [0x1B] + charBytes
                } else {
                    bytes = Array(chars.utf8)
                }
            }
        } else {
            return
        }

        bytes.withUnsafeBufferPointer { ptr in
            _ = at_surface_key_event(s, ptr.baseAddress!, UInt32(ptr.count))
        }
    }

    override func flagsChanged(with event: NSEvent) {}

    // MARK: - Scroll Wheel (Scrollback)

    override func scrollWheel(with event: NSEvent) {
        guard let s = surface, appState == .terminal else { return }

        let mouseMode = at_surface_get_mouse_mode(s)
        if mouseMode > 0 {
            // Mouse reporting enabled — send scroll as mouse button 4/5 (up/down)
            let location = convert(event.locationInWindow, from: nil)
            let col = Int(location.x / cellWidth) + 1
            let row = Int(location.y / cellHeight) + 1  // Will be flipped below
            let flippedRow = Int(termRows) - row + 1

            let sgrMode = at_surface_get_sgr_mouse(s)
            let lines = max(1, Int(abs(event.scrollingDeltaY) / 3.0 + 0.5))
            for _ in 0..<lines {
                let button = event.scrollingDeltaY > 0 ? 64 : 65 // scroll up : scroll down
                let seq: [UInt8]
                if sgrMode {
                    let str = "\u{1b}[\(button);\(col);\(flippedRow)M"
                    seq = Array(str.utf8)
                } else {
                    // X10 encoding
                    seq = [0x1b, 0x5b, 0x4d,
                           UInt8(32 + button),
                           UInt8(32 + col),
                           UInt8(32 + flippedRow)]
                }
                seq.withUnsafeBufferPointer { ptr in
                    _ = at_surface_key_event(s, ptr.baseAddress!, UInt32(ptr.count))
                }
            }
            return
        }

        // Normal scrollback
        let delta = event.scrollingDeltaY
        let lines = Int(delta / 3.0)
        if lines != 0 {
            at_surface_scroll_viewport(s, Int32(lines))
            let offset = at_surface_get_viewport_offset(s)
            userScrolledUp = offset > 0
            updateCellBuffer()
            needsRender = true
        }
    }

    // MARK: - Mouse Events (Selection + Mouse Reporting)

    private func gridPosition(for event: NSEvent) -> (col: Int, row: Int) {
        let location = convert(event.locationInWindow, from: nil)
        // NSView coordinates: origin at bottom-left, we need top-left
        let col = max(0, min(Int(termCols) - 1, Int(location.x / cellWidth)))
        let row = max(0, min(Int(termRows) - 1, Int(termRows) - 1 - Int(location.y / cellHeight)))
        return (col, row)
    }

    /// Convert grid row to absolute row (accounting for scrollback viewport).
    private func absoluteRow(gridRow: Int) -> Int32 {
        guard let s = surface else { return Int32(gridRow) }
        let offset = at_surface_get_viewport_offset(s)
        let sbLen = at_surface_get_scrollback_len(s)
        if offset == 0 {
            return Int32(gridRow)
        }
        let viewportStart = Int(sbLen) - Int(offset)
        let absRow = viewportStart + gridRow
        return Int32(absRow - Int(sbLen))
    }

    private func sendMouseEvent(button: Int, col: Int, row: Int, release: Bool) {
        guard let s = surface else { return }
        let sgrMode = at_surface_get_sgr_mouse(s)
        let c = col + 1  // 1-indexed
        let r = row + 1

        if sgrMode {
            let suffix = release ? "m" : "M"
            let str = "\u{1b}[<\(button);\(c);\(r)\(suffix)"
            let bytes = Array(str.utf8)
            bytes.withUnsafeBufferPointer { ptr in
                _ = at_surface_key_event(s, ptr.baseAddress!, UInt32(ptr.count))
            }
        } else {
            if release { return } // X10 doesn't report releases
            let bytes: [UInt8] = [0x1b, 0x5b, 0x4d,
                                   UInt8(32 + button),
                                   UInt8(32 + min(col + 1, 223)),
                                   UInt8(32 + min(row + 1, 223))]
            bytes.withUnsafeBufferPointer { ptr in
                _ = at_surface_key_event(s, ptr.baseAddress!, UInt32(ptr.count))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocused?(self)

        guard appState == .terminal, let s = surface else {
            super.mouseDown(with: event)
            return
        }

        let (col, row) = gridPosition(for: event)

        // Click on fold indicator (left edge, col 0) to toggle fold
        if col == 0 && !foldRegions.isEmpty {
            let absRow = absoluteRow(gridRow: row)
            if at_surface_toggle_fold(s, absRow) {
                updateCellBuffer()
                needsRender = true
                return
            }
        }

        // Cmd+click: open hyperlink
        if event.modifierFlags.contains(.command) {
            let urlPtr = at_surface_get_hyperlink(s, UInt32(col), UInt32(row))
            if let urlPtr, let urlStr = String(cString: urlPtr, encoding: .utf8) {
                at_free_string(urlPtr)
                if let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                    return
                }
            }
        }

        let mouseMode = at_surface_get_mouse_mode(s)

        if mouseMode > 0 {
            sendMouseEvent(button: 0, col: col, row: row, release: false)
            return
        }

        // Start selection
        let absRow = absoluteRow(gridRow: row)

        if event.clickCount == 2 {
            // Double-click: select word
            selectWord(at: col, row: absRow)
        } else if event.clickCount == 3 {
            // Triple-click: select line
            at_surface_start_selection(s, UInt32(0), absRow)
            at_surface_update_selection(s, UInt32(termCols - 1), absRow)
        } else {
            at_surface_start_selection(s, UInt32(col), absRow)
        }
        updateCellBuffer()
        needsRender = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard appState == .terminal, let s = surface else { return }

        let (col, row) = gridPosition(for: event)
        let mouseMode = at_surface_get_mouse_mode(s)

        if mouseMode >= 2 {
            // Button/drag mouse reporting
            sendMouseEvent(button: 32, col: col, row: row, release: false)
            return
        }

        if mouseMode == 0 {
            let absRow = absoluteRow(gridRow: row)
            at_surface_update_selection(s, UInt32(col), absRow)
            updateCellBuffer()
            needsRender = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard appState == .terminal, let s = surface else { return }

        let (col, row) = gridPosition(for: event)
        let mouseMode = at_surface_get_mouse_mode(s)

        if mouseMode > 0 {
            sendMouseEvent(button: 0, col: col, row: row, release: true)
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard appState == .terminal, let s = surface else {
            super.rightMouseDown(with: event)
            return
        }
        let mouseMode = at_surface_get_mouse_mode(s)
        if mouseMode > 0 {
            let (col, row) = gridPosition(for: event)
            sendMouseEvent(button: 2, col: col, row: row, release: false)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard appState == .terminal, let s = surface else {
            super.rightMouseUp(with: event)
            return
        }
        let mouseMode = at_surface_get_mouse_mode(s)
        if mouseMode > 0 {
            let (col, row) = gridPosition(for: event)
            sendMouseEvent(button: 2, col: col, row: row, release: true)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard appState == .terminal, let s = surface else { return }
        let mouseMode = at_surface_get_mouse_mode(s)
        if mouseMode == 3 {
            let (col, row) = gridPosition(for: event)
            sendMouseEvent(button: 35, col: col, row: row, release: false)
        }
    }

    private func selectWord(at col: Int, row: Int32) {
        guard let s = surface else { return }
        // Simple word selection: expand from position until whitespace
        let cols = Int(termCols)
        var startCol = col
        var endCol = col

        // Read cell buffer to find word boundaries
        let idx = Int(row) * cols // Approximate — works when not scrolled
        while startCol > 0 {
            let cellIdx = idx + startCol - 1
            if cellIdx >= 0 && cellIdx < cellBuffer.count {
                let cp = cellBuffer[cellIdx].codepoint
                if cp <= 32 { break }
            } else { break }
            startCol -= 1
        }
        while endCol < cols - 1 {
            let cellIdx = idx + endCol + 1
            if cellIdx >= 0 && cellIdx < cellBuffer.count {
                let cp = cellBuffer[cellIdx].codepoint
                if cp <= 32 { break }
            } else { break }
            endCol += 1
        }

        at_surface_start_selection(s, UInt32(startCol), row)
        at_surface_update_selection(s, UInt32(endCol), row)
    }

    // MARK: - Copy/Paste (Cmd+C, Cmd+V)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard appState == .terminal else { return super.performKeyEquivalent(with: event) }
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }

        switch event.charactersIgnoringModifiers {
        case "c":
            return copySelection()
        case "v":
            pasteFromClipboard()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func copySelection() -> Bool {
        guard let s = surface else { return false }
        guard let cStr = at_surface_get_selected_text(s) else { return false }
        let text = String(cString: cStr)
        at_free_string(cStr)

        if text.isEmpty { return false }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Clear selection after copy
        at_surface_clear_selection(s)
        updateCellBuffer()
        needsRender = true
        return true
    }

    private func pasteFromClipboard() {
        guard let s = surface else { return }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }

        let bracketedPaste = at_surface_get_bracketed_paste(s)
        var pasteData = text
        if bracketedPaste {
            pasteData = "\u{1b}[200~" + text + "\u{1b}[201~"
        }

        let bytes = Array(pasteData.utf8)
        bytes.withUnsafeBufferPointer { ptr in
            _ = at_surface_key_event(s, ptr.baseAddress!, UInt32(ptr.count))
        }
    }

    // MARK: - Drag and Drop

    func setupDragAndDrop() {
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard appState == .terminal else { return [] }
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard appState == .terminal, let s = surface else { return false }
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return false
        }

        let paths = urls.map { url -> String in
            shellEscape(url.path)
        }
        let joined = paths.joined(separator: " ")
        let bytes = Array(joined.utf8)
        bytes.withUnsafeBufferPointer { ptr in
            _ = at_surface_key_event(s, ptr.baseAddress!, UInt32(ptr.count))
        }
        return true
    }

    private func shellEscape(_ path: String) -> String {
        // Wrap in single quotes, escaping any internal single quotes
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Search

    func toggleSearch() {
        if searchBar != nil {
            closeSearch()
        } else {
            openSearch()
        }
    }

    private func openSearch() {
        guard searchBar == nil else { return }

        let bar = SearchBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        bar.onClose = { [weak self] in
            self?.closeSearch()
        }
        bar.onSearchChanged = { [weak self] query in
            self?.performSearch(query)
        }
        bar.onNextMatch = { [weak self] in
            self?.navigateSearch(forward: true)
        }
        bar.onPrevMatch = { [weak self] in
            self?.navigateSearch(forward: false)
        }

        searchBar = bar
        bar.activate()
    }

    private func closeSearch() {
        searchBar?.removeFromSuperview()
        searchBar = nil
        searchResults = []
        currentSearchIndex = 0
        window?.makeFirstResponder(self)
        needsRender = true
    }

    private func performSearch(_ query: String) {
        guard let s = surface else { return }
        searchResults = []
        currentSearchIndex = 0
        searchQueryLength = query.count

        if query.isEmpty {
            searchBar?.updateMatchCount(current: 0, total: 0)
            needsRender = true
            return
        }

        var results = [ATSearchResult](repeating: ATSearchResult(col: 0, row: 0), count: 1000)
        let count = query.withCString { cQuery in
            results.withUnsafeMutableBufferPointer { buf in
                at_surface_search(s, cQuery, buf.baseAddress!, UInt32(buf.count))
            }
        }

        searchResults = (0..<Int(count)).map { i in
            (col: Int(results[i].col), row: results[i].row)
        }

        if !searchResults.isEmpty {
            // Find the closest result to current viewport
            let viewportOffset = at_surface_get_viewport_offset(s)
            let scrollbackLen = at_surface_get_scrollback_len(s)
            let viewportTopRow = Int32(-scrollbackLen + (scrollbackLen - viewportOffset))
            var closest = 0
            var closestDist = Int32.max
            for (i, result) in searchResults.enumerated() {
                let dist = abs(result.row - viewportTopRow)
                if dist < closestDist {
                    closestDist = dist
                    closest = i
                }
            }
            currentSearchIndex = closest
        }

        searchBar?.updateMatchCount(current: searchResults.isEmpty ? 0 : currentSearchIndex + 1,
                                     total: searchResults.count)
        scrollToCurrentMatch()
    }

    private func navigateSearch(forward: Bool) {
        guard !searchResults.isEmpty else { return }
        if forward {
            currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
        } else {
            currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
        }
        searchBar?.updateMatchCount(current: currentSearchIndex + 1, total: searchResults.count)
        scrollToCurrentMatch()
    }

    private func scrollToCurrentMatch() {
        guard let s = surface, !searchResults.isEmpty else { return }

        let match = searchResults[currentSearchIndex]
        let scrollbackLen = Int(at_surface_get_scrollback_len(s))
        let rows = Int(termRows)

        // Convert absolute row to viewport offset needed to show it
        // match.row: negative = scrollback, 0+ = screen row
        // We want the match to be roughly centered in the viewport
        if match.row < 0 {
            // Scrollback match: row is -(scrollbackLen) to -1
            // Offset needed = distance from bottom of scrollback
            let sbIndex = scrollbackLen + Int(match.row) // 0-based index into scrollback
            let targetOffset = scrollbackLen - sbIndex - rows / 2
            let clampedOffset = max(0, min(targetOffset, scrollbackLen))
            // Reset to bottom, then scroll up
            at_surface_scroll_viewport(s, Int32(-scrollbackLen))
            at_surface_scroll_viewport(s, Int32(clampedOffset))
        } else {
            // On-screen match — go to live view
            at_surface_scroll_viewport(s, Int32(-scrollbackLen))
        }

        updateCellBuffer()
        needsRender = true
    }

    private func computeVisibleSearchHighlights() -> (cells: [(col: Int, row: Int, len: Int)], currentIndex: Int) {
        guard let s = surface, !searchResults.isEmpty else { return ([], -1) }

        let viewportOffset = Int(at_surface_get_viewport_offset(s))
        let rows = Int(termRows)
        let cols = Int(termCols)

        // The viewport shows rows from (scrollbackLen - viewportOffset - rows) to (scrollbackLen - viewportOffset - 1)
        // in absolute terms. But our search results use: negative = scrollback, 0+ = screen.
        // Convert viewport to absolute row range:
        // Viewport top absolute row = -(viewportOffset + rows) .. -(viewportOffset) for scrollback,
        //   or 0..(rows-1) for screen rows when viewportOffset==0

        // Absolute row of viewport top: if offset=0 → screen row 0, if offset>0 → negative
        let viewportTopAbs: Int = -viewportOffset
        let viewportBottomAbs: Int = viewportTopAbs + rows - 1

        var highlights: [(col: Int, row: Int, len: Int)] = []
        var currentIdx = -1

        for (i, result) in searchResults.enumerated() {
            let absRow = Int(result.row)
            if absRow >= viewportTopAbs && absRow <= viewportBottomAbs {
                let screenRow = absRow - viewportTopAbs
                let clampedLen = min(searchQueryLength, cols - result.col)
                if clampedLen > 0 {
                    if i == currentSearchIndex {
                        currentIdx = highlights.count
                    }
                    highlights.append((col: result.col, row: screenRow, len: clampedLen))
                }
            }
        }

        return (highlights, currentIdx)
    }
}
