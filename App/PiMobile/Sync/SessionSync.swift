import Foundation
import Observation
import UIKit

/// Sessions kept in step across the user's devices through iCloud (`SessionCloud`). One device has a session at a time,
/// the one it was last continued on: it runs there, and after each run that device sends what's new (the entries after
/// the ones iCloud has, its settings, its changed files). The other devices bring their copy up to date and show it
/// read-only until the user continues it on one of them (`continueHere`), which makes that device the one that has it
/// and tells the agent the session moved. What a device added to a session another device had taken meanwhile (offline,
/// say) isn't lost: it stays in a session of its own (`replica.split`).
///
/// Launch arguments for tests: `-syncFolder PATH` (a folder for iCloud, shared by simulators), `-syncDeviceName NAME`,
/// `-syncInterval SECONDS`.
@MainActor
@Observable
final class SessionSync {
    /// Where a session stands, for its screen and its row.
    enum Status: Equatable {
        /// In iCloud as it is here.
        case synced
        /// Its changes wait to go: until its run ends, or for the reason given.
        case waiting(String)
        case uploading
        case downloading
        /// Another device has it (its name); this copy is up to date with iCloud unless `behind`.
        case elsewhere(String, running: Bool, behind: Bool)
    }

    /// Everything at once, for the sessions list and Settings.
    enum Summary: Equatable {
        case off(String)
        case syncing
        case synced(Date?)
        case waiting(String)
    }

    /// Whether sessions sync (Settings); on unless the user turned it off.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            Task { await tellEngine() }
            if enabled { kick() }
        }
    }
    /// What the other devices call this one (Settings); its kind unless the user named it.
    var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: Self.nameKey) }
    }
    let deviceKind: String
    let deviceID: String

    /// Why sessions can't sync (no iCloud account, a build without iCloud), or nil.
    private(set) var unavailable: String?
    private(set) var syncing = false
    private(set) var lastSynced: Date?
    /// The last cycle's failure, if it failed.
    private(set) var failure: String?
    /// Sessions sending or receiving right now.
    private(set) var activity: [Int: Status] = [:]
    /// The sessions as iCloud has them (by sync id), as last read.
    private(set) var records: [String: SessionRecord] = [:]

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var cloud: SessionCloud?
    @ObservationIgnored private var saved = Saved()
    @ObservationIgnored private var cycleTask: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let enabledKey = "syncSessions"
    private static let nameKey = "syncDeviceName"

    /// What this device remembers between launches.
    private struct Saved: Codable {
        var token: Data?
        var records: [String: SessionRecord] = [:]
        /// Sessions here with changes to send (local ids).
        var dirty: Set<Int> = []
        /// How far this device brought another device's session (by sync id).
        var applied: [String: Applied] = [:]
        var lastSynced: Date?

        struct Applied: Codable {
            var count: Int
            var manifest: String?
            var docs: String?
            /// The record it was brought up to (its tag): nothing to do while iCloud's has the same.
            var tag: String?
        }
    }

    init() {
        let defaults = UserDefaults.standard
        // On unless turned off (in Settings, or `-syncSessions NO`).
        enabled = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
        deviceKind = ProcessInfo.processInfo.isiOSAppOnMac ? "Mac" : UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        deviceName = defaults.string(forKey: Self.nameKey) ?? deviceKind
        // Not restored from a backup onto another device, unlike a value in UserDefaults.
        deviceID = UIDevice.current.identifierForVendor?.uuidString ?? {
            let stored = defaults.string(forKey: "syncDeviceID") ?? UUID().uuidString
            defaults.set(stored, forKey: "syncDeviceID")
            return stored
        }()
        if let folder = defaults.string(forKey: "syncFolder") {
            cloud = FolderSessionCloud(root: URL(fileURLWithPath: folder))
        } else if let container = Bundle.main.object(forInfoDictionaryKey: "PiSyncContainer") as? String, container.hasPrefix("iCloud.") {
            cloud = CloudKitSessionCloud(containerIdentifier: container)
        } else {
            unavailable = "This build of pi doesn't sync sessions"
        }
    }

    /// Whether this build syncs sessions at all (it names an iCloud container, or a test folder).
    var supported: Bool { cloud != nil }

    /// Whether sessions sync now: on, and possible.
    var active: Bool { enabled && cloud != nil }

    /// For the engine's `open`: the device, for the agent.
    var deviceInfo: [String: Any] { ["kind": deviceKind, "name": deviceName, "sync": active] }

    private func tellEngine() async {
        _ = try? await app?.engine.command("replica.device", deviceInfo)
    }

    // MARK: - Starting, and what starts a sync

    /// Starts syncing once the app's store is open (and again after the engine restarts).
    func start(_ app: AppModel, storage: String) {
        self.app = app
        if stateFile == nil {
            stateFile = URL.applicationSupportDirectory.appending(path: "session-sync-\(storage).json")
            if let data = try? Data(contentsOf: stateFile!), let state = try? JSONDecoder().decode(Saved.self, from: data) { saved = state }
            records = saved.records
            lastSynced = saved.lastSynced
        }
        let interval = UserDefaults.standard.double(forKey: "syncInterval")
        if ticker == nil {
            // While pi is in front: other devices' changes come within this long.
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval > 0 ? interval : 30))
                    guard let self, UIApplication.shared.applicationState != .background else { continue }
                    self.kick()
                }
            }
        }
        kick()
    }

    @ObservationIgnored private var stateFile: URL?

    private func persist() {
        saved.records = records
        saved.lastSynced = lastSynced
        guard let stateFile, let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: stateFile, options: .atomic)
    }

    /// A session here has something to send (an entry, a new title or model): sent once it isn't running.
    func changed(_ id: Int) {
        guard let session = app?.session(id), session.heldBy == nil else { return }
        if saved.dirty.insert(id).inserted { persist() }
        if !session.running { kick() }
    }

    /// A run started here: the other devices show that it's running.
    func runStarted(_ id: Int) {
        guard active, let syncId = app?.session(id)?.syncId, let known = records[syncId], known.holder == deviceID, !known.running else { return }
        Task {
            await serialized {
                guard let cloud, var record = records[syncId], record.holder == deviceID else { return }
                record.running = true
                record.updatedAt = .now
                if case .saved(let stored) = try? await cloud.save(record) { records[syncId] = stored }
            }
        }
    }

    /// Syncs now, then again if something else asked meanwhile.
    func kick() {
        guard active, app?.phase == .ready else { return }
        if cycleTask != nil {
            again = true
            return
        }
        cycleTask = Task {
            repeat {
                again = false
                await serialized { await cycle() }
            } while again
            cycleTask = nil
        }
    }

    /// One sync at a time: a cycle, a Continue Here, a deletion.
    private func serialized<T>(_ work: () async throws -> T) async rethrows -> T {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await work()
    }

    private func cycle() async {
        guard active, let cloud, let app else { return }
        if let reason = await cloud.unavailableReason() {
            unavailable = reason
            return
        }
        unavailable = nil
        syncing = true
        defer {
            syncing = false
            activity = [:]
            persist()
        }
        do {
            try await pull(cloud)
            // What the engine has that iCloud doesn't, whether or not this device saw it come.
            if let unsent = try await command("replica.unsent", [:])["ids"] as? [Int] { saved.dirty.formUnion(unsent) }
            for id in pending(in: app) { try await push(id, cloud: cloud) }
            failure = nil
            lastSynced = .now
        } catch {
            failure = Self.describe(error)
            log("sync", "failed: \(failure ?? "")")
        }
    }

    /// Sessions this device has with something to send: changed ones, and ones never sent; the latest first.
    private func pending(in app: AppModel) -> [Int] {
        app.sessions
            .filter { $0.heldBy == nil && ($0.syncId == nil || saved.dirty.contains($0.id)) }
            .sorted { $0.lastActive > $1.lastActive }
            .map(\.id)
    }

    // MARK: - Sending

    /// Sends what's new of a session this device has: its entries a chunk at a time, its settings, its files.
    private func push(_ id: Int, cloud: SessionCloud) async throws {
        guard let app, let session = app.session(id), session.heldBy == nil else {
            saved.dirty.remove(id)
            return
        }
        // After its run: its files may be changing until then.
        guard !session.running else { return }
        var record = session.syncId.flatMap { records[$0] }
        if let record, record.holder != deviceID { return }
        activity[id] = .uploading
        var more = true
        while more {
            let export = try await command("replica.export", ["id": id])
            guard let syncId = export["syncId"] as? String, let base = export["base"] as? Int else { throw SyncError.message("The session couldn't be read") }
            let entries = export["entries"] as? [Any] ?? []
            let ids = export["ids"] as? [Int] ?? []
            more = export["more"] as? Bool ?? false
            if record == nil { record = try await cloud.record(syncId) }
            // Another device has it now: the next pull keeps what this device added in a session of its own.
            if let record, record.holder != deviceID || record.deleted { return }
            var next = record ?? SessionRecord(syncId: syncId, title: "", createdAt: 0, holder: deviceID, holderName: deviceName, count: 0,
                                               chunks: [], running: false, deleted: false, updatedAt: .now)
            var chunk: String?
            if !entries.isEmpty {
                let name = SessionRecord.chunkName(from: base, device: deviceID)
                try await cloud.putChunk(try Self.pack(["base": base, "entries": entries]), named: name, session: syncId)
                chunk = name
                // A chunk sent before that iCloud's record never counted (the app stopped in between) is sent again in this one.
                next.chunks.removeAll { SessionRecord.chunkStart($0) >= base }
                next.chunks.append(name)
                next.count = base + entries.count
            }
            let meta = export["meta"] as? [String: Any] ?? [:]
            next.title = meta["title"] as? String ?? next.title
            next.createdAt = meta["createdAt"] as? Double ?? next.createdAt
            next.lastActiveAt = meta["lastActiveAt"] as? Double
            next.model = (meta["model"] as? [String: Any]).map { SessionRecord.Model(provider: $0["provider"] as? String ?? "", modelId: $0["modelId"] as? String ?? "") }
            next.thinkingLevel = meta["thinkingLevel"] as? String
            if let docs = export["docs"], !(docs is NSNull) {
                let data = try JSONSerialization.data(withJSONObject: docs, options: .sortedKeys)
                next.docs = try await putBlob(data, cloud: cloud)
            }
            if !more { next.manifest = try await sendFiles(of: id, cloud: cloud) }
            next.holder = deviceID
            next.holderName = deviceName
            next.running = false
            next.updatedAt = .now
            switch try await cloud.save(next) {
            case .saved(let stored):
                records[syncId] = stored
                record = stored
                // What iCloud has is what this device has: if another device takes the session, only what it adds comes.
                saved.applied[syncId] = Saved.Applied(count: stored.count, manifest: stored.manifest, docs: stored.docs, tag: stored.tag)
            case .conflict(let theirs):
                records[syncId] = theirs
                if let chunk { try? await cloud.deleteChunks(named: [chunk], session: syncId) }
                if theirs.holder != deviceID || theirs.deleted { return }
                throw SyncError.message("iCloud's copy changed while sending")
            }
            if !ids.isEmpty { _ = try await command("replica.uploaded", ["id": id, "ids": ids]) }
        }
        saved.dirty.remove(id)
        log("sync", "[\(id)] sent: \(record?.count ?? 0) entries in iCloud")
    }

    /// Sends the workspace's files that iCloud doesn't have, and their manifest; the manifest's blob (nil with no files).
    private func sendFiles(of id: Int, cloud: SessionCloud) async throws -> String? {
        guard let app else { return nil }
        let workspace = app.workspace(of: id)
        var known = loadKnown(id)
        let (manifest, skipped) = WorkspaceFiles.scan(workspace, known: &known)
        saveKnown(known, for: id)
        if !skipped.isEmpty { log("sync", "[\(id)] too large to send: \(skipped.joined(separator: ", "))") }
        guard !manifest.files.isEmpty else { return nil }
        let byHash = Dictionary(manifest.files.map { ($0.value.hash, $0.key) }, uniquingKeysWith: { first, _ in first })
        for hash in try await cloud.missingBlobs(Array(byHash.keys)) {
            guard let path = byHash[hash] else { continue }
            try await cloud.putBlob(hash, file: workspace.appending(path: path))
        }
        return try await putBlob(try JSONEncoder.sorted.encode(manifest), cloud: cloud)
    }

    /// Data as a blob, sent unless iCloud has it; its hash.
    private func putBlob(_ data: Data, cloud: SessionCloud) async throws -> String {
        let hash = WorkspaceFiles.sha256(data)
        if try await !cloud.missingBlobs([hash]).isEmpty {
            let file = FileManager.default.temporaryDirectory.appending(path: "blob-\(hash)")
            try data.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            try await cloud.putBlob(hash, file: file)
        }
        return hash
    }

    // MARK: - Receiving

    private func pull(_ cloud: SessionCloud) async throws {
        let (changed, token) = try await cloud.changes(since: saved.token)
        for record in changed { records[record.syncId] = record }
        saved.token = token
        // Every session other devices have, whether it changed now or an earlier download didn't finish; the latest first.
        for record in records.values.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            try await reconcile(record, cloud: cloud)
        }
    }

    private func reconcile(_ record: SessionRecord, cloud: SessionCloud) async throws {
        guard let app else { return }
        let local = app.sessions.first { $0.syncId == record.syncId }
        if record.deleted {
            if let local {
                log("sync", "[\(local.id)] deleted on another device")
                await app.delete(local.id, everywhere: false)
            }
            saved.applied[record.syncId] = nil
            return
        }
        // This device has it (as iCloud says): it sends, it doesn't receive.
        if record.holder == deviceID {
            if let local, local.heldBy != nil { _ = try await command("replica.setHolder", ["id": local.id, "heldBy": NSNull()]) }
            return
        }
        if let local, local.heldBy == record.holderName, saved.applied[record.syncId]?.tag == record.tag { return }
        if let local, local.heldBy == nil {
            // It was this device's, and another device took it: a run here stops. Whatever this device added that iCloud
            // doesn't have stays in a session of its own (the engine finds it as it applies).
            log("sync", "[\(local.id)] continued on \(record.holderName)")
            _ = try await command("replica.setHolder", ["id": local.id, "heldBy": record.holderName])
        }
        try await download(record, cloud: cloud)
    }

    /// Brings this device's copy of another device's session up to iCloud's: entries, settings, files.
    private func download(_ record: SessionRecord, cloud: SessionCloud) async throws {
        guard let app else { return }
        let syncId = record.syncId
        var applied = saved.applied[syncId] ?? Saved.Applied(count: 0)
        var localId = app.sessions.first { $0.syncId == syncId }?.id
        if let localId { activity[localId] = .downloading }
        var docs: Any = NSNull()
        if let hash = record.docs, hash != applied.docs {
            docs = (try? JSONSerialization.jsonObject(with: try await cloud.blob(hash))) ?? NSNull()
        }
        let meta: [String: Any] = [
            "title": record.title, "createdAt": record.createdAt, "lastActiveAt": record.lastActiveAt ?? NSNull(),
            "model": record.model.map { ["provider": $0.provider, "modelId": $0.modelId] } ?? NSNull(),
            "thinkingLevel": record.thinkingLevel ?? NSNull(),
        ]
        let starts = record.chunks.map(SessionRecord.chunkStart)
        var count = applied.count
        // Bounded: each round applies a chunk, finds where this device is, or splits once.
        for _ in 0..<(record.chunks.count * 2 + 4) {
            var base = count, entries: [Any] = []
            if count < record.count {
                guard let index = starts.lastIndex(where: { $0 <= count }),
                      let data = try await cloud.chunk(named: record.chunks[index], session: syncId)
                else { throw SyncError.message("Part of \(record.title) isn't in iCloud yet") }
                let payload = try Self.unpack(data)
                base = payload["base"] as? Int ?? starts[index]
                // The chunk's own entries: a chunk sent again can run past where the next one starts.
                let end = index + 1 < starts.count ? starts[index + 1] : record.count
                entries = Array((payload["entries"] as? [Any] ?? []).prefix(max(0, end - base)))
            }
            var parameters: [String: Any] = ["syncId": syncId, "base": base, "entries": entries, "meta": meta, "docs": docs, "heldBy": record.holderName]
            if let model = app.defaultModel { parameters["model"] = ["provider": model.provider, "modelId": model.modelId] }
            let result = try await command("replica.apply", parameters)
            localId = result["id"] as? Int ?? localId
            if result["diverged"] as? Bool == true, let id = localId {
                // What this device added while the other had it: a session of its own, sent from here.
                let split = try await command("replica.split", ["id": id, "label": deviceName])
                if let kept = split["kept"] as? Int { saved.dirty.insert(kept) }
                log("sync", "[\(id)] kept what this device added in a session of its own; \(record.title) continues as \(split["id"] ?? "new")")
                localId = split["id"] as? Int
                count = localId == nil ? 0 : count
                continue
            }
            if let missing = result["missing"] as? Int {
                count = missing
                continue
            }
            docs = NSNull()
            count = result["count"] as? Int ?? count
            applied.count = count
            applied.docs = record.docs
            if count >= record.count { break }
        }
        guard count >= record.count, let localId else { throw SyncError.message("\(record.title) couldn't be brought up to date") }
        if record.manifest != applied.manifest {
            var manifest = FileManifest()
            if let hash = record.manifest { manifest = try JSONDecoder().decode(FileManifest.self, from: try await cloud.blob(hash)) }
            var known = loadKnown(localId)
            defer { saveKnown(known, for: localId) }
            try await WorkspaceFiles.apply(manifest, to: app.workspace(of: localId), known: &known) { try await cloud.blob($0) }
            applied.manifest = record.manifest
        }
        applied.tag = record.tag
        saved.applied[syncId] = applied
        log("sync", "[\(localId)] up to date with \(record.holderName): \(count) entries")
    }

    // MARK: - Continue Here, and deleting

    /// The user continues here a session another device has: brought up to date, made this device's in iCloud, and the
    /// agent told it moved. If the other device is mid-run, its newest steps stay there, in a session of their own.
    func continueHere(_ id: Int) async throws {
        guard active, let cloud, let app else { throw SyncError.message("Turn on Sync Sessions in Settings to continue it here") }
        try await serialized {
            guard let syncId = app.session(id)?.syncId else { throw SyncError.message("This session doesn't sync") }
            var from = app.session(id)?.heldBy ?? "another device"
            for attempt in 1...3 {
                guard var record = try await cloud.record(syncId) else { throw SyncError.message("This session isn't in iCloud") }
                records[syncId] = record
                if record.deleted { throw SyncError.message("This session was deleted on another device") }
                if record.holder == deviceID { break }
                from = record.holderName
                try await download(record, cloud: cloud)
                record.holder = deviceID
                record.holderName = deviceName
                record.running = false
                record.updatedAt = .now
                switch try await cloud.save(record) {
                case .saved(let stored):
                    records[syncId] = stored
                    saved.applied[syncId]?.tag = stored.tag
                case .conflict(let theirs):
                    // It changed just now (the other device sent its run): up to date with that, then again.
                    records[syncId] = theirs
                    if attempt == 3 { throw SyncError.message("\(theirs.holderName) keeps changing it: try again in a moment") }
                    continue
                }
                break
            }
            guard let localId = app.sessions.first(where: { $0.syncId == syncId })?.id else { throw SyncError.message("The session is gone") }
            _ = try await command("replica.claim", ["id": localId, "from": from, "to": deviceName])
            saved.dirty.insert(localId)
            persist()
            log("sync", "[\(localId)] continued here (from \(from))")
        }
        kick()
    }

    /// A session deleted here: deleted on every device.
    func deleted(syncId: String?) {
        guard active, let syncId, let cloud else { return }
        Task {
            await serialized {
                for _ in 1...3 {
                    guard var record = (try? await cloud.record(syncId)) ?? nil, !record.deleted else { break }
                    record.deleted = true
                    record.running = false
                    record.updatedAt = .now
                    guard let result = try? await cloud.save(record) else { break }
                    if case .saved(let stored) = result {
                        records[syncId] = stored
                        try? await cloud.deleteChunks(named: record.chunks, session: syncId)
                        break
                    }
                }
                saved.applied[syncId] = nil
                persist()
            }
        }
    }

    // MARK: - What the screens show

    /// Where a session stands.
    func status(of session: AppModel.Session) -> Status? {
        guard active else { return nil }
        if let now = activity[session.id] { return now }
        if let holder = session.heldBy {
            let record = session.syncId.flatMap { records[$0] }
            let behind = record.map { saved.applied[$0.syncId]?.tag != $0.tag } ?? true
            return .elsewhere(holder, running: record?.running ?? false, behind: behind)
        }
        if session.running { return .waiting("Syncs when its run ends") }
        if session.syncId == nil || saved.dirty.contains(session.id) { return .waiting(failure ?? unavailable ?? "Waiting to sync") }
        return .synced
    }

    var summary: Summary {
        guard enabled else { return .off("Off") }
        if let unavailable { return .off(unavailable) }
        // Only while something goes or comes: a check that finds nothing new leaves "All synced" as it is.
        if syncing, !activity.isEmpty { return .syncing }
        let sessions = app?.sessions ?? []
        let waiting = sessions.filter { $0.heldBy == nil && ($0.syncId == nil || saved.dirty.contains($0.id)) && !$0.running }.count
        let behind = records.values.filter { !$0.deleted && $0.holder != deviceID && saved.applied[$0.syncId]?.tag != $0.tag }.count
        if let failure, waiting + behind > 0 { return .waiting(failure) }
        if waiting > 0 { return .waiting("\(waiting) \(waiting == 1 ? "session" : "sessions") to send") }
        if behind > 0 { return .waiting("\(behind) \(behind == 1 ? "session" : "sessions") to bring up to date") }
        return .synced(lastSynced)
    }

    // MARK: - Helpers

    private func command(_ method: String, _ parameters: [String: Any]) async throws -> [String: Any] {
        guard let app else { throw SyncError.message("pi isn't ready") }
        return try await app.engine.command(method, parameters) as? [String: Any] ?? [:]
    }

    private static func pack(_ value: [String: Any]) throws -> Data {
        try (JSONSerialization.data(withJSONObject: value) as NSData).compressed(using: .zlib) as Data
    }

    private static func unpack(_ data: Data) throws -> [String: Any] {
        let json = try (data as NSData).decompressed(using: .zlib) as Data
        return try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
    }

    private func knownFile(_ id: Int) -> URL { URL.applicationSupportDirectory.appending(path: "session-sync-files/\(id).json") }

    /// The workspace's files as last hashed (`WorkspaceFiles.Known`).
    private func loadKnown(_ id: Int) -> [String: WorkspaceFiles.Known] {
        (try? Data(contentsOf: knownFile(id))).flatMap { try? JSONDecoder().decode([String: WorkspaceFiles.Known].self, from: $0) } ?? [:]
    }

    private func saveKnown(_ known: [String: WorkspaceFiles.Known], for id: Int) {
        let file = knownFile(id)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(known).write(to: file, options: .atomic)
    }

    private static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.isEmpty ? "Sync failed" : text
    }
}

private extension JSONEncoder {
    /// Keys in order, so the same manifest is the same blob.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
