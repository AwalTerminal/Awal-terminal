import Foundation

/// A single completion suggestion.
struct Completion {
    let text: String       // The full completion text
    let display: String    // Display text in popup
    let detail: String     // Secondary description
    let icon: String       // SF Symbol name or emoji
    let insertText: String // Text to insert (remaining chars after prefix)
}

/// Protocol for completion providers.
protocol CompletionProvider {
    func completions(for input: String, cursorPos: Int) -> [Completion]
}

/// Provides file path completions.
class FilePathProvider: CompletionProvider {
    func completions(for input: String, cursorPos: Int) -> [Completion] {
        // Extract the path token being typed
        let prefix = String(input.prefix(cursorPos))
        guard let pathStart = findPathStart(in: prefix) else { return [] }
        let pathPrefix = String(prefix[prefix.index(prefix.startIndex, offsetBy: pathStart)...])

        guard pathPrefix.contains("/") || pathPrefix.hasPrefix("./") || pathPrefix.hasPrefix("~") else {
            return []
        }

        // Expand ~ to home directory
        var expandedPath = pathPrefix
        if expandedPath.hasPrefix("~") {
            expandedPath = (expandedPath as NSString).expandingTildeInPath
        }

        let fm = FileManager.default
        let isDir = expandedPath.hasSuffix("/")

        let directory: String
        let namePrefix: String

        if isDir {
            directory = expandedPath
            namePrefix = ""
        } else {
            directory = (expandedPath as NSString).deletingLastPathComponent
            namePrefix = (expandedPath as NSString).lastPathComponent
        }

        guard fm.fileExists(atPath: directory) else { return [] }

        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        let matching = contents
            .filter { namePrefix.isEmpty || $0.lowercased().hasPrefix(namePrefix.lowercased()) }
            .filter { !$0.hasPrefix(".") || namePrefix.hasPrefix(".") }
            .sorted()
            .prefix(8)

        return matching.map { name in
            let fullPath = (directory as NSString).appendingPathComponent(name)
            var isDirEntry: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDirEntry)
            let icon = isDirEntry.boolValue ? "folder" : "doc"

            // Calculate insert text: what needs to be appended
            let insert: String
            if namePrefix.isEmpty {
                insert = name
            } else {
                insert = String(name.dropFirst(namePrefix.count))
            }

            return Completion(
                text: name,
                display: name,
                detail: isDirEntry.boolValue ? "Directory" : "File",
                icon: icon,
                insertText: insert + (isDirEntry.boolValue ? "/" : "")
            )
        }
    }

    private func findPathStart(in text: String) -> Int? {
        // Walk backwards from end to find start of path token
        var i = text.count - 1
        for ch in text.reversed() {
            if ch == " " || ch == "'" || ch == "\"" || ch == "(" || ch == ")" || ch == ";" || ch == "|" || ch == "&" {
                return i + 1
            }
            i -= 1
        }
        return 0
    }
}

/// Provides history-based completions.
class HistoryProvider: CompletionProvider {
    static let shared = HistoryProvider()

    private var commandHistory: [String] = []
    private let maxHistory = 500

    func recordCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Remove duplicates, keep most recent
        commandHistory.removeAll { $0 == trimmed }
        commandHistory.insert(trimmed, at: 0)
        if commandHistory.count > maxHistory {
            commandHistory.removeLast()
        }
    }

    func completions(for input: String, cursorPos: Int) -> [Completion] {
        let prefix = String(input.prefix(cursorPos)).trimmingCharacters(in: .whitespaces)
        guard prefix.count >= 2 else { return [] }

        let lower = prefix.lowercased()
        let matches = commandHistory
            .filter { $0.lowercased().hasPrefix(lower) && $0 != prefix }
            .prefix(5)

        return matches.map { cmd in
            let insert = String(cmd.dropFirst(prefix.count))
            return Completion(
                text: cmd,
                display: cmd,
                detail: "History",
                icon: "clock",
                insertText: insert
            )
        }
    }
}
