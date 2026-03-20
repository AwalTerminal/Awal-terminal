import Foundation
import Speech
import AVFoundation

/// Result of a speech-to-text transcription.
struct TranscriptionResult {
    var text: String
    var confidence: Float
    var durationMs: Int
    var isCommand: Bool = false
    var action: VoiceAction? = nil
}

/// Speech-to-text transcriber using Apple's SFSpeechRecognizer (on-device).
class WhisperTranscriber {

    static let shared = WhisperTranscriber()

    private(set) var isAvailable = false
    private(set) var authorizationChecked = false

    // Lazy — don't touch Speech framework until user explicitly enables voice
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Latest transcription text from the current streaming session
    private var latestTranscription: String = ""

    /// Partial transcription callback (for live preview)
    var onPartialResult: ((String) -> Void)?

    private init() {
        // Don't touch SFSpeechRecognizer here — TCC will crash the process
        // if privacy keys are missing. Everything is deferred to first use.
    }

    /// Set the language for recognition.
    func setLanguage(_ code: String) {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: code))
    }

    // MARK: - Authorization

    /// Check if TCC privacy keys are present in the bundle Info.plist.
    private static var hasTCCKeys: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["NSSpeechRecognitionUsageDescription"] != nil
    }

    /// Request authorization. Must be called before using speech recognition.
    /// Returns true if authorized.
    func requestAccess() async -> Bool {
        if isAvailable { return true }

        guard Self.hasTCCKeys else {
            debugLog("WhisperTranscriber: NSSpeechRecognitionUsageDescription missing. Voice requires bundled .app (just bundle).")
            authorizationChecked = true
            return false
        }

        // Create recognizer lazily
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: AppConfig.shared.voiceLanguage))
        }

        let authorized = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        isAvailable = authorized
        authorizationChecked = true

        if authorized {
            debugLog("WhisperTranscriber: Speech recognition authorized")
        } else {
            debugLog("WhisperTranscriber: Speech recognition denied — enable in System Settings > Privacy > Speech Recognition")
        }
        return authorized
    }

    // MARK: - Streaming Recognition

    /// Start a streaming recognition session.
    func startStreaming() {
        guard isAvailable, let recognizer = speechRecognizer, recognizer.isAvailable else {
            debugLog("WhisperTranscriber: Cannot start streaming — not authorized or not available")
            return
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        latestTranscription = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latestTranscription = result.bestTranscription.formattedString
                if !result.isFinal {
                    DispatchQueue.main.async {
                        self.onPartialResult?(self.latestTranscription)
                    }
                }
            }
            if let error {
                debugLog("WhisperTranscriber: Recognition error: \(error.localizedDescription)")
            }
        }

        recognitionRequest = request
        debugLog("WhisperTranscriber: Streaming started")
    }

    /// Append an audio buffer to the active streaming session.
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    /// Stop streaming and return the final transcription.
    func stopStreaming() async -> TranscriptionResult {
        let startTime = DispatchTime.now()

        recognitionRequest?.endAudio()

        // Give the recognizer time to finalize
        try? await Task.sleep(nanoseconds: 600_000_000)

        let text = latestTranscription
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        latestTranscription = ""

        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let durationMs = Int(elapsed / 1_000_000)

        debugLog("WhisperTranscriber: Streaming stopped, got: \"\(text)\" in \(durationMs)ms")

        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: 1.0,
            durationMs: durationMs
        )
    }

    /// Non-async cleanup (for cancellation).
    func stopStreaming(completion: ((TranscriptionResult) -> Void)?) {
        recognitionRequest?.endAudio()
        let text = latestTranscription
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        latestTranscription = ""
        completion?(TranscriptionResult(text: text, confidence: 1.0, durationMs: 0))
    }

    /// Transcribe a batch of audio samples (non-streaming fallback).
    func transcribe(audioSamples: [Float]) async -> TranscriptionResult {
        guard isAvailable, let recognizer = speechRecognizer, recognizer.isAvailable else {
            return TranscriptionResult(text: "", confidence: 0, durationMs: 0)
        }

        let startTime = DispatchTime.now()

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioSamples.count)) else {
            return TranscriptionResult(text: "", confidence: 0, durationMs: 0)
        }
        buffer.frameLength = AVAudioFrameCount(audioSamples.count)
        let channelData = buffer.floatChannelData![0]
        for i in 0..<audioSamples.count {
            channelData[i] = audioSamples[i]
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        request.append(buffer)
        request.endAudio()

        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    resumed = true
                    debugLog("WhisperTranscriber: Batch error: \(error.localizedDescription)")
                    continuation.resume(returning: "")
                }
            }
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let durationMs = Int(elapsed / 1_000_000)

        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: 1.0,
            durationMs: durationMs
        )
    }
}
