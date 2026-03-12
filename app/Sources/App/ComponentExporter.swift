import Foundation

/// Supported export formats for AI components.
enum ExportFormat: String, CaseIterable {
    case cursor
    case agentsMd = "agents-md"
    case copilot
    case continuedev = "continue"
}

/// Target location for exported files.
enum ExportTarget: String {
    case cache
    case project
}

/// Result of a single format export.
struct ExportResult {
    let format: ExportFormat
    let outputPath: URL
    let fileCount: Int
}

/// Exports assembled AI components to various external tool formats.
enum ComponentExporter {

    private static let fm = FileManager.default
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/awal")

    /// Export components to the specified formats.
    static func export(
        stacks: Set<String>,
        registries: [RegistryConfig],
        formats: [ExportFormat],
        target: ExportTarget,
        projectPath: String,
        disabledComponents: Set<String>
    ) -> [ExportResult] {
        // Collect all markdown content from registries
        let content = collectContent(stacks: stacks, registries: registries, disabledComponents: disabledComponents)
        guard !content.isEmpty else { return [] }

        let baseDir: URL
        switch target {
        case .cache:
            let hash = projectPath.utf8.reduce(0) { ($0 &* 31) &+ UInt64($1) }
            baseDir = configDir.appendingPathComponent("exports/\(String(hash, radix: 16))")
        case .project:
            baseDir = URL(fileURLWithPath: projectPath)
        }

        var results: [ExportResult] = []

        for format in formats {
            if let result = exportFormat(format, content: content, baseDir: baseDir) {
                results.append(result)
            }
        }

        return results
    }

    // MARK: - Content Collection

    private struct ComponentContent {
        let name: String
        let key: String
        let type: String  // "rule", "skill", "prompt"
        let body: String
    }

    private static func collectContent(
        stacks: Set<String>,
        registries: [RegistryConfig],
        disabledComponents: Set<String>
    ) -> [ComponentContent] {
        var content: [ComponentContent] = []

        for reg in registries {
            let regPath = RegistryManager.shared.registryPath(name: reg.name)
            guard fm.fileExists(atPath: regPath.path) else { continue }

            // Common
            collectFromDir(regPath.appendingPathComponent("common/rules"), type: "rule",
                          registryName: reg.name, stackName: "common",
                          disabledComponents: disabledComponents, content: &content)
            collectFromDir(regPath.appendingPathComponent("common/skills"), type: "skill",
                          registryName: reg.name, stackName: "common",
                          disabledComponents: disabledComponents, content: &content)
            collectFromDir(regPath.appendingPathComponent("common/prompts"), type: "prompt",
                          registryName: reg.name, stackName: "common",
                          disabledComponents: disabledComponents, content: &content)

            // Stack-specific
            for stack in stacks {
                let stackPath = regPath.appendingPathComponent("stacks/\(stack)")
                collectFromDir(stackPath.appendingPathComponent("rules"), type: "rule",
                              registryName: reg.name, stackName: stack,
                              disabledComponents: disabledComponents, content: &content)
                collectFromDir(stackPath.appendingPathComponent("skills"), type: "skill",
                              registryName: reg.name, stackName: stack,
                              disabledComponents: disabledComponents, content: &content)
                collectFromDir(stackPath.appendingPathComponent("prompts"), type: "prompt",
                              registryName: reg.name, stackName: stack,
                              disabledComponents: disabledComponents, content: &content)
            }
        }

        return content
    }

    private static func collectFromDir(
        _ dir: URL,
        type: String,
        registryName: String,
        stackName: String,
        disabledComponents: Set<String>,
        content: inout [ComponentContent]
    ) {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        for item in items {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                // Skill directory — read SKILL.md
                let skillMd = item.appendingPathComponent("SKILL.md")
                guard let body = try? String(contentsOf: skillMd, encoding: .utf8) else { continue }
                let name = item.lastPathComponent
                let key = "\(registryName)/\(stackName)/\(type)/\(name)"
                guard !disabledComponents.contains(key) else { continue }
                content.append(ComponentContent(name: name, key: key, type: type, body: body))
            } else if item.pathExtension == "md" {
                guard let body = try? String(contentsOf: item, encoding: .utf8) else { continue }
                let name = item.deletingPathExtension().lastPathComponent
                let key = "\(registryName)/\(stackName)/\(type)/\(name)"
                guard !disabledComponents.contains(key) else { continue }
                content.append(ComponentContent(name: name, key: key, type: type, body: body))
            }
        }
    }

    // MARK: - Format Exporters

    private static func exportFormat(
        _ format: ExportFormat,
        content: [ComponentContent],
        baseDir: URL
    ) -> ExportResult? {
        switch format {
        case .cursor:
            return exportCursor(content: content, baseDir: baseDir)
        case .agentsMd:
            return exportAgentsMd(content: content, baseDir: baseDir)
        case .copilot:
            return exportCopilot(content: content, baseDir: baseDir)
        case .continuedev:
            return exportContinue(content: content, baseDir: baseDir)
        }
    }

    /// Export as Cursor .mdc files.
    private static func exportCursor(content: [ComponentContent], baseDir: URL) -> ExportResult? {
        let outputDir = baseDir.appendingPathComponent(".cursor/rules")
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var count = 0
        for item in content {
            let frontmatter = """
            ---
            description: \(item.name) (\(item.type))
            alwaysApply: true
            ---
            """
            let output = frontmatter + "\n\n" + item.body
            let outFile = outputDir.appendingPathComponent("\(item.name).mdc")
            if (try? output.write(to: outFile, atomically: true, encoding: .utf8)) != nil {
                count += 1
            }
        }

        return count > 0 ? ExportResult(format: .cursor, outputPath: outputDir, fileCount: count) : nil
    }

    /// Export as a single AGENTS.md file.
    private static func exportAgentsMd(content: [ComponentContent], baseDir: URL) -> ExportResult? {
        var sections: [String] = []
        for item in content {
            sections.append("## \(item.name)\n\n\(item.body)")
        }

        guard !sections.isEmpty else { return nil }

        let output = sections.joined(separator: "\n\n---\n\n")
        let outFile = baseDir.appendingPathComponent("AGENTS.md")
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

        guard (try? output.write(to: outFile, atomically: true, encoding: .utf8)) != nil else { return nil }
        return ExportResult(format: .agentsMd, outputPath: outFile, fileCount: 1)
    }

    /// Export as GitHub Copilot instructions.
    private static func exportCopilot(content: [ComponentContent], baseDir: URL) -> ExportResult? {
        let githubDir = baseDir.appendingPathComponent(".github")
        try? fm.createDirectory(at: githubDir, withIntermediateDirectories: true)

        var sections: [String] = []
        for item in content {
            sections.append("## \(item.name)\n\n\(item.body)")
        }

        guard !sections.isEmpty else { return nil }

        let output = sections.joined(separator: "\n\n---\n\n")
        let outFile = githubDir.appendingPathComponent("copilot-instructions.md")

        guard (try? output.write(to: outFile, atomically: true, encoding: .utf8)) != nil else { return nil }
        return ExportResult(format: .copilot, outputPath: outFile, fileCount: 1)
    }

    /// Export as Continue.dev rules.
    private static func exportContinue(content: [ComponentContent], baseDir: URL) -> ExportResult? {
        let outputDir = baseDir.appendingPathComponent(".continue/rules")
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var count = 0
        for item in content {
            let outFile = outputDir.appendingPathComponent("\(item.name).md")
            if (try? item.body.write(to: outFile, atomically: true, encoding: .utf8)) != nil {
                count += 1
            }
        }

        return count > 0 ? ExportResult(format: .continuedev, outputPath: outputDir, fileCount: count) : nil
    }
}
