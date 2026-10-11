import Foundation
import Observation
import AVFoundation
@preconcurrency import WatchConnectivity
import PiWatchLink

@MainActor @Observable
final class WatchModel: NSObject, WCSessionDelegate {
    static let shared = WatchModel()
    private(set) var snapshot: WatchSnapshot?
    private(set) var conversations: [Int: WatchConversation] = [:]
    private(set) var pending: [WatchRequest] = []
    private(set) var reachable = false
    private(set) var failures: [UUID: String] = [:]
    private(set) var voiceDraft: WatchVoiceDraft?
    private var visibility: WatchListVisibility?
    private let voiceDirectory = URL.applicationSupportDirectory.appending(path: "voice-draft", directoryHint: .isDirectory)
    private var voiceFile: URL { voiceDirectory.appending(path: "recording.m4a") }
    private var voiceState: URL { voiceDirectory.appending(path: "draft.json") }
    private var voiceStorageReady = true
    private(set) var voiceReceived = false
    private var voiceTimeout: Task<Void, Never>?
    #if DEBUG && targetEnvironment(simulator)
    private var voiceSending = false
    #endif
    var visibleRuns: [WatchRun] { (snapshot?.runs ?? []).filter { visibility?.contains(task: $0.id) != true } }
    var visibleSessions: [WatchSession] {
        guard let snapshot else { return [] }
        return snapshot.sessions.filter { visibility?.contains(session: $0.id, host: snapshot.hostID) != true }
    }
    var error: String?
    var requestedSession: Int?
    private let outbox = URL.applicationSupportDirectory.appending(path: "outbox.json")
    private let cache = URL.applicationSupportDirectory.appending(path: "snapshot.json")
    private var sending: Set<UUID> = []
    private let speech = AVSpeechSynthesizer()
    private var storageReady = true

    private override init() {
        super.init()
        do {
            visibility = try WatchListVisibility(file: URL.applicationSupportDirectory.appending(path: "hidden-items.json"))
        } catch { self.error = "Couldn't load Watch list preferences: \(error.localizedDescription)" }
        do {
            if FileManager.default.fileExists(atPath: voiceState.path) {
                voiceDraft = try JSONDecoder().decode(WatchVoiceDraft.self, from: Data(contentsOf: voiceState))
            }
        } catch {
            voiceStorageReady = false
            self.error = "Couldn't load the saved recording. Open Pi on iPhone before recording again."
        }
        snapshot = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode(WatchSnapshot.self, from: $0) }
        if let conversation = snapshot?.conversation { conversations[conversation.sessionID] = conversation }
        do {
            if FileManager.default.fileExists(atPath: outbox.path) {
                pending = try JSONDecoder().decode([WatchRequest].self, from: Data(contentsOf: outbox))
            }
        } catch {
            storageReady = false
            self.error = "Couldn't read saved prompts. Open Pi on iPhone before sending again."
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func refresh() {
        send(WatchRequest(command: .refresh))
        for request in pending where failures[request.id] == nil { send(request) }
        if voiceDraft != nil, voiceDraft?.reply == nil, voiceTimeout == nil { retryVoice() }
    }

    func open(_ id: Int) {
        guard let host = snapshot?.hostID else { return }
        send(WatchRequest(command: .conversation(hostID: host, sessionID: id)))
    }

    @discardableResult
    func prompt(_ text: String, sessionID: Int?, requestID: UUID = UUID()) -> UUID? {
        do {
            guard storageReady else { return nil }
            guard let host = snapshot?.hostID else { error = "Open Pi on your paired iPhone and refresh first."; return nil }
            guard pending.count < 10 else { error = "Wait for your queued messages to reach iPhone first."; return nil }
            let request = WatchRequest(id: requestID, command: .prompt(hostID: host, sessionID: sessionID, text: text))
            try request.validate(for: host)
            try saveOutbox(pending.filter { $0.id != requestID } + [request])
            send(request)
            return request.id
        } catch { self.error = error.localizedDescription; return nil }
    }

    func retry(_ request: WatchRequest) {
        failures[request.id] = nil
        send(request)
    }

    func cancel(_ request: WatchRequest) {
        do {
            try saveOutbox(pending.filter { $0.id != request.id })
            for transfer in WCSession.default.outstandingUserInfoTransfers where matches(transfer.userInfo, request.id) { transfer.cancel() }
            failures[request.id] = nil
            try visibility?.hide(task: request.id)
        } catch { self.error = error.localizedDescription }
    }

    func hide(_ run: WatchRun) {
        do {
            guard let visibility else { throw CocoaError(.fileReadCorruptFile) }
            try visibility.hide(task: run.id)
        } catch { self.error = "Couldn't remove this task: \(error.localizedDescription)" }
    }

    func hide(_ session: WatchSession) {
        do {
            guard let visibility else { throw CocoaError(.fileReadCorruptFile) }
            guard let host = snapshot?.hostID else { throw WatchLinkError.hostChanged }
            try visibility.hide(session: session.id, host: host)
        } catch { self.error = "Couldn't remove this session: \(error.localizedDescription)" }
    }

    func transcribe(_ file: URL, sessionID: Int?) throws {
        guard voiceStorageReady else { throw CocoaError(.fileReadCorruptFile) }
        guard voiceDraft == nil, let host = snapshot?.hostID else { throw WatchLinkError.hostChanged }
        let request = WatchVoiceRequest(hostID: host, sessionID: sessionID, locale: Locale.current.identifier)
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try request.validate(for: host, bytes: bytes)
        try FileManager.default.createDirectory(at: voiceDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: voiceFile.path) { try FileManager.default.removeItem(at: voiceFile) }
        try FileManager.default.copyItem(at: file, to: voiceFile)
        try saveVoice(WatchVoiceDraft(request: request))
        retryVoice()
    }

    private func saveVoice(_ draft: WatchVoiceDraft) throws {
        try JSONEncoder().encode(draft).write(to: voiceState, options: .atomic)
        voiceDraft = draft
    }

    func retryVoice() {
        guard var draft = voiceDraft, WCSession.default.activationState == .activated else { return }
        do {
            guard let host = snapshot?.hostID else { return }
            let bytes = try voiceFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try draft.request.validate(for: host, bytes: bytes)
            #if !(DEBUG && targetEnvironment(simulator))
            let alreadyQueued = WCSession.default.outstandingFileTransfers.contains(where: {
                guard let data = $0.file.metadata?[WatchWire.key] as? Data else { return false }
                return (try? WatchWire.decode(WatchVoiceRequest.self, from: data))?.id == draft.request.id
            })
            #endif
            #if DEBUG && targetEnvironment(simulator)
            guard !voiceSending, WCSession.default.isReachable else { return }
            #endif
            draft.reply = nil
            try saveVoice(draft)
            voiceReceived = false
            voiceTimeout?.cancel()
            let request = draft.request
            voiceTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                self?.voiceFailed(request, message: "No transcription reply yet. Recording saved; open Pi on iPhone and retry.")
            }
            #if DEBUG && targetEnvironment(simulator)
            sendSimulatorVoice(request)
            #else
            if !alreadyQueued { WCSession.default.transferFile(voiceFile, metadata: [WatchWire.key: try WatchWire.encode(request)]) }
            #endif
        } catch {
            draft.reply = WatchVoiceReply(requestID: draft.request.id, hostID: draft.request.hostID, error: error.localizedDescription)
            try? saveVoice(draft)
        }
    }

    private func voiceFailed(_ request: WatchVoiceRequest, message: String) {
        guard var draft = voiceDraft, draft.request == request, draft.reply?.text.isEmpty != false else { return }
        voiceTimeout?.cancel()
        voiceTimeout = nil
        draft.reply = WatchVoiceReply(requestID: request.id, hostID: request.hostID, error: message)
        try? saveVoice(draft)
    }

    #if DEBUG && targetEnvironment(simulator)
    private func sendSimulatorVoice(_ request: WatchVoiceRequest) {
        voiceSending = true
        Task { [weak self] in
            guard let self else { return }
            defer { voiceSending = false }
            do {
                let audio = try Data(contentsOf: voiceFile)
                let metadata = try WatchWire.encode(request)
                for offset in stride(from: 0, to: audio.count, by: 32_000) {
                    guard voiceDraft?.request == request else { return }
                    let end = min(offset + 32_000, audio.count)
                    let chunk = audio.subdata(in: offset..<end)
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                        WCSession.default.sendMessage([
                            "voiceRequest": metadata, "voiceAudio": chunk,
                            "voiceOffset": offset, "voiceTotal": audio.count
                        ], replyHandler: { @Sendable reply in
                            if reply["voiceOffset"] as? Int == end { continuation.resume() }
                            else { continuation.resume(throwing: NSError(domain: "PiVoice", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: reply["voiceError"] as? String ?? "Audio transfer wasn't acknowledged. Retry."])) }
                        }, errorHandler: { @Sendable error in continuation.resume(throwing: error) })
                    }
                }
            } catch { voiceFailed(request, message: error.localizedDescription) }
        }
    }
    #endif

    func discardVoice() {
        guard let draft = voiceDraft else { return }
        voiceTimeout?.cancel()
        voiceTimeout = nil
        voiceReceived = false
        for transfer in WCSession.default.outstandingFileTransfers {
            guard let data = transfer.file.metadata?[WatchWire.key] as? Data,
                  (try? WatchWire.decode(WatchVoiceRequest.self, from: data))?.id == draft.request.id else { continue }
            transfer.cancel()
        }
        do {
            try FileManager.default.removeItem(at: voiceDirectory)
            voiceDraft = nil
        } catch { self.error = "Couldn't remove the recording: \(error.localizedDescription)" }
    }

    @discardableResult
    func sendVoicePrompt() -> Bool {
        guard let draft = voiceDraft, let reply = draft.reply, reply.error == nil, !reply.text.isEmpty else { return false }
        guard draft.request.hostID == snapshot?.hostID else { error = WatchLinkError.hostChanged.localizedDescription; return false }
        if prompt(reply.text, sessionID: draft.request.sessionID, requestID: draft.request.id) != nil {
            discardVoice()
            return true
        }
        return false
    }

    private func saveOutbox(_ requests: [WatchRequest]) throws {
        try FileManager.default.createDirectory(at: outbox.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(requests).write(to: outbox, options: .atomic)
        pending = requests
    }

    private func matches(_ info: [String: Any], _ id: UUID) -> Bool {
        guard let data = info[WatchWire.key] as? Data else { return false }
        return (try? WatchWire.decode(WatchRequest.self, from: data))?.id == id
    }

    private func queue(_ request: WatchRequest, data: Data) {
        guard pending.contains(where: { $0.id == request.id }), WCSession.default.activationState == .activated else { return }
        guard !WCSession.default.outstandingUserInfoTransfers.contains(where: { matches($0.userInfo, request.id) }) else { return }
        WCSession.default.transferUserInfo([WatchWire.key: data])
    }

    private func send(_ request: WatchRequest) {
        guard WCSession.default.activationState == .activated else { return }
        do {
            let data = try WatchWire.encode(request)
            guard WCSession.default.isReachable else { queue(request, data: data); return }
            guard sending.insert(request.id).inserted else { return }
            WCSession.default.sendMessage([WatchWire.key: data], replyHandler: { @Sendable [weak self] reply in
                let response = reply[WatchWire.key] as? Data
                Task { @MainActor in
                    self?.sending.remove(request.id)
                    if let response { self?.receive(response) }
                    else { self?.queue(request, data: data) }
                }
            }, errorHandler: { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.sending.remove(request.id)
                    self?.reachable = WCSession.default.isReachable
                    self?.queue(request, data: data)
                }
            })
        } catch { self.error = error.localizedDescription }
    }

    private func receive(_ data: Data) {
        do {
            switch try WatchWire.decode(WatchReply.self, from: data) {
            case .voiceReceived(let requestID, let hostID):
                guard voiceDraft?.request.id == requestID, voiceDraft?.request.hostID == hostID else { return }
                voiceReceived = true
            case .voiceTranscript(let reply):
                guard var draft = voiceDraft, reply.requestID == draft.request.id, reply.hostID == draft.request.hostID else { return }
                if draft.reply?.text.isEmpty == false && draft.reply?.error == nil { return }
                voiceTimeout?.cancel()
                voiceTimeout = nil
                draft.reply = reply
                try saveVoice(draft)
            case .snapshot(let incoming):
                if let previous = snapshot, previous.hostID == incoming.hostID, previous.updatedAt > incoming.updatedAt { return }
                if snapshot?.hostID != incoming.hostID { conversations = [:] }
                let newerRuns = (snapshot?.hostID == incoming.hostID ? snapshot?.runs ?? [] : []).filter { old in
                    !incoming.runs.contains { $0.id == old.id && $0.updatedAt >= old.updatedAt }
                }
                snapshot = incoming
                for run in newerRuns { merge(run) }
                for run in incoming.runs { acknowledge(run.id) }
                if let conversation = incoming.conversation { cacheConversation(conversation) }
            case .conversation(let conversation): cacheConversation(conversation)
            case .accepted(let run):
                // Delayed receipts may belong to a previous phone store.
                if case .prompt(let host, _, _) = run.request.command, snapshot?.hostID == host { merge(run) }
                acknowledge(run.id)
            case .failure(let message): error = message
            case .rejected(let id, let message):
                if pending.contains(where: { $0.id == id }) { failures[id] = message }
                else { error = message }
            }
            if let snapshot {
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: cache, options: .atomic)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func cacheConversation(_ conversation: WatchConversation) {
        guard conversation.hostID == snapshot?.hostID else { return }
        if let previous = conversations[conversation.sessionID], previous.updatedAt > conversation.updatedAt { return }
        conversations[conversation.sessionID] = conversation
        snapshot?.conversation = conversation
    }

    private func merge(_ run: WatchRun) {
        guard var value = snapshot else { return }
        if let previous = value.runs.first(where: { $0.id == run.id }), previous.updatedAt > run.updatedAt { return }
        value.runs.removeAll { $0.id == run.id }
        value.runs.append(run)
        value.runs = Array(value.runs.sorted { $0.updatedAt > $1.updatedAt }.prefix(8))
        snapshot = value
    }

    private func acknowledge(_ id: UUID) {
        guard pending.contains(where: { $0.id == id }) else { return }
        do { try saveOutbox(pending.filter { $0.id != id }) }
        catch { self.error = error.localizedDescription; return }
        failures[id] = nil
        for transfer in WCSession.default.outstandingUserInfoTransfers where matches(transfer.userInfo, id) { transfer.cancel() }
    }

    func speak(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: text))
    }
    func stopSpeaking() { speech.stopSpeaking(at: .immediate) }

    func finishBackgroundDelivery() async {
        await Task.yield()
        while WCSession.default.activationState != .activated || WCSession.default.hasContentPending {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
        // Delegate callbacks enqueue their cache writes on the main actor before delivery drains.
        await Task.yield()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchWire.key] as? Data else { return }
        Task { @MainActor [weak self] in self?.receive(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchWire.key] as? Data else { return }
        Task { @MainActor [weak self] in self?.receive(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchWire.key] as? Data else { return }
        Task { @MainActor [weak self] in self?.receive(data) }
    }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        guard let message = error?.localizedDescription,
              let data = fileTransfer.file.metadata?[WatchWire.key] as? Data,
              let request = try? WatchWire.decode(WatchVoiceRequest.self, from: data) else { return }
        Task { @MainActor [weak self] in self?.voiceFailed(request, message: message) }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let data = session.receivedApplicationContext[WatchWire.key] as? Data
        Task { @MainActor [weak self] in
            if let data { self?.receive(data) }
            self?.reachable = WCSession.default.isReachable
            self?.refresh()
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.reachable = WCSession.default.isReachable
            self?.refresh()
        }
    }
}
