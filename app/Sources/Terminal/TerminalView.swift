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
        case recentFolder(String)
        case openFolder
        case resumeSessionsLink
        case resumeSession(SessionManager.ResumeEntry)
        case loadingIndicator(String)
    }

    private enum MenuPhase {
        case main
        case pickModel(String) // folder path selected via Open Folder
        case pickFolder(LLMModel) // model selected, now pick a folder
        case resumeSessions // browsing past sessions submenu
    }

    private var appState: AppState = .menu
    private var menuPhase: MenuPhase = .main
    private var menuSelection: Int = 0
    private var menuRendered: Bool = false
    private var menuEntries: [MenuEntry] = []
    private var pendingDeleteIndex: Int? = nil
    private var menuRenderPending = true
    private var deferredMenuRender: DispatchWorkItem?

    private(set) var activeModelName: String = ""
    private(set) var lastAIComponentContext: AIComponentContext?
    private var postSessionHooks: [URL] = []
    private var beforeCommitHooks: [URL] = []
    private var lastWorkingDir: String?
    private(set) var activeProvider: String = ""
    private(set) var isGenerating: Bool = false

    /// Maps the last region type to a human-readable phase label.
    var generationPhase: String {
        guard let last = foldRegions.last else { return "Generating..." }
        switch last.regionType {
        case 1: return "Running tool..."
        case 2: return "Reading output..."
        case 3: return "Writing code..."
        case 4: return "Thinking..."
        case 7: return "Generating diff..."
        default: return "Generating..."
        }
    }

    // Callbacks for status bar updates
    var onSessionChanged: ((_ model: String, _ provider: String, _ cols: Int, _ rows: Int) -> Void)?
    var onShellSpawned: ((_ pid: pid_t) -> Void)?
    var onFocused: ((_ terminal: TerminalView) -> Void)?
    var onTerminalIdle: (() -> Void)?
    var onCopied: (() -> Void)?
    var onGeneratingChanged: ((_ isGenerating: Bool) -> Void)?

    // Deferred launch for new panes (set before adding to window)
    var pendingLaunchModel: MenuItem?
    var pendingLaunchDir: String?

    var modelItems: [LLMModel] { ModelCatalog.all }

    // MARK: - Terminal Properties

    private var surface: OpaquePointer?
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
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
    private var ptyResizeTimer: Timer?
    private var hadRecentOutput: Bool = false
    private var isSuspendedForSleep: Bool = false
    private var isWaitingForOutput: Bool = false
    private var isLoadingResumeSessions: Bool = false
    private var loadingPhase: Float = 0
    private var lastLoadingRenderTime: CFTimeInterval = 0

    // MARK: - Metal Properties

    private var metalLayer: CAMetalLayer!
    private var renderer: MetalRenderer!
    private var needsRender: Bool = true
    private var contentDirty: Bool = true
    private var lastOverlayComputeTime: CFTimeInterval = 0
    private var cachedSearchHighlights: (cells: [(col: Int, row: Int, len: Int)], currentIndex: Int) = ([], -1)
    private var cachedFoldIndicators: [FoldIndicator] = []
    private var cachedCodeBlockRows: Set<Int> = []
    private var cachedDiffRowColors: [Int: (UInt8, UInt8, UInt8, UInt8)] = [:]
    private var currentScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0

    /// True when the user has manually scrolled up; suppresses auto-snap to bottom.
    private var userScrolledUp: Bool = false
    private var scrollAccumulator: CGFloat = 0.0
    private var autoScrollTimer: Timer?
    private var autoScrollDelta: Int = 0  // -1 = scroll up, +1 = scroll down

    // MARK: - Search State

    private var searchBar: SearchBarView?
    private var searchResults: [(col: Int, row: Int32)] = []
    private var currentSearchIndex: Int = 0
    private var searchQueryLength: Int = 0

    // MARK: - Selection Tracking

    private var selectionStartAbsRow: Int32 = 0
    private var selectionEndAbsRow: Int32 = 0

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

    // MARK: - Syntax Highlighting

    private let syntaxHighlighter = SyntaxHighlighter()

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

        // Push theme ANSI colors to the Rust palette so indexed colors match our theme
        let ansiColors = AppConfig.shared.ansiColors
        for i in 0..<min(16, ansiColors.count) {
            let c = ansiColors[i].usingColorSpace(.sRGB) ?? ansiColors[i]
            at_surface_set_palette_color(surface!, UInt8(i),
                                         UInt8(c.redComponent * 255),
                                         UInt8(c.greenComponent * 255),
                                         UInt8(c.blueComponent * 255))
        }

        // Push theme default fg/bg to Rust so Color::Default resolves to configured colors
        if let fg = AppConfig.shared.themeFg.usingColorSpace(.sRGB) {
            at_surface_set_default_fg(surface!,
                                      UInt8(fg.redComponent * 255),
                                      UInt8(fg.greenComponent * 255),
                                      UInt8(fg.blueComponent * 255))
        }
        if let bg = AppConfig.shared.themeBg.usingColorSpace(.sRGB) {
            at_surface_set_default_bg(surface!,
                                      UInt8(bg.redComponent * 255),
                                      UInt8(bg.greenComponent * 255),
                                      UInt8(bg.blueComponent * 255))
        }

        cellBuffer = [CCell](repeating: CCell(), count: Int(termCols * termRows))

        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.cursorBlinkOn.toggle()
            self?.needsRender = true
        }

        setupDragAndDrop()

        // Observe sleep/wake to suspend background activity
        let wsc = NSWorkspace.shared.notificationCenter
        wsc.addObserver(self, selector: #selector(handleSleep),
                        name: NSWorkspace.willSleepNotification, object: nil)
        wsc.addObserver(self, selector: #selector(handleWake),
                        name: NSWorkspace.didWakeNotification, object: nil)
        wsc.addObserver(self, selector: #selector(handleSleep),
                        name: NSWorkspace.screensDidSleepNotification, object: nil)
        wsc.addObserver(self, selector: #selector(handleWake),
                        name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        cursorBlinkTimer?.invalidate()
        idleTimer?.invalidate()
        stopDisplayLink()
        if let source = readSource {
            source.cancel()
        }
        if let source = writeSource {
            source.cancel()
        }
        if let s = surface {
            at_surface_destroy(s)
        }
    }

    // MARK: - Sleep/Wake

    @objc private func handleSleep() {
        guard !isSuspendedForSleep else { return }
        isSuspendedForSleep = true

        stopDisplayLink()
        readSource?.suspend()
        writeSource?.suspend()
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }

    @objc private func handleWake() {
        guard isSuspendedForSleep else { return }
        isSuspendedForSleep = false

        if window != nil {
            startDisplayLink()
        }
        readSource?.resume()
        writeSource?.resume()
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.cursorBlinkOn.toggle()
            self?.needsRender = true
        }
        needsRender = true
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
        // Prevent implicit CA animations from stretching the drawable during layout animations.
        layer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "contents": NSNull(),
            "contentsScale": NSNull(),
        ]

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
        view.menuRenderPending = false
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
        if appState == .menu && newSize.width > 0 && newSize.height > 0 {
            if menuRenderPending {
                // Debounce: cancel any previously scheduled render and reschedule.
                // This ensures we only render once layout has settled (no more
                // setFrameSize calls), avoiding the menu flicker/jump on new tabs.
                deferredMenuRender?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, let s = self.surface, self.appState == .menu else { return }
                    // Force any pending layout to complete so we get final dimensions
                    self.superview?.layoutSubtreeIfNeeded()
                    // Update grid dimensions immediately from current bounds,
                    // bypassing the debounced recalculateGridSize() which defers
                    // the termCols/termRows update behind a 150ms timer.
                    let newCols = max(1, UInt32(self.bounds.width / self.cellWidth))
                    let newRows = max(1, UInt32(self.bounds.height / self.cellHeight))
                    if newCols != self.termCols || newRows != self.termRows {
                        self.termCols = newCols
                        self.termRows = newRows
                        at_surface_resize(s, newCols, newRows)
                        self.updateCellBuffer()
                    }
                    self.ptyResizeTimer?.invalidate()
                    self.menuRenderPending = false
                    self.deferredMenuRender = nil
                    self.renderMenu()
                }
                deferredMenuRender = work
                // Delay long enough for Auto Layout to fully settle.
                // renderFrame() suppresses Metal presentation while menuRenderPending
                // is true, so the delay is imperceptible.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
            } else {
                renderMenu()
            }
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

    override func layout() {
        super.layout()
        updateMetalLayerSize()
        recalculateGridSize()
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        CATransaction.commit()
        let scale = window?.backingScaleFactor ?? layer.contentsScale
        layer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        contentDirty = true
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

    private func isSelectable(_ entry: MenuEntry) -> Bool {
        switch entry {
        case .sectionHeader, .separator, .loadingIndicator:
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
                        out += "\u{1b}[48;2;79;70;229m"
                        out += "\u{1b}[1;37m"
                        out += " \(arrow) \(nameField)"
                        out += "\u{1b}[0;37m"
                        out += "\u{1b}[48;2;79;70;229m"
                        out += " \(modelStr)"
                        out += "\u{1b}[90m"
                        out += "\u{1b}[48;2;79;70;229m"
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
                    out += "\u{1b}[48;2;79;70;229m"
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

            case .resumeSessionsLink:
                let isSelected = i == menuSelection
                let arrow = isSelected ? "▸" : " "
                let text = "Resume Session"
                let suffix = "▸"

                if isSelected {
                    let pad = itemWidth - 4 - text.count - suffix.count
                    out += itemPadStr
                    out += "\u{1b}[48;2;79;70;229m"
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
                    out += "\u{1b}[48;2;79;70;229m"
                    out += "\u{1b}[1;37m"
                    out += " \(arrow) \(modelField)"
                    out += "\u{1b}[0;37m\u{1b}[48;2;79;70;229m"
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
                launchSession(model: item, workingDir: folder)
            case .pickFolder, .resumeSessions:
                break
            }

        case .recentFolder(let path):
            if case .pickFolder(let model) = menuPhase {
                launchSession(model: model, workingDir: path)
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

    private func showResumeSessionFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
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

    private func loadResumableSessionsAsync(projectPath: String) {
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

    private func launchResumeSession(_ entry: SessionManager.ResumeEntry) {
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

    private func launchSession(model: MenuItem, workingDir: String?, commandOverride: String? = nil) {
        guard let s = surface else { return }

        activeModelName = model.name
        activeProvider = model.provider
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

        // Save workspace
        if let dir = workingDir {
            WorkspaceStore.shared.save(path: dir, model: model.name)
        }

        // Inject AI components based on model and project type
        lastAIComponentContext = nil
        postSessionHooks = []
        beforeCommitHooks = []
        lastWorkingDir = workingDir
        var aiComponentContext: AIComponentContext? = nil
        if let dir = workingDir, AppConfig.shared.aiComponentsEnabled {
            aiComponentContext = AIComponentInjector.inject(
                modelName: model.name,
                projectPath: dir
            )
        }

        // Execute pre-session hooks
        if let ctx = aiComponentContext {
            postSessionHooks = ctx.postSessionHooks
            beforeCommitHooks = ctx.beforeCommitHooks
            for hookURL in ctx.preSessionHooks {
                executeHookScript(hookURL, workingDir: workingDir)
            }
        }

        // Build the full command to execute
        var modelCmd = commandOverride ?? model.command
        if commandOverride == nil, !modelCmd.isEmpty, let bin = model.binaryName, let install = model.installCommand {
            modelCmd = "command -v \(bin) >/dev/null 2>&1 || { echo \"Installing \(model.name)...\"; \(install); } && \(model.command)"
        }

        // For non-Claude models, modify the command with AI component flags
        if let ctx = aiComponentContext, let cmdModifier = ctx.commandModifier {
            modelCmd = cmdModifier(modelCmd)
        }
        lastAIComponentContext = aiComponentContext

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
            if case .pickFolder(let model) = self?.menuPhase {
                self?.launchSession(model: model, workingDir: url.path)
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

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Compact path: abbreviates intermediate directories to fit within `maxLen`.
    /// Example: ~/Projects/Workspace/Code/awal-terminal → ~/P…/W…/Code/awal-terminal
    private func compactPath(_ path: String, maxLen: Int) -> String {
        let shortened = shortenPath(path)
        if shortened.count <= maxLen { return shortened }

        var components = shortened.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 2 else {
            // Just prefix/last — truncate the end
            return String(shortened.prefix(maxLen - 1)) + "…"
        }

        // Keep first (~ or root) and last component intact, abbreviate middle ones
        let first = components.removeFirst()
        let last = components.removeLast()

        // Progressively shorten middle components from the left
        var middle = components
        for i in 0..<middle.count {
            let current = ([first] + middle + [last]).joined(separator: "/")
            if current.count <= maxLen { return current }
            // Abbreviate this component to first char + …
            if middle[i].count > 2 {
                middle[i] = String(middle[i].prefix(1)) + "…"
            }
        }

        // Still too long — drop middle components
        var result = ([first] + middle + [last]).joined(separator: "/")
        while result.count > maxLen && !middle.isEmpty {
            middle.removeFirst()
            result = ([first] + ["…"] + middle + [last]).joined(separator: "/")
        }
        if result.count > maxLen {
            result = first + "/…/" + last
        }
        if result.count > maxLen {
            return String(result.prefix(maxLen - 1)) + "…"
        }
        return result
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

    /// Execute a hook script synchronously in a subprocess.
    private func executeHookScript(_ scriptURL: URL, workingDir: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        if let dir = workingDir {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Execute post-session hooks asynchronously.
    func executePostSessionHooks() {
        guard !postSessionHooks.isEmpty else { return }
        let hooks = postSessionHooks
        let dir = lastWorkingDir
        postSessionHooks = []
        DispatchQueue.global(qos: .utility).async {
            for hookURL in hooks {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [hookURL.path]
                if let dir = dir {
                    process.currentDirectoryURL = URL(fileURLWithPath: dir)
                }
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }
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

    /// Activate the write source to drain queued PTY writes when the fd is writable.
    private func activateWriteSource() {
        guard writeSource == nil, let s = surface else { return }
        let fd = at_surface_get_fd(s)
        if fd < 0 { return }

        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.drainWriteQueue()
        }
        source.setCancelHandler { }
        source.resume()
        self.writeSource = source
    }

    /// Drain queued writes; suspend write source when done.
    private func drainWriteQueue() {
        guard let s = surface else { return }
        let result = at_surface_drain_writes(s)
        if result < 0 {
            // Error — stop trying
            writeSource?.cancel()
            writeSource = nil
            return
        }
        if !at_surface_has_pending_writes(s) {
            writeSource?.cancel()
            writeSource = nil
        }
    }

    /// Queue data for writing to the PTY (non-blocking).
    private func queuePtyWrite(_ bytes: [UInt8]) {
        guard let s = surface else { return }
        bytes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            at_surface_queue_write(s, base, UInt32(ptr.count))
        }
        activateWriteSource()
    }

    private func readPTY() {
        guard let s = surface else { return }

        var totalRead: Int32 = 0
        var iterations = 0
        let deadline = CACurrentMediaTime() + 0.008 // 8ms cap
        while iterations < 16 {
            let n = at_surface_process_pty(s)
            if n <= 0 { break }
            totalRead += n
            iterations += 1
            if CACurrentMediaTime() >= deadline { break }
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
            isWaitingForOutput = false
            if !isGenerating && !activeModelName.isEmpty {
                isGenerating = true
                onGeneratingChanged?(true)
            }
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
        if isGenerating {
            isGenerating = false
            onGeneratingChanged?(false)
        }
        onTerminalIdle?()
    }

    // MARK: - Grid Size

    private func recalculateGridSize() {
        guard surface != nil else { return }

        let newCols = max(1, UInt32(bounds.width / cellWidth))
        let newRows = max(1, UInt32(bounds.height / cellHeight))

        if newCols != termCols || newRows != termRows {
            // Don't update termCols/termRows yet — the renderer uses them as
            // the row stride for cellBuffer, which still holds old-size data.
            // Debounce the full resize (grid + PTY) so the child sees one
            // consistent resize after the animation settles.
            needsRender = true
            ptyResizeTimer?.invalidate()
            ptyResizeTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                guard let self = self, let s = self.surface else { return }
                self.termCols = max(1, UInt32(self.bounds.width / self.cellWidth))
                self.termRows = max(1, UInt32(self.bounds.height / self.cellHeight))
                at_surface_resize(s, self.termCols, self.termRows)
                self.userScrolledUp = false
                self.updateCellBuffer()
                self.needsRender = true
                if self.appState == .terminal {
                    self.onSessionChanged?(self.activeModelName, self.activeProvider,
                                           Int(self.termCols), Int(self.termRows))
                } else if self.appState == .menu {
                    self.renderMenu()
                }
            }
        }
    }

    private func updateCellBuffer() {
        guard let s = surface else { return }

        let needed = Int(termCols * termRows)
        if cellBuffer.count < needed {
            cellBuffer = [CCell](repeating: CCell(), count: needed)
        }
        contentDirty = true

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

    /// Apply syntax highlighting to code block regions, mutating cellBuffer in-place.
    /// Returns the set of viewport rows that belong to code blocks (for background tinting).
    private func applySyntaxHighlighting() -> Set<Int> {
        guard let s = surface, !foldRegions.isEmpty else { return [] }

        let cols = Int(termCols)
        let rows = Int(termRows)
        let viewportOffset = Int(at_surface_get_viewport_offset(s))
        let scrollbackLen = Int(at_surface_get_scrollback_len(s))

        var codeBlockRows = Set<Int>()

        for region in foldRegions {
            // Only highlight CodeBlock regions (type 3)
            guard region.regionType == 3 else { continue }

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

            // Detect language from the first row (``` fence line)
            let lang: LanguageInfo
            if vpStart >= 0 && vpStart < rows {
                var fenceLine = ""
                let fenceBase = vpStart * cols
                for c in 0..<cols {
                    let idx = fenceBase + c
                    guard idx < cellBuffer.count else { break }
                    let cp = cellBuffer[idx].codepoint
                    if cp > 0 { fenceLine.append(Character(UnicodeScalar(cp)!)) }
                }
                // Extract language after ```
                let trimmed = fenceLine.trimmingCharacters(in: .whitespaces)
                let langStr = trimmed.hasPrefix("```") ? String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces) : ""
                lang = syntaxHighlighter.languageInfo(for: langStr)
            } else {
                lang = syntaxHighlighter.languageInfo(for: "")
            }

            // Process content rows (skip first/last fence rows)
            let contentStart = max(clippedStart, vpStart + 1)
            let contentEnd = min(clippedEnd, vpEnd - 1)

            for vpRow in contentStart...max(contentStart, contentEnd) {
                guard vpRow >= 0 && vpRow < rows else { continue }
                codeBlockRows.insert(vpRow)

                // Extract text from cellBuffer for this row
                let base = vpRow * cols
                var lineText = ""
                var colOffsets: [Int] = [] // maps string index → cell column
                for c in 0..<cols {
                    let idx = base + c
                    guard idx < cellBuffer.count else { break }
                    let cp = cellBuffer[idx].codepoint
                    if cp > 0 {
                        colOffsets.append(c)
                        lineText.append(Character(UnicodeScalar(cp)!))
                    }
                }

                guard !lineText.isEmpty else { continue }

                // Tokenize
                let spans = syntaxHighlighter.tokenize(line: lineText, language: lang)

                // Apply colors to cellBuffer — only override default fg (229,229,229)
                for span in spans {
                    guard let color = SyntaxColorScheme.color(for: span.type) else { continue }
                    for j in 0..<span.length {
                        let charIdx = span.start + j
                        guard charIdx < colOffsets.count else { break }
                        let col = colOffsets[charIdx]
                        let cellIdx = base + col
                        guard cellIdx < cellBuffer.count else { break }
                        // Only override cells with default fg color
                        if cellBuffer[cellIdx].fg_r == 229 &&
                           cellBuffer[cellIdx].fg_g == 229 &&
                           cellBuffer[cellIdx].fg_b == 229 {
                            cellBuffer[cellIdx].fg_r = color.r
                            cellBuffer[cellIdx].fg_g = color.g
                            cellBuffer[cellIdx].fg_b = color.b
                        }
                    }
                }
            }

            // Also add fence rows to codeBlockRows for background
            for vpRow in clippedStart...clippedEnd {
                codeBlockRows.insert(vpRow)
            }
        }

        return codeBlockRows
    }

    /// Apply colored backgrounds to diff regions (type 7) based on line content.
    /// Returns a dict mapping viewport row → RGBA color tuple.
    private func applyDiffHighlighting() -> [Int: (UInt8, UInt8, UInt8, UInt8)] {
        guard let s = surface, !foldRegions.isEmpty else { return [:] }

        let cols = Int(termCols)
        let rows = Int(termRows)
        let viewportOffset = Int(at_surface_get_viewport_offset(s))
        let scrollbackLen = Int(at_surface_get_scrollback_len(s))

        var diffColors: [Int: (UInt8, UInt8, UInt8, UInt8)] = [:]

        for region in foldRegions {
            guard region.regionType == 7 else { continue }

            let regStart = Int(region.startRow)
            let regEnd = Int(region.endRow)

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

            let clippedStart = max(0, vpStart)
            let clippedEnd = min(rows - 1, vpEnd)
            guard clippedStart <= clippedEnd else { continue }

            for vpRow in clippedStart...clippedEnd {
                guard vpRow >= 0 && vpRow < rows else { continue }

                let base = vpRow * cols

                // Skip rows where the program already set non-default fg colors
                // (Claude Code already colors diff output with ANSI codes)
                var hasStyledFg = false
                for c in 0..<cols {
                    let idx = base + c
                    guard idx < cellBuffer.count else { break }
                    let cell = cellBuffer[idx]
                    if cell.codepoint > 32 {
                        // Check if fg is not the default (229,229,229)
                        if cell.fg_r != 229 || cell.fg_g != 229 || cell.fg_b != 229 {
                            hasStyledFg = true
                        }
                        break
                    }
                }
                if hasStyledFg { continue }

                // Read first few non-space characters from cellBuffer
                var lineChars: [UInt32] = []
                for c in 0..<cols {
                    let idx = base + c
                    guard idx < cellBuffer.count else { break }
                    let cp = cellBuffer[idx].codepoint
                    if cp > 32 {
                        lineChars.append(cp)
                        if lineChars.count >= 4 { break }
                    }
                }

                guard !lineChars.isEmpty else { continue }
                let first = lineChars[0]
                let second = lineChars.count > 1 ? lineChars[1] : UInt32(0)
                let third = lineChars.count > 2 ? lineChars[2] : UInt32(0)

                let color: (UInt8, UInt8, UInt8, UInt8)
                if first == 0x40 && second == 0x40 { // '@@'
                    color = (40, 30, 65, 80)
                } else if first == 0x2B && second != 0x2B && second != 0x2B { // '+' but not '+++'
                    // Skip '+' followed by digits (e.g. "+157 lines")
                    if second >= 0x30 && second <= 0x39 { continue }
                    color = (30, 60, 30, 80)
                } else if first == 0x2D && second != 0x2D { // '-' but not '---'
                    color = (60, 25, 25, 80)
                } else {
                    continue
                }

                diffColors[vpRow] = color
            }
        }

        return diffColors
    }

    // MARK: - Metal Rendering (Display Link)

    private func renderFrame() {
        guard needsRender else { return }
        // Don't present any frame to screen while the menu is still
        // waiting for layout to settle — Metal drawables bypass view alpha.
        guard !menuRenderPending else { return }
        guard let layer = metalLayer else { return }
        let drawableSize = layer.drawableSize
        guard drawableSize.width > 0 && drawableSize.height > 0 else { return }
        guard let drawable = layer.nextDrawable() else { return }

        needsRender = false

        let viewportSize = layer.drawableSize

        // Advance loading animation (throttled to ~30fps to avoid starving scroll events)
        var currentLoadingPhase: Float? = nil
        if isWaitingForOutput || isGenerating || isLoadingResumeSessions {
            let now = CACurrentMediaTime()
            let elapsed = now - lastLoadingRenderTime
            if elapsed >= 0.033 {
                loadingPhase += 0.024
                if loadingPhase > 2.0 { loadingPhase -= 2.0 }
                lastLoadingRenderTime = now
                // Schedule next loading frame after interval instead of continuous rendering
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in
                    guard let self, self.isWaitingForOutput || self.isGenerating || self.isLoadingResumeSessions else { return }
                    self.needsRender = true
                }
            }
            currentLoadingPhase = loadingPhase
        }

        // Only recompute visual overlays when content has changed, debounced to 100ms
        if contentDirty {
            let now = CACurrentMediaTime()
            if now - lastOverlayComputeTime >= 0.1 {
                cachedSearchHighlights = computeVisibleSearchHighlights()
                cachedFoldIndicators = computeFoldIndicators()
                cachedCodeBlockRows = applySyntaxHighlighting()
                cachedDiffRowColors = applyDiffHighlighting()
                lastOverlayComputeTime = now
                contentDirty = false
            }
        }

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
                searchHighlights: cachedSearchHighlights.cells,
                currentHighlight: cachedSearchHighlights.currentIndex,
                foldIndicators: cachedFoldIndicators,
                codeBlockRows: cachedCodeBlockRows,
                diffRowColors: cachedDiffRowColors,
                loadingPhase: currentLoadingPhase
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
        // Handle delete confirmation mode
        if pendingDeleteIndex != nil {
            if let chars = event.characters, chars == "y" {
                // Confirm deletion
                if let idx = pendingDeleteIndex, idx < menuEntries.count,
                   case .recentWorkspace(let ws) = menuEntries[idx] {
                    WorkspaceStore.shared.remove(path: ws.path, model: ws.lastModel)
                    pendingDeleteIndex = nil
                    buildMenuEntries()
                    // Adjust selection if it's now out of bounds
                    if menuSelection >= menuEntries.count {
                        menuSelection = max(0, menuEntries.count - 1)
                    }
                    if !menuEntries.isEmpty && !isSelectable(menuEntries[menuSelection]) {
                        moveToFirstSelectable()
                    }
                }
            } else {
                // Any other key cancels
                pendingDeleteIndex = nil
            }
            renderMenu()
            return
        }

        switch event.keyCode {
        case 126: // Up arrow
            moveSelection(by: -1)
            renderMenu()
        case 125: // Down arrow
            moveSelection(by: 1)
            renderMenu()
        case 36: // Return
            handleSelection()
        case 51: // Backspace / Delete
            if case .main = menuPhase,
               menuSelection < menuEntries.count,
               case .recentWorkspace = menuEntries[menuSelection] {
                pendingDeleteIndex = menuSelection
                renderMenu()
            }
        case 53: // Escape
            switch menuPhase {
            case .main:
                // Launch Shell directly
                let shellItem = modelItems.last!
                launchSession(model: shellItem, workingDir: nil)
            case .pickModel, .pickFolder, .resumeSessions:
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
                    switch menuPhase {
                    case .main, .pickFolder:
                        showFolderPicker()
                    default:
                        break
                    }
                default:
                    break
                }
            }
        }
    }

    private func handleTerminalKey(_ event: NSEvent) {
        guard let s = surface else { return }

        let modFlags = event.modifierFlags

        // Let Cmd-key combos through to the menu system (Cmd+,  Cmd+Q  etc.)
        if modFlags.contains(.command) { return }

        let bytes: [UInt8]

        if let chars = event.characters, !chars.isEmpty {
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

        let delta = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas

        // Reset accumulator at the start of a new trackpad gesture
        if precise && event.phase == .began {
            scrollAccumulator = 0.0
        }

        let mouseMode = at_surface_get_mouse_mode(s)
        if mouseMode > 0 {
            // Mouse reporting enabled — send scroll as mouse button 4/5 (up/down)
            let location = convert(event.locationInWindow, from: nil)
            let col = Int(location.x / cellWidth) + 1
            let row = Int(location.y / cellHeight) + 1  // Will be flipped below
            let flippedRow = Int(termRows) - row + 1

            let lines: Int
            if precise {
                scrollAccumulator += delta / cellHeight
                lines = Int(scrollAccumulator)
                scrollAccumulator -= CGFloat(lines)
            } else {
                lines = max(1, Int(abs(delta) / 3.0 + 0.5)) * (delta > 0 ? 1 : -1)
            }

            let absLines = abs(lines)
            guard absLines > 0 else { return }

            let sgrMode = at_surface_get_sgr_mouse(s)
            for _ in 0..<absLines {
                let button = lines > 0 ? 64 : 65 // scroll up : scroll down
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
        let lines: Int
        if precise {
            scrollAccumulator += delta / cellHeight
            lines = Int(scrollAccumulator)
            scrollAccumulator -= CGFloat(lines)
        } else {
            lines = Int(delta / 3.0)
        }
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

        // Start selection (Option+click = rectangular/block selection)
        let absRow = absoluteRow(gridRow: row)
        selectionStartAbsRow = absRow
        selectionEndAbsRow = absRow

        let isRectangular = event.modifierFlags.contains(.option)
        at_surface_set_rectangular_selection(s, isRectangular)

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

    private func startAutoScroll(delta: Int) {
        guard autoScrollDelta != delta else { return }
        stopAutoScroll()
        autoScrollDelta = delta
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.autoScrollTick()
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDelta = 0
    }

    private func autoScrollTick() {
        guard let s = surface, autoScrollDelta != 0 else { return }
        at_surface_scroll_viewport(s, Int32(autoScrollDelta))
        let offset = at_surface_get_viewport_offset(s)
        userScrolledUp = offset > 0

        // Extend selection to the edge row
        let edgeRow = autoScrollDelta < 0 ? Int(termRows) - 1 : 0
        let edgeCol = autoScrollDelta < 0 ? Int(termCols) - 1 : 0
        let absRow = absoluteRow(gridRow: edgeRow)
        selectionEndAbsRow = absRow
        at_surface_update_selection(s, UInt32(edgeCol), absRow)
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
            let location = convert(event.locationInWindow, from: nil)
            if location.y < 0 {
                // Mouse below view — scroll down
                startAutoScroll(delta: -1)
            } else if location.y > bounds.height {
                // Mouse above view — scroll up
                startAutoScroll(delta: 1)
            } else {
                stopAutoScroll()
            }
            let absRow = absoluteRow(gridRow: row)
            selectionEndAbsRow = absRow
            at_surface_update_selection(s, UInt32(col), absRow)
            updateCellBuffer()
            needsRender = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoScroll()
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
        // Don't intercept when a sheet (e.g. alert dialog) is active on this or another window
        if window?.attachedSheet != nil || event.window != window {
            return super.performKeyEquivalent(with: event)
        }
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
        var text = String(cString: cStr)
        at_free_string(cStr)

        if text.isEmpty { return false }

        // Smart copy: strip code block fences if selection is within a CodeBlock region
        text = smartStripCodeBlock(text)

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        onCopied?()
        return true
    }

    /// If the selection falls entirely within a single CodeBlock region (type 3),
    /// strip leading/trailing lines that start with ```.
    private func smartStripCodeBlock(_ text: String) -> String {
        let minRow = min(selectionStartAbsRow, selectionEndAbsRow)
        let maxRow = max(selectionStartAbsRow, selectionEndAbsRow)

        // Check if selection bounds fall within a single CodeBlock region
        for region in foldRegions {
            guard region.regionType == 3 else { continue }
            if minRow >= region.startRow && maxRow <= region.endRow {
                // Selection is within this code block — strip fence lines
                var lines = text.components(separatedBy: "\n")
                // Strip leading fence
                if let first = lines.first?.trimmingCharacters(in: .whitespaces),
                   first.hasPrefix("```") {
                    lines.removeFirst()
                }
                // Strip trailing fence
                if let last = lines.last?.trimmingCharacters(in: .whitespaces),
                   last.hasPrefix("```") {
                    lines.removeLast()
                }
                return lines.joined(separator: "\n")
            }
        }

        return text
    }

    private func pasteFromClipboard() {
        guard let _ = surface else { return }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }

        gatedPaste(text) { [weak self] approved in
            guard let self, let _ = self.surface else { return }
            let bracketedPaste = at_surface_get_bracketed_paste(self.surface)
            var pasteData = approved
            if bracketedPaste {
                pasteData = "\u{1b}[200~" + approved + "\u{1b}[201~"
            }
            self.queuePtyWrite(Array(pasteData.utf8))
        }
    }

    /// Inject text into the terminal as if typed (used by voice dictation).
    func injectText(_ text: String) {
        guard let _ = surface else { return }

        gatedPaste(text) { [weak self] approved in
            guard let self, let _ = self.surface else { return }
            let bracketedPaste = at_surface_get_bracketed_paste(self.surface)
            var data = approved
            if bracketedPaste {
                data = "\u{1b}[200~" + approved + "\u{1b}[201~"
            }
            self.queuePtyWrite(Array(data.utf8))
        }
    }

    /// Gate large pastes behind a confirmation dialog.
    /// If the text is within the threshold, calls completion immediately.
    /// Otherwise shows a sheet with options to save-to-file, paste all, truncate, or cancel.
    private func gatedPaste(_ text: String, completion: @escaping (String) -> Void) {
        let config = AppConfig.shared
        guard text.count > config.pasteWarningThreshold else {
            completion(text)
            return
        }

        guard let window = self.window else {
            completion(text)
            return
        }

        let lineCount = text.components(separatedBy: "\n").count
        let charCount = text.count
        let truncateLen = config.pasteTruncateLength

        let alert = NSAlert.branded()
        alert.messageText = "Large Paste Detected"
        alert.informativeText = "The clipboard contains \(formatCount(charCount)) characters (\(formatCount(lineCount)) lines). Pasting this much text may cause performance issues."
        alert.addButton(withTitle: "Save to File & Paste Path")
        alert.addButton(withTitle: "Paste All")
        alert.addButton(withTitle: "Paste First \(formatCount(truncateLen)) Characters")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                // Save to file & paste path
                self?.saveToFileAndPastePath(text, completion: completion)
            case .alertSecondButtonReturn:
                // Paste all
                completion(text)
            case .alertThirdButtonReturn:
                // Paste truncated
                let truncated = String(text.prefix(truncateLen))
                completion(truncated)
            default:
                // Cancel — do nothing
                break
            }
        }
    }

    /// Save pasted content to a file and return the file path via completion.
    private func saveToFileAndPastePath(_ text: String, completion: @escaping (String) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) ? "json" : "txt"
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = ".pasted-content-\(timestamp).\(ext)"

        let dir: String
        if let wd = lastWorkingDir, FileManager.default.fileExists(atPath: wd) {
            dir = wd
        } else {
            dir = NSTemporaryDirectory()
        }

        let path = (dir as NSString).appendingPathComponent(filename)
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            completion(path)
        } catch {
            // Fall back to pasting all if file write fails
            completion(text)
        }
    }

    /// Format a number with grouping separators for display.
    private func formatCount(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Set the search query in the search bar (opens search if not visible).
    func setSearchQuery(_ query: String) {
        if searchBar == nil {
            toggleSearch()
        }
        searchBar?.setQuery(query)
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
        queuePtyWrite(Array(joined.utf8))
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
        contentDirty = true

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
