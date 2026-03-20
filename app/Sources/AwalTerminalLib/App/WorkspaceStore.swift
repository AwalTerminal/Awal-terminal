import Foundation

struct Workspace: Codable {
    let path: String
    var lastModel: String
    var lastUsed: Date
}

class WorkspaceStore {

    static let shared = WorkspaceStore()

    private let maxRecents = 10
    private var workspaces: [Workspace] = []

    private var storePath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Awal Terminal")
        return dir.appendingPathComponent("workspaces.json")
    }

    private init() {
        load()
    }

    func recents() -> [Workspace] {
        return workspaces
    }

    func save(path: String, model: String) {
        // Remove existing entry for this path + model combo
        workspaces.removeAll { $0.path == path && $0.lastModel == model }

        // Insert at front
        let entry = Workspace(path: path, lastModel: model, lastUsed: Date())
        workspaces.insert(entry, at: 0)

        // Trim to max
        if workspaces.count > maxRecents {
            workspaces = Array(workspaces.prefix(maxRecents))
        }

        persist()
    }

    func remove(path: String, model: String) {
        workspaces.removeAll { $0.path == path && $0.lastModel == model }
        persist()
    }

    // MARK: - Private

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storePath.path) else { return }

        do {
            let data = try Data(contentsOf: storePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            workspaces = try decoder.decode([Workspace].self, from: data)
        } catch {
            debugLog("WorkspaceStore: failed to load: \(error)")
        }
    }

    private func persist() {
        let fm = FileManager.default
        let dir = storePath.deletingLastPathComponent()

        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(workspaces)
            try data.write(to: storePath, options: .atomic)
        } catch {
            debugLog("WorkspaceStore: failed to save: \(error)")
        }
    }
}
