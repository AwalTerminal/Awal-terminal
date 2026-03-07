import Foundation

/// Central voice input state machine managing audio capture, VAD, transcription, and commands.
class VoiceInputController {

    enum State {
        case idle
        case listening    // Mic active, waiting for speech (continuous/wake mode)
        case recording    // Actively capturing speech
        case processing   // Transcribing audio
    }

    enum Mode: String {
        case pushToTalk = "push_to_talk"
        case continuous = "continuous"
        case wakeWord = "wake_word"
    }

    /// Current state
    private(set) var state: State = .idle

    /// Current mode
    var mode: Mode = .pushToTalk

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
    private let vad = VoiceActivityDetector()
    private let transcriber = WhisperTranscriber.shared
    private let commandParser = VoiceCommandParser()

    // Config
    var dictationAutoEnter = false
    var dictationAutoSpace = true
    var commandPrefix = ""
    var wakeWord = "hey terminal"

    // Wake word state
    private var isWakeWordActive = false

    static let shared = VoiceInputController()

    private init() {
        setupCallbacks()
        loadConfig()
    }

    // MARK: - Public API

    /// Start recording (used by both PTT hotkey and mic button click).
    func startRecording() {
        guard state == .idle || state == .listening else {
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
                self.setState(self.mode == .continuous || self.mode == .wakeWord ? .listening : .idle)
            }
        }
    }

    /// Start push-to-talk recording (alias for startRecording)
    func startPushToTalk() {
        guard isEnabled, state == .idle || state == .listening else { return }
        startRecording()
    }

    /// Stop push-to-talk and process (alias for stopRecording)
    func stopPushToTalk() {
        stopRecording()
    }

    /// Start continuous listening mode
    func startContinuous() {
        guard isEnabled, state == .idle else { return }
        audioManager.startCapture()
        setState(.listening)
    }

    /// Stop all voice input
    func stop() {
        audioManager.onBuffer = nil
        audioManager.stopCapture()
        vad.reset()
        transcriber.stopStreaming(completion: nil)
        setState(.idle)
        isWakeWordActive = false
    }

    /// Toggle voice input on/off. When in PTT mode, directly starts/stops recording.
    func toggle() {
        NSLog("VoiceInput: toggle() called, state=\(state), mode=\(mode), isEnabled=\(isEnabled)")
        if state == .recording {
            NSLog("VoiceInput: stopping recording")
            stopRecording()
        } else if state != .idle {
            NSLog("VoiceInput: stopping (state was not idle)")
            stop()
        } else {
            isEnabled = true
            NSLog("VoiceInput: starting, mode=\(mode)")
            switch mode {
            case .pushToTalk:
                startRecording()
            case .continuous:
                startContinuous()
            case .wakeWord:
                startContinuous()
            }
        }
    }

    // MARK: - Private

    private func setupCallbacks() {
        audioManager.onSamples = { [weak self] samples in
            guard let self else { return }
            if self.state == .listening {
                self.vad.process(samples: samples)
            }
        }

        audioManager.onAudioLevel = { [weak self] level in
            self?.onAudioLevel?(level)
        }

        vad.onSpeechSegment = { [weak self] segment in
            guard let self else { return }
            DispatchQueue.main.async {
                // In continuous mode, process the segment
                self.setState(.processing)
                self.processAudio(segment)
            }
        }

        vad.onStateChanged = { [weak self] vadState in
            guard let self else { return }
            DispatchQueue.main.async {
                if vadState == .speech && self.state == .listening {
                    self.setState(.recording)
                }
            }
        }

        transcriber.onPartialResult = { [weak self] text in
            self?.onPartialTranscription?(text)
        }
    }

    private func processAudio(_ samples: [Float]) {
        guard !samples.isEmpty else {
            setState(mode == .continuous || mode == .wakeWord ? .listening : .idle)
            return
        }

        Task {
            let result = await transcriber.transcribe(audioSamples: samples)

            await MainActor.run {
                if self.mode == .wakeWord && !self.isWakeWordActive {
                    if result.text.lowercased().contains(self.wakeWord.lowercased()) {
                        self.isWakeWordActive = true
                        self.setState(.listening)
                        return
                    }
                    self.setState(.listening)
                    return
                }

                if self.mode == .wakeWord {
                    self.isWakeWordActive = false
                }

                self.handleTranscription(result)
                self.setState(self.mode == .continuous || self.mode == .wakeWord ? .listening : .idle)
            }
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
        mode = Mode(rawValue: config.voiceMode) ?? .pushToTalk
        vad.threshold = config.voiceVadThreshold
        dictationAutoEnter = config.voiceDictationAutoEnter
        dictationAutoSpace = config.voiceDictationAutoSpace
        commandPrefix = config.voiceCommandPrefix
        wakeWord = config.voiceWakeWord
    }
}
