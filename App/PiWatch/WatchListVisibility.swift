import Foundation
import Observation

@MainActor
@Observable
final class WatchListVisibility {
    private let file: URL
    private var hidden: Set<String>

    init(file: URL) throws {
        self.file = file
        hidden = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file)) : []
    }

    func contains(task: UUID) -> Bool { hidden.contains("task:\(task)") }
    func contains(session: Int, host: UUID) -> Bool { hidden.contains("session:\(host):\(session)") }
    func hide(task: UUID) throws { try save("task:\(task)") }
    func hide(session: Int, host: UUID) throws { try save("session:\(host):\(session)") }

    private func save(_ key: String) throws {
        let next = hidden.union([key])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        hidden = next
    }
}
