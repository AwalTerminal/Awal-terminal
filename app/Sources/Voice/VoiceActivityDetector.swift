import Foundation

/// Energy-based Voice Activity Detection using RMS threshold with state machine.
class VoiceActivityDetector {

    enum State {
        case silence
        case speech
    }

    /// Current VAD state
    private(set) var state: State = .silence

    /// RMS threshold for speech detection (configurable)
    var threshold: Float = 0.02

    /// Called when a complete speech segment is detected
    var onSpeechSegment: (([Float]) -> Void)?

    /// Called when state changes
    var onStateChanged: ((State) -> Void)?

    // State machine timing (in frames)
    private let speechOnsetFrames = 10   // 200ms at 20ms/frame
    private let speechHangoverFrames = 15 // 300ms at 20ms/frame

    private var aboveThresholdCount = 0
    private var belowThresholdCount = 0

    // Accumulate speech samples
    private var speechBuffer: [Float] = []

    private let frameSamples = 320  // 20ms at 16kHz

    // Accumulate incoming samples into frames
    private var pendingSamples: [Float] = []

    /// Process new audio samples. Automatically segments into 20ms frames.
    func process(samples: [Float]) {
        pendingSamples.append(contentsOf: samples)

        while pendingSamples.count >= frameSamples {
            let frame = Array(pendingSamples.prefix(frameSamples))
            pendingSamples.removeFirst(frameSamples)
            processFrame(frame)
        }
    }

    /// Reset the detector state.
    func reset() {
        state = .silence
        aboveThresholdCount = 0
        belowThresholdCount = 0
        speechBuffer.removeAll()
        pendingSamples.removeAll()
    }

    // MARK: - Private

    private func processFrame(_ frame: [Float]) {
        let rms = computeRMS(frame)
        let isSpeech = rms > threshold

        switch state {
        case .silence:
            if isSpeech {
                aboveThresholdCount += 1
                // Buffer frames during onset detection
                speechBuffer.append(contentsOf: frame)
                if aboveThresholdCount >= speechOnsetFrames {
                    state = .speech
                    belowThresholdCount = 0
                    onStateChanged?(.speech)
                }
            } else {
                aboveThresholdCount = 0
                // Discard buffered onset samples if we didn't reach threshold
                if !speechBuffer.isEmpty {
                    speechBuffer.removeAll()
                }
            }

        case .speech:
            speechBuffer.append(contentsOf: frame)
            if isSpeech {
                belowThresholdCount = 0
            } else {
                belowThresholdCount += 1
                if belowThresholdCount >= speechHangoverFrames {
                    // End of speech — emit segment
                    let segment = speechBuffer
                    speechBuffer.removeAll()
                    state = .silence
                    aboveThresholdCount = 0
                    onStateChanged?(.silence)
                    onSpeechSegment?(segment)
                }
            }
        }
    }

    private func computeRMS(_ frame: [Float]) -> Float {
        var sumSq: Float = 0
        for s in frame { sumSq += s * s }
        return sqrtf(sumSq / Float(frame.count))
    }
}
