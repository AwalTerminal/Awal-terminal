import Foundation

/// Central voice input controller managing audio capture, transcription, and commands.
/// Supports push-to-talk mode only.
class VoiceInputController {

    enum State {
        case idle
        case recording    // Actively capturing speech
        case processing   // Transcribing audio
    }

    /// Current state
    private(set) var state: State = .idle

    /// Whether voice input is enabled
    var isEnabled: Bool = false {
        didSet {
            if !isEnabled, oldValue { stop() }
        }
    }

    // Callbacks
    var onStateChanged: ((State) -> Void)?
    var onTranscription: ((TranscriptionResult) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onPartialTranscription: ((String) -> Void)?

    // Components
    private let audioManager = AudioCaptureManager.shared
    private let transcriber = WhisperTranscriber.shared
    private let commandParser = VoiceCommandParser()

    // Config
    var dictationAutoEnter = false
    var dictationAutoSpace = true
    var commandPrefix = ""

    static let shared = VoiceInputController()

    private init() {
        setupCallbacks()
        loadConfig()
    }

    // MARK: - Public API

    /// Start recording (used by PTT hotkey and mic button click).
    func startRecording() {
        guard state == .idle else {
            NSLog("VoiceInput: startRecording() skipped, state=\(state)")
            return
        }
        isEnabled = true
        NSLog("VoiceInput: startRecording() called")
        setState(.recording)  // Set early to prevent re-entry during async gap

        Task {
            let authorized = await transcriber.requestAccess()
            NSLog("VoiceInput: speech auth=\(authorized)")

            await MainActor.run {
                guard authorized else {
                    NSLog("VoiceInput: not authorized, aborting")
                    self.setState(.idle)
                    return
                }

                self.transcriber.startStreaming()
                self.audioManager.onBuffer = { [weak self] buffer in
                    self?.transcriber.appendBuffer(buffer)
                }
                self.audioManager.startCapture()
                NSLog("VoiceInput: capture started, isCapturing=\(self.audioManager.isCapturing)")
            }
        }
    }

    /// Stop recording and process the result.
    func stopRecording() {
        guard state == .recording else { return }
        setState(.processing)

        audioManager.onBuffer = nil
        audioManager.stopCapture()

        Task {
            let result = await transcriber.stopStreaming()

            await MainActor.run {
                self.handleTranscription(result)
                self.setState(.idle)
            }
        }
    }

    /// Start push-to-talk recording (alias for startRecording)
    func startPushToTalk() {
        guard isEnabled, state == .idle else { return }
        startRecording()
    }

    /// Stop push-to-talk and process (alias for stopRecording)
    func stopPushToTalk() {
        stopRecording()
    }

    /// Stop all voice input
    func stop() {
        audioManager.onBuffer = nil
        audioManager.stopCapture()
        transcriber.stopStreaming(completion: nil)
        setState(.idle)
    }

    /// Toggle voice input on/off.
    func toggle() {
        NSLog("VoiceInput: toggle() called, state=\(state), isEnabled=\(isEnabled)")
        if state == .recording {
            NSLog("VoiceInput: stopping recording")
            stopRecording()
        } else if state != .idle {
            NSLog("VoiceInput: stopping (state was not idle)")
            stop()
        } else {
            isEnabled = true
            NSLog("VoiceInput: starting push-to-talk")
            startRecording()
        }
    }

    // MARK: - Private

    private func setupCallbacks() {
        audioManager.onAudioLevel = { [weak self] level in
            self?.onAudioLevel?(level)
        }

        transcriber.onPartialResult = { [weak self] text in
            self?.onPartialTranscription?(text)
        }
    }

    private func handleTranscription(_ result: TranscriptionResult) {
        guard !result.text.isEmpty else { return }

        // Try command parsing first
        let textToCheck = commandPrefix.isEmpty
            ? result.text
            : result.text.replacingOccurrences(of: commandPrefix, with: "").trimmingCharacters(in: .whitespaces)

        if let action = commandParser.parse(textToCheck) {
            var commandResult = result
            commandResult.isCommand = true
            commandResult.action = action
            onTranscription?(commandResult)
            return
        }

        // Dictation fallback
        var dictationResult = result
        if dictationAutoSpace {
            dictationResult.text = result.text + " "
        }
        if dictationAutoEnter {
            dictationResult.text = dictationResult.text.trimmingCharacters(in: .whitespaces) + "\n"
        }
        onTranscription?(dictationResult)
    }

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChanged?(newState)
    }

    private func loadConfig() {
        let config = AppConfig.shared
        isEnabled = config.voiceEnabled
        dictationAutoEnter = config.voiceDictationAutoEnter
        dictationAutoSpace = config.voiceDictationAutoSpace
        commandPrefix = config.voiceCommandPrefix
    }
}
