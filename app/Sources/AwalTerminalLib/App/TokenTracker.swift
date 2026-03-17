import Foundation

class TokenTracker {

    static let shared = TokenTracker()

    /// Cumulative output tokens across all turns (for cost estimation).
    private(set) var totalOutput: Int = 0
    /// Last turn's input tokens — represents current context window usage.
    private(set) var currentInput: Int = 0
    /// Cumulative input tokens that were NOT cache reads (for cost: billed at full rate).
    private(set) var cumulativeInputFull: Int = 0
    /// Cumulative cache read tokens (for cost: billed at cache rate).
    private(set) var cumulativeCacheRead: Int = 0
    private(set) var conversationTurns: Int = 0
    private(set) var toolCalls: [String] = []
    private(set) var modelUsed: String = ""
    private(set) var sessionId: String = ""

    private var lastFile: String = ""
    private var lastFileSize: UInt64 = 0
    private var sessionStart: Date = Date()

    init() {}

    // MARK: - Shared Pricing

    struct ModelPricing {
        let inputPerM: Double
        let outputPerM: Double
        let cacheReadPerM: Double
    }

    static let pricing: [String: ModelPricing] = [
        "Claude": ModelPricing(inputPerM: 3.0, outputPerM: 15.0, cacheReadPerM: 0.30),
        "Gemini": ModelPricing(inputPerM: 1.25, outputPerM: 5.0, cacheReadPerM: 0.315),
        "Codex": ModelPricing(inputPerM: 2.50, outputPerM: 10.0, cacheReadPerM: 0.0),
    ]

    static func estimateCost(model: String, inputFull: Int, cacheRead: Int, output: Int) -> Double {
        guard let pricing = Self.pricing[model] else { return 0 }
        let inputCost = Double(inputFull) / 1_000_000.0 * pricing.inputPerM
        let cacheCost = Double(cacheRead) / 1_000_000.0 * pricing.cacheReadPerM
        let outputCost = Double(output) / 1_000_000.0 * pricing.outputPerM
        return inputCost + cacheCost + outputCost
    }

    var estimatedCost: Double {
        Self.estimateCost(model: modelUsed, inputFull: cumulativeInputFull, cacheRead: cumulativeCacheRead, output: totalOutput)
    }

    /// Find the Claude projects directory for a given working path.
    static func claudeProjectDir(for projectPath: String) -> URL? {
        let dirName = projectPath
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
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

        var outputTotal = 0
        var inputFullTotal = 0   // non-cache input tokens (cumulative, for cost)
        var cacheReadTotal = 0   // cache read tokens (cumulative, for cost)
        var lastTurnInput = 0    // last turn's total input (= current context usage)
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
                        let input = usage["input_tokens"] as? Int ?? 0
                        let output = usage["output_tokens"] as? Int ?? 0
                        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                        let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0

                        // Current context = input + cache_read + cache_create for this turn
                        // (each API call reports the full context size for that request)
                        lastTurnInput = input + cacheRead + cacheCreate

                        // For cost: input_tokens are billed at full rate,
                        // cache_read at reduced rate, cache_create at full rate
                        inputFullTotal += input + cacheCreate
                        cacheReadTotal += cacheRead
                        outputTotal += output
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
        currentInput = lastTurnInput
        cumulativeInputFull = inputFullTotal
        cumulativeCacheRead = cacheReadTotal
        totalOutput = outputTotal
        conversationTurns = turns
        toolCalls = tools
        modelUsed = model
        sessionId = sid
    }

    var displayString: String {
        guard currentInput > 0 || totalOutput > 0 else { return "" }
        return "\(formatTokenCount(currentInput)) ctx · \(formatTokenCount(totalOutput)) out"
    }

    func reset() {
        currentInput = 0
        cumulativeInputFull = 0
        cumulativeCacheRead = 0
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
