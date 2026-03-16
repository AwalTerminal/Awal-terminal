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
    /// Resolution order: standard → claude-plugin → in-repo .awal-mapping.json → local mapping → unmapped.
    /// If `configMapping` is "standard", force standard mode. If "custom", require local mapping.
    static func resolveMode(registryName: String, repoPath: URL, configMapping: String = "auto") -> RegistryMappingMode {
        if configMapping == "standard" {
            return .standard
        }

        if configMapping == "custom" {
            return localMappingExists(registryName: registryName) ? .localMapping : .unmapped
        }

        // Auto mode: try each in order
        if hasStandardStructure(repoPath: repoPath) {
            return .standard
        }
        if hasClaudePluginManifest(repoPath: repoPath) {
            return .claudePlugin
        }
        // Local mapping takes precedence over in-repo mapping
        if localMappingExists(registryName: registryName) {
            return .localMapping
        }
        if inRepoMappingExists(repoPath: repoPath) {
            return .inRepoMapping
        }
        return .unmapped
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
            guard let skillPaths = plugin["skills"] as? [String] else { continue }
            for skillPath in skillPaths {
                // Resolve relative path (strip leading ./)
                let cleaned = skillPath.hasPrefix("./") ? String(skillPath.dropFirst(2)) : skillPath
                let skillDir = repoPath.appendingPathComponent(cleaned)
                // Look for SKILL.md inside
                let skillMd = skillDir.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: skillMd.path) else { continue }
                let name = skillDir.lastPathComponent
                components.append(ResolvedComponent(
                    name: name,
                    type: .skill,
                    stack: "common",
                    fileURL: skillDir,
                    group: groupName,
                    hookPhase: nil
                ))
            }
        }
        return components
    }

    // MARK: - Mapping Resolution (Glob Expansion)

    /// Resolve a mapping against the repo filesystem, returning discovered components.
    static func resolveMapping(_ mapping: RegistryMapping, repoPath: URL) -> [ResolvedComponent] {
        let rootPath: URL
        if let root = mapping.root, !root.isEmpty, root != "." {
            rootPath = repoPath.appendingPathComponent(root)
        } else {
            rootPath = repoPath
        }

        var components: [ResolvedComponent] = []
        var matched = Set<String>()  // Track matched paths for first-match-wins

        for entry in mapping.mappings {
            guard let compType = ComponentType(rawValue: entry.type) else { continue }
            let stack = entry.stack ?? "common"

            let matchedURLs = expandGlob(pattern: entry.path, in: rootPath)
            for url in matchedURLs {
                let relPath = url.path.replacingOccurrences(of: rootPath.path + "/", with: "")
                guard !matched.contains(relPath) else { continue }
                matched.insert(relPath)

                let name = entry.name ?? deriveComponentName(url: url, type: compType, entry: entry)
                components.append(ResolvedComponent(
                    name: name,
                    type: compType,
                    stack: stack,
                    fileURL: url,
                    group: nil,
                    hookPhase: entry.hookPhase
                ))
            }
        }

        // Process file_transforms for any unmatched files
        if let transforms = mapping.fileTransforms {
            for (ext, typeStr) in transforms {
                guard let compType = ComponentType(rawValue: typeStr) else { continue }
                let pattern = "**/*\(ext)"
                let matchedURLs = expandGlob(pattern: pattern, in: rootPath)
                for url in matchedURLs {
                    let relPath = url.path.replacingOccurrences(of: rootPath.path + "/", with: "")
                    guard !matched.contains(relPath) else { continue }
                    matched.insert(relPath)

                    let name = url.deletingPathExtension().lastPathComponent
                    components.append(ResolvedComponent(
                        name: name,
                        type: compType,
                        stack: "common",
                        fileURL: url,
                        group: nil,
                        hookPhase: nil
                    ))
                }
            }
        }

        return components
    }

    /// Resolve a mapping with per-entry source tracking for highlighting.
    /// Returns tuples of (mappingIndex, component) so the UI can associate each result with its source mapping row.
    static func resolveMappingDetailed(_ mapping: RegistryMapping, repoPath: URL) -> [(mappingIndex: Int, component: ResolvedComponent)] {
        let rootPath: URL
        if let root = mapping.root, !root.isEmpty, root != "." {
            rootPath = repoPath.appendingPathComponent(root)
        } else {
            rootPath = repoPath
        }

        var results: [(mappingIndex: Int, component: ResolvedComponent)] = []
        var matched = Set<String>()

        for (idx, entry) in mapping.mappings.enumerated() {
            guard let compType = ComponentType(rawValue: entry.type) else { continue }
            let stack = entry.stack ?? "common"

            let matchedURLs = expandGlob(pattern: entry.path, in: rootPath)
            for url in matchedURLs {
                let relPath = url.path.replacingOccurrences(of: rootPath.path + "/", with: "")
                guard !matched.contains(relPath) else { continue }
                matched.insert(relPath)

                let name = entry.name ?? deriveComponentName(url: url, type: compType, entry: entry)
                let comp = ResolvedComponent(
                    name: name,
                    type: compType,
                    stack: stack,
                    fileURL: url,
                    group: nil,
                    hookPhase: entry.hookPhase
                )
                results.append((mappingIndex: idx, component: comp))
            }
        }

        return results
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
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return name.hasPrefix(prefix)
        }
        if pattern.hasPrefix("*") && pattern.hasSuffix("*") {
            let middle = String(pattern.dropFirst().dropLast())
            return name.contains(middle)
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
