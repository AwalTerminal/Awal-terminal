import Foundation

/// Result of assembling a plugin directory with all component types.
struct AssemblyResult {
    let pluginDirs: [URL]
    let skillCount: Int
    let ruleCount: Int
    let promptCount: Int
    let agentCount: Int
    let mcpServerCount: Int
    let hookCount: Int
    var warnings: [String] = []

    var totalCount: Int { skillCount + ruleCount + promptCount + agentCount + mcpServerCount + hookCount }
}

/// Component type for listing active components.
enum ComponentType: String, CaseIterable {
    case skill = "skill"
    case rule = "rule"
    case prompt = "prompt"
    case agent = "agent"
    case mcpServer = "mcp-server"
    case hook = "hook"

    var pluralLabel: String {
        switch self {
        case .skill: return "skills"
        case .rule: return "rules"
        case .prompt: return "prompts"
        case .agent: return "agents"
        case .mcpServer: return "MCP servers"
        case .hook: return "hooks"
        }
    }
}

/// Assembles AI component plugin directories from registry clones using symlinks.
/// Each registry + stack combo gets its own assembled directory.
class AIComponentRegistry {

    static let shared = AIComponentRegistry()

    private let fm = FileManager.default
    private let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/awal")
    private var pluginsDir: URL { configDir.appendingPathComponent("ai-component-plugins") }
    private var cacheDir: URL { configDir.appendingPathComponent("ai-component-cache") }

    // MARK: - Assembly

    /// Assemble plugin directories for the given stacks from all registries.
    /// Returns AssemblyResult with all component counts.
    func assemble(
        stacks: Set<String>,
        registries: [RegistryConfig],
        disabledComponents: Set<String> = [],
        blockedComponents: Set<String> = []
    ) -> AssemblyResult {
        let skip = disabledComponents.union(blockedComponents)
        var allDirs: [URL] = []
        var totalSkills = 0
        var totalRules = 0
        var totalPrompts = 0
        var totalAgents = 0
        var totalMcpServers = 0
        var totalHooks = 0
        var warnings: [String] = []

        for reg in registries {
            let regPath = RegistryManager.shared.registryPath(name: reg.name)
            guard fm.fileExists(atPath: regPath.path) else {
                warnings.append("\(reg.name): not cloned yet")
                continue
            }

            // Count MCP servers and hooks at registry level (not per-stack)
            totalMcpServers += countItems(in: regPath.appendingPathComponent("common/mcp-servers"), ext: "json")
            totalHooks += countHooks(in: regPath.appendingPathComponent("common/hooks"))

            for stack in stacks {
                totalMcpServers += countItems(in: regPath.appendingPathComponent("stacks/\(stack)/mcp-servers"), ext: "json")
                totalHooks += countHooks(in: regPath.appendingPathComponent("stacks/\(stack)/hooks"))

                let pluginDir = pluginsDir.appendingPathComponent("\(reg.name)--\(stack)")
                let counts = assemblePlugin(
                    at: pluginDir,
                    regPath: regPath,
                    registryName: reg.name,
                    stackName: stack,
                    skip: skip
                )

                if counts.total > 0 {
                    allDirs.append(pluginDir)
                    totalSkills += counts.skills
                    totalRules += counts.rules
                    totalPrompts += counts.prompts
                    totalAgents += counts.agents
                }
            }
        }

        // Add structure warnings from RegistryManager
        for reg in registries {
            let structWarnings = RegistryManager.shared.validateStructure(name: reg.name)
            for w in structWarnings {
                warnings.append("\(reg.name): \(w)")
            }
        }

        return AssemblyResult(
            pluginDirs: allDirs,
            skillCount: totalSkills,
            ruleCount: totalRules,
            promptCount: totalPrompts,
            agentCount: totalAgents,
            mcpServerCount: totalMcpServers,
            hookCount: totalHooks,
            warnings: warnings
        )
    }

    /// Generate a combined markdown file for non-Claude models (Gemini, Codex).
    /// Returns the path to the generated file, or nil if no content found.
    func generateCombinedMarkdown(
        stacks: Set<String>,
        registries: [RegistryConfig],
        prefix: String,
        projectPath: String,
        disabledComponents: Set<String> = [],
        blockedComponents: Set<String> = []
    ) -> URL? {
        var ruleSections: [String] = []
        var skillSections: [String] = []
        var commandSections: [String] = []
        var promptSections: [String] = []
        var agentSections: [String] = []

        for reg in registries {
            let regPath = RegistryManager.shared.registryPath(name: reg.name)
            guard fm.fileExists(atPath: regPath.path) else { continue }

            // Common
            ruleSections.append(contentsOf: collectMarkdown(from: regPath.appendingPathComponent("common/rules")))
            skillSections.append(contentsOf: collectMarkdown(from: regPath.appendingPathComponent("common/skills")))
            commandSections.append(contentsOf: collectMarkdown(from: regPath.appendingPathComponent("common/commands")))
            promptSections.append(contentsOf: collectMarkdown(from: regPath.appendingPathComponent("common/prompts")))
            agentSections.append(contentsOf: collectAgentMarkdown(from: regPath.appendingPathComponent("common/agents")))

            // Stack-specific
            for stack in stacks {
                let stackPath = regPath.appendingPathComponent("stacks/\(stack)")
                ruleSections.append(contentsOf: collectMarkdown(from: stackPath.appendingPathComponent("rules")))
                skillSections.append(contentsOf: collectMarkdown(from: stackPath.appendingPathComponent("skills")))
                commandSections.append(contentsOf: collectMarkdown(from: stackPath.appendingPathComponent("commands")))
                promptSections.append(contentsOf: collectMarkdown(from: stackPath.appendingPathComponent("prompts")))
                agentSections.append(contentsOf: collectAgentMarkdown(from: stackPath.appendingPathComponent("agents")))
            }
        }

        let allEmpty = ruleSections.isEmpty && skillSections.isEmpty && commandSections.isEmpty
            && promptSections.isEmpty && agentSections.isEmpty
        guard !allEmpty else { return nil }

        // Build combined markdown: rules first (top priority), then skills, commands, prompts, agents
        var parts: [String] = []

        if !ruleSections.isEmpty {
            parts.append("# Coding Rules\n\n" + ruleSections.joined(separator: "\n\n---\n\n"))
        }
        if !skillSections.isEmpty {
            parts.append("# Skills\n\n" + skillSections.joined(separator: "\n\n---\n\n"))
        }
        if !commandSections.isEmpty {
            parts.append("# Commands\n\n" + commandSections.joined(separator: "\n\n---\n\n"))
        }
        if !promptSections.isEmpty {
            parts.append("# Available Prompts\n\n" + promptSections.joined(separator: "\n\n---\n\n"))
        }
        if !agentSections.isEmpty {
            parts.append("# Agents\n\n" + agentSections.joined(separator: "\n\n---\n\n"))
        }

        // Hash project path for unique filename
        let hash = projectPath.utf8.reduce(0) { ($0 &* 31) &+ UInt64($1) }
        let filename = "\(prefix)-\(String(hash, radix: 16)).md"
        let outFile = cacheDir.appendingPathComponent(filename)

        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let content = parts.joined(separator: "\n\n---\n\n")
        try? content.write(to: outFile, atomically: true, encoding: .utf8)

        return outFile
    }

    /// List all active components for given stacks and registries.
    func listActiveComponents(
        stacks: Set<String>,
        registries: [RegistryConfig],
        disabledComponents: Set<String> = []
    ) -> [(name: String, source: String, stack: String, type: ComponentType, key: String)] {
        var components: [(name: String, source: String, stack: String, type: ComponentType, key: String)] = []

        for reg in registries {
            let regPath = RegistryManager.shared.registryPath(name: reg.name)
            guard fm.fileExists(atPath: regPath.path) else { continue }

            let source = reg.type == .localskills ? "localskills" : reg.name

            func addComponents(names: [String], stack: String, type: ComponentType) {
                for name in names {
                    let key = "\(reg.name)/\(stack)/\(type.rawValue)/\(name)"
                    let displayName: String
                    if reg.type == .localskills && type == .skill {
                        let skillDir = RegistryManager.shared.registryPath(name: reg.name)
                            .appendingPathComponent("\(stack == "common" ? "common/skills" : "stacks/\(stack)/skills")/\(name)")
                        displayName = localskillsDisplayName(slug: name, skillDir: skillDir)
                    } else {
                        displayName = name
                    }
                    components.append((name: displayName, source: source, stack: stack, type: type, key: key))
                }
            }

            // Common components
            addComponents(names: skillNames(in: regPath.appendingPathComponent("common/skills")), stack: "common", type: .skill)
            addComponents(names: mdFileNames(in: regPath.appendingPathComponent("common/rules")), stack: "common", type: .rule)
            addComponents(names: mdFileNames(in: regPath.appendingPathComponent("common/prompts")), stack: "common", type: .prompt)
            addComponents(names: agentNames(in: regPath.appendingPathComponent("common/agents")), stack: "common", type: .agent)
            addComponents(names: jsonFileNames(in: regPath.appendingPathComponent("common/mcp-servers")), stack: "common", type: .mcpServer)
            addComponents(names: hookNames(in: regPath.appendingPathComponent("common/hooks")), stack: "common", type: .hook)

            // Stack-specific components
            for stack in stacks {
                let stackPath = regPath.appendingPathComponent("stacks/\(stack)")
                addComponents(names: skillNames(in: stackPath.appendingPathComponent("skills")), stack: stack, type: .skill)
                addComponents(names: mdFileNames(in: stackPath.appendingPathComponent("rules")), stack: stack, type: .rule)
                addComponents(names: mdFileNames(in: stackPath.appendingPathComponent("prompts")), stack: stack, type: .prompt)
                addComponents(names: agentNames(in: stackPath.appendingPathComponent("agents")), stack: stack, type: .agent)
                addComponents(names: jsonFileNames(in: stackPath.appendingPathComponent("mcp-servers")), stack: stack, type: .mcpServer)
                addComponents(names: hookNames(in: stackPath.appendingPathComponent("hooks")), stack: stack, type: .hook)
            }
        }

        return components
    }

    /// Collect MCP server configs from all registries for the given stacks.
    /// Returns a dictionary of server name → config dict, with names prefixed by registry.
    func collectMcpConfigs(
        stacks: Set<String>,
        registries: [RegistryConfig],
        disabledComponents: Set<String> = [],
        blockedComponents: Set<String> = []
    ) -> [String: [String: Any]] {
        let skip = disabledComponents.union(blockedComponents)
        var configs: [String: [String: Any]] = [:]

        for reg in registries {
            let regPath = RegistryManager.shared.registryPath(name: reg.name)
            guard fm.fileExists(atPath: regPath.path) else { continue }

            let stackList: [(dir: URL, stack: String)] = [
                (regPath.appendingPathComponent("common/mcp-servers"), "common")
            ] + stacks.map { (regPath.appendingPathComponent("stacks/\($0)/mcp-servers"), $0) }

            for (dir, stack) in stackList {
                guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for item in items where item.pathExtension == "json" {
                    let name = item.deletingPathExtension().lastPathComponent
                    let key = "\(reg.name)/\(stack)/mcp-server/\(name)"
                    guard !skip.contains(key) else { continue }
                    guard let data = try? Data(contentsOf: item),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    let serverName = "awal-\(reg.name)-\(name)"
                    configs[serverName] = json
                }
            }
        }

        return configs
    }

    /// Collect hook script URLs from all registries for the given stacks.
    func collectHooks(
        stacks: Set<String>,
        registries: [RegistryConfig],
        disabledComponents: Set<String> = [],
        blockedComponents: Set<String> = []
    ) -> (preSession: [URL], postSession: [URL], beforeCommit: [URL]) {
        let skip = disabledComponents.union(blockedComponents)
        var pre: [URL] = []
        var post: [URL] = []
        var commit: [URL] = []

        for reg in registries {
            let regPath = RegistryManager.shared.registryPath(name: reg.name)
            guard fm.fileExists(atPath: regPath.path) else { continue }

            let hookDirs: [(dir: URL, stack: String)] = [
                (regPath.appendingPathComponent("common/hooks"), "common")
            ] + stacks.map { (regPath.appendingPathComponent("stacks/\($0)/hooks"), $0) }

            for (dir, stack) in hookDirs {
                for subdir in ["pre-session", "post-session", "before-commit"] {
                    for url in scriptURLs(in: dir.appendingPathComponent(subdir)) {
                        let name = "\(subdir)/\(url.deletingPathExtension().lastPathComponent)"
                        let key = "\(reg.name)/\(stack)/hook/\(name)"
                        if !skip.contains(key) {
                            switch subdir {
                            case "pre-session": pre.append(url)
                            case "post-session": post.append(url)
                            case "before-commit": commit.append(url)
                            default: break
                            }
                        }
                    }
                }
            }
        }

        return (pre, post, commit)
    }

    /// Clean up assembled plugin directories.
    func cleanup() {
        try? fm.removeItem(at: pluginsDir)
        try? fm.removeItem(at: cacheDir)
    }

    // MARK: - Private

    private struct PluginCounts {
        var skills = 0
        var rules = 0
        var prompts = 0
        var agents = 0
        var total: Int { skills + rules + prompts + agents }
    }

    private func assemblePlugin(
        at pluginDir: URL,
        regPath: URL,
        registryName: String,
        stackName: String,
        skip: Set<String> = []
    ) -> PluginCounts {
        // Clean and recreate
        try? fm.removeItem(at: pluginDir)
        try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let skillsDir = pluginDir.appendingPathComponent("skills")
        let commandsDir = pluginDir.appendingPathComponent("commands")
        let rulesDir = pluginDir.appendingPathComponent("rules")
        let agentsDir = pluginDir.appendingPathComponent("agents")
        try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: commandsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        var counts = PluginCounts()

        // Create .claude-plugin/plugin.json
        let claudePluginDir = pluginDir.appendingPathComponent(".claude-plugin")
        try? fm.createDirectory(at: claudePluginDir, withIntermediateDirectories: true)
        let pluginJson: [String: Any] = [
            "name": "\(registryName)-\(stackName)-skills",
            "description": "Components from \(registryName) for \(stackName) projects",
            "version": "1.0.0",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: pluginJson, options: .prettyPrinted) {
            try? data.write(to: claudePluginDir.appendingPathComponent("plugin.json"))
        }

        let commonPath = regPath.appendingPathComponent("common")
        let stackPath = regPath.appendingPathComponent("stacks/\(stackName)")

        let commonSkip = { (name: String, type: String) -> Bool in
            skip.contains("\(registryName)/common/\(type)/\(name)")
        }
        let stackSkip = { (name: String, type: String) -> Bool in
            skip.contains("\(registryName)/\(stackName)/\(type)/\(name)")
        }

        // Skills → symlink dirs into skills/ AND expose SKILL.md as commands/<name>.md
        counts.skills += symlinkSkillsAsCommands(from: commonPath.appendingPathComponent("skills"), skillsDir: skillsDir, commandsDir: commandsDir, shouldSkip: { commonSkip($0, "skill") })
        counts.skills += symlinkSkillsAsCommands(from: stackPath.appendingPathComponent("skills"), skillsDir: skillsDir, commandsDir: commandsDir, shouldSkip: { stackSkip($0, "skill") })

        // Commands
        _ = symlinkContents(from: commonPath.appendingPathComponent("commands"), to: commandsDir)
        _ = symlinkContents(from: stackPath.appendingPathComponent("commands"), to: commandsDir)

        // Rules → symlink into plugin rules/ dir
        counts.rules += symlinkContents(from: commonPath.appendingPathComponent("rules"), to: rulesDir, shouldSkip: { commonSkip($0, "rule") })
        counts.rules += symlinkContents(from: stackPath.appendingPathComponent("rules"), to: rulesDir, shouldSkip: { stackSkip($0, "rule") })

        // Prompts → symlink into commands/ dir (acts as slash commands for Claude)
        counts.prompts += symlinkContents(from: commonPath.appendingPathComponent("prompts"), to: commandsDir, shouldSkip: { commonSkip($0, "prompt") })
        counts.prompts += symlinkContents(from: stackPath.appendingPathComponent("prompts"), to: commandsDir, shouldSkip: { stackSkip($0, "prompt") })

        // Agents → symlink into agents/ dir
        counts.agents += symlinkContents(from: commonPath.appendingPathComponent("agents"), to: agentsDir, shouldSkip: { commonSkip($0, "agent") })
        counts.agents += symlinkContents(from: stackPath.appendingPathComponent("agents"), to: agentsDir, shouldSkip: { stackSkip($0, "agent") })

        return counts
    }

    /// Symlink all items from source dir into target dir. Returns count of items linked.
    private func symlinkContents(from source: URL, to target: URL, shouldSkip: ((String) -> Bool)? = nil) -> Int {
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else {
            return 0
        }

        var count = 0
        for item in items {
            let name = item.deletingPathExtension().lastPathComponent
            if shouldSkip?(name) == true { continue }
            let dest = target.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.createSymbolicLink(at: dest, withDestinationURL: item)
                count += 1
            }
        }
        return count
    }

    /// Symlink skill directories into skills/ dir AND expose each SKILL.md as commands/<name>.md
    /// so Claude Code recognizes them as slash commands.
    private func symlinkSkillsAsCommands(from source: URL, skillsDir: URL, commandsDir: URL, shouldSkip: ((String) -> Bool)? = nil) -> Int {
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else {
            return 0
        }

        var count = 0
        for item in items {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if shouldSkip?(item.lastPathComponent) == true { continue }

            // Symlink the skill directory into skills/
            let skillDest = skillsDir.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: skillDest.path) {
                try? fm.createSymbolicLink(at: skillDest, withDestinationURL: item)
            }

            // Also symlink SKILL.md as commands/<name>.md for slash command access
            let skillMd = item.appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: skillMd.path) {
                let cmdDest = commandsDir.appendingPathComponent("\(item.lastPathComponent).md")
                if !fm.fileExists(atPath: cmdDest.path) {
                    try? fm.createSymbolicLink(at: cmdDest, withDestinationURL: skillMd)
                }
                count += 1
            }
        }
        return count
    }

    /// Collect all markdown content from a directory.
    private func collectMarkdown(from dir: URL) -> [String] {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        var sections: [String] = []
        for item in items {
            // If it's a directory, look for SKILL.md inside
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                let skillMd = item.appendingPathComponent("SKILL.md")
                if let content = try? String(contentsOf: skillMd, encoding: .utf8) {
                    sections.append(content)
                }
            } else if item.pathExtension == "md" {
                if let content = try? String(contentsOf: item, encoding: .utf8) {
                    sections.append(content)
                }
            }
        }
        return sections
    }

    /// Collect agent definitions as markdown from agents/ directories.
    private func collectAgentMarkdown(from dir: URL) -> [String] {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        var sections: [String] = []
        for item in items {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                let agentJson = item.appendingPathComponent("agent.json")
                if let data = try? Data(contentsOf: agentJson),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    sections.append(renderAgentAsMarkdown(name: item.lastPathComponent, json: json))
                }
            }
        }
        return sections
    }

    /// Render an agent.json as a markdown description.
    private func renderAgentAsMarkdown(name: String, json: [String: Any]) -> String {
        var lines = ["## Agent: \(name)"]
        if let desc = json["description"] as? String {
            lines.append(desc)
        }
        if let tools = json["tools"] as? [String] {
            lines.append("\n**Tools:** " + tools.joined(separator: ", "))
        }
        if let instructions = json["instructions"] as? String {
            lines.append("\n**Instructions:**\n\(instructions)")
        }
        return lines.joined(separator: "\n")
    }

    /// Get skill names from a skills directory.
    private func skillNames(in dir: URL) -> [String] {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return items.compactMap { item in
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                let skillMd = item.appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: skillMd.path) {
                    return item.lastPathComponent
                }
            } else if item.pathExtension == "md" {
                return item.deletingPathExtension().lastPathComponent
            }
            return nil
        }
    }

    /// Get markdown file names (without extension) from a directory.
    private func mdFileNames(in dir: URL) -> [String] {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return items.compactMap { item in
            item.pathExtension == "md" ? item.deletingPathExtension().lastPathComponent : nil
        }
    }

    /// Get agent names (directories containing agent.json).
    private func agentNames(in dir: URL) -> [String] {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return items.compactMap { item in
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                let agentJson = item.appendingPathComponent("agent.json")
                if fm.fileExists(atPath: agentJson.path) {
                    return item.lastPathComponent
                }
            }
            return nil
        }
    }

    /// Get JSON file names (without extension) from a directory.
    private func jsonFileNames(in dir: URL) -> [String] {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return items.compactMap { item in
            item.pathExtension == "json" ? item.deletingPathExtension().lastPathComponent : nil
        }
    }

    /// Get hook script names from hooks/ subdirectories.
    private func hookNames(in hooksDir: URL) -> [String] {
        var names: [String] = []
        for subdir in ["pre-session", "post-session", "before-commit"] {
            let dir = hooksDir.appendingPathComponent(subdir)
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for item in items where item.pathExtension == "sh" {
                    names.append("\(subdir)/\(item.deletingPathExtension().lastPathComponent)")
                }
            }
        }
        return names
    }

    /// Count items with a specific extension in a directory.
    private func countItems(in dir: URL, ext: String) -> Int {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return 0
        }
        return items.filter { $0.pathExtension == ext }.count
    }

    /// Count hook scripts in hooks/ subdirectories.
    private func countHooks(in hooksDir: URL) -> Int {
        var count = 0
        for subdir in ["pre-session", "post-session", "before-commit"] {
            let dir = hooksDir.appendingPathComponent(subdir)
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                count += items.filter { $0.pathExtension == "sh" }.count
            }
        }
        return count
    }

    /// Get script URLs from a hooks subdirectory.
    private func scriptURLs(in dir: URL) -> [URL] {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return items.filter { $0.pathExtension == "sh" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Parse the `name` field from SKILL.md frontmatter and return "<name> [<slug>]".
    /// Falls back to the slug if no name is found.
    private func localskillsDisplayName(slug: String, skillDir: URL) -> String {
        let skillMd = skillDir.appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOf: skillMd, encoding: .utf8) else { return slug }

        // Parse YAML frontmatter between --- delimiters
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return slug }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.hasPrefix("name:") {
                let value = trimmed.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    return "\(value) [\(slug)]"
                }
            }
        }
        return slug
    }
}
