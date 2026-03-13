import Foundation
import os.log

private let sessionLog = OSLog(subsystem: "com.awal.terminal", category: "SessionDiscovery")

/// Manages session state: save/restore, JSONL session listing, and session metadata.
class SessionManager {

    static let shared = SessionManager()

    private let sessionsDir: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDir = appSupport.appendingPathComponent("Awal Terminal/sessions")
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    // MARK: - Session Metadata

    struct SessionInfo: Codable {
        let id: String
        let model: String
        let projectPath: String
        let startedAt: Date
        let lastActiveAt: Date
        let inputTokens: Int
        let outputTokens: Int
        let turns: Int
        let jsonlPath: String?
    }

    /// Save session metadata to disk.
    func saveSession(_ info: SessionInfo) {
        let file = sessionsDir.appendingPathComponent("\(info.id).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(info) {
            try? data.write(to: file)
        }
    }

    /// Load all saved sessions, sorted by most recent.
    func loadSessions() -> [SessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SessionInfo? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SessionInfo.self, from: data)
            }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    /// Delete a saved session.
    func deleteSession(id: String) {
        let file = sessionsDir.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Claude JSONL Session Discovery

    /// List all Claude Code sessions for a project path.
    func listClaudeSessions(projectPath: String) -> [ClaudeSession] {
        guard let claudeDir = TokenTracker.claudeProjectDir(for: projectPath) else {
            return []
        }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: claudeDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> ClaudeSession? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let date = values.contentModificationDate,
                      let size = values.fileSize else { return nil }

                let filename = (url.lastPathComponent as NSString).deletingPathExtension
                return ClaudeSession(
                    id: filename,
                    path: url.path,
                    lastModified: date,
                    fileSize: size
                )
            }
            .sorted { $0.lastModified > $1.lastModified }
    }

    struct ClaudeSession {
        let id: String
        let path: String
        let lastModified: Date
        let fileSize: Int
    }

    /// Parse a Claude JSONL session to extract summary info.
    func parseClaudeSession(_ session: ClaudeSession) -> ClaudeSessionSummary? {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: session.path),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var inputTokens = 0
        var outputTokens = 0
        var turns = 0
        var model = ""
        var toolNames: Set<String> = []
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            // Parse timestamp
            if let ts = json["timestamp"] as? String {
                if let date = dateFormatter.date(from: ts) {
                    if firstTimestamp == nil { firstTimestamp = date }
                    lastTimestamp = date
                }
            }

            let type = json["type"] as? String ?? ""

            if type == "assistant", let message = json["message"] as? [String: Any] {
                turns += 1

                if let m = message["model"] as? String, !m.isEmpty {
                    model = m
                }

                if let usage = message["usage"] as? [String: Any] {
                    inputTokens += usage["input_tokens"] as? Int ?? 0
                    outputTokens += usage["output_tokens"] as? Int ?? 0
                    inputTokens += usage["cache_read_input_tokens"] as? Int ?? 0
                    inputTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
                }

                if let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        if block["type"] as? String == "tool_use",
                           let name = block["name"] as? String {
                            toolNames.insert(name)
                        }
                    }
                }
            }
        }

        return ClaudeSessionSummary(
            id: session.id,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            turns: turns,
            toolsUsed: Array(toolNames).sorted(),
            startedAt: firstTimestamp,
            lastActiveAt: lastTimestamp,
            fileSize: session.fileSize
        )
    }

    // MARK: - Resume Session Discovery

    struct ResumeEntry {
        let modelName: String
        let provider: String
        let sessionId: String?
        let projectPath: String?
        let summary: String
        let isInteractive: Bool
    }

    func discoverResumableSessions(for projectPath: String) -> [ResumeEntry] {
        os_log(.debug, log: sessionLog, "discoverResumableSessions for: %{public}@", projectPath)
        var entries: [ResumeEntry] = []

        // Claude: list sessions for this project path
        let sessions = listClaudeSessions(projectPath: projectPath)
        os_log(.debug, log: sessionLog, "Claude sessions found: %d", sessions.count)
        if let latest = sessions.first {
            let approxTurns = max(1, latest.fileSize / 2048)
            let timeAgo = relativeTimeString(latest.lastModified)
            entries.append(ResumeEntry(
                modelName: "Claude", provider: "Anthropic",
                sessionId: latest.id, projectPath: projectPath,
                summary: "~\(approxTurns) turns \u{00b7} \(timeAgo)",
                isInteractive: false
            ))
        }

        // Codex: show interactive resume if binary exists
        if binaryExists("codex") {
            entries.append(ResumeEntry(
                modelName: "Codex", provider: "OpenAI",
                sessionId: nil, projectPath: projectPath,
                summary: "Resume interactive session",
                isInteractive: true
            ))
        }

        // Gemini: list sessions for this project path
        os_log(.debug, log: sessionLog, "Gemini binary exists: %{public}@", binaryExists("gemini") ? "yes" : "no")
        if binaryExists("gemini") {
            let geminiEntries = listGeminiSessions(projectPath: projectPath)
            os_log(.debug, log: sessionLog, "Gemini entries: %d", geminiEntries.count)
            entries.append(contentsOf: geminiEntries)
        }

        os_log(.debug, log: sessionLog, "Total entries: %d", entries.count)
        return entries
    }

    // MARK: - Gemini Session Discovery

    func listGeminiSessions(projectPath: String?) -> [ResumeEntry] {
        guard let bin = binaryPath("gemini") else {
            os_log(.debug, log: sessionLog, "Gemini binary not found")
            return []
        }
        os_log(.debug, log: sessionLog, "Gemini binary: %{public}@, projectPath: %{public}@", bin, projectPath ?? "nil")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "cd \(projectPath ?? ".") && \(bin) --list-sessions 2>/dev/null"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch {
            os_log(.error, log: sessionLog, "Gemini process launch failed: %{public}@", error.localizedDescription)
            return []
        }

        // Read output concurrently to avoid pipe buffer deadlock
        var outputData = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global().async {
            outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        // Timeout after 10 seconds
        let deadline = DispatchTime.now() + .seconds(10)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            os_log(.debug, log: sessionLog, "Gemini process timed out")
            return []
        }
        readGroup.wait()

        guard let output = String(data: outputData, encoding: .utf8) else {
            os_log(.debug, log: sessionLog, "Gemini output not decodable")
            return []
        }
        os_log(.debug, log: sessionLog, "Gemini output: %{public}@", output)

        // Parse lines like: "  1. hello (4 hours ago) [uuid]"
        var entries: [ResumeEntry] = []
        guard let regex = try? NSRegularExpression(pattern: #"^\s*(\d+)\.\s+(.+?)\s+\((.+?)\)\s+\[(.+?)\]"#) else {
            return []
        }
        for line in output.split(separator: "\n") {
            let str = String(line)
            guard let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
                  match.numberOfRanges >= 5 else { continue }
            let number = String(str[Range(match.range(at: 1), in: str)!])
            let title = String(str[Range(match.range(at: 2), in: str)!])
            let timeAgo = String(str[Range(match.range(at: 3), in: str)!])
            entries.append(ResumeEntry(
                modelName: "Gemini", provider: "Google",
                sessionId: number,
                projectPath: projectPath,
                summary: "\(title) \u{00b7} \(timeAgo)",
                isInteractive: false
            ))
        }
        os_log(.debug, log: sessionLog, "Gemini found %d sessions", entries.count)
        return entries
    }

    private func binaryPath(_ name: String) -> String? {
        for dir in ["/usr/local/bin", "/opt/homebrew/bin"] {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private func binaryExists(_ name: String) -> Bool {
        binaryPath(name) != nil
    }

    private func relativeTimeString(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }

    struct ClaudeSessionSummary {
        let id: String
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let turns: Int
        let toolsUsed: [String]
        let startedAt: Date?
        let lastActiveAt: Date?
        let fileSize: Int
    }
}
