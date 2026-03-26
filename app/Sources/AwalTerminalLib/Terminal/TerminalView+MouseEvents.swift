import AppKit
import CAwalTerminal

// MARK: - Mouse Events (Selection + Mouse Reporting)

extension TerminalView {

    func gridPosition(for event: NSEvent) -> (col: Int, row: Int) {
        let location = convert(event.locationInWindow, from: nil)
        // NSView coordinates: origin at bottom-left, we need top-left
        let col = max(0, min(Int(termCols) - 1, Int(location.x / cellWidth)))
        let row = max(0, min(Int(termRows) - 1, Int(termRows) - 1 - Int(location.y / cellHeight)))
        return (col, row)
    }

    /// Convert grid row to absolute row (accounting for scrollback viewport).
    func absoluteRow(gridRow: Int) -> Int32 {
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

    func sendMouseEvent(button: Int, col: Int, row: Int, release: Bool) {
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

        // Dismiss autocomplete popup on click
        hideCompletions()

        guard appState == .terminal, let s = surface else {
            super.mouseDown(with: event)
            return
        }

        // Skip selection if click is on the scroll-to-bottom button
        if let btn = scrollToBottomButton {
            let loc = convert(event.locationInWindow, from: nil)
            if btn.frame.contains(loc) {
                return
            }
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

        // Cmd+click: open hyperlink or preview file
        if event.modifierFlags.contains(.command) {
            let urlPtr = at_surface_get_hyperlink(s, UInt32(col), UInt32(row))
            if let urlPtr, let urlStr = String(cString: urlPtr, encoding: .utf8) {
                at_free_string(urlPtr)
                if let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                    return
                }
            }

            // Try to detect a file path at the click position
            if let filePath = detectFilePath(at: col, row: row) {
                showQuickLookPreview(for: filePath)
                return
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
            // Don't start selection on single click — defer to mouseDragged
            pendingSelectionCol = UInt32(col)
            pendingSelectionRow = absRow
            selectionStartedByDrag = false
            // Clear any existing selection so the old highlight disappears
            at_surface_clear_selection(s)
        }
        updateCellBuffer()
        needsRender = true
    }

    func startAutoScroll(delta: Int) {
        guard autoScrollDelta != delta else { return }
        stopAutoScroll()
        autoScrollDelta = delta
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.autoScrollTick()
        }
    }

    func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDelta = 0
    }

    func showOrHideScrollToBottom() {
        if userScrolledUp {
            if scrollToBottomButton == nil {
                let button = ScrollToBottomButton()
                button.onScrollToBottom = { [weak self] in
                    self?.scrollToBottom()
                }
                addSubview(button)
                button.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                    button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -40),
                ])
                button.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    button.animator().alphaValue = 1
                }
                scrollToBottomButton = button
            }
        } else {
            if let button = scrollToBottomButton {
                scrollToBottomButton = nil
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    button.animator().alphaValue = 0
                }, completionHandler: {
                    button.removeFromSuperview()
                })
            }
        }
    }

    func showZoomHUD() {
        if zoomHUD == nil {
            let hud = ZoomHUDView()
            addSubview(hud)
            hud.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hud.centerXAnchor.constraint(equalTo: centerXAnchor),
                hud.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            zoomHUD = hud
        }
        let percent = Int(round((font.pointSize / baseFontSize) * 100))
        zoomHUD?.show(zoomPercent: percent)
    }

    func setRecordingIndicatorVisible(_ visible: Bool) {
        if visible {
            guard recordingIndicator == nil else { return }
            let indicator = RecordingIndicatorView()
            addSubview(indicator)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                indicator.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
            indicator.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                indicator.animator().alphaValue = 1
            }
            recordingIndicator = indicator
        } else {
            if let indicator = recordingIndicator {
                recordingIndicator = nil
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    indicator.animator().alphaValue = 0
                }, completionHandler: {
                    indicator.removeFromSuperview()
                })
            }
        }
    }

    func scrollToBottom() {
        guard let s = surface else { return }
        let offset = at_surface_get_viewport_offset(s)
        if offset > 0 { at_surface_scroll_viewport(s, -offset) }
        userScrolledUp = false
        showOrHideScrollToBottom()
        updateCellBuffer()
        needsRender = true
    }

    func autoScrollTick() {
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
            let absRow = absoluteRow(gridRow: row)
            // Only start selection once the mouse moves to a different cell
            if !selectionStartedByDrag {
                if UInt32(col) == pendingSelectionCol && absRow == pendingSelectionRow {
                    return
                }
                at_surface_start_selection(s, pendingSelectionCol, pendingSelectionRow)
                selectionStartedByDrag = true
            }
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

        // Clear selection if no drag, or if drag ended on the same cell (micro-movement)
        let absRow = absoluteRow(gridRow: row)
        if !selectionStartedByDrag
            || (UInt32(col) == pendingSelectionCol && absRow == pendingSelectionRow)
        {
            at_surface_clear_selection(s)
            updateCellBuffer()
            needsRender = true
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
            showContextMenu(for: event)
        }
    }

    func showContextMenu(for event: NSEvent) {
        let menu = NSMenu()

        // Check if there's a selection
        let hasSelection: Bool
        if let s = surface, let cStr = at_surface_get_selected_text(s) {
            let text = String(cString: cStr)
            at_free_string(cStr)
            hasSelection = !text.isEmpty
        } else {
            hasSelection = false
        }

        if hasSelection {
            let copyItem = NSMenuItem(title: "Copy", action: #selector(contextCopy(_:)), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)

            let copyMdItem = NSMenuItem(title: "Copy as Markdown", action: #selector(contextCopyAsMarkdown(_:)), keyEquivalent: "")
            copyMdItem.target = self
            menu.addItem(copyMdItem)

            menu.addItem(NSMenuItem.separator())
        }

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(contextPaste(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc func contextCopy(_ sender: Any?) {
        _ = copySelection()
    }

    @objc func contextCopyAsMarkdown(_ sender: Any?) {
        copySelectionAsMarkdown()
    }

    @objc func contextPaste(_ sender: Any?) {
        pasteFromClipboard()
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

    func selectWord(at col: Int, row: Int32) {
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
}
