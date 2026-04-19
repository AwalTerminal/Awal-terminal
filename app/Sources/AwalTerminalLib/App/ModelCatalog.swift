import Foundation

/// How AI components are injected into a model session.
enum AIComponentInjectionStrategy {
    case claudePlugin       // Symlink to ~/.claude/plugins/ + enabledPlugins
    case systemInstruction  // --system-instruction-file flag (Gemini)
    case instructionsFlag   // Reserved for CLI instruction flags
    case none               // No injection (Shell, unknown)
}

struct LLMModel {
    let name: String
    let provider: String
    let command: String
    let configPath: String?
    let installCommand: String?
    let contextWindow: Int
    let resumeCommand: String?
    let injectionStrategy: AIComponentInjectionStrategy
    /// CLI flag to skip permission prompts (danger mode). Nil if model doesn't support it.
    let dangerFlag: String?
    /// CLI flag to enable remote control. Nil if model doesn't support it.
    let remoteControlFlag: String?

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
        LLMModel(name: "Claude",   provider: "Anthropic",       command: "claude",              configPath: "~/.claude/settings.json",       installCommand: "npm install -g @anthropic-ai/claude-code",  contextWindow: 200_000, resumeCommand: "claude --resume",  injectionStrategy: .claudePlugin,       dangerFlag: "--dangerously-skip-permissions", remoteControlFlag: "--remote-control"),
        LLMModel(name: "Gemini",   provider: "Google",          command: "gemini",              configPath: "~/.config/gemini/settings.json", installCommand: "npm install -g @google/gemini-cli",        contextWindow: 1_000_000, resumeCommand: "gemini --resume", injectionStrategy: .systemInstruction, dangerFlag: "--yolo", remoteControlFlag: nil),
        LLMModel(name: "Codex",    provider: "OpenAI",          command: "codex",               configPath: nil,                             installCommand: "npm install -g @openai/codex",             contextWindow: 200_000, resumeCommand: "codex resume",     injectionStrategy: .instructionsFlag,   dangerFlag: "--full-auto", remoteControlFlag: nil),
        LLMModel(name: "Copilot",  provider: "GitHub",          command: "copilot",             configPath: "~/.copilot/config.json",        installCommand: "npm install -g @github/copilot",           contextWindow: 200_000, resumeCommand: "copilot --resume", injectionStrategy: .instructionsFlag,   dangerFlag: "--allow-all", remoteControlFlag: nil),
        LLMModel(name: "Shell",    provider: "Terminal",         command: "",                    configPath: nil,                             installCommand: nil,                                        contextWindow: 0, resumeCommand: nil,                      injectionStrategy: .none,               dangerFlag: nil, remoteControlFlag: nil),
    ]

    static var configurable: [LLMModel] { all.filter { $0.hasConfig } }

    static func find(_ name: String) -> LLMModel? {
        all.first { $0.name == name }
    }
}
