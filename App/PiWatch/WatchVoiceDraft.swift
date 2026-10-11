import Foundation
import PiWatchLink

struct WatchVoiceDraft: Codable, Equatable, Sendable {
    let request: WatchVoiceRequest
    var reply: WatchVoiceReply?
}
