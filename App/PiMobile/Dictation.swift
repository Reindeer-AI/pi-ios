import AVFoundation
import Speech

/// Speech to text for the message box, with iOS's own recognizer (on the device when it can be): the words appear as
/// they are recognized, after what was already typed.
///
/// A dictation can outlast one recognition: iOS ends a request on its own (about a minute on its servers, an abort, a
/// long pause) and starts a new transcription after a pause. What was heard is kept through all of that, and listening
/// goes on in a new request until the user stops it; an empty result never replaces the words.
@MainActor
@Observable
final class Dictation {
    private(set) var listening = false
    private(set) var error: String?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var update: (@MainActor (String) -> Void)?
    private var heard = HeardText(after: "")
    /// Requests in a row that ended without a word (silence, or a recognizer that keeps failing).
    private var silent = 0

    /// Starts listening; `update` gets the text so far (`prefix` plus the words heard) as it changes.
    func start(after prefix: String, update: @escaping @MainActor (String) -> Void) async {
        error = nil
        guard await authorized() else {
            error = "pi needs Microphone and Speech Recognition access (Settings → Apps → pi)."
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            error = "Speech recognition is not available right now."
            return
        }
        self.recognizer = recognizer
        self.update = update
        heard = HeardText(after: prefix)
        silent = 0
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            begin()
            engine.prepare()
            try engine.start()
            listening = true
        } catch {
            self.error = "Could not start listening: \(error.localizedDescription)"
            stop()
        }
    }

    /// A new recognition request, fed by the microphone from now on.
    private func begin() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        engine.inputNode.removeTap(onBus: 0)
        feed(engine.inputNode, to: request)
        let id = ObjectIdentifier(request)
        task = recognize(request, with: recognizer) { [weak self] text, final in
            Task { @MainActor in self?.received(text, final: final, from: id) }
        }
    }

    private func received(_ text: String?, final: Bool, from id: ObjectIdentifier) {
        guard request.map(ObjectIdentifier.init) == id else { return }
        if let shown = heard.received(text) {
            silent = 0
            update?(shown)
        }
        guard final else { return }
        if !heard.ended() { silent += 1 }
        if listening, silent < 3 {
            // iOS ended the request on its own (a time limit, an abort, a long pause): listening goes on in a new one.
            task = nil
            begin()
        } else {
            finish()
        }
    }

    /// Stops listening; the words still being recognized arrive first (briefly).
    func stop() {
        guard listening || request != nil else { return }
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        let pending = request.map(ObjectIdentifier.init)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if request.map(ObjectIdentifier.init) == pending { finish() }
        }
    }

    private func finish() {
        task?.cancel()
        task = nil
        request = nil
        listening = false
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// The audio tap, the recognizer, and the permission request call back on their own threads: their closures are made here,
// at file scope, outside the main-actor Dictation, so they are not main-actor isolated (Swift would trap when they run).

private func feed(_ input: AVAudioInputNode, to request: SFSpeechAudioBufferRecognitionRequest) {
    nonisolated(unsafe) let request = request
    input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
        request.append(buffer)
    }
}

private func recognize(
    _ request: SFSpeechAudioBufferRecognitionRequest,
    with recognizer: SFSpeechRecognizer,
    heard: @escaping @Sendable (_ text: String?, _ final: Bool) -> Void
) -> SFSpeechRecognitionTask {
    recognizer.recognitionTask(with: request) { result, error in
        heard(result?.bestTranscription.formattedString, result?.isFinal == true || error != nil)
    }
}

private func authorized() async -> Bool {
    guard await authorizeSpeechRecognition() else { return false }
    return await AVAudioApplication.requestRecordPermission()
}

func authorizeSpeechRecognition() async -> Bool {
    if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
    return await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
    }
}
