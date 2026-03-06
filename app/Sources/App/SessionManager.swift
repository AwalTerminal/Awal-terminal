import Foundation

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
