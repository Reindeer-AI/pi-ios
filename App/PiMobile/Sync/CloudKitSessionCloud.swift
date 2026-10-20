import CloudKit
import Foundation

/// Sessions in the user's private iCloud database (`SessionSync`): records in the zone "Sessions" (read as changes since
/// a token), chunks of entries and file contents in the zone "Data" (read by name). Titles, model names and device names
/// are encrypted fields; contents are assets. Needs the iCloud (CloudKit) entitlement with the app's container
/// (`PiSyncContainer` in Info.plist names it; builds without one don't sync).
final class CloudKitSessionCloud: SessionCloud, @unchecked Sendable {
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private static let sessionsZone = CKRecordZone.ID(zoneName: "Sessions")
    private static let dataZone = CKRecordZone.ID(zoneName: "Data")
    /// CloudKit takes at most 400 records in one request.
    private static let batch = 200

    private let lock = NSLock()
    private var zonesReady = false
    /// The records as last read or saved, for a compare-and-swap save (CloudKit's needs the record it changes).
    private var server: [String: CKRecord] = [:]

    init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    func unavailableReason() async -> String? {
        do {
            switch try await container.accountStatus() {
            case .available: return nil
            case .noAccount: return "Sign in to iCloud in Settings to sync sessions"
            case .restricted: return "iCloud is restricted on this device"
            case .temporarilyUnavailable: return "iCloud is temporarily unavailable"
            default: return "iCloud's status is unknown"
            }
        } catch {
            return error.localizedDescription
        }
    }

    private func ensureZones() async throws {
        if lock.withLock({ zonesReady }) { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.sessionsZone), CKRecordZone(zoneID: Self.dataZone)], deleting: [])
        lock.withLock { zonesReady = true }
    }

    /// Runs `work`, making the zones again if they're gone (the user cleared pi's iCloud data).
    private func withZones<T>(_ work: () async throws -> T) async throws -> T {
        try await ensureZones()
        do {
            return try await work()
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            lock.withLock { zonesReady = false }
            try await ensureZones()
            return try await work()
        }
    }

    // MARK: Records

    func changes(since token: Data?) async throws -> (records: [SessionRecord], token: Data?, complete: Bool) {
        try await withZones {
            var changeToken = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
            var records: [SessionRecord] = []
            var complete = true
            while true {
                let page: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>], deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
                do {
                    page = try await database.recordZoneChanges(inZoneWith: Self.sessionsZone, since: changeToken)
                } catch let error as CKError where error.code == .changeTokenExpired {
                    changeToken = nil
                    records = []
                    complete = true
                    continue
                }
                for result in page.modificationResultsByID.values {
                    switch result {
                    case .success(let modification):
                        remember(modification.record)
                        records.append(Self.session(from: modification.record))
                    case .failure:
                        complete = false
                    }
                }
                changeToken = page.changeToken
                if !page.moreComing { break }
            }
            guard complete else { return (records, token, false) }
            return (records, changeToken.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }, true)
        }
    }

    func record(_ syncId: String) async throws -> SessionRecord? {
        try await withZones {
            do {
                let record = try await database.record(for: CKRecord.ID(recordName: syncId, zoneID: Self.sessionsZone))
                remember(record)
                return Self.session(from: record)
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
        }
    }

    func save(_ record: SessionRecord) async throws -> SessionSave {
        try await withZones {
            let id = CKRecord.ID(recordName: record.syncId, zoneID: Self.sessionsZone)
            var base = lock.withLock { server[record.syncId] }
            if let tag = record.tag, base?.recordChangeTag != tag {
                // Read since this launch, or changed since: compare with the cloud's.
                base = try? await database.record(for: id)
                guard let base, base.recordChangeTag == tag else {
                    if let base { remember(base); return .conflict(Self.session(from: base)) }
                    throw SyncError.message("The session's record is gone from iCloud")
                }
            }
            let saving = Self.fill(record.tag == nil ? CKRecord(recordType: "Session", recordID: id) : base!, from: record)
            let results = try await database.modifyRecords(saving: [saving], deleting: [], savePolicy: .ifServerRecordUnchanged)
            switch results.saveResults[id] {
            case .success(let saved):
                remember(saved)
                return .saved(Self.session(from: saved))
            case .failure(let error as CKError) where error.code == .serverRecordChanged:
                guard let theirs = error.serverRecord else { throw error }
                remember(theirs)
                return .conflict(Self.session(from: theirs))
            case .failure(let error):
                throw error
            case nil:
                throw SyncError.message("iCloud didn't save the session")
            }
        }
    }

    private func remember(_ record: CKRecord) {
        lock.withLock { server[record.recordID.recordName] = record }
    }

    private static func fill(_ record: CKRecord, from session: SessionRecord) -> CKRecord {
        let secret = record.encryptedValues
        secret["title"] = session.title
        secret["holderName"] = session.holderName
        secret["model"] = session.model.map { "\($0.provider)\n\($0.modelId)" }
        secret["thinkingLevel"] = session.thinkingLevel
        secret["manifest"] = session.manifest
        secret["docs"] = session.docs
        record["createdAt"] = session.createdAt
        record["lastActiveAt"] = session.lastActiveAt
        record["holder"] = session.holder
        record["count"] = session.count
        record["chunks"] = session.chunks
        record["running"] = session.running
        record["deleted"] = session.deleted
        record["updatedAt"] = session.updatedAt
        return record
    }

    private static func session(from record: CKRecord) -> SessionRecord {
        let secret = record.encryptedValues
        let model = (secret["model"] as? String)?.split(separator: "\n", maxSplits: 1).map(String.init)
        return SessionRecord(
            syncId: record.recordID.recordName,
            title: secret["title"] as? String ?? "",
            createdAt: record["createdAt"] as? Double ?? 0,
            lastActiveAt: record["lastActiveAt"] as? Double,
            model: model.flatMap { $0.count == 2 ? SessionRecord.Model(provider: $0[0], modelId: $0[1]) : nil },
            thinkingLevel: secret["thinkingLevel"] as? String,
            holder: record["holder"] as? String ?? "",
            holderName: secret["holderName"] as? String ?? "another device",
            count: record["count"] as? Int ?? 0,
            chunks: record["chunks"] as? [String] ?? [],
            manifest: secret["manifest"] as? String,
            docs: secret["docs"] as? String,
            running: record["running"] as? Bool ?? false,
            deleted: record["deleted"] as? Bool ?? false,
            updatedAt: record["updatedAt"] as? Date ?? .distantPast,
            tag: record.recordChangeTag
        )
    }

    // MARK: Contents

    private func chunkID(_ name: String, session: String) -> CKRecord.ID {
        CKRecord.ID(recordName: SessionRecord.storedName(chunk: name, session: session), zoneID: Self.dataZone)
    }

    private func blobID(_ hash: String) -> CKRecord.ID {
        CKRecord.ID(recordName: SessionRecord.storedName(blob: hash), zoneID: Self.dataZone)
    }

    /// Saves a record with `file` as its asset, replacing one of that name.
    private func put(_ id: CKRecord.ID, type: String, file: URL) async throws {
        try await withZones {
            let record = CKRecord(recordType: type, recordID: id)
            record["data"] = CKAsset(fileURL: file)
            let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            if case .failure(let error) = results.saveResults[id] { throw error }
        }
    }

    /// A record's asset, or nil when there's no such record.
    private func contents(_ id: CKRecord.ID) async throws -> Data? {
        try await withZones {
            do {
                let record = try await database.record(for: id)
                guard let url = (record["data"] as? CKAsset)?.fileURL else { return nil }
                return try Data(contentsOf: url)
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
        }
    }

    func putChunk(_ data: Data, named name: String, session: String) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "chunk-\(UUID().uuidString)")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await put(chunkID(name, session: session), type: "Chunk", file: file)
    }

    func chunk(named name: String, session: String) async throws -> Data? {
        try await contents(chunkID(name, session: session))
    }

    /// The zone "Data" from its start, names only (no contents).
    func stored() async throws -> [String] {
        try await withZones {
            var names: [String] = []
            var token: CKServerChangeToken?
            while true {
                let page = try await database.recordZoneChanges(inZoneWith: Self.dataZone, since: token, desiredKeys: [])
                names += page.modificationResultsByID.keys.map(\.recordName)
                token = page.changeToken
                if !page.moreComing { break }
            }
            return names
        }
    }

    func delete(stored names: [String]) async throws {
        try await withZones {
            for start in stride(from: 0, to: names.count, by: Self.batch) {
                let ids = names[start..<min(start + Self.batch, names.count)].map { CKRecord.ID(recordName: $0, zoneID: Self.dataZone) }
                _ = try await database.modifyRecords(saving: [], deleting: ids)
            }
        }
    }

    func missingBlobs(_ hashes: [String]) async throws -> Set<String> {
        try await withZones {
            var missing = Set<String>()
            for start in stride(from: 0, to: hashes.count, by: Self.batch) {
                let some = Array(hashes[start..<min(start + Self.batch, hashes.count)])
                let results = try await database.records(for: some.map(blobID), desiredKeys: [])
                for hash in some {
                    switch results[blobID(hash)] {
                    case .success: break
                    case .failure(let error as CKError) where error.code == .unknownItem: missing.insert(hash)
                    case .failure(let error): throw error
                    case nil: missing.insert(hash)
                    }
                }
            }
            return missing
        }
    }

    func putBlob(_ hash: String, file: URL) async throws {
        try await put(blobID(hash), type: "Blob", file: file)
    }

    func blob(_ hash: String) async throws -> Data {
        guard let data = try await contents(blobID(hash)) else { throw SyncError.message("A file isn't in iCloud yet") }
        return data
    }
}
