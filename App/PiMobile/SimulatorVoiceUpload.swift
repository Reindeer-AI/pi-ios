#if DEBUG
import Foundation
import PiWatchLink

struct SimulatorVoiceUpload {
    let request: WatchVoiceRequest
    let totalBytes: Int
    private(set) var audio = Data()

    init(request: WatchVoiceRequest, totalBytes: Int, hostID: UUID) throws {
        try request.validate(for: hostID, bytes: totalBytes)
        self.request = request
        self.totalBytes = totalBytes
    }

    mutating func append(_ chunk: Data, offset: Int) throws -> Bool {
        guard offset == audio.count, !chunk.isEmpty, chunk.count <= 32_000,
              chunk.count <= totalBytes - audio.count else { throw WatchLinkError.requestConflict }
        audio.append(chunk)
        return audio.count == totalBytes
    }
}
#endif
