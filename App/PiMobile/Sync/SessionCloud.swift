import Foundation

/// Where sessions sync (`SessionSync`): the user's private iCloud database (`CloudKitSessionCloud`), or a folder
/// (`FolderSessionCloud`, for tests: two simulators sharing one folder are two devices). Per session it holds a record
/// (its details, which device has it, how many of its entries are there and in which chunks, its files' manifest), its
/// entries in chunks, and file contents by SHA-256, which every session shares (the manifest and settings are files
/// too). Nothing there is ever changed in place except records, and those only by compare-and-swap. A deleted session's
/// record stays, emptied (so a device that was offline deletes its copy too); chunks and files no session refers to go
/// in `SessionSync`'s sweep.
protocol SessionCloud: Sendable {
    /// Why sessions can't sync now (not signed in to iCloud, say), or nil when they can.
    func unavailableReason() async -> String?
    /// The records changed since `token` (all of them for nil), and the token to ask with next time; `complete`: none
    /// failed to read (else the token stays, so they come again).
    func changes(since token: Data?) async throws -> (records: [SessionRecord], token: Data?, complete: Bool)
    /// One session's record as it is now, if there is one.
    func record(_ syncId: String) async throws -> SessionRecord?
    /// Saves `record` if the cloud's is still the one it was read as (`record.tag`; nil: there must be none yet). On a
    /// conflict, the cloud's newer record.
    func save(_ record: SessionRecord) async throws -> SessionSave
    func putChunk(_ data: Data, named name: String, session: String) async throws
    func chunk(named name: String, session: String) async throws -> Data?
    /// Of these SHA-256 hashes, the ones whose contents the cloud doesn't have.
    func missingBlobs(_ hashes: [String]) async throws -> Set<String>
    func putBlob(_ hash: String, file: URL) async throws
    func blob(_ hash: String) async throws -> Data
    /// Every chunk and blob the cloud has (`SessionRecord.storedName`), and deleting some.
    func stored() async throws -> [String]
    func delete(stored names: [String]) async throws
}

extension SessionCloud {
    func deleteChunks(named names: [String], session: String) async throws {
        try await delete(stored: names.map { SessionRecord.storedName(chunk: $0, session: session) })
    }
}

enum SessionSave: Sendable {
    case saved(SessionRecord)
    case conflict(SessionRecord)
}

/// A session in the cloud.
struct SessionRecord: Codable, Sendable, Equatable {
    struct Model: Codable, Sendable, Equatable {
        var provider: String
        var modelId: String
    }

    var syncId: String
    var title: String
    /// Milliseconds since 1970, as the engine keeps them.
    var createdAt: Double
    var lastActiveAt: Double?
    var model: Model?
    var thinkingLevel: String?
    /// The device that has the session (`SessionSync.deviceID`), and its name for the others.
    var holder: String
    var holderName: String
    /// How many of its entries the cloud has, and the chunks they're in, in order (`SessionRecord.chunkStart`).
    var count: Int
    var chunks: [String]
    /// Its workspace files' manifest and its settings, as blobs (SHA-256); nil for none.
    var manifest: String?
    var docs: String?
    /// Whether the device that has it is running it (its newest steps come when the run ends).
    var running: Bool
    var deleted: Bool
    var updatedAt: Date
    /// What the cloud's copy was when this was read (CloudKit's change tag, the folder's version); nil before it's saved.
    var tag: String?

    /// A chunk's name: where its entries start, and the device that sent it (two devices never write the same chunk).
    static func chunkName(from: Int, device: String) -> String { "\(from).\(device.prefix(8))" }
    static func chunkStart(_ name: String) -> Int { Int(name.prefix { $0 != "." }) ?? 0 }

    /// A chunk's or a blob's name among everything the cloud has (`SessionCloud.stored`).
    static func storedName(chunk name: String, session: String) -> String { "chunk.\(session).\(name)" }
    static func storedName(blob hash: String) -> String { "blob.\(hash)" }

    /// A deleted session's record, with nothing of the session left in it but its id.
    mutating func empty() {
        deleted = true
        running = false
        title = ""
        createdAt = 0
        lastActiveAt = nil
        model = nil
        thinkingLevel = nil
        holder = ""
        holderName = ""
        count = 0
        chunks = []
        manifest = nil
        docs = nil
        updatedAt = .now
    }

    var emptied: Bool {
        title.isEmpty && holder.isEmpty && holderName.isEmpty && model == nil && chunks.isEmpty && manifest == nil && docs == nil
    }
}

/// A folder as the cloud, for tests (`-syncFolder PATH`): `records/<id>.json`, `chunks/<id>/<name>`, `blobs/<hash>`. A
/// lock file makes a save compare-and-swap, between processes too (two simulators).
final class FolderSessionCloud: SessionCloud {
    let root: URL

    init(root: URL) {
        self.root = root
        for folder in ["records", "chunks", "blobs"] {
            try? FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
    }

    private struct Stored: Codable {
        var version: Int
        var record: SessionRecord
    }

    func unavailableReason() async -> String? {
        FileManager.default.fileExists(atPath: root.path) ? nil : "The sync folder is missing"
    }

    private func recordURL(_ syncId: String) -> URL { root.appending(path: "records/\(syncId).json") }

    private func read(_ url: URL) -> Stored? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
    }

    private func tagged(_ stored: Stored) -> SessionRecord {
        var record = stored.record
        record.tag = String(stored.version)
        return record
    }

    func changes(since token: Data?) async throws -> (records: [SessionRecord], token: Data?, complete: Bool) {
        let seen = token.flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        var versions: [String: Int] = [:]
        var changed: [SessionRecord] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "records"), includingPropertiesForKeys: nil)) ?? []
        var complete = true
        for file in files where file.pathExtension == "json" {
            guard let stored = read(file) else {
                complete = false
                continue
            }
            versions[stored.record.syncId] = stored.version
            if seen[stored.record.syncId] != stored.version { changed.append(tagged(stored)) }
        }
        return (changed, complete ? try JSONEncoder().encode(versions) : token, complete)
    }

    func record(_ syncId: String) async throws -> SessionRecord? {
        read(recordURL(syncId)).map(tagged)
    }

    func save(_ record: SessionRecord) async throws -> SessionSave {
        try locked {
            let url = recordURL(record.syncId)
            let current = read(url)
            if let current, String(current.version) != record.tag { return .conflict(tagged(current)) }
            if current == nil, record.tag != nil { throw SyncError.message("The session's record is gone") }
            var stored = Stored(version: (current?.version ?? 0) + 1, record: record)
            stored.record.tag = nil
            try JSONEncoder().encode(stored).write(to: url, options: .atomic)
            return .saved(tagged(stored))
        }
    }

    /// Runs `work` holding the folder's lock.
    private func locked<T>(_ work: () throws -> T) throws -> T {
        let descriptor = open(root.appending(path: "lock").path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw SyncError.message("The sync folder can't be locked") }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN) }
        return try work()
    }

    func putChunk(_ data: Data, named name: String, session: String) async throws {
        let folder = root.appending(path: "chunks/\(session)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: name), options: .atomic)
    }

    func chunk(named name: String, session: String) async throws -> Data? {
        try? Data(contentsOf: root.appending(path: "chunks/\(session)/\(name)"))
    }


    func missingBlobs(_ hashes: [String]) async throws -> Set<String> {
        Set(hashes.filter { !FileManager.default.fileExists(atPath: root.appending(path: "blobs/\($0)").path) })
    }

    func putBlob(_ hash: String, file: URL) async throws {
        let target = root.appending(path: "blobs/\(hash)")
        let partial = root.appending(path: "blobs/.\(hash).\(UUID().uuidString)")
        try FileManager.default.copyItem(at: file, to: partial)
        if (try? FileManager.default.moveItem(at: partial, to: target)) == nil { try? FileManager.default.removeItem(at: partial) }
    }

    func blob(_ hash: String) async throws -> Data {
        guard let data = try? Data(contentsOf: root.appending(path: "blobs/\(hash)")) else { throw SyncError.message("A file isn't in the sync folder yet") }
        return data
    }

    private func names(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: folder).path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    func stored() async throws -> [String] {
        names(in: "blobs").map(SessionRecord.storedName(blob:))
            + names(in: "chunks").flatMap { session in names(in: "chunks/\(session)").map { SessionRecord.storedName(chunk: $0, session: session) } }
    }

    func delete(stored names: [String]) async throws {
        for name in names {
            var path: String?
            if name.hasPrefix("blob.") {
                path = "blobs/\(name.dropFirst(5))"
            } else if name.hasPrefix("chunk.") {
                // chunk.<session>.<name>: a session's id has no dots.
                let rest = name.dropFirst(6)
                if let dot = rest.firstIndex(of: ".") { path = "chunks/\(rest[..<dot])/\(rest[rest.index(after: dot)...])" }
            }
            if let path { try? FileManager.default.removeItem(at: root.appending(path: path)) }
        }
    }
}

enum SyncError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}
