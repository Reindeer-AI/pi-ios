import Foundation

public struct WatchRequest: Codable, Equatable, Sendable, Identifiable {
    public enum Command: Codable, Equatable, Sendable {
        case refresh
        case conversation(hostID: UUID, sessionID: Int)
        case prompt(hostID: UUID, sessionID: Int?, text: String)
    }

    public let id: UUID
    public let command: Command

    public init(id: UUID = UUID(), command: Command) {
        self.id = id
        self.command = command
    }

    public func validate(for hostID: UUID) throws {
        switch command {
        case .refresh: break
        case .conversation(let host, _):
            guard host == hostID else { throw WatchLinkError.hostChanged }
        case .prompt(let host, _, let text):
            guard host == hostID else { throw WatchLinkError.hostChanged }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw WatchLinkError.emptyPrompt }
            guard text.utf8.count <= 4_000 else { throw WatchLinkError.promptTooLong }
            guard !trimmed.hasPrefix("!"), !trimmed.hasPrefix("/") else {
                throw WatchLinkError.phoneCommand
            }
        }
    }
}

public enum WatchReply: Codable, Sendable {
    case voiceReceived(requestID: UUID, hostID: UUID)
    case voiceTranscript(WatchVoiceReply)
    case snapshot(WatchSnapshot)
    case conversation(WatchConversation)
    case accepted(WatchRun)
    case failure(String)
    case rejected(requestID: UUID, message: String)
}

public struct WatchSnapshot: Codable, Equatable, Sendable {
    public var hostID: UUID
    public var updatedAt: Date
    public var sessions: [WatchSession]
    public var runs: [WatchRun]
    public var conversation: WatchConversation?

    public init(hostID: UUID, updatedAt: Date = .now, sessions: [WatchSession], runs: [WatchRun], conversation: WatchConversation? = nil) {
        self.hostID = hostID
        self.updatedAt = updatedAt
        self.sessions = sessions
        self.runs = runs
        self.conversation = conversation
    }
}

public struct WatchSession: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public var title: String
    public var updatedAt: Date
    public var running: Bool
    public var preview: String
    public var needsPhone: Bool
    public var error: String?

    public init(id: Int, title: String, updatedAt: Date, running: Bool, preview: String, needsPhone: Bool, error: String?) {
        self.id = id
        self.title = title.watchPrefix(120)
        self.updatedAt = updatedAt
        self.running = running
        self.preview = preview.watchPrefix(240)
        self.needsPhone = needsPhone
        self.error = error?.watchPrefix(300)
    }
}

public struct WatchConversation: Codable, Equatable, Sendable {
    public struct Message: Codable, Equatable, Sendable, Identifiable {
        public enum Role: String, Codable, Sendable { case user, assistant }
        public let id: Int
        public let role: Role
        public let text: String
        public let truncated: Bool

        public init(id: Int, role: Role, text: String) {
            self.id = id
            self.role = role
            self.text = text.watchPrefix(2_000)
            truncated = self.text != text
        }
    }

    public var hostID: UUID
    public var sessionID: Int
    public var updatedAt: Date
    public var messages: [Message]

    public init(hostID: UUID, sessionID: Int, updatedAt: Date = .now, messages: [Message]) {
        self.hostID = hostID
        self.sessionID = sessionID
        self.updatedAt = updatedAt
        self.messages = Array(messages.suffix(8))
    }
}

public struct WatchRun: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case received, queued, running, answered, failed
        public var terminal: Bool { self == .answered || self == .failed }
    }

    public var id: UUID { request.id }
    public let request: WatchRequest
    public var sessionID: Int?
    public var state: State
    public var answer: String
    public var error: String?
    public var updatedAt: Date

    public init(request: WatchRequest, sessionID: Int? = nil, state: State = .received,
                answer: String = "", error: String? = nil, updatedAt: Date = .now) {
        if case .prompt(let host, let session, let text) = request.command {
            self.request = WatchRequest(id: request.id, command: .prompt(hostID: host, sessionID: session, text: text.watchPrefix(240)))
        } else { self.request = request }
        self.sessionID = sessionID
        self.state = state
        self.answer = answer.watchPrefix(1_000)
        self.error = error?.watchPrefix(300)
        self.updatedAt = updatedAt
    }
}

public enum WatchLinkError: LocalizedError {
    case hostChanged, emptyPrompt, promptTooLong, phoneCommand, unsupportedVersion, tooLarge, requestConflict
    public var errorDescription: String? {
        switch self {
        case .hostChanged: "Pi's session store changed. Refresh the watch before sending."
        case .emptyPrompt: "Enter a message first."
        case .promptTooLong: "Use a shorter message (up to 4 KB)."
        case .phoneCommand: "Run shell and slash commands in Pi on iPhone."
        case .unsupportedVersion: "Update Pi on both iPhone and Apple Watch."
        case .tooLarge: "This update is too large for Apple Watch."
        case .requestConflict: "This message ID was already used for a different request."
        }
    }
}

public enum WatchWire {
    public static let key = "piWatch"
    public static let notificationCategory = "pi.watch.reply"
    private struct Envelope<Value: Codable>: Codable { let version: Int; let value: Value }
    public static func encode<Value: Codable>(_ value: Value) throws -> Data {
        let data = try JSONEncoder().encode(Envelope(version: 1, value: value))
        guard data.count <= 60_000 else { throw WatchLinkError.tooLarge }
        return data
    }
    public static func decode<Value: Codable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard data.count <= 60_000 else { throw WatchLinkError.tooLarge }
        let envelope = try JSONDecoder().decode(Envelope<Value>.self, from: data)
        guard envelope.version == 1 else { throw WatchLinkError.unsupportedVersion }
        return envelope.value
    }
}

extension String {
    public func watchPrefix(_ bytes: Int) -> String {
        guard utf8.count > bytes else { return self }
        var result = ""
        var count = 0
        for character in self {
            let size = String(character).utf8.count
            guard count + size <= bytes else { break }
            result.append(character)
            count += size
        }
        return result
    }
}
