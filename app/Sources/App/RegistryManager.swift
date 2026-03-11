import Foundation

/// Errors that can occur during registry sync operations.
enum RegistrySyncError: Error, LocalizedError {
    case cloneFailed(name: String, stderr: String)
    case pullFailed(name: String, stderr: String)
    case invalidStructure(name: String, details: String)
    case gitNotFound

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

    // MARK: - Public API

    /// Clone or pull all configured registries. Runs on a background queue.
    func syncAll(
        registries: [(name: String, url: String, branch: String)],
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
                let result = self.syncOneInternal(name: reg.name, url: reg.url, branch: reg.branch, force: force)
                results[reg.name] = result
            }
        }
    }

    /// Sync a single registry immediately (blocking). Returns result.
    @discardableResult
    func syncOne(name: String, url: String, branch: String) -> Result<Void, RegistrySyncError> {
        return syncOneInternal(name: name, url: url, branch: branch, force: true)
    }

    /// Remove a cloned registry.
    func removeRegistry(name: String) {
        let repoDir = registriesDir.appendingPathComponent(name)
        try? fm.removeItem(at: repoDir)
        removeMeta(name: name)
        registryStatuses[name] = .notCloned
        postStatusChange()
    }

    /// Get the local path for a registry's clone.
    func registryPath(name: String) -> URL {
        registriesDir.appendingPathComponent(name)
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

    private func syncOneInternal(name: String, url: String, branch: String, force: Bool) -> Result<Void, RegistrySyncError> {
        setStatus(name, .syncing)

        let repoDir = registriesDir.appendingPathComponent(name)
        let result: Result<Void, RegistrySyncError>

        if fm.fileExists(atPath: repoDir.path) {
            if !force && !shouldSync(name: name) {
                // Already up to date
                if let meta = loadMeta()[name],
                   let ts = meta["lastSync"] as? TimeInterval,
                   let hash = meta["commitHash"] as? String {
                    setStatus(name, .synced(lastSync: Date(timeIntervalSince1970: ts), commitHash: hash))
                }
                return .success(())
            }
            result = pullRegistry(at: repoDir, branch: branch, name: name)
        } else {
            result = cloneRegistry(url: url, to: repoDir, branch: branch, name: name)
        }

        switch result {
        case .success:
            let commitHash = currentCommit(at: repoDir)
            updateMeta(name: name, commitHash: commitHash)

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

    private func updateMeta(name: String, commitHash: String) {
        var meta = loadMeta()
        meta[name] = [
            "lastSync": Date().timeIntervalSince1970,
            "commitHash": commitHash,
        ]
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
