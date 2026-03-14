import Foundation
import CommonCrypto

/// Summary of component changes after a sync operation.
struct SyncChangeSummary {
    struct ComponentChange {
        let name: String
        let type: ComponentType
        let source: String
        let stack: String
    }
    let added: [ComponentChange]
    let removed: [ComponentChange]
    let modified: [ComponentChange]
    var hasChanges: Bool { !added.isEmpty || !removed.isEmpty || !modified.isEmpty }

    /// Derive affected registry names from the component changes.
    var registriesUpdated: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for change in added + removed + modified {
            if seen.insert(change.source).inserted {
                result.append(change.source)
            }
        }
        return result
    }
}

/// Detects changes in AI components across sync operations by snapshotting and diffing.
class SyncChangeDetector {

    private(set) var hasSnapshot = false
    private var snapshotKeys: Set<String> = []
    private var snapshotComponents: [(name: String, source: String, stack: String, type: ComponentType, key: String)] = []
    private var snapshotHashes: [String: String] = [:]  // key → content hash

    /// Capture current component list as a baseline for comparison.
    func snapshot(stacks: Set<String>, registries: [RegistryConfig]) {
        let components = AIComponentRegistry.shared.listActiveComponents(
            stacks: stacks,
            registries: registries
        )
        snapshotComponents = components
        snapshotKeys = Set(components.map { $0.key })
        snapshotHashes = [:]
        for comp in components {
            if let path = contentFilePath(key: comp.key, type: comp.type) {
                snapshotHashes[comp.key] = fileHash(at: path)
            }
        }
        hasSnapshot = true
    }

    /// Diff current components against the snapshot and return a summary.
    func computeChanges(stacks: Set<String>, registries: [RegistryConfig]) -> SyncChangeSummary {
        let current = AIComponentRegistry.shared.listActiveComponents(
            stacks: stacks,
            registries: registries
        )
        let currentKeys = Set(current.map { $0.key })

        let addedKeys = currentKeys.subtracting(snapshotKeys)
        let removedKeys = snapshotKeys.subtracting(currentKeys)
        let commonKeys = currentKeys.intersection(snapshotKeys)

        let added = current.filter { addedKeys.contains($0.key) }.map {
            SyncChangeSummary.ComponentChange(name: $0.name, type: $0.type, source: $0.source, stack: $0.stack)
        }
        let removed = snapshotComponents.filter { removedKeys.contains($0.key) }.map {
            SyncChangeSummary.ComponentChange(name: $0.name, type: $0.type, source: $0.source, stack: $0.stack)
        }

        // Detect modified components by comparing content hashes
        var modified: [SyncChangeSummary.ComponentChange] = []
        for comp in current where commonKeys.contains(comp.key) {
            if let path = contentFilePath(key: comp.key, type: comp.type) {
                let newHash = fileHash(at: path)
                let oldHash = snapshotHashes[comp.key] ?? ""
                if !newHash.isEmpty && newHash != oldHash {
                    modified.append(SyncChangeSummary.ComponentChange(
                        name: comp.name, type: comp.type, source: comp.source, stack: comp.stack
                    ))
                }
            }
        }

        return SyncChangeSummary(
            added: added,
            removed: removed,
            modified: modified
        )
    }

    // MARK: - Private

    /// Resolve the main content file path for a component key.
    /// Key format: "registryName/stack/type/componentName"
    private func contentFilePath(key: String, type: ComponentType) -> URL? {
        let parts = key.split(separator: "/", maxSplits: 3)
        guard parts.count == 4 else { return nil }
        let regName = String(parts[0])
        let stack = String(parts[1])
        let name = String(parts[3])

        let regPath = RegistryManager.shared.registryPath(name: regName)
        let stackPrefix = stack == "common" ? "common" : "stacks/\(stack)"

        switch type {
        case .skill:
            return regPath.appendingPathComponent("\(stackPrefix)/skills/\(name)/SKILL.md")
        case .rule:
            return regPath.appendingPathComponent("\(stackPrefix)/rules/\(name).md")
        case .prompt:
            return regPath.appendingPathComponent("\(stackPrefix)/prompts/\(name).md")
        case .agent:
            return regPath.appendingPathComponent("\(stackPrefix)/agents/\(name)/AGENT.toml")
        case .mcpServer:
            return regPath.appendingPathComponent("\(stackPrefix)/mcp-servers/\(name).json")
        case .hook:
            return regPath.appendingPathComponent("\(stackPrefix)/hooks/\(name)")
        }
    }

    /// Simple SHA-256 hash of file contents, or empty string if unreadable.
    private func fileHash(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
