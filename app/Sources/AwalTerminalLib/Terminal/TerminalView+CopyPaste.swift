import AppKit
import CAwalTerminal

// MARK: - Copy/Paste (Cmd+C, Cmd+V)

extension TerminalView {

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard appState == .terminal else { return super.performKeyEquivalent(with: event) }
        // Don't intercept when a sheet (e.g. alert dialog) is active on this or another window
        if window?.attachedSheet != nil || event.window != window {
            return super.performKeyEquivalent(with: event)
        }
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }

        switch event.charactersIgnoringModifiers {
        case "c":
            if event.modifierFlags.contains(.shift) {
                copySelectionAsMarkdown()
                return true
            }
            return copySelection()
        case "v":
            pasteFromClipboard()
            return true
        default:
            // Cmd+End: jump to bottom
            if event.keyCode == 119 {
                if let s = surface {
                    let offset = at_surface_get_viewport_offset(s)
                    if offset > 0 { at_surface_scroll_viewport(s, -offset) }
                    userScrolledUp = false
                    showOrHideScrollToBottom()
                    updateCellBuffer()
                    needsRender = true
                }
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    @discardableResult
    func copySelection() -> Bool {
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
    func smartStripCodeBlock(_ text: String) -> String {
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

    func copySelectionAsMarkdown() {
        guard let s = surface else { return }
        guard let cStr = at_surface_get_selected_text(s) else { return }
        let text = String(cString: cStr)
        at_free_string(cStr)
        guard !text.isEmpty else { return }

        let minRow = min(selectionStartAbsRow, selectionEndAbsRow)
        let maxRow = max(selectionStartAbsRow, selectionEndAbsRow)

        // Find regions overlapping with selection
        var overlapping: [(region: FoldRegion, startInSel: Int32, endInSel: Int32)] = []
        for region in foldRegions {
            let rStart = max(region.startRow, minRow)
            let rEnd = min(region.endRow, maxRow)
            if rStart <= rEnd {
                overlapping.append((region, rStart, rEnd))
            }
        }

        // If no regions overlap, just copy as plain text
        guard !overlapping.isEmpty else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            onCopied?()
            return
        }

        // Build markdown by processing lines with region awareness
        let lines = text.components(separatedBy: "\n")
        var markdown = ""
        var inCodeBlock = false
        var inThinking = false

        for (i, line) in lines.enumerated() {
            let absRow = minRow + Int32(i)

            // Check if we're entering/leaving a region boundary
            for (region, rStart, _) in overlapping {
                if absRow == rStart {
                    // Entering a region
                    switch region.regionType {
                    case 3: // CodeBlock
                        let lang = region.label.isEmpty ? "" : region.label
                        markdown += "```\(lang)\n"
                        inCodeBlock = true
                        continue
                    case 4: // Thinking
                        inThinking = true
                    case 1: // ToolUse
                        let cleaned = line.trimmingCharacters(in: .whitespaces)
                        markdown += "**\(cleaned)**\n"
                        continue
                    default:
                        break
                    }
                }
            }

            // Check if this line is the closing fence of a code block region
            if inCodeBlock {
                var isRegionEnd = false
                for (region, _, rEnd) in overlapping where region.regionType == 3 {
                    if absRow == rEnd {
                        isRegionEnd = true
                        break
                    }
                }
                if isRegionEnd {
                    markdown += "```\n"
                    inCodeBlock = false
                    continue
                }
                // Strip the leading box-drawing prefix from code block content
                let stripped = stripBoxDrawing(line)
                markdown += stripped + "\n"
                continue
            }

            if inThinking {
                var isRegionEnd = false
                for (region, _, rEnd) in overlapping where region.regionType == 4 {
                    if absRow == rEnd {
                        isRegionEnd = true
                        break
                    }
                }
                markdown += "> " + line + "\n"
                if isRegionEnd {
                    inThinking = false
                }
                continue
            }

            // Check for ToolOutput (type 2) — strip box-drawing chars
            var isToolOutput = false
            for (region, rStart, rEnd) in overlapping where region.regionType == 2 {
                if absRow >= rStart && absRow <= rEnd {
                    isToolOutput = true
                    break
                }
            }

            if isToolOutput {
                let stripped = stripBoxDrawing(line)
                markdown += "    " + stripped + "\n"
            } else {
                markdown += line + "\n"
            }
        }

        // Trim trailing newline
        if markdown.hasSuffix("\n") {
            markdown = String(markdown.dropLast())
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdown, forType: .string)
        onCopied?()
    }

    /// Strip common box-drawing characters from line prefixes.
    func stripBoxDrawing(_ line: String) -> String {
        var result = line
        let boxChars: [Character] = ["\u{2502}", "\u{251C}", "\u{2570}", "\u{2500}", "\u{256E}", "\u{256F}", "\u{2574}"] // │ ├ ╰ ─ ╮ ╯ ╴
        // Strip leading box-drawing + space prefix
        while let first = result.first, boxChars.contains(first) || first == " " {
            result = String(result.dropFirst())
            if result.isEmpty { break }
        }
        return result
    }

    func pasteFromClipboard() {
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
    func gatedPaste(_ text: String, completion: @escaping (String) -> Void) {
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
    func saveToFileAndPastePath(_ text: String, completion: @escaping (String) -> Void) {
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
    func formatCount(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
