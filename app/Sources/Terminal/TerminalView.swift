import AppKit
import CClaudeTerminal

class TerminalView: NSView {

    // MARK: - Properties

    private var surface: OpaquePointer?
    private var readSource: DispatchSourceRead?
    private var displayLink: CVDisplayLink?

    private let cellWidth: CGFloat = 8.0
    private let cellHeight: CGFloat = 16.0
    private let font: NSFont

    private var termCols: UInt32 = 80
    private var termRows: UInt32 = 24

    private var cellBuffer: [CCell] = []
    private var cursorRow: UInt32 = 0
    private var cursorCol: UInt32 = 0
    private var cursorVisible: Bool = true
    private var cursorBlinkOn: Bool = true
    private var cursorBlinkTimer: Timer?

    // MARK: - Init

    override init(frame: NSRect) {
        self.font = NSFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)

        // Calculate cell size from font metrics
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 30.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1.0).cgColor

        // Create the terminal surface
        surface = ct_surface_new(termCols, termRows)
        cellBuffer = [CCell](repeating: CCell(), count: Int(termCols * termRows))

        // Set up cursor blink timer
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.cursorBlinkOn.toggle()
            self?.setNeedsDisplay(self?.bounds ?? .zero)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        cursorBlinkTimer?.invalidate()
        stopDisplayLink()
        if let source = readSource {
            source.cancel()
        }
        if let s = surface {
            ct_surface_destroy(s)
        }
    }

    // MARK: - View Lifecycle

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recalculateGridSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalculateGridSize()
    }

    // MARK: - Shell & PTY

    func spawnShell() {
        guard let s = surface else { return }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = shell.withCString { cstr in
            ct_surface_spawn_shell(s, cstr)
        }

        if result != 0 {
            NSLog("Failed to spawn shell")
            return
        }

        let fd = ct_surface_get_fd(s)
        if fd < 0 {
            NSLog("Invalid PTY fd")
            return
        }

        // Set up GCD source to read from PTY
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readPTY()
        }
        source.setCancelHandler { }
        source.resume()
        self.readSource = source
    }

    private func readPTY() {
        guard let s = surface else { return }

        var totalRead: Int32 = 0
        // Read in a loop to drain the buffer
        while true {
            let n = ct_surface_process_pty(s)
            if n <= 0 { break }
            totalRead += n
        }

        if totalRead > 0 {
            updateCellBuffer()
            setNeedsDisplay(bounds)
        }
    }

    // MARK: - Grid Size

    private func recalculateGridSize() {
        guard let s = surface else { return }

        let newCols = max(1, UInt32(bounds.width / cellWidth))
        let newRows = max(1, UInt32(bounds.height / cellHeight))

        if newCols != termCols || newRows != termRows {
            termCols = newCols
            termRows = newRows
            ct_surface_resize(s, termCols, termRows)
            cellBuffer = [CCell](repeating: CCell(), count: Int(termCols * termRows))
            updateCellBuffer()
            setNeedsDisplay(bounds)
        }
    }

    private func updateCellBuffer() {
        guard let s = surface else { return }

        let needed = Int(termCols * termRows)
        if cellBuffer.count < needed {
            cellBuffer = [CCell](repeating: CCell(), count: needed)
        }

        cellBuffer.withUnsafeMutableBufferPointer { ptr in
            _ = ct_surface_read_cells(s, ptr.baseAddress!, UInt32(needed))
        }

        var row: UInt32 = 0
        var col: UInt32 = 0
        var visible: Bool = true
        ct_surface_get_cursor(s, &row, &col, &visible)
        cursorRow = row
        cursorCol = col
        cursorVisible = visible
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bgColor = CGColor(red: 30.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1.0)
        ctx.setFillColor(bgColor)
        ctx.fill(bounds)

        let totalCells = Int(termCols * termRows)
        guard cellBuffer.count >= totalCells else { return }

        // Draw cells
        for row in 0..<Int(termRows) {
            for col in 0..<Int(termCols) {
                let idx = row * Int(termCols) + col
                let cell = cellBuffer[idx]

                // Cell rect (origin at top-left, but NSView is flipped=false so bottom-left)
                let x = CGFloat(col) * cellWidth
                let y = bounds.height - CGFloat(row + 1) * cellHeight

                // Draw background
                let bgR = CGFloat(cell.bg_r) / 255.0
                let bgG = CGFloat(cell.bg_g) / 255.0
                let bgB = CGFloat(cell.bg_b) / 255.0
                let cellBg = CGColor(red: bgR, green: bgG, blue: bgB, alpha: 1.0)

                // Only draw non-default backgrounds
                if cell.bg_r != 30 || cell.bg_g != 30 || cell.bg_b != 30 {
                    ctx.setFillColor(cellBg)
                    ctx.fill(CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
                }

                // Draw character
                let codepoint = cell.codepoint
                guard codepoint > 32, let scalar = Unicode.Scalar(codepoint) else { continue }

                let ch = String(Character(scalar))
                let fgR = CGFloat(cell.fg_r) / 255.0
                let fgG = CGFloat(cell.fg_g) / 255.0
                let fgB = CGFloat(cell.fg_b) / 255.0

                let isBold = (cell.attrs & 0x01) != 0
                let drawFont = isBold
                    ? NSFont.monospacedSystemFont(ofSize: 13.0, weight: .bold)
                    : font

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: drawFont,
                    .foregroundColor: NSColor(red: fgR, green: fgG, blue: fgB, alpha: 1.0),
                ]

                let str = NSAttributedString(string: ch, attributes: attrs)
                str.draw(at: NSPoint(x: x, y: y))
            }
        }

        // Draw cursor
        if cursorVisible && cursorBlinkOn {
            let cx = CGFloat(cursorCol) * cellWidth
            let cy = bounds.height - CGFloat(cursorRow + 1) * cellHeight
            let cursorRect = CGRect(x: cx, y: cy, width: cellWidth, height: cellHeight)

            ctx.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 0.7))
            ctx.fill(cursorRect)

            // Redraw the character under cursor with inverted color
            let idx = Int(cursorRow) * Int(termCols) + Int(cursorCol)
            if idx < cellBuffer.count {
                let cell = cellBuffer[idx]
                let codepoint = cell.codepoint
                if codepoint > 32, let scalar = Unicode.Scalar(codepoint) {
                    let ch = String(Character(scalar))
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: NSColor(red: 30.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1.0),
                    ]
                    let str = NSAttributedString(string: ch, attributes: attrs)
                    str.draw(at: NSPoint(x: cx, y: cy))
                }
            }
        }
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard let s = surface else { return }

        // Reset cursor blink on keypress
        cursorBlinkOn = true

        let bytes: [UInt8]

        if let chars = event.characters, !chars.isEmpty {
            let modFlags = event.modifierFlags

            // Handle special keys
            switch event.keyCode {
            case 36: // Return
                bytes = [0x0D]
            case 48: // Tab
                bytes = [0x09]
            case 51: // Backspace
                bytes = [0x7F]
            case 53: // Escape
                bytes = [0x1B]
            case 123: // Left arrow
                bytes = [0x1B, 0x5B, 0x44]
            case 124: // Right arrow
                bytes = [0x1B, 0x5B, 0x43]
            case 125: // Down arrow
                bytes = [0x1B, 0x5B, 0x42]
            case 126: // Up arrow
                bytes = [0x1B, 0x5B, 0x41]
            case 115: // Home
                bytes = [0x1B, 0x5B, 0x48]
            case 119: // End
                bytes = [0x1B, 0x5B, 0x46]
            case 116: // Page Up
                bytes = [0x1B, 0x5B, 0x35, 0x7E]
            case 121: // Page Down
                bytes = [0x1B, 0x5B, 0x36, 0x7E]
            case 117: // Delete (forward)
                bytes = [0x1B, 0x5B, 0x33, 0x7E]
            default:
                if modFlags.contains(.control) {
                    // Control key combinations
                    if let firstChar = chars.unicodeScalars.first {
                        let value = firstChar.value
                        if value >= 0x61 && value <= 0x7A {
                            // Ctrl+a through Ctrl+z
                            bytes = [UInt8(value - 0x60)]
                        } else if value >= 0x41 && value <= 0x5A {
                            bytes = [UInt8(value - 0x40)]
                        } else {
                            bytes = Array(chars.utf8)
                        }
                    } else {
                        return
                    }
                } else if modFlags.contains(.option) {
                    // Alt/Option key — send ESC prefix
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
            _ = ct_surface_key_event(s, ptr.baseAddress!, UInt32(ptr.count))
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // No-op — modifier-only changes don't send bytes
    }

    // MARK: - Display Link (unused for now, ready for Metal)

    private func startDisplayLink() {
        // Will be used for Metal rendering in Phase 1
    }

    private func stopDisplayLink() {
        // Will be used for Metal rendering in Phase 1
    }
}
