import SwiftUI
import WatchKit
import AVFoundation
import PiWatchLink

@MainActor @Observable
private final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    var recording = false
    var finished: URL?
    var error: String?
    private var recorder: AVAudioRecorder?
    private var cancelled = false
    private var starting = false
    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    func start() async {
        guard !recording, !starting else { return }
        starting = true
        defer { starting = false }
        cancel()
        cancelled = false
        error = nil
        finished = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Allow microphone access in Watch Settings to record a prompt."
            return
        }
        guard !cancelled else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            let activated = await withCheckedContinuation { continuation in
                session.activate(options: []) { @Sendable success, _ in continuation.resume(returning: success) }
            }
            guard activated, !cancelled else {
                releaseAudioSession()
                if !cancelled { error = "The microphone couldn't activate. Try recording again." }
                return
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            recorder = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
            ])
            recorder?.delegate = self
            guard recorder?.record(forDuration: WatchVoiceRequest.maximumDuration) == true else {
                throw RecordingError()
            }
            recording = true
            WKInterfaceDevice.current().play(.start)
        } catch {
            self.error = "Couldn't start recording: \(error.localizedDescription)"
            releaseAudioSession()
        }
    }

    func stop() { recorder?.stop() }

    func cancel() {
        cancelled = true
        recording = false
        recorder?.stop()
        if let file = recorder?.url { try? FileManager.default.removeItem(at: file) }
        recorder = nil
        finished = nil
        releaseAudioSession()
    }

    private func releaseAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false)
        try? session.setCategory(.playback, mode: .default)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let file = recorder.url
        Task { @MainActor [weak self] in
            guard let self, !cancelled, self.recorder?.url == file else { return }
            recording = false
            releaseAudioSession()
            if flag { finished = file; WKInterfaceDevice.current().play(.stop) }
            else { error = "Recording was interrupted. Record again." }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let file = recorder.url
        let message = error?.localizedDescription ?? "Audio recording failed."
        Task { @MainActor [weak self] in
            guard let self, !cancelled, self.recorder?.url == file else { return }
            recording = false
            self.error = message
            releaseAudioSession()
        }
    }

    private struct RecordingError: LocalizedError {
        var errorDescription: String? { "The microphone couldn't start. Check microphone access or use system input." }
    }
}

struct WatchVoiceComposer: View {
    @Bindable var model: WatchModel
    let sessionID: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = VoiceRecorder()
    @State private var typedText = ""
    @State private var inputError: String?

    var body: some View {
        List {
            if recorder.recording {
                VStack(spacing: 8) {
                    Image(systemName: "mic.fill").font(.largeTitle).foregroundStyle(.red)
                    Text("Listening…").font(.headline)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(Int(recorder.elapsed)) / 60 seconds").font(.caption).monospacedDigit()
                    }
                }.frame(maxWidth: .infinity)
                Button("Stop recording", systemImage: "stop.circle.fill") { recorder.stop() }.tint(.red)
            } else if let draft = model.voiceDraft {
                if let reply = draft.reply, reply.error == nil, !reply.text.isEmpty {
                    Text(reply.text)
                    if draft.request.hostID != model.snapshot?.hostID {
                        Text("Pi's session store changed. Discard this recording and record again.").foregroundStyle(.orange)
                    } else {
                        Button(model.reachable ? "Send" : "Queue for iPhone", systemImage: "paperplane.fill") {
                            if model.sendVoicePrompt() { dismiss() }
                        }
                    }
                } else {
                    if let message = draft.reply?.error { Text(message).foregroundStyle(.orange) }
                    else {
                        ProgressView()
                        Text(model.voiceReceived ? "Transcribing on iPhone…" : model.reachable ? "Sending recording to iPhone…" : "Recording saved. Waiting for iPhone…")
                    }
                    Button("Retry transcription", systemImage: "arrow.clockwise") { model.retryVoice() }
                    Button("Close") { dismiss() }
                }
                Button("Record again", systemImage: "mic.fill") {
                    model.discardVoice()
                    if model.voiceDraft == nil { Task { await recorder.start() } }
                }
            } else if !typedText.isEmpty {
                Text(typedText)
                Button(model.reachable ? "Send" : "Queue for iPhone", systemImage: "paperplane.fill") {
                    if model.prompt(typedText, sessionID: sessionID) != nil { dismiss() }
                }
                Button("Record instead", systemImage: "mic.fill") { typedText = ""; Task { await recorder.start() } }
            } else {
                if let message = recorder.error { Text(message).foregroundStyle(.orange) }
                Button("Record prompt", systemImage: "mic.fill") { Task { await recorder.start() } }
            }
            if model.voiceDraft == nil {
                Button("Use system input", systemImage: "keyboard") {
                    recorder.cancel()
                    WKApplication.shared().visibleInterfaceController?.presentTextInputController(withSuggestions: [], allowedInputMode: .plain) { @Sendable results in
                        let text = (results?.first as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { @MainActor in if let text, !text.isEmpty { typedText = text } }
                    }
                }
            }
            if let inputError { Text(inputError).foregroundStyle(.orange) }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
            Button("Cancel", role: .cancel) {
                recorder.cancel()
                model.discardVoice()
                dismiss()
            }
        }
        .navigationTitle(model.voiceDraft?.request.sessionID != nil || sessionID != nil ? "Reply" : "New session")
        .task {
            model.stopSpeaking()
            if model.voiceDraft == nil { await recorder.start() }
        }
        .onChange(of: recorder.finished) {
            guard let file = recorder.finished else { return }
            do { try model.transcribe(file, sessionID: sessionID); recorder.cancel() }
            catch { inputError = error.localizedDescription }
        }
        .onDisappear { recorder.cancel() }
    }
}
