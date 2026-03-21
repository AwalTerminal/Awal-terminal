import Foundation

// MARK: - Data Structures

/// Schema for `.awal-mapping.json` files (both in-repo and local).
struct RegistryMapping: Codable {
    let version: Int
    var root: String?
    var mappings: [PathMapping]
    var fileTransforms: [String: String]?

    enum CodingKeys: String, CodingKey {
        case version, root, mappings
        case fileTransforms = "file_transforms"
    }
}

/// A single path→type mapping entry.
struct PathMapping: Codable {
    let path: String
    let type: String  // skill, rule, prompt, agent, mcp-server, hook
    var stack: String?
    var name: String?
    var skillFile: String?
    var agentFile: String?
    var hookPhase: String?

    enum CodingKeys: String, CodingKey {
        case path, type, stack, name
        case skillFile = "skill_file"
        case agentFile = "agent_file"
        case hookPhase = "hook_phase"
    }
}

/// A component discovered through mapping or claude-plugin manifest.
struct ResolvedComponent {
    let name: String
    let type: ComponentType
    let stack: String
    let fileURL: URL
    let group: String?  // Grouping label from claude-plugin plugins[].name
    let hookPhase: String?  // For hooks: pre-session, post-session, before-commit
}

/// How a registry's structure is being interpreted.
enum RegistryMappingMode: Equatable {
    case standard
    case claudePlugin
    case inRepoMapping
    case localMapping
    case unmapped
}

// MARK: - Resolver

/// Resolves non-standard registry structures using mapping files or claude-plugin manifests.
enum RegistryMappingResolver {

    private static let fm = FileManager.default
    private static var mappingsDir: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/awal/mappings")
    }

    // MARK: - Resolution Order

    /// Determine which mapping mode applies for a registry.
    /// Resolution order: standard → in-repo .awal-mapping.json → claude-plugin → local mapping (standalone) → unmapped.
    /// Local mapping is used as an overlay on top of the base mode (see `applyLocalOverrides`),
    /// and only becomes a standalone mode when no base mode applies.
    /// If `configMapping` is "standard", force standard mode. If "custom", require local mapping.
    static func resolveMode(registryName: String, repoPath: URL, configMapping: String = "auto") -> RegistryMappingMode {
        if configMapping == "standard" {
            return .standard
        }

        if configMapping == "custom" {
            return localMappingExists(registryName: registryName) ? .localMapping : .unmapped
        }

        // Auto mode: try each base mode in order
        if hasStandardStructure(repoPath: repoPath) {
            return .standard
        }
        if inRepoMappingExists(repoPath: repoPath) {
            return .inRepoMapping
        }
        if hasClaudePluginManifest(repoPath: repoPath) {
            return .claudePlugin
        }

        // Local mapping is standalone only when no base mode applies
        if localMappingExists(registryName: registryName) {
            return .localMapping
        }
        return .unmapped
    }

    // MARK: - Local Mapping Overlay

    /// Apply local mapping overrides on top of base-resolved components.
    /// Each local mapping entry's glob is matched against base component paths.
    /// Matching base components get their type/stack overridden (preserving group).
    /// Local mapping entries that don't match any base component are resolved
    /// normally and appended as new components.
    /// Returns base unchanged if no local mapping exists.
    static func applyLocalOverrides(
        base: [ResolvedComponent],
        registryName: String,
        repoPath: URL
    ) -> [ResolvedComponent] {
        guard localMappingExists(registryName: registryName),
              let mapping = loadMappingFile(at: localMappingPath(registryName: registryName)) else {
            return base
        }
        guard !mapping.mappings.isEmpty else { return base }

        let rootPath: URL
        if let root = mapping.root, !root.isEmpty, root != "." {
            rootPath = repoPath.appendingPathComponent(root)
        } else {
            rootPath = repoPath
        }

        var merged = base
        var matchedBaseIndices = Set<Int>()

        for entry in mapping.mappings {
            guard let compType = ComponentType(rawValue: entry.type) else { continue }
            let stack = entry.stack ?? "common"

            // Try to match this entry's glob against existing base components
            var entryMatchedBase = false
            for (i, comp) in merged.enumerated() {
                let relPath = comp.fileURL.path.replacingOccurrences(of: rootPath.path + "/", with: "")
                if globMatches(pattern: entry.path, path: relPath) {
                    // Override this base component's type/stack, preserve group
                    merged[i] = ResolvedComponent(
                        name: entry.name ?? comp.name,
                        type: compType,
                        stack: stack,
                        fileURL: comp.fileURL,
                        group: comp.group,
                        hookPhase: entry.hookPhase ?? comp.hookPhase
                    )
                    matchedBaseIndices.insert(i)
                    entryMatchedBase = true
                }
            }

            // If no base component matched, resolve the glob and add as new components
            if !entryMatchedBase {
                let matchedURLs = expandGlob(pattern: entry.path, in: rootPath)
                for url in matchedURLs {
                    let name = entry.name ?? deriveComponentName(url: url, type: compType, entry: entry)
                    merged.append(ResolvedComponent(
                        name: name,
                        type: compType,
                        stack: stack,
                        fileURL: url,
                        group: nil,
                        hookPhase: entry.hookPhase
                    ))
                }
            }
        }

        return merged
    }

    /// Check if a glob pattern matches a given relative path.
    /// The glob matches if the path itself matches, or if the path is a prefix of
    /// the glob (e.g., path "skills/foo" matches glob "skills/foo/**").
    private static func globMatches(pattern: String, path: String) -> Bool {
        let patternParts = pattern.components(separatedBy: "/")
        let pathParts = path.components(separatedBy: "/")

        // Check if the path is a prefix up to the first ** or wildcard
        // e.g., pattern "skills/foo/**" should match path "skills/foo"
        var concretePrefix: [String] = []
        for part in patternParts {
            if part == "**" || part.contains("*") { break }
            concretePrefix.append(part)
        }

        // Exact prefix match: path matches the concrete part of the glob
        if pathParts == concretePrefix {
            return true
        }

        // Also check if the full path matches the full pattern (for non-** globs)
        if patternParts.count == pathParts.count {
            for (pp, pathP) in zip(patternParts, pathParts) {
                if pp == "**" { return true }
                if pp == pathP { continue }
                if matchWildcard(pattern: pp, against: pathP) { continue }
                return false
            }
            return true
        }

        // Check ** patterns: path components match up to ** then anything after
        if let starIdx = patternParts.firstIndex(of: "**") {
            // Parts before ** must match exactly
            let prefixParts = Array(patternParts[..<starIdx])
            guard pathParts.count >= prefixParts.count else { return false }
            for (pp, pathP) in zip(prefixParts, pathParts) {
                if !matchWildcard(pattern: pp, against: pathP) && pp != pathP { return false }
            }
            // If ** is the last part, any path with the prefix matches
            if starIdx == patternParts.count - 1 {
                return true
            }
        }

        return false
    }

    // MARK: - Structure Detection

    static func hasStandardStructure(repoPath: URL) -> Bool {
        fm.fileExists(atPath: repoPath.appendingPathComponent("common").path)
            || fm.fileExists(atPath: repoPath.appendingPathComponent("stacks").path)
    }

    static func hasClaudePluginManifest(repoPath: URL) -> Bool {
        fm.fileExists(atPath: repoPath.appendingPathComponent(".claude-plugin/marketplace.json").path)
    }

    static func inRepoMappingExists(repoPath: URL) -> Bool {
        fm.fileExists(atPath: repoPath.appendingPathComponent(".awal-mapping.json").path)
    }

    static func localMappingExists(registryName: String) -> Bool {
        fm.fileExists(atPath: localMappingPath(registryName: registryName).path)
    }

    // MARK: - Mapping Loading

    /// Load only the in-repo `.awal-mapping.json` (ignoring any local mapping).
    static func loadInRepoMapping(repoPath: URL) -> RegistryMapping? {
        let inRepoPath = repoPath.appendingPathComponent(".awal-mapping.json")
        return loadMappingFile(at: inRepoPath)
    }

    /// Load the effective mapping for a registry.
    /// Local mapping takes precedence over in-repo mapping when both exist.
    static func loadMapping(registryName: String, repoPath: URL) -> RegistryMapping? {
        // Try local mapping first
        let localPath = localMappingPath(registryName: registryName)
        if let mapping = loadMappingFile(at: localPath) {
            return mapping
        }

        // Try in-repo mapping
        let inRepoPath = repoPath.appendingPathComponent(".awal-mapping.json")
        return loadMappingFile(at: inRepoPath)
    }

    /// Save a mapping to the local mappings directory.
    static func saveMapping(_ mapping: RegistryMapping, registryName: String) {
        try? fm.createDirectory(at: mappingsDir, withIntermediateDirectories: true)
        let path = localMappingPath(registryName: registryName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(mapping) {
            try? data.write(to: path)
        }
    }

    /// Delete a local mapping file.
    static func deleteLocalMapping(registryName: String) {
        let path = localMappingPath(registryName: registryName)
        try? fm.removeItem(at: path)
    }

    // MARK: - Claude Plugin Manifest Parsing

    /// Parse `.claude-plugin/marketplace.json` and return resolved skill components.
    static func parseClaudePluginManifest(repoPath: URL) -> [ResolvedComponent] {
        let manifestPath = repoPath.appendingPathComponent(".claude-plugin/marketplace.json")
        guard let data = try? Data(contentsOf: manifestPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [[String: Any]] else {
            return []
        }

        var components: [ResolvedComponent] = []
        for plugin in plugins {
            let groupName = plugin["name"] as? String

            // If explicit skills array is provided, use it
            if let skillPaths = plugin["skills"] as? [String] {
                for skillPath in skillPaths {
                    let cleaned = skillPath.hasPrefix("./") ? String(skillPath.dropFirst(2)) : skillPath
                    let skillDir = repoPath.appendingPathComponent(cleaned)
                    let skillMd = skillDir.appendingPathComponent("SKILL.md")
                    guard fm.fileExists(atPath: skillMd.path) else { continue }
                    let name = skillDir.lastPathComponent
                    components.append(ResolvedComponent(
                        name: name, type: .skill, stack: "common",
                        fileURL: skillDir, group: groupName, hookPhase: nil
                    ))
                }
                continue
            }

            // No explicit arrays — discover components from source directory (only when explicitly set)
            guard let source = plugin["source"] as? String else { continue }
            let cleaned = source.hasPrefix("./") ? String(source.dropFirst(2)) : source
            let sourceDir = cleaned.isEmpty ? repoPath : repoPath.appendingPathComponent(cleaned)

            // Discover skills (directories containing SKILL.md)
            let skillsParent = sourceDir.appendingPathComponent("skills")
            if let items = try? fm.contentsOfDirectory(at: skillsParent, includingPropertiesForKeys: nil) {
                for item in items {
                    let skillMd = item.appendingPathComponent("SKILL.md")
                    guard fm.fileExists(atPath: skillMd.path) else { continue }
                    components.append(ResolvedComponent(
                        name: item.lastPathComponent, type: .skill, stack: "common",
                        fileURL: item, group: groupName, hookPhase: nil
                    ))
                }
            }

            // Discover rules (.md files in rules/ and rules/<subdir>/)
            let rulesParent = sourceDir.appendingPathComponent("rules")
            if let items = try? fm.contentsOfDirectory(at: rulesParent, includingPropertiesForKeys: nil) {
                for item in items {
                    if item.pathExtension == "md", item.lastPathComponent != "README.md" {
                        components.append(ResolvedComponent(
                            name: item.deletingPathExtension().lastPathComponent, type: .rule,
                            stack: "common", fileURL: item, group: groupName, hookPhase: nil
                        ))
                    } else {
                        // Subdirectory of rules (e.g. rules/python/)
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                            if let subItems = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                                let stack = item.lastPathComponent
                                for sub in subItems where sub.pathExtension == "md" && sub.lastPathComponent != "README.md" {
                                    components.append(ResolvedComponent(
                                        name: sub.deletingPathExtension().lastPathComponent, type: .rule,
                                        stack: stack, fileURL: sub, group: groupName, hookPhase: nil
                                    ))
                                }
                            }
                        }
                    }
                }
            }

            // Discover commands (.md files)
            let commandsParent = sourceDir.appendingPathComponent("commands")
            if let items = try? fm.contentsOfDirectory(at: commandsParent, includingPropertiesForKeys: nil) {
                for item in items where item.pathExtension == "md" && item.lastPathComponent != "README.md" {
                    components.append(ResolvedComponent(
                        name: item.deletingPathExtension().lastPathComponent, type: .prompt,
                        stack: "common", fileURL: item, group: groupName, hookPhase: nil
                    ))
                }
            }

            // Discover agents (.md files)
            let agentsParent = sourceDir.appendingPathComponent("agents")
            if let items = try? fm.contentsOfDirectory(at: agentsParent, includingPropertiesForKeys: nil) {
                for item in items where item.pathExtension == "md" && item.lastPathComponent != "README.md" {
                    components.append(ResolvedComponent(
                        name: item.deletingPathExtension().lastPathComponent, type: .agent,
                        stack: "common", fileURL: item, group: groupName, hookPhase: nil
                    ))
                }
            }
        }
        return components
    }

    // MARK: - Mapping Resolution (Glob Expansion)

    /// Resolve a mapping against the repo filesystem, returning discovered components.
    /// Later mappings override earlier ones for the same path (last-match-wins),
    /// so specific child patterns placed after broad parent patterns take priority.
    static func resolveMapping(_ mapping: RegistryMapping, repoPath: URL) -> [ResolvedComponent] {
        let rootPath: URL
        if let root = mapping.root, !root.isEmpty, root != "." {
            rootPath = repoPath.appendingPathComponent(root)
        } else {
            rootPath = repoPath
        }

        // Last-match-wins: later mappings override earlier ones for the same path
        var componentByPath: [String: ResolvedComponent] = [:]
        var insertionOrder: [String] = []

        for entry in mapping.mappings {
            guard let compType = ComponentType(rawValue: entry.type) else { continue }
            let stack = entry.stack ?? "common"

            let matchedURLs = expandGlob(pattern: entry.path, in: rootPath)
            for url in matchedURLs {
                let relPath = url.path.replacingOccurrences(of: rootPath.path + "/", with: "")
                if componentByPath[relPath] == nil {
                    insertionOrder.append(relPath)
                }

                let name = entry.name ?? deriveComponentName(url: url, type: compType, entry: entry)
                componentByPath[relPath] = ResolvedComponent(
                    name: name,
                    type: compType,
                    stack: stack,
                    fileURL: url,
                    group: nil,
                    hookPhase: entry.hookPhase
                )
            }
        }

        // Process file_transforms for paths not already matched by explicit mappings
        if let transforms = mapping.fileTransforms {
            for (ext, typeStr) in transforms {
                guard let compType = ComponentType(rawValue: typeStr) else { continue }
                let pattern = "**/*\(ext)"
                let matchedURLs = expandGlob(pattern: pattern, in: rootPath)
                for url in matchedURLs {
                    let relPath = url.path.replacingOccurrences(of: rootPath.path + "/", with: "")
                    guard componentByPath[relPath] == nil else { continue }
                    insertionOrder.append(relPath)

                    let name = url.deletingPathExtension().lastPathComponent
                    componentByPath[relPath] = ResolvedComponent(
                        name: name,
                        type: compType,
                        stack: "common",
                        fileURL: url,
                        group: nil,
                        hookPhase: nil
                    )
                }
            }
        }

        return insertionOrder.compactMap { componentByPath[$0] }
    }

    /// Resolve a mapping with per-entry source tracking for highlighting.
    /// Returns tuples of (mappingIndex, component) so the UI can associate each result with its source mapping row.
    /// Later mappings override earlier ones for the same path (last-match-wins).
    static func resolveMappingDetailed(_ mapping: RegistryMapping, repoPath: URL) -> [(mappingIndex: Int, component: ResolvedComponent)] {
        let rootPath: URL
        if let root = mapping.root, !root.isEmpty, root != "." {
            rootPath = repoPath.appendingPathComponent(root)
        } else {
            rootPath = repoPath
        }

        var resultByPath: [String: (mappingIndex: Int, component: ResolvedComponent)] = [:]
        var insertionOrder: [String] = []

        for (idx, entry) in mapping.mappings.enumerated() {
            guard let compType = ComponentType(rawValue: entry.type) else { continue }
            let stack = entry.stack ?? "common"

            let matchedURLs = expandGlob(pattern: entry.path, in: rootPath)
            for url in matchedURLs {
                let relPath = url.path.replacingOccurrences(of: rootPath.path + "/", with: "")
                if resultByPath[relPath] == nil {
                    insertionOrder.append(relPath)
                }

                let name = entry.name ?? deriveComponentName(url: url, type: compType, entry: entry)
                let comp = ResolvedComponent(
                    name: name,
                    type: compType,
                    stack: stack,
                    fileURL: url,
                    group: nil,
                    hookPhase: entry.hookPhase
                )
                resultByPath[relPath] = (mappingIndex: idx, component: comp)
            }
        }

        return insertionOrder.compactMap { resultByPath[$0] }
    }

    /// Get a tree of repo files up to a given depth, for the mapping editor.
    static func repoFileTree(repoPath: URL, maxDepth: Int = 3) -> [String] {
        var paths: [String] = []
        collectFiles(in: repoPath, relativeTo: repoPath, depth: 0, maxDepth: maxDepth, into: &paths)
        return paths.sorted()
    }

    // MARK: - Private Helpers

    private static func localMappingPath(registryName: String) -> URL {
        mappingsDir.appendingPathComponent("\(registryName).mapping.json")
    }

    private static func loadMappingFile(at url: URL) -> RegistryMapping? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RegistryMapping.self, from: data)
    }

    private static func deriveComponentName(url: URL, type: ComponentType, entry: PathMapping) -> String {
        switch type {
        case .skill:
            // For skill dirs, use the directory name
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url.lastPathComponent
            }
            return url.deletingPathExtension().lastPathComponent
        case .agent:
            // For agent dirs, use the parent directory name
            let agentFile = entry.agentFile ?? "agent.json"
            if url.lastPathComponent == agentFile {
                return url.deletingLastPathComponent().lastPathComponent
            }
            return url.lastPathComponent
        case .hook:
            return url.deletingPathExtension().lastPathComponent
        default:
            return url.deletingPathExtension().lastPathComponent
        }
    }

    /// Expand a glob pattern against a directory.
    /// Supports `*` (single level), `**` (recursive), and `*.ext` patterns.
    private static func expandGlob(pattern: String, in dir: URL) -> [URL] {
        let parts = pattern.components(separatedBy: "/")
        var results: [URL] = [dir]

        for (i, part) in parts.enumerated() {
            var nextResults: [URL] = []

            for current in results {
                if part == "**" {
                    // Recursive: collect all subdirectories
                    nextResults.append(current)
                    let subdirs = allSubdirectories(of: current)
                    nextResults.append(contentsOf: subdirs)
                } else if part.contains("*") {
                    // Wildcard: match entries in current directory
                    guard let items = try? fm.contentsOfDirectory(at: current, includingPropertiesForKeys: nil) else { continue }
                    for item in items {
                        if matchWildcard(pattern: part, against: item.lastPathComponent) {
                            nextResults.append(item)
                        }
                    }
                } else {
                    // Exact match
                    let candidate = current.appendingPathComponent(part)
                    if fm.fileExists(atPath: candidate.path) {
                        nextResults.append(candidate)
                    }
                }
            }

            // After **, the remaining parts should filter the recursive results
            if part == "**" && i + 1 < parts.count {
                // Continue with next parts filtering these directories
                let remainingPattern = parts[(i + 1)...].joined(separator: "/")
                var filtered: [URL] = []
                for subdir in nextResults {
                    filtered.append(contentsOf: expandGlob(pattern: remainingPattern, in: subdir))
                }
                return filtered
            }

            results = nextResults
        }

        // Filter to only existing files/dirs
        return results.filter { fm.fileExists(atPath: $0.path) && $0 != dir }
    }

    private static func matchWildcard(pattern: String, against name: String) -> Bool {
        if pattern == "*" {
            return true
        }
        if pattern.hasPrefix("*.") {
            let ext = String(pattern.dropFirst(2))
            return name.hasSuffix(".\(ext)")
        }
        // Check *contains* before suffix-only to avoid mismatching "*foo*" as prefix "foo*"
        if pattern.hasPrefix("*") && pattern.hasSuffix("*") && pattern.count > 2 {
            let middle = String(pattern.dropFirst().dropLast())
            return name.contains(middle)
        }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return name.hasPrefix(prefix)
        }
        if pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return name.hasSuffix(suffix)
        }
        return name == pattern
    }

    private static func allSubdirectories(of dir: URL) -> [URL] {
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles]) else { return [] }
        var dirs: [URL] = []
        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                dirs.append(url)
            }
        }
        return dirs
    }

    private static func collectFiles(in dir: URL, relativeTo base: URL, depth: Int, maxDepth: Int, into paths: inout [String]) {
        guard depth < maxDepth else { return }
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for item in items {
            guard !item.lastPathComponent.hasPrefix(".") else { continue }
            let relPath = item.path.replacingOccurrences(of: base.path + "/", with: "")
            paths.append(relPath)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                collectFiles(in: item, relativeTo: base, depth: depth + 1, maxDepth: maxDepth, into: &paths)
            }
        }
    }
}
