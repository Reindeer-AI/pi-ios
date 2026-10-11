import AVFoundation
import Speech
import PiWatchLink

@MainActor
final class WatchVoiceTranscriber {
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var completion: CheckedContinuation<String, any Error>?
    private var timeout: Task<Void, Never>?
    private var cancelled = false

    func transcribe(_ file: URL, locale: String) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw VoiceError("On iPhone, open Pi Settings → Apple Watch → Enable voice transcription, then retry.")
        }
        try checkCancellation()
        let duration = try await AVURLAsset(url: file).load(.duration).seconds
        try checkCancellation()
        guard duration.isFinite, duration > 0, duration <= WatchVoiceRequest.maximumDuration + 1 else {
            throw VoiceError("Record up to 60 seconds, then try again.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            throw VoiceError("Speech recognition isn't available for this language. Check the iPhone connection and retry.")
        }
        self.recognizer = recognizer
        return try await withTaskCancellationHandler {
            try checkCancellation()
            return try await recognize(file, with: recognizer)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func recognize(_ file: URL, with recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        #if targetEnvironment(simulator)
        request.requiresOnDeviceRecognition = false
        #else
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        #endif
        request.taskHint = .dictation
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.finish(.failure(VoiceError("Transcription timed out. Open Pi on iPhone and retry.")))
            }
            task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
                var message = error?.localizedDescription
                #if targetEnvironment(simulator)
                if let error = error as NSError?, error.domain == "kLSRErrorDomain", error.code == 300 {
                    message = "Apple Speech couldn't start in this iPhone Simulator. Recording saved. Test transcription on your paired iPhone and Watch."
                }
                #endif
                let failureMessage = message
                Task { @MainActor in
                    if let text {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.finish(trimmed.isEmpty ? .failure(VoiceError("No speech was recognized. Record again.")) : .success(trimmed))
                    } else if let failureMessage { self?.finish(.failure(VoiceError(failureMessage))) }
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        finish(.failure(CancellationError()))
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func finish(_ result: Result<String, any Error>) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel()
        timeout = nil
        task?.cancel()
        task = nil
        recognizer = nil
        completion.resume(with: result)
    }

    private struct VoiceError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
