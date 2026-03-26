import AppKit
import CAwalTerminal
import Quartz

// MARK: - File Preview (Quick Look)

extension TerminalView {

    /// Extract a file path from terminal text at the given grid position.
    func detectFilePath(at col: Int, row: Int) -> String? {
        guard let s = surface else { return nil }

        // Read the text of the clicked row
        let rowStart = row * Int(termCols)
        let rowEnd = min(rowStart + Int(termCols), cellBuffer.count)
        guard rowStart >= 0, rowEnd <= cellBuffer.count else { return nil }

        var rowText = ""
        for i in rowStart..<rowEnd {
            let cp = cellBuffer[i].codepoint
            if cp == 0 { rowText.append(" ") }
            else if let scalar = Unicode.Scalar(cp) {
                rowText.append(Character(scalar))
            }
        }

        // Find path-like tokens in the row text
        // Split by whitespace and check each token
        let tokens = rowText.split(whereSeparator: { $0.isWhitespace || $0 == "'" || $0 == "\"" || $0 == "(" || $0 == ")" }).map(String.init)

        // Find which token contains the clicked column
        var offset = 0
        for token in tokens {
            let tokenRange = (rowText as NSString).range(of: token, range: NSRange(location: offset, length: rowText.count - offset))
            if tokenRange.location == NSNotFound { continue }

            let tokenStart = tokenRange.location
            let tokenEnd = tokenRange.location + tokenRange.length
            offset = tokenEnd

            // Check if click is within this token
            if col >= tokenStart && col < tokenEnd {
                return resolveFilePath(token)
            }
        }

        return nil
    }

    /// Resolve a path string to an absolute path, checking if the file exists.
    func resolveFilePath(_ pathStr: String) -> String? {
        // Strip trailing colon + line number (e.g., "file.rs:42:")
        var cleaned = pathStr
        if let colonRange = cleaned.range(of: ":\\d+", options: .regularExpression) {
            cleaned = String(cleaned[cleaned.startIndex..<colonRange.lowerBound])
        }

        // Try as absolute path
        if cleaned.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: cleaned) ? cleaned : nil
        }

        // Try relative to CWD (from OSC 7)
        if let s = surface,
           let cwdPtr = at_surface_get_working_directory(s) {
            let cwd = String(cString: cwdPtr)
            at_free_string(cwdPtr)
            if !cwd.isEmpty {
                var resolvedCwd = cwd
                // Strip file:// URI prefix if present
                if resolvedCwd.hasPrefix("file://") {
                    resolvedCwd = String(resolvedCwd.dropFirst(7))
                    // Remove hostname portion (file://hostname/path)
                    if let slashIdx = resolvedCwd.firstIndex(of: "/") {
                        resolvedCwd = String(resolvedCwd[slashIdx...])
                    }
                }
                let fullPath = (resolvedCwd as NSString).appendingPathComponent(cleaned)
                if FileManager.default.fileExists(atPath: fullPath) {
                    return fullPath
                }
            }
        }

        // Try relative to home directory for ~/... paths
        if cleaned.hasPrefix("~/") {
            let expanded = (cleaned as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
        }

        return nil
    }

    /// Show Quick Look preview panel for a file path.
    func showQuickLookPreview(for path: String) {
        quickLookItems = [URL(fileURLWithPath: path)]
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookItems = []
    }
}

// MARK: - Quick Look Data Source

extension TerminalView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookItems[index] as NSURL
    }
}
