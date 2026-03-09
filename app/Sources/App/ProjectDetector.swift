import Foundation

/// Detects project stack types by scanning for marker files in a directory.
struct ProjectDetector {

    /// Built-in stack detection rules.
    static let builtInRules: [String: [String]] = [
        "go":      ["go.mod", "go.sum"],
        "flutter": ["pubspec.yaml"],
        "swift":   ["Package.swift", "*.xcodeproj"],
        "python":  ["pyproject.toml", "setup.py", "requirements.txt"],
        "csharp":  ["*.csproj", "*.sln"],
        "rust":    ["Cargo.toml"],
        "node":    ["package.json"],
        "java":    ["pom.xml", "build.gradle"],
    ]

    /// Detect which stacks a project directory belongs to.
    /// - Parameters:
    ///   - path: The project root directory
    ///   - registryRules: Additional detection rules from registry.toml files (merged with built-in)
    ///   - overrideStacks: If set from config, skip detection and return these stacks
    /// - Returns: Set of detected stack names
    static func detect(
        path: String,
        registryRules: [String: [String]] = [:],
        overrideStacks: Set<String>? = nil
    ) -> Set<String> {
        // Config override takes priority
        if let overrides = overrideStacks, !overrides.isEmpty {
            return overrides
        }

        // Merge built-in + registry rules
        var rules = builtInRules
        for (stack, markers) in registryRules {
            var existing = rules[stack] ?? []
            for marker in markers where !existing.contains(marker) {
                existing.append(marker)
            }
            rules[stack] = existing
        }

        let fm = FileManager.default
        var detected = Set<String>()

        for (stack, markers) in rules {
            for marker in markers {
                if marker.contains("*") {
                    // Glob pattern — check directory contents
                    if matchesGlob(marker, inDirectory: path, fileManager: fm) {
                        detected.insert(stack)
                        break
                    }
                } else {
                    // Exact file match
                    let filePath = (path as NSString).appendingPathComponent(marker)
                    if fm.fileExists(atPath: filePath) {
                        detected.insert(stack)
                        break
                    }
                }
            }
        }

        return detected
    }

    /// Check if any file in the directory matches a simple glob pattern (e.g. "*.xcodeproj").
    private static func matchesGlob(_ pattern: String, inDirectory dir: String, fileManager fm: FileManager) -> Bool {
        guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { return false }

        // Convert simple glob to check: "*.ext" → check suffix
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(1)) // ".xcodeproj"
            return contents.contains { $0.hasSuffix(suffix) }
        }

        // Prefix glob: "prefix*" → check prefix
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast(1))
            return contents.contains { $0.hasPrefix(prefix) }
        }

        // Fallback: exact match
        return contents.contains(pattern)
    }
}
