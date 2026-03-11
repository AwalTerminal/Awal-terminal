import Foundation

/// Context returned after AI component injection, including any command modifications needed.
struct AIComponentContext {
    let detectedStacks: Set<String>
    let skillCount: Int
    let ruleCount: Int
    let promptCount: Int
    let agentCount: Int
    let mcpServerCount: Int
    let commandModifier: ((String) -> String)?
    let preSessionHooks: [URL]
    let postSessionHooks: [URL]
    let beforeCommitHooks: [URL]

    var totalCount: Int { skillCount + ruleCount + promptCount + agentCount + mcpServerCount }
}

/// Injects AI components into AI sessions based on model type.
/// - Claude: uses plugin system (symlinks + enabledPlugins)
/// - Gemini: uses --system-instruction-file flag
/// - Codex: uses --instructions flag
enum AIComponentInjector {

    /// Inject AI components for the given model and project.
    /// Returns an AIComponentContext with detected info and optional command modifier.
    static func inject(modelName: String, projectPath: String) -> AIComponentContext? {
        let config = AppConfig.shared
        guard config.aiComponentsEnabled else { return nil }

        let registries = config.aiComponentRegistries
        guard !registries.isEmpty else { return nil }

        // Detect project stacks
        let overrides = config.aiComponentOverride(for: projectPath)
        var registryRules: [String: [String]] = [:]
        for reg in registries {
            let rules = RegistryManager.shared.parseRegistryToml(name: reg.name)
            for (stack, markers) in rules {
                var existing = registryRules[stack] ?? []
                existing.append(contentsOf: markers)
                registryRules[stack] = existing
            }
        }

        let stacks = ProjectDetector.detect(
            path: projectPath,
            registryRules: registryRules,
            overrideStacks: overrides
        )
        guard !stacks.isEmpty else { return nil }

        // Auto-sync registries if enabled
        if config.aiComponentsAutoSync {
            RegistryManager.shared.syncAll(registries: registries)
        }

        // Collect hooks for all models
        let hooks = AIComponentRegistry.shared.collectHooks(stacks: stacks, registries: registries)

        // Choose injection strategy based on model
        switch modelName {
        case "Claude":
            return injectClaude(stacks: stacks, registries: registries, hooks: hooks)
        case "Gemini":
            return injectGeneric(
                stacks: stacks,
                registries: registries,
                prefix: "gemini",
                projectPath: projectPath,
                flagName: "--system-instruction-file",
                hooks: hooks
            )
        case "Codex":
            return injectGeneric(
                stacks: stacks,
                registries: registries,
                prefix: "codex",
                projectPath: projectPath,
                flagName: "--instructions",
                hooks: hooks
            )
        default:
            return injectGeneric(
                stacks: stacks,
                registries: registries,
                prefix: "generic",
                projectPath: projectPath,
                flagName: nil,
                hooks: hooks
            )
        }
    }

    /// Clean up any injected state (call when session ends).
    static func cleanup(modelName: String) {
        if modelName == "Claude" {
            cleanupClaude()
        }
    }

    // MARK: - Claude Plugin Injection

    private static func injectClaude(
        stacks: Set<String>,
        registries: [(name: String, url: String, branch: String)],
        hooks: (preSession: [URL], postSession: [URL], beforeCommit: [URL])
    ) -> AIComponentContext {
        let result = AIComponentRegistry.shared.assemble(stacks: stacks, registries: registries)

        // Set up Claude skill + plugin symlinks and settings
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeSkillsDir = home.appendingPathComponent(".claude/skills")
        let claudePluginsDir = home.appendingPathComponent(".claude/plugins/cache")
        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        let fm = FileManager.default

        try? fm.createDirectory(at: claudeSkillsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: claudePluginsDir, withIntermediateDirectories: true)

        // Symlink skill directories into ~/.claude/skills/ (prefixed awal-)
        for pluginDir in result.pluginDirs {
            let skillsSubdir = pluginDir.appendingPathComponent("skills")
            if let items = try? fm.contentsOfDirectory(at: skillsSubdir, includingPropertiesForKeys: nil) {
                for item in items {
                    let dest = claudeSkillsDir.appendingPathComponent("awal-\(item.lastPathComponent)")
                    try? fm.removeItem(at: dest)
                    // Resolve the symlink to get the actual skill directory
                    let resolved = item.resolvingSymlinksInPath()
                    try? fm.createSymbolicLink(at: dest, withDestinationURL: resolved)
                }
            }
        }

        var pluginNames: [String] = []

        for pluginDir in result.pluginDirs {
            let name = "awal-\(pluginDir.lastPathComponent)"
            let symlinkPath = claudePluginsDir.appendingPathComponent(name)

            // Remove existing symlink
            try? fm.removeItem(at: symlinkPath)
            try? fm.createSymbolicLink(at: symlinkPath, withDestinationURL: pluginDir)
            pluginNames.append(symlinkPath.path)
        }

        // Update Claude settings: enable plugins and merge MCP servers
        let mcpConfigs = AIComponentRegistry.shared.collectMcpConfigs(stacks: stacks, registries: registries)
        updateClaudeSettings(settingsFile: claudeSettings, pluginPaths: pluginNames, mcpConfigs: mcpConfigs)

        // Write hooks to Claude settings
        if !hooks.preSession.isEmpty || !hooks.postSession.isEmpty || !hooks.beforeCommit.isEmpty {
            writeClaudeHooks(settingsFile: claudeSettings, preHooks: hooks.preSession, postHooks: hooks.postSession, beforeCommitHooks: hooks.beforeCommit)
        }

        return AIComponentContext(
            detectedStacks: stacks,
            skillCount: result.skillCount,
            ruleCount: result.ruleCount,
            promptCount: result.promptCount,
            agentCount: result.agentCount,
            mcpServerCount: result.mcpServerCount,
            commandModifier: nil,
            preSessionHooks: hooks.preSession,
            postSessionHooks: hooks.postSession,
            beforeCommitHooks: hooks.beforeCommit
        )
    }

    private static func updateClaudeSettings(
        settingsFile: URL,
        pluginPaths: [String],
        mcpConfigs: [String: [String: Any]]
    ) {
        let fm = FileManager.default
        var settings: [String: Any] = [:]

        if let data = try? Data(contentsOf: settingsFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        // Get or create enabledPlugins record (path → true)
        var plugins = settings["enabledPlugins"] as? [String: Bool] ?? [:]

        // Add our plugin paths
        for path in pluginPaths {
            plugins[path] = true
        }

        settings["enabledPlugins"] = plugins

        // Merge MCP server configs (prefixed with awal-)
        if !mcpConfigs.isEmpty {
            var mcpServers = settings["mcpServers"] as? [String: Any] ?? [:]
            for (name, config) in mcpConfigs {
                mcpServers[name] = config
            }
            settings["mcpServers"] = mcpServers
        }

        // Atomic write
        try? fm.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsFile, options: .atomic)
        }
    }

    private static func writeClaudeHooks(settingsFile: URL, preHooks: [URL], postHooks: [URL], beforeCommitHooks: [URL]) {
        guard let data = try? Data(contentsOf: settingsFile),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Remove all existing awal hook groups before re-adding (detect by command path)
        for key in hooks.keys {
            if var entries = hooks[key] as? [[String: Any]] {
                entries.removeAll { group in
                    guard let innerHooks = group["hooks"] as? [[String: Any]] else { return false }
                    return innerHooks.allSatisfy { entry in
                        (entry["command"] as? String)?.contains(".config/awal/") == true
                    }
                }
                hooks[key] = entries.isEmpty ? nil : entries
            }
        }

        if !preHooks.isEmpty {
            var sessionStart = hooks["SessionStart"] as? [[String: Any]] ?? []
            let hookEntries = preHooks.map { url -> [String: Any] in
                ["type": "command", "command": "bash \(url.path)"]
            }
            sessionStart.append(["hooks": hookEntries])
            hooks["SessionStart"] = sessionStart
        }

        if !postHooks.isEmpty {
            var stop = hooks["Stop"] as? [[String: Any]] ?? []
            let hookEntries = postHooks.map { url -> [String: Any] in
                ["type": "command", "command": "bash \(url.path)"]
            }
            stop.append(["hooks": hookEntries])
            hooks["Stop"] = stop
        }

        if !beforeCommitHooks.isEmpty {
            var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
            let hookEntries = beforeCommitHooks.map { url -> [String: Any] in
                ["type": "command", "command": "bash \(url.path)"]
            }
            preToolUse.append(["matcher": "Bash", "hooks": hookEntries])
            hooks["PreToolUse"] = preToolUse
        }

        settings["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsFile, options: .atomic)
        }
    }

    private static func cleanupClaude() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeSkillsDir = home.appendingPathComponent(".claude/skills")
        let claudePluginsDir = home.appendingPathComponent(".claude/plugins/cache")
        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        let fm = FileManager.default

        // Remove awal-* skill symlinks
        if let contents = try? fm.contentsOfDirectory(atPath: claudeSkillsDir.path) {
            for item in contents where item.hasPrefix("awal-") {
                try? fm.removeItem(at: claudeSkillsDir.appendingPathComponent(item))
            }
        }

        // Remove awal-* plugin symlinks
        if let contents = try? fm.contentsOfDirectory(atPath: claudePluginsDir.path) {
            for item in contents where item.hasPrefix("awal-") {
                try? fm.removeItem(at: claudePluginsDir.appendingPathComponent(item))
            }
        }

        // Remove from enabledPlugins, mcpServers, and hooks in settings
        if let data = try? Data(contentsOf: claudeSettings),
           var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // Clean enabledPlugins (record format: path → true)
            if var plugins = settings["enabledPlugins"] as? [String: Bool] {
                let awalKeys = plugins.keys.filter { $0.contains("/plugins/cache/awal-") }
                for key in awalKeys {
                    plugins.removeValue(forKey: key)
                }
                settings["enabledPlugins"] = plugins
            }

            // Clean awal- prefixed MCP servers
            if var mcpServers = settings["mcpServers"] as? [String: Any] {
                let awalKeys = mcpServers.keys.filter { $0.hasPrefix("awal-") }
                for key in awalKeys {
                    mcpServers.removeValue(forKey: key)
                }
                settings["mcpServers"] = mcpServers
            }

            // Clean awal hooks (detect by command path)
            if var hooks = settings["hooks"] as? [String: Any] {
                for key in hooks.keys {
                    if var entries = hooks[key] as? [[String: Any]] {
                        entries.removeAll { group in
                            guard let innerHooks = group["hooks"] as? [[String: Any]] else { return false }
                            return innerHooks.allSatisfy { entry in
                                (entry["command"] as? String)?.contains(".config/awal/") == true
                            }
                        }
                        hooks[key] = entries.isEmpty ? nil : entries
                    }
                }
                settings["hooks"] = hooks
            }

            if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: claudeSettings, options: .atomic)
            }
        }
    }

    // MARK: - Generic (Gemini, Codex, etc.)

    private static func injectGeneric(
        stacks: Set<String>,
        registries: [(name: String, url: String, branch: String)],
        prefix: String,
        projectPath: String,
        flagName: String?,
        hooks: (preSession: [URL], postSession: [URL], beforeCommit: [URL])
    ) -> AIComponentContext? {
        let components = AIComponentRegistry.shared.listActiveComponents(stacks: stacks, registries: registries)

        let mdFile = AIComponentRegistry.shared.generateCombinedMarkdown(
            stacks: stacks,
            registries: registries,
            prefix: prefix,
            projectPath: projectPath
        )

        let skillCount = components.filter { $0.type == .skill }.count
        let ruleCount = components.filter { $0.type == .rule }.count
        let promptCount = components.filter { $0.type == .prompt }.count
        let agentCount = components.filter { $0.type == .agent }.count
        let total = skillCount + ruleCount + promptCount + agentCount

        guard total > 0 || mdFile != nil else {
            return AIComponentContext(
                detectedStacks: stacks,
                skillCount: 0, ruleCount: 0, promptCount: 0, agentCount: 0, mcpServerCount: 0,
                commandModifier: nil,
                preSessionHooks: hooks.preSession,
                postSessionHooks: hooks.postSession,
                beforeCommitHooks: hooks.beforeCommit
            )
        }

        let modifier: ((String) -> String)? = flagName.flatMap { flag in
            mdFile.map { file in
                { cmd in "\(cmd) \(flag) \(file.path)" }
            }
        }

        return AIComponentContext(
            detectedStacks: stacks,
            skillCount: skillCount,
            ruleCount: ruleCount,
            promptCount: promptCount,
            agentCount: agentCount,
            mcpServerCount: 0,  // MCP is Claude-only
            commandModifier: modifier,
            preSessionHooks: hooks.preSession,
            postSessionHooks: hooks.postSession,
            beforeCommitHooks: hooks.beforeCommit
        )
    }
}
