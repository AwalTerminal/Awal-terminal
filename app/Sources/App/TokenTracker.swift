import Foundation

class TokenTracker {

    static let shared = TokenTracker()

    private(set) var totalInput: Int = 0
    private(set) var totalOutput: Int = 0

    private var lastFile: String = ""
    private var lastFileSize: UInt64 = 0

    private init() {}

    func update(projectPath: String?) {
        guard let projectPath = projectPath, !projectPath.isEmpty else { return }

        // Convert project path to Claude's dir format: /Users/foo/Bar → -Users-foo-Bar
        let dirName = projectPath.replacingOccurrences(of: "/", with: "-")
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(dirName)")

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

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

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

        lastFile = latestPath
        lastFileSize = fileSize
        totalInput = inputTotal
        totalOutput = outputTotal
    }

    var displayString: String {
        guard totalInput > 0 || totalOutput > 0 else { return "" }
        return "\(formatTokenCount(totalInput)) in · \(formatTokenCount(totalOutput)) out"
    }

    func reset() {
        totalInput = 0
        totalOutput = 0
        lastFile = ""
        lastFileSize = 0
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
