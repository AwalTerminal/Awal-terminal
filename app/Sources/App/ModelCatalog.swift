import Foundation

struct LLMModel {
    let name: String
    let provider: String
    let command: String
    let configPath: String?
    let installCommand: String?
    let contextWindow: Int

    var hasConfig: Bool { configPath != nil }
    var storageKey: String { name.lowercased() }

    var binaryName: String? {
        let bin = command.split(separator: " ").first.map(String.init)
        return bin?.isEmpty == true ? nil : bin
    }

    var configExtension: String? {
        guard let p = configPath else { return nil }
        return (p as NSString).pathExtension.lowercased()
    }

    var expandedConfigPath: String? {
        guard let p = configPath else { return nil }
        return p.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}

enum ModelCatalog {
    static let all: [LLMModel] = [
        LLMModel(name: "Claude",   provider: "Anthropic",       command: "claude",              configPath: "~/.claude/settings.json",       installCommand: "npm install -g @anthropic-ai/claude-code",  contextWindow: 200_000),
        LLMModel(name: "Gemini",   provider: "Google",          command: "gemini",              configPath: "~/.config/gemini/settings.json", installCommand: "npm install -g @google/gemini-cli",        contextWindow: 1_000_000),
        LLMModel(name: "Codex",    provider: "OpenAI",          command: "codex",               configPath: nil,                             installCommand: "npm install -g @openai/codex",             contextWindow: 200_000),
        LLMModel(name: "Shell",    provider: "Terminal",         command: "",                    configPath: nil,                             installCommand: nil,                                        contextWindow: 0),
    ]

    static var configurable: [LLMModel] { all.filter { $0.hasConfig } }

    static func find(_ name: String) -> LLMModel? {
        all.first { $0.name == name }
    }
}
