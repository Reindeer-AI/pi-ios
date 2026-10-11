import Foundation

public struct WatchVoiceRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let hostID: UUID
    public let sessionID: Int?
    public let locale: String
    public static let maximumBytes = 512_000
    public static let maximumDuration: TimeInterval = 60

    public init(id: UUID = UUID(), hostID: UUID, sessionID: Int?, locale: String) {
        self.id = id
        self.hostID = hostID
        self.sessionID = sessionID
        self.locale = locale
    }

    public func validate(for host: UUID, bytes: Int) throws {
        guard hostID == host else { throw WatchLinkError.hostChanged }
        guard bytes > 0, bytes <= Self.maximumBytes, !locale.isEmpty, locale.utf8.count <= 100 else { throw WatchLinkError.tooLarge }
        if let sessionID, sessionID <= 0 { throw WatchLinkError.tooLarge }
    }
}

public struct WatchVoiceReply: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let hostID: UUID
    public let text: String
    public let error: String?

    public init(requestID: UUID, hostID: UUID, text: String = "", error: String? = nil) {
        self.requestID = requestID
        self.hostID = hostID
        self.text = text.watchPrefix(4_000)
        self.error = error?.watchPrefix(300)
    }
}
