import Foundation
import Testing
@testable import PiWatchLink

@Test func requestBelongsToPhoneStore() throws {
    let host = UUID()
    let request = WatchRequest(command: .prompt(hostID: host, sessionID: 42, text: "Continue"))
    try request.validate(for: host)
    #expect(throws: WatchLinkError.self) { try request.validate(for: UUID()) }
    #expect(throws: WatchLinkError.self) {
        try WatchRequest(command: .prompt(hostID: host, sessionID: nil, text: " \n ")).validate(for: host)
    }
}

@Test func wireLimitsAndVersion() throws {
    let request = WatchRequest(command: .refresh)
    let data = try WatchWire.encode(request)
    #expect(try WatchWire.decode(WatchRequest.self, from: data) == request)
    let newer = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8)
    #expect(throws: WatchLinkError.self) { try WatchWire.decode(WatchRequest.self, from: newer) }
    #expect(throws: WatchLinkError.self) { try WatchWire.encode(String(repeating: "a", count: 60_000)) }
}

@Test func boundedMessagesPreserveUnicode() {
    let text = String(repeating: "👨‍👩‍👧‍👦", count: 100)
    let message = WatchConversation.Message(id: 1, role: .assistant, text: text)
    #expect(message.text.utf8.count <= 2_000)
    #expect(message.truncated)
    #expect(text.hasPrefix(message.text))
    let messages = (1...12).map { WatchConversation.Message(id: $0, role: .user, text: "message") }
    let conversation = WatchConversation(hostID: UUID(), sessionID: 42, messages: messages)
    #expect(conversation.messages.map(\.id) == Array(5...12))
}

@Test func snapshotFitsConnectivityBudget() throws {
    let host = UUID()
    let sessions = (1...20).map {
        WatchSession(id: $0, title: String(repeating: "a", count: 120), updatedAt: .now, running: false,
                     preview: String(repeating: "b", count: 240), needsPhone: false, error: String(repeating: "c", count: 300))
    }
    let runs = (1...8).map { id in
        WatchRun(request: WatchRequest(command: .prompt(hostID: host, sessionID: id, text: String(repeating: "d", count: 4_000))),
                 state: .answered, answer: String(repeating: "e", count: 4_000), error: String(repeating: "f", count: 1_000))
    }
    let messages = (1...8).map { WatchConversation.Message(id: $0, role: .assistant, text: String(repeating: "g", count: 4_000)) }
    let reply = WatchReply.snapshot(WatchSnapshot(hostID: host, sessions: sessions, runs: runs,
                                                conversation: WatchConversation(hostID: host, sessionID: 1, messages: messages)))
    #expect(try WatchWire.encode(reply).count < 60_000)
}

@Test func voiceRequestsAndRepliesPreserveDestination() throws {
    let host = UUID()
    let request = WatchVoiceRequest(hostID: host, sessionID: 42, locale: "en_US")
    let transcript = WatchVoiceReply(requestID: request.id, hostID: host, text: "Check coffee near the office")
    let reply = try WatchWire.decode(WatchReply.self, from: WatchWire.encode(WatchReply.voiceTranscript(transcript)))
    if case .voiceTranscript(let result) = reply { #expect(result == transcript) }
    else { Issue.record("Expected a transcription reply") }
    try request.validate(for: host, bytes: 256_000)
    #expect(throws: WatchLinkError.self) { try request.validate(for: UUID(), bytes: 256_000) }
    #expect(throws: WatchLinkError.self) { try request.validate(for: host, bytes: 0) }
    #expect(throws: WatchLinkError.self) { try request.validate(for: host, bytes: WatchVoiceRequest.maximumBytes + 1) }
}
