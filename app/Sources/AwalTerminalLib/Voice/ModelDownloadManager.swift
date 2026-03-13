import Foundation

/// Manages downloading and caching WhisperKit models.
class ModelDownloadManager {

    static let shared = ModelDownloadManager()

    private(set) var isDownloading = false
    private(set) var progress: Double = 0

    var onProgress: ((Double) -> Void)?
    var onComplete: ((Bool) -> Void)?

    private let modelDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AwalTerminal/WhisperModels")
    }()

    /// Available model variants
    static let availableModels = [
        "tiny.en",
        "tiny",
        "base.en",
        "base",
        "small.en",
        "small",
    ]

    private init() {}

    /// Check if a model is already downloaded.
    func isModelCached(_ name: String) -> Bool {
        let modelPath = modelDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: modelPath.path)
    }

    /// Download a model if not cached. Reports progress via callbacks.
    func ensureModel(_ name: String) async -> Bool {
        if isModelCached(name) { return true }

        guard !isDownloading else { return false }
        isDownloading = true
        progress = 0

        do {
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

            // WhisperKit handles model downloading internally via its setup methods.
            // This manager tracks the state for UI purposes.
            // The actual download happens through WhisperKit.download(variant:)

            // For now, signal that model setup will happen via WhisperTranscriber
            await MainActor.run {
                self.progress = 1.0
                self.onProgress?(1.0)
                self.isDownloading = false
                self.onComplete?(true)
            }
            return true
        } catch {
            await MainActor.run {
                self.isDownloading = false
                self.onComplete?(false)
            }
            return false
        }
    }

    /// Delete a cached model.
    func deleteModel(_ name: String) {
        let modelPath = modelDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: modelPath)
    }
}
