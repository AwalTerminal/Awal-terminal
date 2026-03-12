import Foundation

/// Result of an import operation.
struct ImportResult {
    let importedCount: Int
    let warnings: [String]
    let outputDir: URL
}

/// Imports components from external tool formats (Cursor, AGENTS.md, Codex) into Awal's component format.
enum ComponentImporter {

    private static let fm = FileManager.default

    // MARK: - Cursor Rules (.mdc)

    /// Import Cursor .mdc rules from a project directory into an Awal registry.
    static func importCursorRules(from projectDir: URL, to registryDir: URL) -> ImportResult {
        let cursorDir = projectDir.appendingPathComponent(".cursor/rules")
        let outputDir = registryDir.appendingPathComponent("common/rules")
        var imported = 0
        var warnings: [String] = []

        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        guard let items = try? fm.contentsOfDirectory(at: cursorDir, includingPropertiesForKeys: nil) else {
            warnings.append("No .cursor/rules/ directory found")
            return ImportResult(importedCount: 0, warnings: warnings, outputDir: outputDir)
        }

        for item in items where item.pathExtension == "mdc" {
            guard let content = try? String(contentsOf: item, encoding: .utf8) else {
                warnings.append("Could not read \(item.lastPathComponent)")
                continue
            }

            let (frontmatter, body) = parseMdcFrontmatter(content)
            let name = item.deletingPathExtension().lastPathComponent
            let outFile = outputDir.appendingPathComponent("\(name).md")

            var output = ""
            if let desc = frontmatter["description"] {
                output += "<!-- Imported from Cursor: \(desc) -->\n\n"
            }
            output += body

            do {
                try output.write(to: outFile, atomically: true, encoding: .utf8)
                imported += 1
            } catch {
                warnings.append("Failed to write \(name).md: \(error.localizedDescription)")
            }
        }

        return ImportResult(importedCount: imported, warnings: warnings, outputDir: outputDir)
    }

    // MARK: - AGENTS.md

    /// Import AGENTS.md from a project directory, splitting by headings into separate rules.
    static func importAgentsMd(from projectDir: URL, to registryDir: URL) -> ImportResult {
        let agentsFile = projectDir.appendingPathComponent("AGENTS.md")
        let outputDir = registryDir.appendingPathComponent("common/rules")
        var imported = 0
        var warnings: [String] = []

        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        guard let content = try? String(contentsOf: agentsFile, encoding: .utf8) else {
            warnings.append("No AGENTS.md found in project root")
            return ImportResult(importedCount: 0, warnings: warnings, outputDir: outputDir)
        }

        let sections = splitByHeadings(content)

        if sections.isEmpty {
            // Single file, no headings — import as one rule
            let outFile = outputDir.appendingPathComponent("agents-md.md")
            do {
                try content.write(to: outFile, atomically: true, encoding: .utf8)
                imported = 1
            } catch {
                warnings.append("Failed to write agents-md.md")
            }
        } else {
            for (heading, body) in sections {
                let slug = slugify(heading)
                let outFile = outputDir.appendingPathComponent("\(slug).md")
                let output = "## \(heading)\n\n\(body)"
                do {
                    try output.write(to: outFile, atomically: true, encoding: .utf8)
                    imported += 1
                } catch {
                    warnings.append("Failed to write \(slug).md")
                }
            }
        }

        return ImportResult(importedCount: imported, warnings: warnings, outputDir: outputDir)
    }

    // MARK: - Codex Skills

    /// Import Codex skills from a project directory into Awal skill format.
    static func importCodexSkills(from projectDir: URL, to registryDir: URL) -> ImportResult {
        let outputDir = registryDir.appendingPathComponent("common/skills")
        var imported = 0
        var warnings: [String] = []

        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Try both possible Codex skill locations
        let candidates = [
            projectDir.appendingPathComponent(".codex/skills"),
            projectDir.appendingPathComponent("codex_skills"),
        ]

        var sourceDir: URL?
        for candidate in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                sourceDir = candidate
                break
            }
        }

        guard let sourceDir else {
            warnings.append("No Codex skills directory found (.codex/skills/ or codex_skills/)")
            return ImportResult(importedCount: 0, warnings: warnings, outputDir: outputDir)
        }

        guard let items = try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil) else {
            return ImportResult(importedCount: 0, warnings: warnings, outputDir: outputDir)
        }

        for item in items {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let skillName = item.lastPathComponent
            let destDir = outputDir.appendingPathComponent(skillName)

            do {
                try? fm.removeItem(at: destDir)
                try fm.copyItem(at: item, to: destDir)

                // Rename instructions.md to SKILL.md if needed
                let instructionsMd = destDir.appendingPathComponent("instructions.md")
                let skillMd = destDir.appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: instructionsMd.path) && !fm.fileExists(atPath: skillMd.path) {
                    try fm.moveItem(at: instructionsMd, to: skillMd)
                }

                imported += 1
            } catch {
                warnings.append("Failed to copy skill \(skillName): \(error.localizedDescription)")
            }
        }

        return ImportResult(importedCount: imported, warnings: warnings, outputDir: outputDir)
    }

    // MARK: - Helpers

    /// Parse MDC frontmatter (YAML between --- delimiters) from content.
    private static func parseMdcFrontmatter(_ content: String) -> (frontmatter: [String: String], body: String) {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], content)
        }

        var frontmatter: [String: String] = [:]
        var bodyStart = 0

        for i in 1..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line == "---" {
                bodyStart = i + 1
                break
            }
            // Simple YAML key: value parsing
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                frontmatter[key] = value
            }
        }

        let body = lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (frontmatter, body)
    }

    /// Split markdown content by ## headings.
    private static func splitByHeadings(_ content: String) -> [(heading: String, body: String)] {
        let lines = content.components(separatedBy: .newlines)
        var sections: [(heading: String, body: String)] = []
        var currentHeading: String?
        var currentBody: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if let heading = currentHeading {
                    sections.append((heading: heading, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentHeading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentBody = []
            } else {
                currentBody.append(line)
            }
        }

        if let heading = currentHeading {
            sections.append((heading: heading, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return sections
    }

    /// Convert a heading string to a URL-safe slug.
    private static func slugify(_ text: String) -> String {
        let lowered = text.lowercased()
        let cleaned = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(cleaned).replacingOccurrences(of: " ", with: "-")
    }
}
