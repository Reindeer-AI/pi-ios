import Foundation
import UIKit
import UserNotifications
@preconcurrency import WatchConnectivity
import PiWatchLink

@MainActor
final class WatchCompanion: NSObject, WCSessionDelegate {
    enum Failure: LocalizedError {
        case sessionMissing, engineUnavailable, onDeviceBackground
        var errorDescription: String? {
            switch self {
            case .sessionMissing: "This session was deleted on iPhone."
            case .engineUnavailable: "Open Pi on iPhone to finish setup."
            case .onDeviceBackground: "Open Pi on iPhone to use its on-device model, or choose a cloud model."
            }
        }
    }

    private weak var app: AppModel?
    private let hostID: UUID
    private let store: WatchRequestStore?
    private let storeError: String?
    private let alertsKey: String
    private var selectedSession: Int?
    private var processing: Set<UUID> = []
    private var update: Task<Void, Never>?
    private var reconciling = false
    #if DEBUG && targetEnvironment(simulator)
    private var simulatorVoiceUpload: SimulatorVoiceUpload?
    #endif
    private var transcribing: [UUID: WatchVoiceTranscriber] = [:]
    private let voiceDirectory: URL
    var alertsEnabled: Bool { UserDefaults.standard.bool(forKey: alertsKey) }

    @MainActor private final class DeliveryLease {
        private var id: UIBackgroundTaskIdentifier = .invalid
        private(set) var expired = false
        init(expiration: @escaping @MainActor () -> Void = {}) {
            id = UIApplication.shared.beginBackgroundTask(withName: "Pi Watch delivery") { [weak self] in
                MainActor.assumeIsolated {
                    self?.expired = true
                    expiration()
                    self?.end()
                }
            }
        }
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    init(app: AppModel, storage: String) {
        self.app = app
        let key = "watch.host.\(storage)"
        hostID = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(hostID.uuidString, forKey: key)
        alertsKey = "watch.alerts.\(storage)"
        voiceDirectory = URL.applicationSupportDirectory.appending(path: "watch-voice-\(storage)", directoryHint: .isDirectory)
        do {
            store = try WatchRequestStore(file: URL.applicationSupportDirectory.appending(path: "watch-\(storage).json"))
            storeError = nil
        } catch {
            store = nil
            storeError = "Pi couldn't read its Watch request receipts: \(error.localizedDescription)"
        }
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func enableAlerts() async {
        await ExtensionPermissions.shared.askSystemNotifications()
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        UserDefaults.standard.set(status == .authorized || status == .provisional, forKey: alertsKey)
    }

    func disableAlerts() { UserDefaults.standard.set(false, forKey: alertsKey) }

    func enableVoice() async -> Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        return await authorizeSpeechRecognition()
    }

    private struct SavedVoice: Codable {
        let request: WatchVoiceRequest
        let reply: WatchVoiceReply
    }

    private func receiveVoice(_ file: URL, request: WatchVoiceRequest) async {
        defer { try? FileManager.default.removeItem(at: file) }
        var reply: WatchVoiceReply
        do {
            let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try request.validate(for: hostID, bytes: bytes)
            if let data = try? WatchWire.encode(WatchReply.voiceReceived(requestID: request.id, hostID: hostID)), WCSession.default.isReachable {
                WCSession.default.sendMessage([WatchWire.key: data], replyHandler: nil, errorHandler: { @Sendable _ in })
            }
            let savedFile = voiceDirectory.appending(path: "\(request.id).json")
            if let data = try? Data(contentsOf: savedFile) {
                let saved = try JSONDecoder().decode(SavedVoice.self, from: data)
                guard saved.request == request else { throw WatchLinkError.requestConflict }
                reply = saved.reply
            } else {
                guard transcribing[request.id] == nil else { return }
                let transcriber = WatchVoiceTranscriber()
                transcribing[request.id] = transcriber
                defer { transcribing[request.id] = nil }
                let lease = DeliveryLease { transcriber.cancel() }
                defer { lease.end() }
                let text = try await transcriber.transcribe(file, locale: request.locale)
                guard text.utf8.count <= 4_000 else { throw WatchLinkError.promptTooLong }
                reply = WatchVoiceReply(requestID: request.id, hostID: hostID, text: text)
                try FileManager.default.createDirectory(at: voiceDirectory, withIntermediateDirectories: true)
                try JSONEncoder().encode(SavedVoice(request: request, reply: reply)).write(to: savedFile, options: .atomic)
            }
        } catch {
            let message = error is CancellationError
                ? "Transcription stopped when iPhone background time ended. Recording saved on Watch; open Pi and retry."
                : error.localizedDescription
            reply = WatchVoiceReply(requestID: request.id, hostID: request.hostID, error: message)
        }
        deliverVoiceReply(reply)
    }

    private func deliverVoiceReply(_ reply: WatchVoiceReply) {
        guard let data = try? WatchWire.encode(WatchReply.voiceTranscript(reply)),
              WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo([WatchWire.key: data])
        if WCSession.default.isReachable {
            WCSession.default.sendMessage([WatchWire.key: data], replyHandler: nil, errorHandler: { @Sendable _ in })
        }
    }

    func changed() {
        guard WCSession.isSupported(), update == nil else { return }
        update = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            update = nil
            await reconcile()
            publish()
        }
    }

    private func conversation(_ id: Int) -> WatchConversation? {
        guard let session = app?.sessions.first(where: { $0.id == id }) else { return nil }
        let messages = session.items.reversed().lazy.compactMap { item -> WatchConversation.Message? in
            switch item {
            case .user(let id, let text): return .init(id: id, role: .user, text: text)
            case .assistant(let id, let text, _, _, let error):
                return .init(id: id, role: .assistant, text: text.isEmpty ? error ?? "" : text)
            default: return nil
            }
        }
        var recent = Array(messages.prefix(8))
        recent.reverse()
        return WatchConversation(hostID: hostID, sessionID: id, messages: recent)
    }

    private func snapshot() -> WatchSnapshot {
        let sessions = (app?.sessions ?? []).sorted { $0.lastActive > $1.lastActive }.prefix(20).map { session in
            WatchSession(id: session.id, title: session.title, updatedAt: session.lastActive,
                         running: session.running, preview: conversation(session.id)?.messages.last?.text ?? "",
                         needsPhone: (app?.dialogs.contains { $0.sessionId == session.id } ?? false)
                            || (app?.panels.contains { $0.sessionId == session.id && $0.visible } ?? false), error: session.error)
        }
        return WatchSnapshot(hostID: hostID, sessions: sessions,
                             runs: Array((store?.runs ?? []).sorted { $0.updatedAt > $1.updatedAt }.prefix(8)).map(\.summary),
                             conversation: selectedSession.flatMap(conversation))
    }

    private func publish() {
        guard WCSession.default.activationState == .activated, WCSession.default.isWatchAppInstalled else { return }
        var latest = snapshot()
        var encoded = try? WatchWire.encode(WatchReply.snapshot(latest))
        if encoded == nil {
            latest.conversation = nil
            latest.sessions = Array(latest.sessions.prefix(10))
            latest.runs = Array(latest.runs.prefix(4))
            encoded = try? WatchWire.encode(WatchReply.snapshot(latest))
        }
        guard let data = encoded else { return }
        do { try WCSession.default.updateApplicationContext([WatchWire.key: data]) }
        catch { log("watch", "Sync: \(error.localizedDescription)") }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage([WatchWire.key: data], replyHandler: nil, errorHandler: { @Sendable _ in })
        }
    }

    private func receive(_ data: Data) -> WatchReply {
        var requestID: UUID?
        do {
            let request = try WatchWire.decode(WatchRequest.self, from: data)
            requestID = request.id
            try request.validate(for: hostID)
            switch request.command {
            case .refresh:
                Task { [weak self] in
                    await self?.app?.start()
                    await self?.reconcile()
                    self?.publish()
                }
                return .snapshot(snapshot())
            case .conversation(_, let id):
                selectedSession = id
                guard let cached = conversation(id) else { throw Failure.sessionMissing }
                Task { [weak self] in
                    await self?.app?.start()
                    await self?.app?.loadTranscript(id)
                    self?.publish()
                }
                return .conversation(cached)
            case .prompt:
                guard let store else { return .failure(storeError ?? "Watch request storage is unavailable.") }
                let run = try store.admit(request)
                if run.state == .received { perform(request.id) }
                return .accepted(run.summary)
            }
        } catch {
            if let requestID { return .rejected(requestID: requestID, message: error.localizedDescription) }
            return .failure(error.localizedDescription)
        }
    }

    private func perform(_ id: UUID) {
        guard let store, let run = store.run(id), run.state == .received, processing.insert(id).inserted else { return }
        Task { [weak self] in
            guard let self, let app else { return }
            let lease = DeliveryLease()
            defer {
                processing.remove(id)
                lease.end()
                changed()
            }
            do {
                await app.start()
                guard !lease.expired else { return }
                guard app.phase == .ready else { throw Failure.engineUnavailable }
                guard case .prompt(_, _, let text) = run.request.command else { return }
                var current = store.run(id) ?? run
                if current.sessionID == nil {
                    current.sessionID = try await app.createSession(requestID: id)
                    try store.save(current)
                }
                guard !lease.expired else { return }
                guard let sessionID = current.sessionID else { throw Failure.sessionMissing }
                current.submissionID = try await app.submitFromWatch(text, sessionID: sessionID, requestID: id)
                current.state = current.submissionID == nil ? .answered : .queued
                if current.submissionID == nil { current.answer = "Handled on iPhone." }
                current.updatedAt = .now
                try store.save(current)
                selectedSession = sessionID
                await reconcile()
            } catch {
                var failed = store.run(id) ?? run
                failed.state = .failed
                failed.error = error.localizedDescription
                failed.updatedAt = .now
                try? store.save(failed)
            }
            publish()
        }
    }

    private func reconcile() async {
        guard !reconciling, let app, app.phase == .ready, let store else { return }
        reconciling = true
        defer { reconciling = false }
        for run in store.runs where !run.state.terminal {
            if run.state == .received { perform(run.id); continue }
            guard let session = run.sessionID, let submission = run.submissionID else { continue }
            do {
                guard let result = try await app.engine.command("session.submission", ["id": session, "submissionId": submission]) as? [String: Any] else { continue }
                var current = store.run(run.id) ?? run
                switch result["status"] as? String {
                case "queued": current.state = .queued
                case "placed": current.state = .running
                case "done":
                    current.answer = (result["text"] as? String ?? "").watchPrefix(2_000)
                    current.error = result["error"] as? String
                    current.state = current.error == nil ? .answered : .failed
                case "unanswered":
                    current.state = .failed
                    current.error = result["detail"] as? String ?? result["reason"] as? String ?? "The task stopped on iPhone."
                default: continue
                }
                if current.state != run.state || current.answer != run.answer || current.error != run.error {
                    current.updatedAt = .now
                    try store.save(current)
                }
            } catch { log("watch", "Reconcile: \(error.localizedDescription)") }
        }
        for run in store.runs where run.state.terminal && !run.notified {
            await completed(run)
        }
    }

    private func completed(_ run: WatchRequestStore.Receipt) async {
        guard let store else { return }
        if WCSession.default.activationState == .activated, WCSession.default.isWatchAppInstalled,
           let data = try? WatchWire.encode(WatchReply.accepted(run.summary)) {
            WCSession.default.transferUserInfo([WatchWire.key: data])
        }
        if alertsEnabled, let session = run.sessionID {
            let content = UNMutableNotificationContent()
            content.title = run.state == .answered ? "Pi finished" : "Pi needs attention"
            content.body = (run.error ?? (run.answer.isEmpty ? "Open Pi to see the result." : run.answer)).watchPrefix(240)
            content.categoryIdentifier = WatchWire.notificationCategory
            content.sound = .default
            content.userInfo = ["session": session, "watchRequest": run.id.uuidString]
            do {
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pi.watch.\(run.id)", content: content, trigger: nil))
            } catch { log("watch", "Notification: \(error.localizedDescription)"); return }
        }
        var current = run
        current.notified = true
        try? store.save(current)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        #if DEBUG && targetEnvironment(simulator)
        if let metadata = message["voiceRequest"] as? Data,
           let audio = message["voiceAudio"] as? Data,
           let offset = message["voiceOffset"] as? Int,
           let total = message["voiceTotal"] as? Int {
            nonisolated(unsafe) let replyHandler = replyHandler
            Task { @MainActor [weak self] in
                guard let self else { replyHandler(["voiceError": "Pi is starting. Retry."]); return }
                do {
                    let request = try WatchWire.decode(WatchVoiceRequest.self, from: metadata)
                    if offset == 0 { simulatorVoiceUpload = try SimulatorVoiceUpload(request: request, totalBytes: total, hostID: hostID) }
                    guard var upload = simulatorVoiceUpload, upload.request == request, upload.totalBytes == total else { throw WatchLinkError.requestConflict }
                    let complete = try upload.append(audio, offset: offset)
                    simulatorVoiceUpload = upload
                    if complete {
                        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
                        try upload.audio.write(to: file, options: .atomic)
                        simulatorVoiceUpload = nil
                        replyHandler(["voiceOffset": upload.audio.count])
                        await receiveVoice(file, request: request)
                    } else { replyHandler(["voiceOffset": upload.audio.count]) }
                } catch {
                    simulatorVoiceUpload = nil
                    replyHandler(["voiceError": error.localizedDescription])
                }
            }
            return
        }
        #endif
        guard let data = message[WatchWire.key] as? Data else { replyHandler([:]); return }
        nonisolated(unsafe) let replyHandler = replyHandler
        Task { @MainActor [weak self] in
            let reply = self?.receive(data) ?? .failure("Pi is starting. Try again.")
            replyHandler((try? WatchWire.encode(reply)).map { [WatchWire.key: $0] } ?? [:])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchWire.key] as? Data else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = receive(data)
            if let response = try? WatchWire.encode(reply), WCSession.default.activationState == .activated {
                WCSession.default.transferUserInfo([WatchWire.key: response])
            }
            changed()
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let data = file.metadata?[WatchWire.key] as? Data,
              let request = try? WatchWire.decode(WatchVoiceRequest.self, from: data) else { return }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            let bytes = try file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 0, bytes <= WatchVoiceRequest.maximumBytes else { throw WatchLinkError.tooLarge }
            try FileManager.default.copyItem(at: file.fileURL, to: copy)
        } catch {
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.deliverVoiceReply(WatchVoiceReply(requestID: request.id, hostID: request.hostID, error: message))
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { try? FileManager.default.removeItem(at: copy); return }
            await receiveVoice(copy, request: request)
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor [weak self] in self?.changed() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) { Task { @MainActor [weak self] in self?.changed() } }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
