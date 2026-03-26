import AppKit
import CAwalTerminal

// MARK: - Drag and Drop

extension TerminalView {

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

    func shellEscape(_ path: String) -> String {
        // Wrap in single quotes, escaping any internal single quotes
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
