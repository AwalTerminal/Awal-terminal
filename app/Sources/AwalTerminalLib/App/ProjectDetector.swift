import Foundation

/// Detects project stack types by scanning for marker files in a directory.
struct ProjectDetector {

    /// Built-in stack detection rules.
    static let builtInRules: [String: [String]] = [
        "go":      ["go.mod", "go.sum"],
        "flutter": ["pubspec.yaml"],
        "swift":   ["Package.swift", "*.xcodeproj", "*.xcworkspace"],
        "python":  ["pyproject.toml", "setup.py", "requirements.txt"],
        "csharp":  ["*.csproj", "*.sln"],
        "rust":    ["Cargo.toml"],
        "node":    ["package.json"],
        "java":    ["pom.xml", "build.gradle", "build.gradle.kts"],
        "kotlin":  ["build.gradle.kts", "*.kt"],
        "php":     ["composer.json", "artisan", "*.php"],
        "ruby":    ["Gemfile", "*.gemspec", "Rakefile"],
        "zig":     ["build.zig"],
        "elixir":  ["mix.exs"],
        "cpp":     ["CMakeLists.txt", "Makefile", "*.cpp"],
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

        // Collect directories to scan: root + immediate subdirectories (for monorepos)
        var dirsToScan = [path]
        if let children = try? fm.contentsOfDirectory(atPath: path) {
            for child in children where !child.hasPrefix(".") {
                let childPath = (path as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: childPath, isDirectory: &isDir), isDir.boolValue {
                    dirsToScan.append(childPath)
                }
            }
        }

        for (stack, markers) in rules {
            for marker in markers {
                var found = false
                for dir in dirsToScan {
                    if marker.contains("*") {
                        if matchesGlob(marker, inDirectory: dir, fileManager: fm) {
                            found = true
                            break
                        }
                    } else {
                        let filePath = (dir as NSString).appendingPathComponent(marker)
                        if fm.fileExists(atPath: filePath) {
                            found = true
                            break
                        }
                    }
                }
                if found {
                    detected.insert(stack)
                    break
                }
            }
        }

        // Detect sub-stacks (frameworks) based on detected parent stacks
        let subStacks = detectSubStacks(parentStacks: detected, path: path)
        detected.formUnion(subStacks)

        return detected
    }

    /// Sub-stack detection rules — keyed by parent stack, containing framework-level detections.
    static let builtInSubStackRules: [String: [String: [String]]] = [
        "node": [
            "nextjs":  ["next.config.js", "next.config.mjs", "next.config.ts"],
            "nuxt":    ["nuxt.config.ts", "nuxt.config.js"],
            "remix":   ["remix.config.js", "remix.config.ts"],
            "nestjs":  ["nest-cli.json"],
        ],
        "python": [
            "django":  ["manage.py"],
            "flask":   ["app.py"],
        ],
        "swift": [
            "vapor":   ["Sources/App/configure.swift"],
        ],
        "ruby": [
            "rails":   ["bin/rails", "config/routes.rb"],
        ],
        "php": [
            "laravel": ["artisan", "app/Http/Kernel.php"],
        ],
    ]

    /// Detect framework-level sub-stacks based on already-detected parent stacks.
    static func detectSubStacks(parentStacks: Set<String>, path: String) -> Set<String> {
        let fm = FileManager.default
        var subStacks = Set<String>()

        for parent in parentStacks {
            guard let rules = builtInSubStackRules[parent] else { continue }

            for (subStack, markers) in rules {
                for marker in markers {
                    let filePath = (path as NSString).appendingPathComponent(marker)
                    if fm.fileExists(atPath: filePath) {
                        subStacks.insert(subStack)
                        break
                    }
                }
            }

            // Dependency-based detection for node sub-stacks
            if parent == "node" {
                let packageJson = (path as NSString).appendingPathComponent("package.json")
                if let content = try? String(contentsOfFile: packageJson, encoding: .utf8) {
                    let depChecks: [(name: String, dep: String)] = [
                        ("nextjs", "\"next\""),
                        ("express", "\"express\""),
                        ("nuxt", "\"nuxt\""),
                        ("remix", "\"@remix-run/"),
                        ("nestjs", "\"@nestjs/"),
                    ]
                    for (name, dep) in depChecks {
                        if content.contains(dep) {
                            subStacks.insert(name)
                        }
                    }
                }
            }

            // Dependency-based detection for python sub-stacks
            if parent == "python" {
                for depFile in ["requirements.txt", "pyproject.toml", "setup.py", "Pipfile"] {
                    let filePath = (path as NSString).appendingPathComponent(depFile)
                    if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                        if content.contains("fastapi") { subStacks.insert("fastapi") }
                        if content.contains("django") { subStacks.insert("django") }
                        if content.contains("flask") { subStacks.insert("flask") }
                    }
                }
            }

            // Dependency-based detection for go sub-stacks
            if parent == "go" {
                let goMod = (path as NSString).appendingPathComponent("go.mod")
                if let content = try? String(contentsOfFile: goMod, encoding: .utf8) {
                    let goFrameworks: [(name: String, dep: String)] = [
                        ("gin", "github.com/gin-gonic/gin"),
                        ("echo", "github.com/labstack/echo"),
                        ("fiber", "github.com/gofiber/fiber"),
                        ("chi", "github.com/go-chi/chi"),
                    ]
                    for (name, dep) in goFrameworks {
                        if content.contains(dep) {
                            subStacks.insert(name)
                        }
                    }
                }
            }
        }

        return subStacks
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
