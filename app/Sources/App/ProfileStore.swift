import Foundation

class ProfileStore {
    static let shared = ProfileStore()

    private let fm = FileManager.default
    private let baseDir: String

    private init() {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDir = appSupport.appendingPathComponent("Awal Terminal/profiles").path
    }

    // MARK: - Bootstrap

    /// Ensures a model has at least a "Default" profile.
    /// On first use, imports the current config file content as "Default".
    func ensureProfiles(for model: LLMModel) {
        let dir = modelDir(for: model)
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let ext = model.configExtension ?? "json"
        let defaultFile = (dir as NSString).appendingPathComponent("Default.\(ext)")

        if !fm.fileExists(atPath: defaultFile) {
            // Import current config if it exists
            var content = ""
            if let realPath = model.expandedConfigPath, fm.fileExists(atPath: realPath) {
                content = (try? String(contentsOfFile: realPath, encoding: .utf8)) ?? ""
            }
            if content.isEmpty {
                content = ext == "json" ? "{}" : ""
            }
            try? content.write(toFile: defaultFile, atomically: true, encoding: .utf8)
        }

        // Ensure meta.json has an entry for this model
        var meta = loadMeta()
        if meta[model.storageKey] == nil {
            meta[model.storageKey] = "Default"
            saveMeta(meta)
        }
    }

    // MARK: - Profile Listing

    func profiles(for model: LLMModel) -> [String] {
        let dir = modelDir(for: model)
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return files
            .filter { !$0.hasPrefix(".") }
            .compactMap { ($0 as NSString).deletingPathExtension }
            .sorted()
    }

    func activeProfileName(for model: LLMModel) -> String {
        let meta = loadMeta()
        return meta[model.storageKey] ?? "Default"
    }

    // MARK: - Read / Write

    func loadProfileContent(for model: LLMModel, name: String) -> String? {
        let path = profilePath(for: model, name: name)
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    func saveProfile(for model: LLMModel, name: String, content: String) {
        let path = profilePath(for: model, name: name)
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Create / Rename / Delete

    func createProfile(for model: LLMModel, name: String, content: String? = nil) {
        let ext = model.configExtension ?? "json"
        let dir = modelDir(for: model)
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let path = (dir as NSString).appendingPathComponent("\(name).\(ext)")
        let body = content ?? (ext == "json" ? "{}" : "")
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func renameProfile(for model: LLMModel, oldName: String, newName: String) {
        let ext = model.configExtension ?? "json"
        let dir = modelDir(for: model)
        let oldPath = (dir as NSString).appendingPathComponent("\(oldName).\(ext)")
        let newPath = (dir as NSString).appendingPathComponent("\(newName).\(ext)")
        try? fm.moveItem(atPath: oldPath, toPath: newPath)

        var meta = loadMeta()
        if meta[model.storageKey] == oldName {
            meta[model.storageKey] = newName
            saveMeta(meta)
        }
    }

    func deleteProfile(for model: LLMModel, name: String) {
        let path = profilePath(for: model, name: name)
        try? fm.removeItem(atPath: path)

        // If we deleted the active profile, reassign
        var meta = loadMeta()
        if meta[model.storageKey] == name {
            let remaining = profiles(for: model)
            meta[model.storageKey] = remaining.first ?? "Default"
            saveMeta(meta)
        }
    }

    // MARK: - Activation

    func activateProfile(for model: LLMModel, name: String) {
        var meta = loadMeta()
        meta[model.storageKey] = name
        saveMeta(meta)

        // Copy profile content to the real config path
        guard let realPath = model.expandedConfigPath else { return }
        let content = loadProfileContent(for: model, name: name) ?? ""

        let dir = (realPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try? content.write(toFile: realPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private func modelDir(for model: LLMModel) -> String {
        (baseDir as NSString).appendingPathComponent(model.storageKey)
    }

    private func profilePath(for model: LLMModel, name: String) -> String {
        let ext = model.configExtension ?? "json"
        return (modelDir(for: model) as NSString).appendingPathComponent("\(name).\(ext)")
    }

    private var metaPath: String {
        (baseDir as NSString).appendingPathComponent("meta.json")
    }

    private func loadMeta() -> [String: String] {
        guard let data = fm.contents(atPath: metaPath),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }

    private func saveMeta(_ meta: [String: String]) {
        if !fm.fileExists(atPath: baseDir) {
            try? fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: metaPath))
    }
}
