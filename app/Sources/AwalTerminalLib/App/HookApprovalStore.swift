import Foundation
import CommonCrypto

/// Persists user approval of registry hook scripts.
///
/// Each approved hook is stored as `{hookKey: sha256Hash}`.  If a hook's
/// content changes after a registry sync the hash will no longer match and
/// the hook is treated as unapproved until the user reviews it again.
final class HookApprovalStore {
    static let shared = HookApprovalStore()

    /// Posted when unapproved hooks are detected during injection.
    /// The `userInfo` dictionary contains `"hooks"` → `[(key: String, url: URL)]`.
    static let unapprovedHooksDetectedNotification = Notification.Name("unapprovedHooksDetected")

    private let storePath: URL
    private var approvals: [String: String] // hookKey → sha256

    private init() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/awal")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        storePath = configDir.appendingPathComponent("approved-hooks.json")
        approvals = [:]
        load()
    }

    // MARK: - Public API

    /// Returns `true` when the hook key exists AND the stored hash matches
    /// the current file contents on disk.
    func isApproved(key: String, fileURL: URL) -> Bool {
        guard let storedHash = approvals[key] else { return false }
        return storedHash == fileHash(at: fileURL)
    }

    /// Approve a hook by storing its key and the SHA-256 of its current content.
    func approve(key: String, fileURL: URL) {
        approvals[key] = fileHash(at: fileURL)
        save()
    }

    /// Revoke approval for a hook.
    func revoke(key: String) {
        approvals.removeValue(forKey: key)
        save()
    }

    /// Partition a list of keyed hooks into approved and unapproved.
    func filterApproved(hooks: [(key: String, url: URL)])
        -> (approved: [URL], unapproved: [(key: String, url: URL)])
    {
        var approved: [URL] = []
        var unapproved: [(key: String, url: URL)] = []
        for hook in hooks {
            if isApproved(key: hook.key, fileURL: hook.url) {
                approved.append(hook.url)
            } else {
                unapproved.append(hook)
            }
        }
        return (approved, unapproved)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storePath),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }
        approvals = dict
    }

    private func save() {
        guard let data = try? JSONSerialization.data(
            withJSONObject: approvals,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: storePath, options: .atomic)
    }

    // MARK: - Hashing

    private func fileHash(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
