import Foundation

/// Actions that can be triggered by voice commands.
enum VoiceAction {
    case scrollUp
    case scrollDown
    case scrollToTop
    case scrollToBottom
    case clear
    case newTab
    case closeTab
    case nextTab
    case previousTab
    case switchTab(Int)
    case splitRight
    case splitDown
    case closePane
    case toggleSidePanel
    case cancel
    case find(String)
}

/// Parses transcribed text into voice commands.
class VoiceCommandParser {

    private static let fillerWords: Set<String> = [
        "please", "um", "uh", "like", "the", "a", "an", "can", "you",
        "could", "would", "just", "go", "do", "hey", "ok", "okay",
    ]

    /// Try to parse text as a voice command. Returns nil if no command matched (dictation fallback).
    func parse(_ text: String) -> VoiceAction? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }

        // Scroll commands
        if matches(normalized, ["scroll up", "scroll higher", "page up"]) {
            return .scrollUp
        }
        if matches(normalized, ["scroll down", "scroll lower", "page down"]) {
            return .scrollDown
        }
        if matches(normalized, ["scroll top", "scroll to top", "go to top", "top"]) {
            return .scrollToTop
        }
        if matches(normalized, ["scroll bottom", "scroll to bottom", "go to bottom", "bottom"]) {
            return .scrollToBottom
        }

        // Terminal commands
        if matches(normalized, ["clear", "clear screen", "clear terminal"]) {
            return .clear
        }
        if matches(normalized, ["cancel", "stop", "interrupt", "kill"]) {
            return .cancel
        }

        // Tab commands
        if matches(normalized, ["new tab", "open tab", "create tab", "add tab"]) {
            return .newTab
        }
        if matches(normalized, ["close tab", "close this tab"]) {
            return .closeTab
        }
        if matches(normalized, ["next tab", "switch next tab", "tab right"]) {
            return .nextTab
        }
        if matches(normalized, ["previous tab", "prev tab", "last tab", "tab left"]) {
            return .previousTab
        }

        // "switch tab N" or "tab N" or "go to tab N"
        if let n = extractTabNumber(normalized) {
            return .switchTab(n)
        }

        // Split commands
        if matches(normalized, ["split right", "split horizontal", "split horizontally"]) {
            return .splitRight
        }
        if matches(normalized, ["split down", "split vertical", "split vertically"]) {
            return .splitDown
        }
        if matches(normalized, ["close pane", "close split", "close this pane"]) {
            return .closePane
        }

        // Panel
        if matches(normalized, ["toggle side panel", "side panel", "toggle panel", "show panel", "hide panel"]) {
            return .toggleSidePanel
        }

        // Find
        if normalized.hasPrefix("find ") {
            let query = String(normalized.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                return .find(query)
            }
        }
        if normalized.hasPrefix("search ") {
            let query = String(normalized.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                return .find(query)
            }
        }

        return nil
    }

    // MARK: - Private

    private func normalize(_ text: String) -> String {
        let lower = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)

        let words = lower.split(separator: " ").map(String.init)
        let filtered = words.filter { !Self.fillerWords.contains($0) }
        return filtered.joined(separator: " ")
    }

    private func matches(_ text: String, _ patterns: [String]) -> Bool {
        for pattern in patterns {
            if text == pattern { return true }
        }
        return false
    }

    private func extractTabNumber(_ text: String) -> Int? {
        // Match "switch tab 3", "tab 3", "go to tab 3"
        let patterns = [
            "switch tab ", "tab ", "go to tab ", "goto tab ",
        ]
        for prefix in patterns {
            if text.hasPrefix(prefix) {
                let numStr = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if let n = Int(numStr), n >= 1 {
                    return n
                }
                // Handle word numbers
                let wordNumbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                                   "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
                if let n = wordNumbers[numStr] {
                    return n
                }
            }
        }
        return nil
    }
}
