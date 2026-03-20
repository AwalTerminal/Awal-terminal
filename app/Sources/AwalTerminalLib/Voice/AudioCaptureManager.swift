import AVFoundation

/// Captures microphone audio via AVAudioEngine, stores in a ring buffer.
/// Provides RMS audio levels and recent audio sample access.
class AudioCaptureManager {

    static let shared = AudioCaptureManager()

    private let engine = AVAudioEngine()
    private let sampleRate: Double = 16000
    private let bufferSeconds: Int = 30
    private var ringBuffer: [Float]
    private var writeHead: Int = 0
    private var totalSamplesWritten: Int = 0
    private let lock = NSLock()

    /// Current RMS audio level (0.0 - 1.0). Accessed from audio + UI threads.
    private(set) var audioLevel: Float {
        get { lock.lock(); defer { lock.unlock() }; return _audioLevel }
        set { lock.lock(); _audioLevel = newValue; lock.unlock() }
    }
    private var _audioLevel: Float = 0

    /// Whether audio capture is currently active
    private(set) var isCapturing = false

    /// Called on main thread with updated audio level
    var onAudioLevel: ((Float) -> Void)?

    /// Called with new audio samples (on audio thread)
    var onSamples: (([Float]) -> Void)?

    /// Called with audio buffer for speech recognition (on audio thread)
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private init() {
        ringBuffer = [Float](repeating: 0, count: Int(sampleRate) * bufferSeconds)
    }

    /// Request microphone permission, then start capturing.
    func startCapture() {
        // Check for NSMicrophoneUsageDescription in Info.plist — without it,
        // requesting mic access crashes the process via TCC on macOS.
        let info = Bundle.main.infoDictionary
        let hasKey = info?["NSMicrophoneUsageDescription"] != nil
        debugLog("AudioCaptureManager: startCapture() called, bundle=\(Bundle.main.bundlePath), infoDictionary keys=\(info?.keys.joined(separator: ",") ?? "nil"), hasMicKey=\(hasKey)")
        if !hasKey {
            debugLog("AudioCaptureManager: NSMicrophoneUsageDescription missing from Info.plist. " +
                  "Voice input requires the bundled .app — run `just bundle` then open AwalTerminal.app")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { self?.beginCapture() }
                }
            }
        default:
            debugLog("AudioCaptureManager: Microphone access denied — enable in System Settings > Privacy > Microphone")
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        audioLevel = 0
    }

    /// Get recent audio samples (most recent N seconds).
    func getRecentAudio(seconds: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let count = min(Int(seconds * sampleRate), totalSamplesWritten, ringBuffer.count)
        guard count > 0 else { return [] }

        var result = [Float](repeating: 0, count: count)
        let start = (writeHead - count + ringBuffer.count) % ringBuffer.count

        if start + count <= ringBuffer.count {
            result = Array(ringBuffer[start..<(start + count)])
        } else {
            let firstChunk = ringBuffer.count - start
            result[0..<firstChunk] = ringBuffer[start...]
            result[firstChunk..<count] = ringBuffer[0..<(count - firstChunk)]
        }
        return result
    }

    // MARK: - Private

    private func beginCapture() {
        guard !isCapturing else { return }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else { return }

        // Install tap at hardware format, then convert
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: sampleRate,
                                          channels: 1,
                                          interleaved: false)!
        let converter = AVAudioConverter(from: hwFormat, to: desiredFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            guard let self, let converter else { return }
            self.processBuffer(buffer, converter: converter, outputFormat: desiredFormat)
        }

        do {
            try engine.start()
            isCapturing = true
        } catch {
            inputNode.removeTap(onBus: 0)
        }
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        // Convert to 16kHz mono
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, converted.frameLength > 0,
              let channelData = converted.floatChannelData else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(converted.frameLength)))

        // Compute RMS
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = sqrtf(sumSq / Float(samples.count))

        // Write to ring buffer
        lock.lock()
        for sample in samples {
            ringBuffer[writeHead] = sample
            writeHead = (writeHead + 1) % ringBuffer.count
        }
        totalSamplesWritten += samples.count
        lock.unlock()

        audioLevel = rms
        onSamples?(samples)
        onBuffer?(converted)

        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(rms)
        }
    }
}
