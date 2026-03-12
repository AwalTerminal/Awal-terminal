import Foundation

/// Severity level for security findings.
enum SecuritySeverity: String {
    case warning
    case critical
}

/// A single security finding from scanning a component.
struct SecurityFinding {
    let componentKey: String  // registry/stack/type/name
    let pattern: String       // what was matched
    let severity: SecuritySeverity
    let line: String          // the matched line
}

/// Scans AI component registries for security issues like prompt injection,
/// data exfiltration, and destructive commands.
enum ComponentSecurityScanner {

    // MARK: - Hook patterns (shell scripts)

    private static let criticalHookPatterns: [(pattern: String, regex: NSRegularExpression?)] = [
        ("curl|wget piped to shell", try? NSRegularExpression(pattern: #"(curl|wget|nc|ncat)\s.*\|\s*(sh|bash|zsh)"#, options: [])),
        ("rm -rf /", try? NSRegularExpression(pattern: #"rm\s+-rf\s+/"#, options: [])),
        ("rm -rf ~", try? NSRegularExpression(pattern: #"rm\s+-rf\s+~"#, options: [])),
        ("rm -rf $HOME", try? NSRegularExpression(pattern: #"rm\s+-rf\s+\$HOME"#, options: [])),
        ("eval with variable", try? NSRegularExpression(pattern: #"eval\s.*\$"#, options: [])),
        ("base64 decode to shell", try? NSRegularExpression(pattern: #"base64.*\|\s*(sh|bash)"#, options: [])),
    ]

    private static let warningHookPatterns: [(pattern: String, regex: NSRegularExpression?)] = [
        ("curl usage", try? NSRegularExpression(pattern: #"\bcurl\b"#, options: [])),
        ("wget usage", try? NSRegularExpression(pattern: #"\bwget\b"#, options: [])),
        ("chmod 777", try? NSRegularExpression(pattern: #"chmod\s+777"#, options: [])),
        ("sudo usage", try? NSRegularExpression(pattern: #"\bsudo\b"#, options: [])),
    ]

    // MARK: - Markdown patterns (rules/skills)

    private static let warningMarkdownPatterns: [(pattern: String, regex: NSRegularExpression?)] = [
        ("prompt injection: ignore previous", try? NSRegularExpression(pattern: #"ignore previous"#, options: [.caseInsensitive])),
        ("prompt injection: disregard all", try? NSRegularExpression(pattern: #"disregard all"#, options: [.caseInsensitive])),
        ("prompt injection: you are now", try? NSRegularExpression(pattern: #"you are now"#, options: [.caseInsensitive])),
        ("prompt injection: output system prompt", try? NSRegularExpression(pattern: #"output the system prompt"#, options: [.caseInsensitive])),
        ("prompt injection: reveal instructions", try? NSRegularExpression(pattern: #"reveal your instructions"#, options: [.caseInsensitive])),
        ("prompt injection: ignore safety", try? NSRegularExpression(pattern: #"ignore safety"#, options: [.caseInsensitive])),
    ]

    // MARK: - MCP config patterns

    private static let warningMcpCommandPatterns = ["curl", "wget", "nc"]

    // MARK: - Public API

    /// Scan a registry directory for security issues across all detected stacks.
    static func scan(registryPath: URL, stacks: Set<String>) -> [SecurityFinding] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: registryPath.path) else { return [] }

        var findings: [SecurityFinding] = []
        let registryName = registryPath.lastPathComponent

        // Scan common/ directory
        scanDirectory(
            registryPath.appendingPathComponent("common"),
            registryName: registryName,
            stackName: "common",
            findings: &findings
        )

        // Scan each detected stack
        for stack in stacks {
            scanDirectory(
                registryPath.appendingPathComponent("stacks/\(stack)"),
                registryName: registryName,
                stackName: stack,
                findings: &findings
            )
        }

        return findings
    }

    // MARK: - Private

    private static func scanDirectory(
        _ dir: URL,
        registryName: String,
        stackName: String,
        findings: inout [SecurityFinding]
    ) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }

        // Scan hooks (shell scripts)
        scanHooks(dir.appendingPathComponent("hooks"), registryName: registryName, stackName: stackName, findings: &findings)

        // Scan rules (markdown)
        scanMarkdownDir(dir.appendingPathComponent("rules"), type: "rule", registryName: registryName, stackName: stackName, findings: &findings)

        // Scan skills (markdown)
        scanSkillsDir(dir.appendingPathComponent("skills"), registryName: registryName, stackName: stackName, findings: &findings)

        // Scan prompts (markdown)
        scanMarkdownDir(dir.appendingPathComponent("prompts"), type: "prompt", registryName: registryName, stackName: stackName, findings: &findings)

        // Scan MCP configs (json)
        scanMcpConfigs(dir.appendingPathComponent("mcp-servers"), registryName: registryName, stackName: stackName, findings: &findings)
    }

    private static func scanHooks(
        _ hooksDir: URL,
        registryName: String,
        stackName: String,
        findings: inout [SecurityFinding]
    ) {
        let fm = FileManager.default
        for subdir in ["pre-session", "post-session", "before-commit"] {
            let dir = hooksDir.appendingPathComponent(subdir)
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }

            for item in items where item.pathExtension == "sh" {
                guard let content = try? String(contentsOf: item, encoding: .utf8) else { continue }
                let componentName = "\(subdir)/\(item.deletingPathExtension().lastPathComponent)"
                let key = "\(registryName)/\(stackName)/hook/\(componentName)"

                for line in content.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

                    let range = NSRange(trimmed.startIndex..., in: trimmed)

                    // Check critical patterns
                    for (pattern, regex) in criticalHookPatterns {
                        if let regex, regex.firstMatch(in: trimmed, range: range) != nil {
                            findings.append(SecurityFinding(
                                componentKey: key, pattern: pattern,
                                severity: .critical, line: trimmed
                            ))
                        }
                    }

                    // Check warning patterns
                    for (pattern, regex) in warningHookPatterns {
                        if let regex, regex.firstMatch(in: trimmed, range: range) != nil {
                            findings.append(SecurityFinding(
                                componentKey: key, pattern: pattern,
                                severity: .warning, line: trimmed
                            ))
                        }
                    }
                }
            }
        }
    }

    private static func scanMarkdownDir(
        _ dir: URL,
        type: String,
        registryName: String,
        stackName: String,
        findings: inout [SecurityFinding]
    ) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        for item in items where item.pathExtension == "md" {
            guard let content = try? String(contentsOf: item, encoding: .utf8) else { continue }
            let name = item.deletingPathExtension().lastPathComponent
            let key = "\(registryName)/\(stackName)/\(type)/\(name)"
            scanMarkdownContent(content, key: key, findings: &findings)
        }
    }

    private static func scanSkillsDir(
        _ dir: URL,
        registryName: String,
        stackName: String,
        findings: inout [SecurityFinding]
    ) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        for item in items {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                let skillMd = item.appendingPathComponent("SKILL.md")
                if let content = try? String(contentsOf: skillMd, encoding: .utf8) {
                    let key = "\(registryName)/\(stackName)/skill/\(item.lastPathComponent)"
                    scanMarkdownContent(content, key: key, findings: &findings)
                }
            }
        }
    }

    private static func scanMarkdownContent(
        _ content: String,
        key: String,
        findings: inout [SecurityFinding]
    ) {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let range = NSRange(trimmed.startIndex..., in: trimmed)
            for (pattern, regex) in warningMarkdownPatterns {
                if let regex, regex.firstMatch(in: trimmed, range: range) != nil {
                    findings.append(SecurityFinding(
                        componentKey: key, pattern: pattern,
                        severity: .warning, line: trimmed
                    ))
                }
            }
        }
    }

    private static func scanMcpConfigs(
        _ dir: URL,
        registryName: String,
        stackName: String,
        findings: inout [SecurityFinding]
    ) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        for item in items where item.pathExtension == "json" {
            guard let data = try? Data(contentsOf: item),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let name = item.deletingPathExtension().lastPathComponent
            let key = "\(registryName)/\(stackName)/mcp-server/\(name)"

            // Check command field
            if let command = json["command"] as? String {
                for pattern in warningMcpCommandPatterns {
                    if command.contains(pattern) {
                        findings.append(SecurityFinding(
                            componentKey: key,
                            pattern: "MCP command contains \(pattern)",
                            severity: .warning,
                            line: "command: \(command)"
                        ))
                    }
                }
            }

            // Check env vars for non-localhost URLs
            if let env = json["env"] as? [String: String] {
                for (envKey, envValue) in env {
                    if (envValue.hasPrefix("http://") || envValue.hasPrefix("https://"))
                        && !envValue.contains("localhost") && !envValue.contains("127.0.0.1") {
                        findings.append(SecurityFinding(
                            componentKey: key,
                            pattern: "MCP env var with external URL",
                            severity: .warning,
                            line: "\(envKey)=\(envValue)"
                        ))
                    }
                }
            }
        }
    }
}
