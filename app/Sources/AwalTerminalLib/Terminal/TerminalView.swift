import AppKit
import IOKit
import IOKit.pwr_mgt
import Metal
import os.log
import QuartzCore
import CAwalTerminal

private let hookLog = OSLog(subsystem: "com.awal.terminal", category: "hooks")

class TerminalView: NSView {

    // MARK: - Menu State

    enum AppState {
        case menu
        case terminal
    }

    typealias MenuItem = LLMModel

    enum MenuEntry {
        case sectionHeader(String)
        case separator
        case restoreSession(tabCount: Int, timeAgo: String, models: String)
        case recentWorkspace(Workspace)
        case modelItem(MenuItem)
        case recentFolder(String)
        case openFolder
        case resumeSessionsLink
        case resumeSession(SessionManager.ResumeEntry)
        case loadingIndicator(String)
    }

    enum MenuPhase {
        case main
        case pickModel(String) // folder path selected via Open Folder
        case pickFolder(LLMModel) // model selected, now pick a folder
        case resumeSessions // browsing past sessions submenu
    }

    var appState: AppState = .menu
    var menuPhase: MenuPhase = .main
    var menuSelection: Int = 0
    var menuRendered: Bool = false
    var menuEntries: [MenuEntry] = []
    var pendingDeleteIndex: Int? = nil
    var menuRenderPending = true
    var deferredMenuRender: DispatchWorkItem?

    var activeModelName: String = ""
    var lastAIComponentContext: AIComponentContext?
    var postSessionHooks: [URL] = []
    var beforeCommitHooks: [URL] = []
    var lastWorkingDir: String?
    var activeProvider: String = ""
    var isGenerating: Bool = false

    /// Session recorder for replay/export.
    var sessionRecorder: SessionRecorder?

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

    /// Called before launching a session to allow the controller to resolve the working directory
    /// (e.g., creating a git worktree for tab isolation). The callback receives the chosen directory
    /// and must call the completion with the resolved directory to use.
    var onProcessExited: (() -> Void)?
    var onWorkspacePicked: ((_ dir: String, _ completion: @escaping (String) -> Void) -> Void)?
    var onRemoteControlChanged: ((_ active: Bool, _ url: String?) -> Void)?
    var onSleepPreventionChanged: ((_ active: Bool) -> Void)?
    var onRestoreSession: (() -> Void)?

    /// Whether the current session is running in danger mode (unrestricted permissions).
    var isDangerMode: Bool = false

    var isRemoteControlActive = false
    var remoteControlURL: String?

    var sleepAssertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    var isSleepPrevented: Bool { sleepAssertionID != IOPMAssertionID(kIOPMNullAssertionID) }

    // Deferred launch for new panes (set before adding to window)
    var pendingLaunchModel: MenuItem?
    var pendingLaunchDir: String?
    var pendingDangerMode: Bool = false
    /// Override the command used for deferred launch (e.g. resume command for session restore).
    var pendingCommandOverride: String?
    /// Skip workspace resolution (worktree prompt) for restored sessions.
    var skipWorkspaceResolution: Bool = false

    var modelItems: [LLMModel] { ModelCatalog.all }

    // MARK: - Terminal Properties

    var surface: OpaquePointer?
    var readSource: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?
    var processSource: DispatchSourceProcess?
    var displayLink: CVDisplayLink?

    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var font: NSFont
    var boldFont: NSFont
    var baselineOffset: CGFloat

    let baseFontSize: CGFloat
    let minFontSize: CGFloat = 8.0
    let maxFontSize: CGFloat = 36.0
    let zoomStep: CGFloat = 1.0

    var termCols: UInt32 = 80
    var termRows: UInt32 = 24

    var cellBuffer: [CCell] = []
    var cursorRow: UInt32 = 0
    var cursorCol: UInt32 = 0
    var cursorVisible: Bool = true
    var cursorBlinkOn: Bool = true
    private var cursorBlinkTimer: Timer?

    var idleTimer: Timer?
    private var ptyResizeTimer: Timer?
    var hadRecentOutput: Bool = false
    var isCleanedUp: Bool = false
    private var isSuspendedForSleep: Bool = false
    var isWaitingForOutput: Bool = false
    var isLoadingResumeSessions: Bool = false
    var loadingPhase: Float = 0
    var lastLoadingRenderTime: CFTimeInterval = 0
    var loadingSpinnerRow: Int = 0
    var loadingSpinnerCol: Int = 0
    var loadingMessageText: String = ""

    // MARK: - Metal Properties

    var metalLayer: CAMetalLayer!
    var renderer: MetalRenderer!
    var needsRender: Bool = true
    var contentDirty: Bool = true
    var lastOverlayComputeTime: CFTimeInterval = 0
    var cachedSearchHighlights: (cells: [(col: Int, row: Int, len: Int)], currentIndex: Int) = ([], -1)
    var cachedFoldIndicators: [FoldIndicator] = []
    var cachedCodeBlockRows: Set<Int> = []
    var cachedDiffRowColors: [Int: (UInt8, UInt8, UInt8, UInt8)] = [:]
    var currentScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0

    /// True when the user has manually scrolled up; suppresses auto-snap to bottom.
    var userScrolledUp: Bool = false
    var scrollAccumulator: CGFloat = 0.0
    var autoScrollTimer: Timer?
    var autoScrollDelta: Int = 0  // -1 = scroll up, +1 = scroll down
    /// Safety timer that force-renders if synchronized output mode (2026) is held too long.
    var syncOutputTimer: Timer?
    var scrollToBottomButton: ScrollToBottomButton?
    var recordingIndicator: RecordingIndicatorView?
    var zoomHUD: ZoomHUDView?
    var quickLookItems: [URL] = []

    // MARK: - Search State

    var searchBar: SearchBarView?
    var searchResults: [(col: Int, row: Int32)] = []
    var currentSearchIndex: Int = 0
    var searchQueryLength: Int = 0

    // MARK: - Autocomplete State

    var completionPopup: CompletionPopupView?
    var completionProviders: [CompletionProvider] = [FilePathProvider(), HistoryProvider.shared]
    var completionDebounceTimer: Timer?

    // MARK: - Selection Tracking

    var selectionStartAbsRow: Int32 = 0
    var selectionEndAbsRow: Int32 = 0
    var pendingSelectionCol: UInt32 = 0
    var pendingSelectionRow: Int32 = 0
    var selectionStartedByDrag = false

    // MARK: - AI Fold State

    /// Cached fold regions for rendering indicators.
    var foldRegions: [FoldRegion] = []

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
        self.baseFontSize = config.fontSize

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

    /// Explicit cleanup — must be called before removing the view.
    /// Idempotent: safe to call multiple times.
    func cleanup() {
        guard !isCleanedUp else { return }
        isCleanedUp = true

        // 1. Stop display link first to prevent use-after-free in callback
        stopDisplayLink()

        // 2. Cancel dispatch sources
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        processSource?.cancel()
        processSource = nil

        // 3. Invalidate all timers
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        ptyResizeTimer?.invalidate()
        ptyResizeTimer = nil
        syncOutputTimer?.invalidate()
        syncOutputTimer = nil

        // 4. Release sleep assertion
        releaseSleepAssertion()

        // 5. Remove notification observers
        NSWorkspace.shared.notificationCenter.removeObserver(self)

        // 6. Terminate child process, then destroy surface
        if let s = surface {
            at_surface_terminate(s)
            at_surface_destroy(s)
            surface = nil
        }
    }

    deinit {
        cleanup()
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
        do {
            self.renderer = try MetalRenderer(
                device: device,
                font: font,
                boldFont: boldFont,
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                scale: scale
            )
        } catch {
            debugLog("MetalRenderer init failed: \(error.localizedDescription). GPU rendering unavailable.")
        }

        return layer
    }

    // MARK: - Factory

    static func createTerminalPane(model: MenuItem, workingDir: String?, dangerMode: Bool = false) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.pendingLaunchModel = model
        view.pendingLaunchDir = workingDir
        view.pendingDangerMode = dangerMode
        view.appState = .terminal
        view.menuRenderPending = false
        return view
    }

    // MARK: - Focus

    func setFocused(_ focused: Bool) {
        guard let layer = layer else { return }
        if focused {
            layer.borderWidth = 1.0
            layer.borderColor = NSColor(red: 45.0/255.0, green: 127.0/255.0, blue: 212.0/255.0, alpha: 1.0).cgColor
        } else {
            layer.borderWidth = 0.0
            layer.borderColor = nil
        }
    }

    var surfacePointer: OpaquePointer? { surface }

    var currentModel: LLMModel? {
        ModelCatalog.find(activeModelName)
    }

    /// Toggle session recording on/off. Returns the saved file URL when stopping, nil when starting.
    @discardableResult
    func toggleRecording() -> URL? {
        guard let recorder = sessionRecorder else {
            // No recorder set — create one and start
            let recorder = SessionRecorder()
            sessionRecorder = recorder
            startRecording(recorder)
            return nil
        }

        if recorder.isRecording {
            return recorder.stop()
        } else {
            startRecording(recorder)
            return nil
        }
    }

    private func startRecording(_ recorder: SessionRecorder) {
        var cols: UInt32 = 80
        var rows: UInt32 = 24
        if let s = surface {
            at_surface_get_size(s, &cols, &rows)
        }
        recorder.start(
            cols: Int(cols),
            rows: Int(rows),
            model: activeModelName,
            projectPath: lastWorkingDir ?? ""
        )
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
                let danger = self.pendingDangerMode
                self.pendingDangerMode = false
                let cmdOverride = self.pendingCommandOverride
                self.pendingCommandOverride = nil
                self.launchSession(model: model, workingDir: dir, commandOverride: cmdOverride, dangerMode: danger)
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
                // Stop display link while recreating renderer to prevent
                // the callback from using the renderer mid-swap.
                stopDisplayLink()
                do {
                    renderer = try MetalRenderer(
                        device: device,
                        font: font,
                        boldFont: boldFont,
                        cellWidth: cellWidth,
                        cellHeight: cellHeight,
                        scale: scale
                    )
                } catch {
                    debugLog("MetalRenderer reinit failed: \(error.localizedDescription)")
                }
                startDisplayLink()
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

    // MARK: - Grid Size

    func recalculateGridSize() {
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

    func updateCellBuffer() {
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

    func updateFoldRegions() {
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
    func computeFoldIndicators() -> [FoldIndicator] {
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
    func applySyntaxHighlighting() -> Set<Int> {
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
    func applyDiffHighlighting() -> [Int: (UInt8, UInt8, UInt8, UInt8)] {
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
}
