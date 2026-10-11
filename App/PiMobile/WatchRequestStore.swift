import Foundation
import PiWatchLink

@MainActor
final class WatchRequestStore {
    struct Receipt: Codable, Equatable, Sendable, Identifiable {
        let request: WatchRequest
        var id: UUID { request.id }
        var sessionID: Int?
        var submissionID: Int?
        var state: WatchRun.State = .received
        var answer = ""
        var error: String?
        var updatedAt: Date = .now
        var notified = false

        var summary: WatchRun {
            WatchRun(request: request, sessionID: sessionID, state: state, answer: answer, error: error, updatedAt: updatedAt)
        }
    }

    private(set) var runs: [Receipt]
    private let file: URL

    init(file: URL) throws {
        self.file = file
        runs = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode([Receipt].self, from: Data(contentsOf: file)) : []
    }

    func run(_ id: UUID) -> Receipt? { runs.first { $0.id == id } }

    @discardableResult
    func admit(_ request: WatchRequest) throws -> Receipt {
        if let existing = run(request.id) {
            guard existing.request == request else { throw WatchLinkError.requestConflict }
            return existing
        }
        guard case .prompt(_, let session, _) = request.command else { throw WatchLinkError.emptyPrompt }
        let run = Receipt(request: request, sessionID: session)
        try save(run)
        return run
    }

    func save(_ run: Receipt) throws {
        var next = runs.filter { $0.id != run.id }
        next.append(run)
        // Keep terminal receipts: a delayed retry must not start the same task again.
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        runs = next
    }
}
