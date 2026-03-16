import AppKit

/// Type of registry source.
enum RegistryType: String {
    case git = "git"
    case localskills = "localskills"
    case local = "local"
}

/// Configuration for a single AI component registry.
struct RegistryConfig {
    let name: String
    let url: String
    let branch: String
    var tag: String? = nil
    var type: RegistryType = .git
    var slugs: [String] = []
    var path: String? = nil
    var mapping: String = "auto"  // "auto" | "standard" | "custom"
}

/// Application configuration loaded from ~/.config/awal/config.toml
struct AppConfig {

    // Font
    var fontFamily: String = ""
    var fontSize: CGFloat = 13.0

    // Theme colors
    var themeBg: NSColor = NSColor(red: 45.0/255.0, green: 48.0/255.0, blue: 57.0/255.0, alpha: 1)
    var themeFg: NSColor = NSColor(white: 0.85, alpha: 1)
    var themeCursor: NSColor = NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 0.7)
    var themeSelection: NSColor = NSColor(red: 45.0/255.0, green: 127.0/255.0, blue: 212.0/255.0, alpha: 0.3)
    var themeAccent: NSColor = NSColor(red: 45.0/255.0, green: 127.0/255.0, blue: 212.0/255.0, alpha: 1)
    var themeTabBarBg: NSColor = NSColor(red: 22.0/255.0, green: 22.0/255.0, blue: 22.0/255.0, alpha: 1)
    var themeTabActiveBg: NSColor = NSColor(red: 35.0/255.0, green: 35.0/255.0, blue: 35.0/255.0, alpha: 1)
    var themeStatusBarBg: NSColor = NSColor(red: 22.0/255.0, green: 22.0/255.0, blue: 22.0/255.0, alpha: 1)

    // ANSI colors (0-15)
    var ansiColors: [NSColor] = defaultAnsiColors

    // Keybindings: action -> key combo string (e.g. "cmd+shift+]")
    var keybindings: [String: String] = [:]

    // Voice
    var voiceEnabled: Bool = false
    var voiceMode: String = "push_to_talk"
    var voicePushToTalkKey: String = "ctrl+shift+space"
    var voiceVadThreshold: Float = 0.02
    var voiceLanguage: String = "en"
    var voiceWhisperModel: String = "tiny.en"
    var voiceDictationAutoEnter: Bool = false
    var voiceDictationAutoSpace: Bool = true
    var voiceCommandPrefix: String = ""
    var voiceWakeWord: String = "hey terminal"

    // Paste
    var pasteWarningThreshold: Int = 100_000
    var pasteTruncateLength: Int = 10_000

    // Tabs
    var tabsRandomColors: Bool = false
    var tabsRandomColorPalette: [NSColor] = []
    var tabsConfirmClose: Bool = false
    var tabsWorktreeIsolation: Bool = true
    var tabsWorktreeBranchPrefix: String = "awal/tab"
    var quitConfirmClose: Bool = true

    // AI Components
    var aiComponentsEnabled: Bool = true
    var aiComponentsAutoDetect: Bool = true
    var aiComponentsAutoSync: Bool = true
    var aiComponentsSyncInterval: Int = 3600
    var aiComponentRegistries: [RegistryConfig] = [
        RegistryConfig(name: "awal-components", url: "https://github.com/AwalTerminal/awal-ai-components-registry.git", branch: "main"),
    ]
    var aiComponentsDisabled: Set<String> = []
    var aiComponentsSecurityScan: Bool = true
    var aiComponentsBlockCritical: Bool = true
    var aiComponentsRequireHookApproval: Bool = true

    // Danger Mode (skip AI tool confirmation prompts)
    var dangerModeEnabled: Bool = false

    // AI Components Export
    var aiComponentsExportEnabled: Bool = false
    var aiComponentsExportFormats: [String] = []
    var aiComponentsExportTarget: String = "cache"

    private var aiComponentOverrides: [String: Set<String>] = [:]

    /// Get stack overrides for a specific project path.
    func aiComponentOverride(for projectPath: String) -> Set<String>? {
        aiComponentOverrides[projectPath]
    }

    /// Parse a keybinding string like "cmd+shift+d" into (keyEquivalent, modifierMask).
    static func parseKeybinding(_ combo: String) -> (String, NSEvent.ModifierFlags)? {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var mods: NSEvent.ModifierFlags = []
        var key = ""

        for part in parts {
            switch part {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: key = part
            }
        }

        guard !key.isEmpty else { return nil }
        return (key, mods)
    }

    private(set) static var shared = load()

    static func reload() {
        shared = load()
    }

    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/awal")
    private static let configFile = configDir.appendingPathComponent("config.toml")

    static func load() -> AppConfig {
        var config = AppConfig()

        guard let contents = try? String(contentsOf: configFile, encoding: .utf8) else {
            return config
        }

        let parsed = parseToml(contents)

        // Font
        if let family = parsed["font.family"] {
            config.fontFamily = family
        }
        if let sizeStr = parsed["font.size"], let size = Double(sizeStr) {
            config.fontSize = CGFloat(size)
        }

        // Theme colors
        if let v = parsed["theme.bg"] { config.themeBg = parseColor(v) ?? config.themeBg }
        if let v = parsed["theme.fg"] { config.themeFg = parseColor(v) ?? config.themeFg }
        if let v = parsed["theme.cursor"] { config.themeCursor = parseColor(v) ?? config.themeCursor }
        if let v = parsed["theme.selection"] { config.themeSelection = parseColor(v) ?? config.themeSelection }
        if let v = parsed["theme.accent"] { config.themeAccent = parseColor(v) ?? config.themeAccent }
        if let v = parsed["theme.tab_bar_bg"] { config.themeTabBarBg = parseColor(v) ?? config.themeTabBarBg }
        if let v = parsed["theme.tab_active_bg"] { config.themeTabActiveBg = parseColor(v) ?? config.themeTabActiveBg }
        if let v = parsed["theme.status_bar_bg"] { config.themeStatusBarBg = parseColor(v) ?? config.themeStatusBarBg }

        // ANSI colors
        for i in 0..<16 {
            if let v = parsed["colors.\(i)"], let c = parseColor(v) {
                config.ansiColors[i] = c
            }
        }

        // Keybindings
        for (key, value) in parsed where key.hasPrefix("keybindings.") {
            let action = String(key.dropFirst("keybindings.".count))
            config.keybindings[action] = value
        }

        // Voice
        if let v = parsed["voice.enabled"] { config.voiceEnabled = v == "true" }
        if let v = parsed["voice.mode"] { config.voiceMode = v }
        if let v = parsed["voice.push_to_talk_key"] { config.voicePushToTalkKey = v }
        if let v = parsed["voice.vad_threshold"], let f = Float(v) { config.voiceVadThreshold = f }
        if let v = parsed["voice.language"] { config.voiceLanguage = v }
        if let v = parsed["voice.whisper_model"] { config.voiceWhisperModel = v }
        if let v = parsed["voice.dictation_auto_enter"] { config.voiceDictationAutoEnter = v == "true" }
        if let v = parsed["voice.dictation_auto_space"] { config.voiceDictationAutoSpace = v == "true" || v.isEmpty }
        if let v = parsed["voice.command_prefix"] { config.voiceCommandPrefix = v }
        if let v = parsed["voice.wake_word"] { config.voiceWakeWord = v }

        // Paste
        if let v = parsed["paste.warning_threshold"], let n = Int(v) { config.pasteWarningThreshold = n }
        if let v = parsed["paste.truncate_length"], let n = Int(v) { config.pasteTruncateLength = n }

        // Tabs
        if let v = parsed["tabs.random_colors"] { config.tabsRandomColors = v == "true" }
        if let v = parsed["tabs.confirm_close"] { config.tabsConfirmClose = v == "true" }
        if let v = parsed["tabs.worktree_isolation"] { config.tabsWorktreeIsolation = v == "true" }
        if let v = parsed["tabs.worktree_branch_prefix"] { config.tabsWorktreeBranchPrefix = v }
        if let v = parsed["quit.confirm_close"] { config.quitConfirmClose = v == "true" }
        if let v = parsed["tabs.random_color_palette"] {
            config.tabsRandomColorPalette = v.split(separator: ",")
                .compactMap { parseColor(String($0)) }
        }

        // Danger mode
        if let v = parsed["ai_components.danger_mode"] { config.dangerModeEnabled = v == "true" }

        // AI Components
        if let v = parsed["ai_components.enabled"] { config.aiComponentsEnabled = v == "true" }
        if let v = parsed["ai_components.auto_detect"] { config.aiComponentsAutoDetect = v == "true" }
        if let v = parsed["ai_components.auto_sync"] { config.aiComponentsAutoSync = v == "true" }
        if let v = parsed["ai_components.sync_interval"], let n = Int(v) { config.aiComponentsSyncInterval = n }

        // Disabled components
        if let v = parsed["ai_components.disabled"] {
            config.aiComponentsDisabled = Set(
                v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            )
        }

        // Security scanning
        if let v = parsed["ai_components.security_scan"] { config.aiComponentsSecurityScan = v == "true" }
        if let v = parsed["ai_components.block_critical"] { config.aiComponentsBlockCritical = v == "true" }
        if let v = parsed["ai_components.require_hook_approval"] { config.aiComponentsRequireHookApproval = v == "true" }

        // Export settings
        if let v = parsed["ai_components.export.enabled"] { config.aiComponentsExportEnabled = v == "true" }
        if let v = parsed["ai_components.export.formats"] {
            config.aiComponentsExportFormats = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let v = parsed["ai_components.export.target"] { config.aiComponentsExportTarget = v }

        // Parse AI component registries: ai_components.registry.<name>.url / .branch / .tag
        var registryNames = Set<String>()
        for key in parsed.keys where key.hasPrefix("ai_components.registry.") {
            let rest = key.dropFirst("ai_components.registry.".count)
            if let dotIdx = rest.firstIndex(of: ".") {
                registryNames.insert(String(rest[rest.startIndex..<dotIdx]))
            }
        }
        for name in registryNames.sorted() {
            let typeStr = parsed["ai_components.registry.\(name).type"] ?? "git"
            let regType = RegistryType(rawValue: typeStr) ?? .git
            let url = parsed["ai_components.registry.\(name).url"] ?? ""
            let branch = parsed["ai_components.registry.\(name).branch"] ?? "main"
            let tag = parsed["ai_components.registry.\(name).tag"]
            let slugsStr = parsed["ai_components.registry.\(name).slugs"] ?? ""
            let slugs = slugsStr.isEmpty ? [] : slugsStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let path = parsed["ai_components.registry.\(name).path"]
            let mapping = parsed["ai_components.registry.\(name).mapping"] ?? "auto"

            let isValid: Bool
            switch regType {
            case .git: isValid = !url.isEmpty
            case .localskills: isValid = !slugs.isEmpty
            case .local: isValid = path != nil && !path!.isEmpty
            }

            if isValid {
                let regConfig = RegistryConfig(name: name, url: url, branch: branch, tag: tag, type: regType, slugs: slugs, path: path, mapping: mapping)
                // Update existing default or append new
                if let idx = config.aiComponentRegistries.firstIndex(where: { $0.name == name }) {
                    config.aiComponentRegistries[idx] = regConfig
                } else {
                    config.aiComponentRegistries.append(regConfig)
                }
            }
        }

        // Parse AI component overrides: ai_components.overrides."<path>".stacks = "go,flutter"
        for (key, value) in parsed where key.hasPrefix("ai_components.overrides.") {
            let rest = key.dropFirst("ai_components.overrides.".count)
            // Key format: "<path>".stacks or <path>.stacks
            if rest.hasSuffix(".stacks") {
                let pathPart = String(rest.dropLast(".stacks".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let stacks = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                config.aiComponentOverrides[pathPart] = stacks
            }
        }

        return config
    }

    // MARK: - Font Resolution

    var resolvedFont: NSFont {
        let family = fontFamily.isEmpty ? BundledFont.defaultFontFamily : fontFamily
        if let font = NSFont(name: family, size: fontSize) {
            return font
        }
        // Try matching by family name
        if let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [
            .family: family
        ]), size: fontSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    var resolvedBoldFont: NSFont {
        let family = fontFamily.isEmpty ? BundledFont.defaultFontFamily : fontFamily
        if let font = NSFont(name: "\(family)-Bold", size: fontSize) {
            return font
        }
        let regular = resolvedFont
        let boldDesc = regular.fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: boldDesc, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    }

    // MARK: - Minimal TOML Parser

    /// Parse a TOML file into flat key-value pairs with dotted keys (e.g. "font.family" -> "JetBrains Mono")
    private static func parseToml(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentSection = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Section header
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Key = value
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)

            // Strip quotes
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            // Strip inline comments
            if let hashIdx = value.firstIndex(of: "#") {
                // Only if preceded by whitespace (not inside value)
                let before = value[value.startIndex..<hashIdx]
                if before.last == " " || before.last == "\t" {
                    value = before.trimmingCharacters(in: .whitespaces)
                }
            }

            let fullKey = currentSection.isEmpty ? key : "\(currentSection).\(key)"
            result[fullKey] = value
        }

        return result
    }

    /// Parse a hex color string like "#1e1e1e" or "1e1e1e" into NSColor
    private static func parseColor(_ hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let val = UInt32(h, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - Default ANSI Colors

    private static let defaultAnsiColors: [NSColor] = [
        // Standard 0-7
        NSColor(red: 0x1e/255.0, green: 0x1e/255.0, blue: 0x1e/255.0, alpha: 1), // 0 black
        NSColor(red: 0xf7/255.0, green: 0x76/255.0, blue: 0x8e/255.0, alpha: 1), // 1 red
        NSColor(red: 0xa6/255.0, green: 0xe2/255.0, blue: 0x2e/255.0, alpha: 1), // 2 green
        NSColor(red: 0xe6/255.0, green: 0xdb/255.0, blue: 0x74/255.0, alpha: 1), // 3 yellow
        NSColor(red: 0x66/255.0, green: 0xd9/255.0, blue: 0xef/255.0, alpha: 1), // 4 blue
        NSColor(red: 0x0d/255.0, green: 0x3a/255.0, blue: 0x5c/255.0, alpha: 1), // 5 magenta
        NSColor(red: 0xa1/255.0, green: 0xef/255.0, blue: 0xe4/255.0, alpha: 1), // 6 cyan
        NSColor(red: 0xf8/255.0, green: 0xf8/255.0, blue: 0xf2/255.0, alpha: 1), // 7 white
        // Bright 8-15
        NSColor(red: 0x75/255.0, green: 0x71/255.0, blue: 0x5e/255.0, alpha: 1), // 8 bright black
        NSColor(red: 0xf7/255.0, green: 0x76/255.0, blue: 0x8e/255.0, alpha: 1), // 9 bright red
        NSColor(red: 0xa6/255.0, green: 0xe2/255.0, blue: 0x2e/255.0, alpha: 1), // 10 bright green
        NSColor(red: 0xe6/255.0, green: 0xdb/255.0, blue: 0x74/255.0, alpha: 1), // 11 bright yellow
        NSColor(red: 0x66/255.0, green: 0xd9/255.0, blue: 0xef/255.0, alpha: 1), // 12 bright blue
        NSColor(red: 0x0d/255.0, green: 0x3a/255.0, blue: 0x5c/255.0, alpha: 1), // 13 bright magenta
        NSColor(red: 0xa1/255.0, green: 0xef/255.0, blue: 0xe4/255.0, alpha: 1), // 14 bright cyan
        NSColor(red: 0xf9/255.0, green: 0xf8/255.0, blue: 0xf5/255.0, alpha: 1), // 15 bright white
    ]
}
