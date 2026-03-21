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
    static let componentsDidChange = Notification.Name("RegistryManagerComponentsDidChange")

    private let fm = FileManager.default
    private let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/awal")
    private var registriesDir: URL { configDir.appendingPathComponent("registries") }
    private var metaFile: URL { configDir.appendingPathComponent("ai-component-meta.json") }

    private let syncLock = NSLock()
    private var _syncInProgress = false
    private var syncInProgress: Bool {
        get { syncLock.lock(); defer { syncLock.unlock() }; return _syncInProgress }
        set { syncLock.lock(); _syncInProgress = newValue; syncLock.unlock() }
    }

    /// Serial queue protecting all mutable shared state.
    private let stateQueue = DispatchQueue(label: "com.awal.registrymanager.state")

    /// Per-registry status tracking.
    private var _registryStatuses: [String: RegistryStatus] = [:]
    private(set) var registryStatuses: [String: RegistryStatus] {
        get { stateQueue.sync { _registryStatuses } }
        set { stateQueue.sync { _registryStatuses = newValue } }
    }

    /// Path overrides for local-type registries (read in-place, no copy).
    private var _pathOverrides: [String: URL] = [:]
    private(set) var pathOverrides: [String: URL] {
        get { stateQueue.sync { _pathOverrides } }
        set { stateQueue.sync { _pathOverrides = newValue } }
    }

    /// Security scan results per registry.
    private var _scanResults: [String: [SecurityFinding]] = [:]
    private(set) var scanResults: [String: [SecurityFinding]] {
        get { stateQueue.sync { _scanResults } }
        set { stateQueue.sync { _scanResults = newValue } }
    }

    /// Resolved mapping mode per registry.
    private var _mappingModes: [String: RegistryMappingMode] = [:]
    var mappingModes: [String: RegistryMappingMode] {
        get { stateQueue.sync { _mappingModes } }
        set { stateQueue.sync { _mappingModes = newValue } }
    }

    /// Resolved components from mapped/claude-plugin registries.
    private var _mappedComponents: [String: [ResolvedComponent]] = [:]
    var mappedComponents: [String: [ResolvedComponent]] {
        get { stateQueue.sync { _mappedComponents } }
        set { stateQueue.sync { _mappedComponents = newValue } }
    }

    /// Pending sync request queued while a sync is already in progress.
    private var pendingSync: (registries: [RegistryConfig], force: Bool, completion: (([String: Result<Void, RegistrySyncError>]) -> Void)?)?

    /// Path for the local registry (used by imports).
    var localRegistryPath: URL { registriesDir.appendingPathComponent("local") }

    // MARK: - Thread-Safe State Accessors

    func setMappingMode(_ mode: RegistryMappingMode, for name: String) {
        stateQueue.sync { _mappingModes[name] = mode }
    }

    func getMappingMode(for name: String) -> RegistryMappingMode? {
        stateQueue.sync { _mappingModes[name] }
    }

    func setMappedComponents(_ components: [ResolvedComponent], for name: String) {
        stateQueue.sync { _mappedComponents[name] = components }
    }

    func getMappedComponents(for name: String) -> [ResolvedComponent]? {
        stateQueue.sync { _mappedComponents[name] }
    }

    func removeMappedComponents(for name: String) {
        stateQueue.sync { _ = _mappedComponents.removeValue(forKey: name) }
    }

    func setScanResults(_ findings: [SecurityFinding], for name: String) {
        stateQueue.sync { _scanResults[name] = findings }
    }

    func setRegistryStatus(_ status: RegistryStatus, for name: String) {
        stateQueue.sync { _registryStatuses[name] = status }
    }

    func getRegistryStatus(for name: String) -> RegistryStatus? {
        stateQueue.sync { _registryStatuses[name] }
    }

    func setPathOverride(_ url: URL, for name: String) {
        stateQueue.sync { _pathOverrides[name] = url }
    }

    func removePathOverride(for name: String) {
        stateQueue.sync { _ = _pathOverrides.removeValue(forKey: name) }
    }

    // MARK: - Migrations

    /// Migrate old registry directory names to current defaults.
    /// Called once before mapping resolution to handle renames across versions.
    private static var migrationsRun = false
    func runMigrationsIfNeeded() {
        guard !Self.migrationsRun else { return }
        Self.migrationsRun = true

        // Rename awal-ai-components-registry → awal-components (default name changed)
        let oldDir = registriesDir.appendingPathComponent("awal-ai-components-registry")
        let newDir = registriesDir.appendingPathComponent("awal-components")
        if fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) {
            try? fm.moveItem(at: oldDir, to: newDir)
            // Migrate metadata key
            var meta = loadMeta()
            if let oldMeta = meta["awal-ai-components-registry"] {
                meta["awal-components"] = oldMeta
                meta.removeValue(forKey: "awal-ai-components-registry")
                saveMeta(meta)
            }
            debugLog("RegistryManager: migrated awal-ai-components-registry → awal-components")
        }
    }

    // MARK: - Mapping Resolution

    /// Resolve mapping modes and components for all already-cloned registries.
    /// Called at startup or when the manager window opens to catch registries
    /// that were synced before the mapping feature was added.
    func resolveMappingsIfNeeded(registries: [RegistryConfig]) {
        runMigrationsIfNeeded()
        for reg in registries {
            // Skip if already resolved
            if mappingModes[reg.name] != nil { continue }

            let repoPath = registryPath(name: reg.name)
            guard fm.fileExists(atPath: repoPath.path) else { continue }

            let mode = RegistryMappingResolver.resolveMode(
                registryName: reg.name, repoPath: repoPath, configMapping: reg.mapping
            )
            mappingModes[reg.name] = mode

            switch mode {
            case .claudePlugin:
                let base = RegistryMappingResolver.parseClaudePluginManifest(repoPath: repoPath)
                mappedComponents[reg.name] = RegistryMappingResolver.applyLocalOverrides(
                    base: base, registryName: reg.name, repoPath: repoPath
                )
            case .inRepoMapping:
                if let mapping = RegistryMappingResolver.loadInRepoMapping(repoPath: repoPath) {
                    let base = RegistryMappingResolver.resolveMapping(mapping, repoPath: repoPath)
                    mappedComponents[reg.name] = RegistryMappingResolver.applyLocalOverrides(
                        base: base, registryName: reg.name, repoPath: repoPath
                    )
                }
            case .localMapping:
                if let mapping = RegistryMappingResolver.loadMapping(registryName: reg.name, repoPath: repoPath) {
                    mappedComponents[reg.name] = RegistryMappingResolver.resolveMapping(mapping, repoPath: repoPath)
                }
            default:
                break
            }

            // If the registry has a valid mapping mode, ensure its status reflects synced
            // (it may have been set to .error by old structure validation)
            if mode != .standard && mode != .unmapped {
                let needsStatusFix: Bool
                switch registryStatuses[reg.name] {
                case .error: needsStatusFix = true
                case .none: needsStatusFix = true  // Not initialized yet
                case .notCloned: needsStatusFix = true
                default: needsStatusFix = false
                }
                if needsStatusFix {
                    let ts = lastSyncTime(name: reg.name) ?? Date()
                    let hash = loadMeta()[reg.name]?["commitHash"] as? String ?? ""
                    registryStatuses[reg.name] = .synced(lastSync: ts, commitHash: hash)
                }
            }
        }
    }

    // MARK: - Public API

    /// Synchronously sync all configured registries. Blocks the calling thread.
    /// Use from `AIComponentInjector.inject` to ensure components are available before assembly.
    func syncAllBlocking(
        registries: [RegistryConfig],
        force: Bool = false
    ) -> [String: Result<Void, RegistrySyncError>] {
        guard !syncInProgress else { return [:] }
        syncInProgress = true
        defer { syncInProgress = false }

        var results: [String: Result<Void, RegistrySyncError>] = [:]
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
        return results
    }

    /// Clone or pull all configured registries. Runs on a background queue.
    func syncAll(
        registries: [RegistryConfig],
        force: Bool = false,
        completion: (([String: Result<Void, RegistrySyncError>]) -> Void)? = nil
    ) {
        guard !syncInProgress else {
            // Queue the request instead of dropping it silently
            syncLock.lock()
            pendingSync = (registries, force, completion)
            syncLock.unlock()
            return
        }
        syncInProgress = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var results: [String: Result<Void, RegistrySyncError>] = [:]

            // Snapshot commit hashes before sync for change detection
            let oldMeta = self.loadMeta()
            var oldHashes: [String: String] = [:]
            for reg in registries {
                oldHashes[reg.name] = oldMeta[reg.name]?["commitHash"] as? String ?? ""
            }

            defer {
                self.syncInProgress = false

                // Detect which registries changed by comparing commit hashes
                let newMeta = self.loadMeta()
                var changedRegistries: [String] = []
                for reg in registries {
                    let newHash = newMeta[reg.name]?["commitHash"] as? String ?? ""
                    let oldHash = oldHashes[reg.name] ?? ""
                    if !newHash.isEmpty && newHash != oldHash {
                        changedRegistries.append(reg.name)
                    }
                }

                DispatchQueue.main.async {
                    if !changedRegistries.isEmpty {
                        NotificationCenter.default.post(
                            name: RegistryManager.componentsDidChange,
                            object: self
                        )
                    }
                    completion?(results)
                }

                // Execute pending sync if one was queued
                self.syncLock.lock()
                let pending = self.pendingSync
                self.pendingSync = nil
                self.syncLock.unlock()

                if let pending {
                    self.syncAll(registries: pending.registries, force: pending.force, completion: pending.completion)
                }
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
        removePathOverride(for: name)
        let repoDir = registriesDir.appendingPathComponent(name)
        try? fm.removeItem(at: repoDir)
        removeMeta(name: name)
        setRegistryStatus(.notCloned, for: name)
        postStatusChange()
    }

    /// Get the local path for a registry's clone (or override for local type).
    func registryPath(name: String) -> URL {
        if let override = stateQueue.sync(execute: { _pathOverrides[name] }) { return override }
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

            // Resolve mapping mode for this registry
            let configMapping = AppConfig.shared.aiComponentRegistries
                .first(where: { $0.name == name })?.mapping ?? "auto"
            let mode = RegistryMappingResolver.resolveMode(
                registryName: name, repoPath: repoDir, configMapping: configMapping
            )
            setMappingMode(mode, for: name)

            // Resolve mapped components for non-standard registries
            switch mode {
            case .claudePlugin:
                let base = RegistryMappingResolver.parseClaudePluginManifest(repoPath: repoDir)
                let resolved = RegistryMappingResolver.applyLocalOverrides(
                    base: base, registryName: name, repoPath: repoDir
                )
                setMappedComponents(resolved, for: name)
            case .inRepoMapping:
                if let mapping = RegistryMappingResolver.loadInRepoMapping(repoPath: repoDir) {
                    let base = RegistryMappingResolver.resolveMapping(mapping, repoPath: repoDir)
                    let resolved = RegistryMappingResolver.applyLocalOverrides(
                        base: base, registryName: name, repoPath: repoDir
                    )
                    setMappedComponents(resolved, for: name)
                }
            case .localMapping:
                if let mapping = RegistryMappingResolver.loadMapping(registryName: name, repoPath: repoDir) {
                    let resolved = RegistryMappingResolver.resolveMapping(mapping, repoPath: repoDir)
                    setMappedComponents(resolved, for: name)
                }
            default:
                removeMappedComponents(for: name)
            }

            // Run security scan if enabled
            if AppConfig.shared.aiComponentsSecurityScan {
                let allStacks = Set(ProjectDetector.builtInRules.keys)
                var findings = ComponentSecurityScanner.scan(registryPath: repoDir, stacks: allStacks)
                // Also scan mapped components
                if mode != .standard {
                    let mappedFindings = ComponentSecurityScanner.scanMappedComponents(
                        registryName: name, repoPath: repoDir, mode: mode
                    )
                    findings.append(contentsOf: mappedFindings)
                }
                setScanResults(findings, for: name)
            }

            // Validate and set status with warnings
            // Skip structure validation for mapped registries — they use a different layout
            if mode == .standard {
                let warnings = validateStructure(name: name)
                if !warnings.isEmpty {
                    setStatus(name, .error(warnings.first ?? "Invalid structure"))
                } else {
                    setStatus(name, .synced(lastSync: Date(), commitHash: commitHash))
                }
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

        let dirURL = URL(fileURLWithPath: path)
        guard fm.fileExists(atPath: path) else {
            setStatus(name, .error("Directory not found: \(path)"))
            return .failure(.invalidStructure(name: name, details: "Directory not found: \(path)"))
        }

        setPathOverride(dirURL, for: name)
        updateMeta(name: name, commitHash: "local")
        setStatus(name, .synced(lastSync: Date(), commitHash: "local"))

        // Resolve mapping mode and components (same as syncOneInternal)
        let configMapping = AppConfig.shared.aiComponentRegistries
            .first(where: { $0.name == name })?.mapping ?? "auto"
        let mode = RegistryMappingResolver.resolveMode(
            registryName: name, repoPath: dirURL, configMapping: configMapping
        )
        setMappingMode(mode, for: name)

        switch mode {
        case .claudePlugin:
            let base = RegistryMappingResolver.parseClaudePluginManifest(repoPath: dirURL)
            let resolved = RegistryMappingResolver.applyLocalOverrides(
                base: base, registryName: name, repoPath: dirURL
            )
            setMappedComponents(resolved, for: name)
        case .inRepoMapping:
            if let mapping = RegistryMappingResolver.loadInRepoMapping(repoPath: dirURL) {
                let base = RegistryMappingResolver.resolveMapping(mapping, repoPath: dirURL)
                let resolved = RegistryMappingResolver.applyLocalOverrides(
                    base: base, registryName: name, repoPath: dirURL
                )
                setMappedComponents(resolved, for: name)
            }
        case .localMapping:
            if let mapping = RegistryMappingResolver.loadMapping(registryName: name, repoPath: dirURL) {
                let resolved = RegistryMappingResolver.resolveMapping(mapping, repoPath: dirURL)
                setMappedComponents(resolved, for: name)
            }
        default:
            removeMappedComponents(for: name)
        }

        return .success(())
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
        // Fetch latest from remote, then hard-reset to match.
        // The clone is a read-only cache so we always want to mirror the remote exactly.
        let fetch = Process()
        fetch.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        fetch.arguments = ["-C", dir.path, "fetch", "origin", branch]
        fetch.standardOutput = FileHandle.nullDevice
        let fetchStderrPipe = Pipe()
        fetch.standardError = fetchStderrPipe

        do {
            try fetch.run()
            fetch.waitUntilExit()
            let stderrData = fetchStderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if fetch.terminationStatus != 0 {
                return .failure(.pullFailed(name: name, stderr: stderrStr))
            }
        } catch {
            return .failure(.pullFailed(name: name, stderr: error.localizedDescription))
        }

        // Reset local branch to match the fetched remote state
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        reset.arguments = ["-C", dir.path, "reset", "--hard", "origin/\(branch)"]
        reset.standardOutput = FileHandle.nullDevice
        let resetStderrPipe = Pipe()
        reset.standardError = resetStderrPipe

        do {
            try reset.run()
            reset.waitUntilExit()
            let stderrData = resetStderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if reset.terminationStatus != 0 {
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
        setRegistryStatus(status, for: name)
        DispatchQueue.main.async { [weak self] in
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
