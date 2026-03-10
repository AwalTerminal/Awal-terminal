import Foundation

/// Manages skill registry Git repos: clone, pull, caching, and sync metadata.
class RegistryManager {

    static let shared = RegistryManager()

    private let fm = FileManager.default
    private let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/awal")
    private var registriesDir: URL { configDir.appendingPathComponent("registries") }
    private var metaFile: URL { configDir.appendingPathComponent("ai-component-meta.json") }

    private var syncInProgress = false

    // MARK: - Public API

    /// Clone or pull all configured registries. Runs on a background queue.
    func syncAll(registries: [(name: String, url: String, branch: String)], force: Bool = false, completion: (() -> Void)? = nil) {
        guard !syncInProgress else {
            completion?()
            return
        }
        syncInProgress = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer {
                self.syncInProgress = false
                DispatchQueue.main.async { completion?() }
            }

            for reg in registries {
                let repoDir = self.registriesDir.appendingPathComponent(reg.name)

                if self.fm.fileExists(atPath: repoDir.path) {
                    if !force && !self.shouldSync(name: reg.name) {
                        continue
                    }
                    self.pullRegistry(at: repoDir, branch: reg.branch)
                } else {
                    self.cloneRegistry(url: reg.url, to: repoDir, branch: reg.branch)
                }

                // Update metadata
                let commitHash = self.currentCommit(at: repoDir)
                self.updateMeta(name: reg.name, commitHash: commitHash)
            }
        }
    }

    /// Sync a single registry immediately (blocking).
    func syncOne(name: String, url: String, branch: String) {
        let repoDir = registriesDir.appendingPathComponent(name)

        if fm.fileExists(atPath: repoDir.path) {
            pullRegistry(at: repoDir, branch: branch)
        } else {
            cloneRegistry(url: url, to: repoDir, branch: branch)
        }

        let commitHash = currentCommit(at: repoDir)
        updateMeta(name: name, commitHash: commitHash)
    }

    /// Remove a cloned registry.
    func removeRegistry(name: String) {
        let repoDir = registriesDir.appendingPathComponent(name)
        try? fm.removeItem(at: repoDir)
        removeMeta(name: name)
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

    // MARK: - Git Operations

    private func cloneRegistry(url: String, to dir: URL, branch: String) {
        try? fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["clone", "--depth", "1", "--branch", branch, url, dir.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                NSLog("[AIComponentRegistry] Failed to clone \(url)")
            }
        } catch {
            NSLog("[AIComponentRegistry] Clone error: \(error)")
        }
    }

    private func pullRegistry(at dir: URL, branch: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir.path, "pull", "--ff-only", "origin", branch]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            NSLog("[AIComponentRegistry] Pull error: \(error)")
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
