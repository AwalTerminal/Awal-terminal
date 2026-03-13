import Foundation

/// Errors that can occur during registry sync operations.
enum RegistrySyncError: Error, LocalizedError {
    case cloneFailed(name: String, stderr: String)
    case pullFailed(name: String, stderr: String)
    case invalidStructure(name: String, details: String)
    case gitNotFound
    case localskillsNotFound
    case localskillsInstallFailed(name: String, stderr: String)

    var errorDescription: String? {
        switch self {
        case .cloneFailed(let name, let stderr):
            return "Failed to clone '\(name)': \(stderr)"
        case .pullFailed(let name, let stderr):
            return "Failed to pull '\(name)': \(stderr)"
        case .invalidStructure(let name, let details):
            return "Invalid structure in '\(name)': \(details)"
        case .gitNotFound:
            return "Git executable not found at /usr/bin/git"
        case .localskillsNotFound:
            return "localskills CLI not found. Install with: npm i -g @localskills/cli"
        case .localskillsInstallFailed(let name, let stderr):
            return "Failed to install localskills '\(name)': \(stderr)"
        }
    }
}

/// Per-registry sync status.
enum RegistryStatus {
    case notCloned
    case synced(lastSync: Date, commitHash: String)
    case syncing
    case error(String)
}

/// Manages skill registry Git repos: clone, pull, caching, and sync metadata.
class RegistryManager {

    static let shared = RegistryManager()

    static let statusDidChange = Notification.Name("RegistryManagerStatusDidChange")

    private let fm = FileManager.default
    private let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/awal")
    private var registriesDir: URL { configDir.appendingPathComponent("registries") }
    private var metaFile: URL { configDir.appendingPathComponent("ai-component-meta.json") }

    private var syncInProgress = false

    /// Per-registry status tracking.
    private(set) var registryStatuses: [String: RegistryStatus] = [:]

    /// Path overrides for local-type registries (read in-place, no copy).
    private(set) var pathOverrides: [String: URL] = [:]

    /// Security scan results per registry.
    private(set) var scanResults: [String: [SecurityFinding]] = [:]

    /// Path for the local registry (used by imports).
    var localRegistryPath: URL { registriesDir.appendingPathComponent("local") }

    // MARK: - Public API

    /// Clone or pull all configured registries. Runs on a background queue.
    func syncAll(
        registries: [RegistryConfig],
        force: Bool = false,
        completion: (([String: Result<Void, RegistrySyncError>]) -> Void)? = nil
    ) {
        guard !syncInProgress else {
            completion?([:])
            return
        }
        syncInProgress = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var results: [String: Result<Void, RegistrySyncError>] = [:]

            defer {
                self.syncInProgress = false
                DispatchQueue.main.async { completion?(results) }
            }

            for reg in registries {
                let result: Result<Void, RegistrySyncError>
                switch reg.type {
                case .git:
                    result = self.syncOneInternal(name: reg.name, url: reg.url, branch: reg.branch, tag: reg.tag, force: force)
                case .localskills:
                    result = self.syncLocalSkills(name: reg.name, slugs: reg.slugs, force: force)
                case .local:
                    result = self.syncLocalDir(name: reg.name, path: reg.path)
                }
                results[reg.name] = result
            }
        }
    }

    /// Sync a single registry immediately (blocking). Returns result.
    @discardableResult
    func syncOne(registry reg: RegistryConfig) -> Result<Void, RegistrySyncError> {
        switch reg.type {
        case .git:
            return syncOneInternal(name: reg.name, url: reg.url, branch: reg.branch, tag: reg.tag, force: true)
        case .localskills:
            return syncLocalSkills(name: reg.name, slugs: reg.slugs, force: true)
        case .local:
            return syncLocalDir(name: reg.name, path: reg.path)
        }
    }

    /// Remove a cloned registry.
    func removeRegistry(name: String) {
        pathOverrides.removeValue(forKey: name)
        let repoDir = registriesDir.appendingPathComponent(name)
        try? fm.removeItem(at: repoDir)
        removeMeta(name: name)
        registryStatuses[name] = .notCloned
        postStatusChange()
    }

    /// Get the local path for a registry's clone (or override for local type).
    func registryPath(name: String) -> URL {
        if let override = pathOverrides[name] { return override }
        return registriesDir.appendingPathComponent(name)
    }

    /// Check if a registry has been cloned.
    func isCloned(name: String) -> Bool {
        fm.fileExists(atPath: registriesDir.appendingPathComponent(name).path)
    }

    /// Read last sync time for display.
    func lastSyncTime(name: String) -> Date? {
        let meta = loadMeta()
        guard let ts = meta[name]?["lastSync"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// Read last sync time across all registries.
    func lastSyncTimeAny() -> Date? {
        let meta = loadMeta()
        var latest: Date? = nil
        for (_, info) in meta {
            if let ts = info["lastSync"] as? TimeInterval {
                let date = Date(timeIntervalSince1970: ts)
                if latest == nil || date > latest! {
                    latest = date
                }
            }
        }
        return latest
    }

    /// Validate registry structure after clone/pull.
    /// Returns a list of warnings (empty if structure is valid).
    func validateStructure(name: String) -> [String] {
        let repoDir = registriesDir.appendingPathComponent(name)
        guard fm.fileExists(atPath: repoDir.path) else {
            return ["Repository directory does not exist"]
        }

        var warnings: [String] = []
        let commonDir = repoDir.appendingPathComponent("common")
        let stacksDir = repoDir.appendingPathComponent("stacks")

        let hasCommon = fm.fileExists(atPath: commonDir.path)
        let hasStacks = fm.fileExists(atPath: stacksDir.path)

        if !hasCommon && !hasStacks {
            warnings.append("Missing both common/ and stacks/ directories")
        }

        if hasCommon {
            let recognized = ["skills", "rules", "prompts", "agents", "mcp-servers", "hooks", "commands"]
            if let contents = try? fm.contentsOfDirectory(atPath: commonDir.path) {
                for item in contents where !item.hasPrefix(".") {
                    if !recognized.contains(item) {
                        warnings.append("Unrecognized directory: common/\(item)")
                    }
                }
            }
        }

        return warnings
    }

    /// Parse a registry.toml file and return stack detection rules.
    func parseRegistryToml(name: String) -> [String: [String]] {
        let tomlPath = registriesDir
            .appendingPathComponent(name)
            .appendingPathComponent("registry.toml")

        guard let contents = try? String(contentsOf: tomlPath, encoding: .utf8) else {
            return [:]
        }

        var rules: [String: [String]] = [:]
        var currentSection = ""

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Parse detect arrays: detect = ["go.mod", "go.sum"]
            if currentSection.hasPrefix("stacks."),
               line.hasPrefix("detect") {
                let stack = String(currentSection.dropFirst("stacks.".count))
                if let bracketStart = line.firstIndex(of: "["),
                   let bracketEnd = line.lastIndex(of: "]") {
                    let inner = line[line.index(after: bracketStart)..<bracketEnd]
                    let markers = inner.split(separator: ",").map { item in
                        item.trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                    rules[stack] = markers
                }
            }
        }

        return rules
    }

    // MARK: - Internal Sync

    private func syncOneInternal(name: String, url: String, branch: String, tag: String? = nil, force: Bool) -> Result<Void, RegistrySyncError> {
        // Local registry — skip git operations
        if name == "local" {
            let repoDir = registriesDir.appendingPathComponent(name)
            if fm.fileExists(atPath: repoDir.path) {
                setStatus(name, .synced(lastSync: Date(), commitHash: "local"))
            } else {
                setStatus(name, .notCloned)
            }
            return .success(())
        }

        setStatus(name, .syncing)

        let repoDir = registriesDir.appendingPathComponent(name)
        let result: Result<Void, RegistrySyncError>

        if fm.fileExists(atPath: repoDir.path) {
            if let tag {
                // Tag-based: check if stored tag matches; if same, skip (tags are immutable)
                let meta = loadMeta()
                let storedTag = meta[name]?["tag"] as? String
                if storedTag == tag && !force {
                    if let ts = meta[name]?["lastSync"] as? TimeInterval,
                       let hash = meta[name]?["commitHash"] as? String {
                        setStatus(name, .synced(lastSync: Date(timeIntervalSince1970: ts), commitHash: hash))
                    }
                    return .success(())
                } else if storedTag != tag {
                    // Different tag — delete and re-clone
                    try? fm.removeItem(at: repoDir)
                    result = cloneRegistry(url: url, to: repoDir, branch: tag, name: name)
                } else {
                    result = .success(())
                }
            } else {
                if !force && !shouldSync(name: name) {
                    if let meta = loadMeta()[name],
                       let ts = meta["lastSync"] as? TimeInterval,
                       let hash = meta["commitHash"] as? String {
                        setStatus(name, .synced(lastSync: Date(timeIntervalSince1970: ts), commitHash: hash))
                    }
                    return .success(())
                }
                result = pullRegistry(at: repoDir, branch: branch, name: name)
            }
        } else {
            let cloneBranch = tag ?? branch
            result = cloneRegistry(url: url, to: repoDir, branch: cloneBranch, name: name)
        }

        switch result {
        case .success:
            let commitHash = currentCommit(at: repoDir)
            updateMeta(name: name, commitHash: commitHash, tag: tag)

            // Run security scan if enabled
            if AppConfig.shared.aiComponentsSecurityScan {
                let allStacks = Set(ProjectDetector.builtInRules.keys)
                let findings = ComponentSecurityScanner.scan(registryPath: repoDir, stacks: allStacks)
                DispatchQueue.main.async { [weak self] in
                    self?.scanResults[name] = findings
                }
            }

            // Validate and set status with warnings
            let warnings = validateStructure(name: name)
            if !warnings.isEmpty {
                setStatus(name, .error(warnings.first ?? "Invalid structure"))
            } else {
                setStatus(name, .synced(lastSync: Date(), commitHash: commitHash))
            }

        case .failure(let error):
            setStatus(name, .error(error.localizedDescription))
        }

        return result
    }

    // MARK: - localskills Sync

    /// Build an environment dictionary with PATH including the binary's directory.
    /// GUI apps don't inherit the shell PATH, so child processes can't find `node` etc.
    private func processEnvironment(binPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let binDir = (binPath as NSString).deletingLastPathComponent
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(binDir):\(existing):/usr/local/bin:/opt/homebrew/bin"
        return env
    }

    private func findLocalskillsBinary() -> String? {
        let home = fm.homeDirectoryForCurrentUser.path
        // Check well-known locations (GUI apps don't inherit shell PATH)
        let candidates = [
            "/usr/local/bin/localskills",
            "/opt/homebrew/bin/localskills",
            "\(home)/.npm-global/bin/localskills",
            "\(home)/.nvm/current/bin/localskills",
            "/opt/homebrew/lib/node_modules/.bin/localskills",
        ]
        for path in candidates {
            if fm.fileExists(atPath: path) { return path }
        }

        // Check nvm versions (e.g. ~/.nvm/versions/node/v20.x.x/bin/localskills)
        let nvmVersionsDir = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmVersionsDir) {
            for version in versions.sorted().reversed() {
                let binPath = "\(nvmVersionsDir)/\(version)/bin/localskills"
                if fm.fileExists(atPath: binPath) { return binPath }
            }
        }

        // Last resort: shell login to resolve PATH
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which localskills"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty && fm.fileExists(atPath: path) { return path }
            }
        } catch {}
        return nil
    }

    private func syncLocalSkills(name: String, slugs: [String], force: Bool) -> Result<Void, RegistrySyncError> {
        var binary = findLocalskillsBinary()
        if binary == nil {
            // Auto-install the CLI
            if case .failure(let err) = installLocalskillsCLI() {
                setStatus(name, .error(err.localizedDescription))
                return .failure(err)
            }
            binary = findLocalskillsBinary()
        }
        guard let binary else {
            setStatus(name, .error("localskills CLI not found after install"))
            return .failure(.localskillsNotFound)
        }

        setStatus(name, .syncing)

        let destDir = registriesDir.appendingPathComponent(name).appendingPathComponent("common/skills")
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        for slug in slugs {
            let tempDir = fm.temporaryDirectory.appendingPathComponent("localskills-\(UUID().uuidString)")
            try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempDir) }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binary)
            proc.arguments = ["install", "--target", "claude", "--project", tempDir.path, "--copy", slug]
            proc.environment = processEnvironment(binPath: binary)
            proc.standardOutput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            proc.standardError = stderrPipe

            do {
                try proc.run()
                proc.waitUntilExit()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus != 0 {
                    setStatus(name, .error("Install failed for \(slug)"))
                    return .failure(.localskillsInstallFailed(name: slug, stderr: stderrStr))
                }

                // Copy skill file from temp staging to registry dir
                let skillSource = tempDir.appendingPathComponent(".claude/skills/\(slug)/SKILL.md")
                let skillDest = destDir.appendingPathComponent(slug)
                try? fm.createDirectory(at: skillDest, withIntermediateDirectories: true)
                let destFile = skillDest.appendingPathComponent("SKILL.md")
                try? fm.removeItem(at: destFile)
                if fm.fileExists(atPath: skillSource.path) {
                    try fm.copyItem(at: skillSource, to: destFile)
                }
            } catch {
                setStatus(name, .error("Install failed for \(slug)"))
                return .failure(.localskillsInstallFailed(name: slug, stderr: error.localizedDescription))
            }
        }

        updateMeta(name: name, commitHash: "localskills")
        setStatus(name, .synced(lastSync: Date(), commitHash: "localskills"))
        return .success(())
    }

    // MARK: - localskills CLI Install

    private func findNpmBinary() -> String? {
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/npm",
            "/opt/homebrew/bin/npm",
            "\(home)/.npm-global/bin/npm",
            "\(home)/.nvm/current/bin/npm",
        ]
        for path in candidates {
            if fm.fileExists(atPath: path) { return path }
        }

        // Check nvm versions
        let nvmVersionsDir = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmVersionsDir) {
            for version in versions.sorted().reversed() {
                let binPath = "\(nvmVersionsDir)/\(version)/bin/npm"
                if fm.fileExists(atPath: binPath) { return binPath }
            }
        }

        // Last resort: shell login to resolve PATH
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which npm"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty && fm.fileExists(atPath: path) { return path }
            }
        } catch {}
        return nil
    }

    private func installLocalskillsCLI() -> Result<Void, RegistrySyncError> {
        guard let npm = findNpmBinary() else {
            return .failure(.localskillsNotFound)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: npm)
        proc.arguments = ["install", "-g", "@localskills/cli"]
        proc.environment = processEnvironment(binPath: npm)
        proc.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if proc.terminationStatus != 0 {
                return .failure(.localskillsInstallFailed(name: "@localskills/cli", stderr: stderrStr))
            }
            return .success(())
        } catch {
            return .failure(.localskillsInstallFailed(name: "@localskills/cli", stderr: error.localizedDescription))
        }
    }

    // MARK: - Local Directory Sync

    private func syncLocalDir(name: String, path: String?) -> Result<Void, RegistrySyncError> {
        guard let path, !path.isEmpty else {
            setStatus(name, .error("No path configured"))
            return .failure(.invalidStructure(name: name, details: "No path configured"))
        }

        if fm.fileExists(atPath: path) {
            pathOverrides[name] = URL(fileURLWithPath: path)
            updateMeta(name: name, commitHash: "local")
            setStatus(name, .synced(lastSync: Date(), commitHash: "local"))
            return .success(())
        } else {
            setStatus(name, .error("Directory not found: \(path)"))
            return .failure(.invalidStructure(name: name, details: "Directory not found: \(path)"))
        }
    }

    // MARK: - Git Operations

    private func cloneRegistry(url: String, to dir: URL, branch: String, name: String) -> Result<Void, RegistrySyncError> {
        guard fm.fileExists(atPath: "/usr/bin/git") else {
            return .failure(.gitNotFound)
        }

        try? fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["clone", "--depth", "1", "--branch", branch, url, dir.path]
        proc.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if proc.terminationStatus != 0 {
                return .failure(.cloneFailed(name: name, stderr: stderrStr))
            }
            return .success(())
        } catch {
            return .failure(.cloneFailed(name: name, stderr: error.localizedDescription))
        }
    }

    private func pullRegistry(at dir: URL, branch: String, name: String) -> Result<Void, RegistrySyncError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir.path, "pull", "--ff-only", "origin", branch]
        proc.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if proc.terminationStatus != 0 {
                return .failure(.pullFailed(name: name, stderr: stderrStr))
            }
            return .success(())
        } catch {
            return .failure(.pullFailed(name: name, stderr: error.localizedDescription))
        }
    }

    private func currentCommit(at dir: URL) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir.path, "rev-parse", "HEAD"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - Status Tracking

    private func setStatus(_ name: String, _ status: RegistryStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.registryStatuses[name] = status
            self?.postStatusChange()
        }
    }

    private func postStatusChange() {
        NotificationCenter.default.post(name: Self.statusDidChange, object: self)
    }

    // MARK: - Sync Metadata

    private func shouldSync(name: String) -> Bool {
        let meta = loadMeta()
        guard let info = meta[name],
              let lastSync = info["lastSync"] as? TimeInterval else {
            return true
        }
        let interval = TimeInterval(AppConfig.shared.aiComponentsSyncInterval)
        return Date().timeIntervalSince1970 - lastSync >= interval
    }

    private func loadMeta() -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: metaFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return [:]
        }
        return json
    }

    private func updateMeta(name: String, commitHash: String, tag: String? = nil) {
        var meta = loadMeta()
        var info: [String: Any] = [
            "lastSync": Date().timeIntervalSince1970,
            "commitHash": commitHash,
        ]
        if let tag { info["tag"] = tag }
        meta[name] = info
        saveMeta(meta)
    }

    private func removeMeta(name: String) {
        var meta = loadMeta()
        meta.removeValue(forKey: name)
        saveMeta(meta)
    }

    private func saveMeta(_ meta: [String: [String: Any]]) {
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: metaFile)
        }
    }
}
