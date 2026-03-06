import Foundation

class TokenTracker {

    static let shared = TokenTracker()

    private(set) var totalInput: Int = 0
    private(set) var totalOutput: Int = 0
    private(set) var conversationTurns: Int = 0
    private(set) var toolCalls: [String] = []
    private(set) var modelUsed: String = ""
    private(set) var sessionId: String = ""

    private var lastFile: String = ""
    private var lastFileSize: UInt64 = 0
    private var sessionStart: Date = Date()

    private init() {}

    /// Find the Claude projects directory for a given working path.
    static func claudeProjectDir(for projectPath: String) -> URL? {
        let dirName = projectPath.replacingOccurrences(of: "/", with: "-")
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(dirName)")
        return FileManager.default.fileExists(atPath: claudeDir.path) ? claudeDir : nil
    }

    func update(projectPath: String?) {
        guard let projectPath = projectPath, !projectPath.isEmpty else { return }

        guard let claudeDir = Self.claudeProjectDir(for: projectPath) else { return }

        // Find most recently modified .jsonl file
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: claudeDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let jsonlFiles = contents.filter { $0.pathExtension == "jsonl" }
        guard !jsonlFiles.isEmpty else { return }

        let sorted = jsonlFiles.compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }

        guard let latestURL = sorted.first?.0 else { return }
        let latestPath = latestURL.path

        // Check file size to skip re-parsing if unchanged
        guard let attrs = try? fm.attributesOfItem(atPath: latestPath),
              let fileSize = attrs[.size] as? UInt64 else { return }

        if latestPath == lastFile && fileSize == lastFileSize {
            return
        }

        // Parse the JSONL file
        guard let data = fm.contents(atPath: latestPath),
              let text = String(data: data, encoding: .utf8) else { return }

        var inputTotal = 0
        var outputTotal = 0
        var turns = 0
        var tools: [String] = []
        var model = ""
        let sessionFile = (latestPath as NSString).lastPathComponent
        let sid = (sessionFile as NSString).deletingPathExtension

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            // Skip messages from before the current session
            if let ts = json["timestamp"] as? String,
               let date = dateFormatter.date(from: ts),
               date < sessionStart {
                continue
            }

            let type = json["type"] as? String ?? ""

            if type == "assistant" {
                turns += 1

                if let message = json["message"] as? [String: Any] {
                    // Extract model
                    if let m = message["model"] as? String, !m.isEmpty {
                        model = m
                    }

                    // Extract usage
                    if let usage = message["usage"] as? [String: Any] {
                        if let input = usage["input_tokens"] as? Int {
                            inputTotal += input
                        }
                        if let output = usage["output_tokens"] as? Int {
                            outputTotal += output
                        }
                        if let cacheRead = usage["cache_read_input_tokens"] as? Int {
                            inputTotal += cacheRead
                        }
                        if let cacheCreate = usage["cache_creation_input_tokens"] as? Int {
                            inputTotal += cacheCreate
                        }
                    }

                    // Extract tool use from content blocks
                    if let content = message["content"] as? [[String: Any]] {
                        for block in content {
                            if block["type"] as? String == "tool_use",
                               let name = block["name"] as? String {
                                if !tools.contains(name) {
                                    tools.append(name)
                                }
                            }
                        }
                    }
                }
            }
        }

        lastFile = latestPath
        lastFileSize = fileSize
        totalInput = inputTotal
        totalOutput = outputTotal
        conversationTurns = turns
        toolCalls = tools
        modelUsed = model
        sessionId = sid
    }

    var displayString: String {
        guard totalInput > 0 || totalOutput > 0 else { return "" }
        return "\(formatTokenCount(totalInput)) in · \(formatTokenCount(totalOutput)) out"
    }

    func reset() {
        totalInput = 0
        totalOutput = 0
        conversationTurns = 0
        toolCalls = []
        modelUsed = ""
        sessionId = ""
        lastFile = ""
        lastFileSize = 0
        sessionStart = Date()
    }

    private func formatTokenCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            let value = Double(n) / 1_000_000.0
            return value.truncatingRemainder(dividingBy: 1.0) < 0.05
                ? String(format: "%.0fM", value)
                : String(format: "%.1fM", value)
        } else if n >= 1_000 {
            let value = Double(n) / 1_000.0
            return value.truncatingRemainder(dividingBy: 1.0) < 0.05
                ? String(format: "%.0fk", value)
                : String(format: "%.1fk", value)
        }
        return "\(n)"
    }
}
