import Foundation
import PiWatchLink

@main
struct StorageChecks {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("requests.json")
        let host = UUID()
        let request = WatchRequest(command: .prompt(hostID: host, sessionID: nil, text: String(repeating: "Fix the failing test. ", count: 100)))
        let store = try WatchRequestStore(file: file)
        var run = try store.admit(request)
        run.sessionID = 42
        run.submissionID = 7
        run.state = .answered
        run.answer = "Fixed"
        run.notified = true
        try store.save(run)
        let message = try JSONSerialization.jsonObject(with: JSONEncoder().encode(run.summary)) as! [String: Any]
        precondition(message["submissionID"] == nil && message["notified"] == nil, "Phone delivery metadata must stay off the wire")
        if case .prompt(_, _, let text) = run.summary.request.command {
            precondition(text.utf8.count <= 240)
        } else { preconditionFailure("Expected a prompt summary") }
        let reopened = try WatchRequestStore(file: file)
        let retry = try reopened.admit(request)
        precondition(retry == run && reopened.runs.count == 1, "A retry must reuse the persisted receipt")
        let conflict = WatchRequest(id: request.id, command: .prompt(hostID: host, sessionID: nil, text: "Different task"))
        try rejects { try reopened.admit(conflict) }
        try Data("not JSON".utf8).write(to: file)
        try rejects { try WatchRequestStore(file: file) }

        let visibilityFile = directory.appendingPathComponent("hidden.json")
        let visibility = try WatchListVisibility(file: visibilityFile)
        try visibility.hide(task: request.id)
        try visibility.hide(session: 42, host: host)
        let restored = try WatchListVisibility(file: visibilityFile)
        precondition(restored.contains(task: request.id))
        precondition(!restored.contains(task: UUID()))
        precondition(restored.contains(session: 42, host: host))
        precondition(!restored.contains(session: 42, host: UUID()), "Hidden sessions belong to one phone store")

        let voice = WatchVoiceRequest(hostID: host, sessionID: 42, locale: "en_US")
        let recording = Data(repeating: 7, count: 98_682)
        var upload = try SimulatorVoiceUpload(request: voice, totalBytes: recording.count, hostID: host)
        try rejects { try upload.append(Data([1]), offset: 1) }
        try rejects { try upload.append(Data(repeating: 1, count: 32_001), offset: 0) }
        precondition(upload.audio.isEmpty)
        for offset in stride(from: 0, to: recording.count, by: 32_000) {
            let end = min(offset + 32_000, recording.count)
            let complete = try upload.append(recording.subdata(in: offset..<end), offset: offset)
            precondition(complete == (end == recording.count))
        }
        precondition(upload.audio == recording)
        try rejects { try upload.append(Data([1]), offset: recording.count) }
        try rejects { try SimulatorVoiceUpload(request: voice, totalBytes: 512_001, hostID: host) }
        try rejects { try SimulatorVoiceUpload(request: voice, totalBytes: 1, hostID: UUID()) }
        print("Watch storage checks passed: receipt projection/retry, conflict, corrupt storage, hidden rows, simulator chunks")
    }

    private static func rejects<T>(_ operation: () throws -> T) throws {
        do { _ = try operation() } catch { return }
        preconditionFailure("Expected the operation to reject invalid input")
    }
}
