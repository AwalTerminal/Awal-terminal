import Foundation
import CAwalTerminal

/// Records terminal frames for session replay and GIF/MP4 export.
class SessionRecorder {

    private var recording: OpaquePointer?  // ATRecording*
    private(set) var isRecording = false
    var onRecordingChanged: ((Bool) -> Void)?
    var onAutoStopped: ((URL) -> Void)?

    private var startTime: UInt64 = 0

    func start(cols: Int, rows: Int, model: String, projectPath: String) {
        guard !isRecording else { return }

        let modelC = model.cString(using: .utf8)
        let pathC = projectPath.cString(using: .utf8)
        recording = at_recording_new(UInt32(cols), UInt32(rows), modelC, pathC)

        startTime = UInt64(Date().timeIntervalSince1970 * 1000)
        isRecording = true
        onRecordingChanged?(true)
    }

    func captureFrame(
        cells: UnsafePointer<CCell>,
        cellCount: Int,
        cursorRow: Int,
        cursorCol: Int,
        cursorVisible: Bool,
        surface: OpaquePointer?
    ) {
        guard isRecording, let recording else { return }

        let timestampMs = UInt64(Date().timeIntervalSince1970 * 1000) - startTime

        let maxDurationMs = UInt64(AppConfig.shared.recordingMaxDuration) * 1000
        if maxDurationMs > 0 && timestampMs >= maxDurationMs {
            DispatchQueue.main.async { [weak self] in
                if let url = self?.stop() {
                    self?.onAutoStopped?(url)
                }
            }
            return
        }

        // Gather regions from the surface if available
        var regions: [CRecordedRegion] = []
        if let surface {
            let regionCount = Int(at_surface_get_region_count(surface))
            if regionCount > 0 {
                var cRegions = [COutputRegion](repeating: COutputRegion(), count: regionCount)
                let actual = Int(at_surface_get_regions(surface, &cRegions, UInt32(regionCount)))
                for i in 0..<actual {
                    var rec = CRecordedRegion()
                    rec.start_row = cRegions[i].start_row
                    rec.end_row = cRegions[i].end_row
                    rec.region_type = cRegions[i].region_type
                    rec.label = cRegions[i].label // borrowing the C string pointer — valid during this call
                    regions.append(rec)
                }
                // Add frame with regions
                regions.withUnsafeMutableBufferPointer { buf in
                    at_recording_add_frame(
                        recording,
                        cells,
                        UInt32(cellCount),
                        UInt32(cursorRow),
                        UInt32(cursorCol),
                        cursorVisible,
                        buf.baseAddress,
                        UInt32(actual),
                        timestampMs
                    )
                }
                // Free the region labels
                for i in 0..<actual {
                    at_free_string(cRegions[i].label)
                }
                return
            }
        }

        // No regions — add frame without
        at_recording_add_frame(
            recording,
            cells,
            UInt32(cellCount),
            UInt32(cursorRow),
            UInt32(cursorCol),
            cursorVisible,
            nil,
            0,
            timestampMs
        )
    }

    @discardableResult
    func stop() -> URL? {
        guard isRecording, let recording else { return nil }
        isRecording = false
        onRecordingChanged?(false)

        // Save to a temp file
        let fileName = "session-\(ISO8601DateFormatter().string(from: Date())).awalrec"
            .replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Awal Terminal/recordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("Failed to create recordings directory: %@", error.localizedDescription)
            at_recording_destroy(recording)
            self.recording = nil
            return nil
        }

        let fileURL = dir.appendingPathComponent(fileName)
        let pathC = fileURL.path.cString(using: .utf8)
        let result = at_recording_save(recording, pathC)
        at_recording_destroy(recording)
        self.recording = nil

        return result == 0 ? fileURL : nil
    }

    var frameCount: UInt32 {
        guard let recording else { return 0 }
        return at_recording_frame_count(recording)
    }

    deinit {
        if let recording {
            at_recording_destroy(recording)
        }
    }
}
