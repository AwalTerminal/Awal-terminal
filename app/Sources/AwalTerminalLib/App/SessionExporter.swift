import AppKit
import ImageIO
import Metal
import CAwalTerminal

/// Exports .awalrec recordings to GIF.
class SessionExporter {

    struct ExportOptions {
        var maxWidth: Int = 800
        var maxHeight: Int = 600
        var idleCapMs: Int = 500  // Cap idle gaps at this duration
        var speed: Double = 1.0
    }

    typealias ProgressCallback = (Double) -> Void

    /// Export a recording to a GIF file.
    static func exportGIF(
        recordingPath: String,
        outputURL: URL,
        renderer: MetalRenderer,
        options: ExportOptions = ExportOptions(),
        progress: ProgressCallback? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Check available disk space (estimate ~2MB per frame as upper bound)
            let outputDir = outputURL.deletingLastPathComponent()
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: outputDir.path),
               let freeSpace = attrs[.systemFreeSize] as? UInt64 {
                // Rough estimate: recording file size * 10 as safety margin for uncompressed frames
                let recSize = (try? FileManager.default.attributesOfItem(atPath: recordingPath))?[.size] as? UInt64 ?? 0
                let estimatedNeeded = max(recSize * 10, 50 * 1024 * 1024) // at least 50MB
                if freeSpace < estimatedNeeded {
                    DispatchQueue.main.async { completion(.failure(ExportError.insufficientDiskSpace(needed: estimatedNeeded, available: freeSpace))) }
                    return
                }
            }

            guard let recording = at_recording_load(recordingPath.cString(using: .utf8)) else {
                DispatchQueue.main.async { completion(.failure(ExportError.failedToLoad)) }
                return
            }
            defer { at_recording_destroy(recording) }

            let frameCount = at_recording_frame_count(recording)
            guard frameCount > 0 else {
                DispatchQueue.main.async { completion(.failure(ExportError.emptyRecording)) }
                return
            }

            var cols: UInt32 = 0
            var rows: UInt32 = 0
            at_recording_get_size(recording, &cols, &rows)

            let scale: CGFloat = 2.0
            let viewportW = CGFloat(cols) * renderer.cellWidth * scale
            let viewportH = CGFloat(rows) * renderer.cellHeight * scale
            let viewportSize = CGSize(width: viewportW, height: viewportH)

            // Scale to fit within max bounds
            let scaleX = CGFloat(options.maxWidth) / viewportW
            let scaleY = CGFloat(options.maxHeight) / viewportH
            let fitScale = min(scaleX, scaleY, 1.0)
            let outputW = Int(viewportW * fitScale)
            let outputH = Int(viewportH * fitScale)

            let total = Int(cols * rows)

            writeGIF(
                recording: recording,
                frameCount: Int(frameCount),
                cols: Int(cols),
                rows: Int(rows),
                total: total,
                renderer: renderer,
                viewportSize: viewportSize,
                scale: scale,
                outputW: outputW,
                outputH: outputH,
                outputURL: outputURL,
                options: options,
                progress: progress,
                completion: completion
            )
        }
    }

    // MARK: - GIF Writer

    private static func writeGIF(
        recording: OpaquePointer,
        frameCount: Int,
        cols: Int,
        rows: Int,
        total: Int,
        renderer: MetalRenderer,
        viewportSize: CGSize,
        scale: CGFloat,
        outputW: Int,
        outputH: Int,
        outputURL: URL,
        options: ExportOptions,
        progress: ProgressCallback?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0  // Loop forever
            ]
        ]

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            "com.compuserve.gif" as CFString,
            frameCount,
            fileProperties as CFDictionary
        ) else {
            completion(.failure(ExportError.failedToCreateDestination))
            return
        }

        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        var cellBuffer = [CCell](repeating: CCell(), count: total)
        var snapshot = CFrameSnapshot()
        var prevTimestamp: UInt64 = 0

        for i in 0..<frameCount {
            autoreleasepool {
                let ok = at_recording_get_frame(recording, UInt32(i), &cellBuffer, &snapshot)
                guard ok else { return }

                // Compute frame delay with idle compression
                var delayMs = Int(snapshot.timestamp_ms) - Int(prevTimestamp)
                if delayMs > options.idleCapMs { delayMs = options.idleCapMs }
                delayMs = max(delayMs, 33) // Min ~30fps
                let delay = Double(delayMs) / 1000.0 / options.speed
                prevTimestamp = snapshot.timestamp_ms

                // Render to texture
                guard let texture = cellBuffer.withUnsafeBufferPointer({ buf -> MTLTexture? in
                    guard let baseAddress = buf.baseAddress else { return nil }
                    return renderer.renderToTexture(
                        cells: baseAddress,
                        cellCount: total,
                        gridCols: cols,
                        gridRows: rows,
                        cursorRow: Int(snapshot.cursor_row),
                        cursorCol: Int(snapshot.cursor_col),
                        cursorVisible: snapshot.cursor_visible,
                        viewportSize: viewportSize,
                        scale: scale
                    )
                }) else { return }

                // Read pixels from texture and scale to output size
                guard let image = textureToImage(texture, width: outputW, height: outputH) else { return }

                let frameProperties: [CFString: Any] = [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: delay,
                        kCGImagePropertyGIFUnclampedDelayTime: delay,
                    ]
                ]
                CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)

                // Reserve the last 1% for finalization
                progress?(Double(i + 1) / Double(frameCount) * 0.99)
            }
        }

        progress?(0.99)  // Signal finalization phase

        if CGImageDestinationFinalize(destination) {
            DispatchQueue.main.async { completion(.success(outputURL)) }
        } else {
            DispatchQueue.main.async { completion(.failure(ExportError.failedToFinalize)) }
        }
    }

    // MARK: - Pixel Helpers

    private static func textureToImage(_ texture: MTLTexture, width: Int, height: Int) -> CGImage? {
        let texW = texture.width
        let texH = texture.height
        let bytesPerRow = texW * 4
        var pixelData = [UInt8](repeating: 0, count: texW * texH * 4)
        texture.getBytes(&pixelData, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, texW, texH), mipmapLevel: 0)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let srcContext = CGContext(
            data: &pixelData,
            width: texW,
            height: texH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let srcImage = srcContext.makeImage() else { return nil }

        // If output size matches texture size, return directly
        if width == texW && height == texH {
            return srcImage
        }

        // Scale down to output size to reduce memory during GIF encoding
        guard let dstContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        dstContext.interpolationQuality = .high
        dstContext.draw(srcImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return dstContext.makeImage()
    }

    // MARK: - Errors

    enum ExportError: Error, LocalizedError {
        case failedToLoad
        case emptyRecording
        case failedToCreateDestination
        case failedToFinalize
        case insufficientDiskSpace(needed: UInt64, available: UInt64)

        var errorDescription: String? {
            switch self {
            case .failedToLoad: return "Failed to load recording file"
            case .emptyRecording: return "Recording has no frames"
            case .failedToCreateDestination: return "Failed to create export destination"
            case .failedToFinalize: return "Failed to finalize export"
            case .insufficientDiskSpace(let needed, let available):
                let neededMB = needed / (1024 * 1024)
                let availMB = available / (1024 * 1024)
                return "Insufficient disk space: need ~\(neededMB)MB, \(availMB)MB available"
            }
        }
    }
}
