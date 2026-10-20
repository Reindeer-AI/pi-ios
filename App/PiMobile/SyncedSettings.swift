import Foundation
import Security

/// Settings that follow the user to their other devices, through iCloud Keychain (end-to-end encrypted): chosen
/// `UserDefaults` keys in one synchronizable item. A single value (the network server, the default model, an account)
/// takes the newest change; a list (MCP servers, extension secrets, the vault's items, the extensions) merges item by
/// item, so an addition on one device is never lost and a deletion wins only over older changes. Pulled at launch,
/// before the app reads them; pushed as they change here.
///
/// A device that never synced and differs from what's in iCloud asks first (`conflicts`): iCloud's, or this device's.
@MainActor
@Observable
final class SyncedSettings {
    static let shared = SyncedSettings(
        defaults: .standard,
        store: UserDefaults.standard.string(forKey: "syncSettingsFolder").map { FolderSyncStore(folder: URL(fileURLWithPath: $0)) } ?? KeychainSyncStore()
    )

    init(defaults: UserDefaults, store: SyncStore) {
        self.defaults = defaults
        self.store = store
    }

    enum Kind {
        /// The newest change wins.
        case value
        /// A dictionary, merged per key.
        case dictionary
        /// A JSON array of objects (Data), merged per object by its `id` field.
        case jsonArray(id: String)
        /// An array of dictionaries, merged per element by its `id` field.
        case array(id: String)
    }

    static let syncedExtensionsKey = "syncedExtensions"
    static let keys: [String: Kind] = [
        "networkEndpoint": .value, "networkName": .value, "defaultModel": .value, "defaultThinkingLevel": .value,
        "githubIdentity": .value, "githubTokenExpiry": .value,
        "crabboxBroker": .value, "crabboxIdentity": .value, "crabboxProvider": .value,
        "extensionSecrets": .dictionary, "vaultItems": .dictionary, "extensionData": .dictionary,
        "mcpServers": .jsonArray(id: "name"),
        syncedExtensionsKey: .array(id: "source"),
    ]

    /// A setting this device and iCloud both have, differently, when this device first syncs.
    struct Conflict: Identifiable {
        let key: String
        let title: String
        let here: String
        let iCloud: String
        /// A list's items both have, differently (none for a single value).
        var items: [String] = []
        var id: String { key }
    }

    /// Asked of the user before this device first syncs (`resolve`); empty otherwise.
    private(set) var conflicts: [Conflict] = []
    /// Settings that came from another device while pi runs: the app applies them (`AppModel.applySyncedSettings`).
    @ObservationIgnored var onPulled: (([String]) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: SyncStore
    private var joined: Bool {
        get { defaults.bool(forKey: "syncJoined") }
        set { defaults.set(newValue, forKey: "syncJoined") }
    }
    /// When each value, and each item of a list, was last pulled or pushed here; the values then (to tell a change here).
    private var syncedAt: [String: Date] {
        get { defaults.dictionary(forKey: "syncAt") as? [String: Date] ?? [:] }
        set { defaults.set(newValue, forKey: "syncAt") }
    }
    private var itemsAt: [String: [String: Date]] {
        get { defaults.dictionary(forKey: "syncItemsAt") as? [String: [String: Date]] ?? [:] }
        set { defaults.set(newValue, forKey: "syncItemsAt") }
    }
    private var syncedValues: [String: Data] {
        get { defaults.dictionary(forKey: "syncValues") as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: "syncValues") }
    }
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// Applies what other devices changed since this one last looked, then sends what changed here; a device that never
    /// synced and differs waits for the user (`conflicts`).
    func start() {
        let remote = remote()
        if !joined, !remote.isEmpty {
            conflicts = findConflicts(remote)
            if !conflicts.isEmpty {
                log("sync", "this device differs from iCloud: \(conflicts.map(\.key).sorted().joined(separator: ", ")); asking")
                return
            }
        }
        joined = true
        pull(remote)
        push()
        observe()
    }

    /// Takes the extensions other devices changed since pi started (it came to the front), for the app to install and
    /// remove (`AppModel.syncExtensions`); whether there were any. Only those: other settings apply when pi starts,
    /// before the app reads them.
    func refreshExtensions() -> Bool {
        guard joined, conflicts.isEmpty else { return false }
        return !pull(remote(), only: [Self.syncedExtensionsKey]).isEmpty
    }

    /// The user's choice for a device's first sync: iCloud's settings, or this device's (sent as the newest).
    func resolve(useICloud: Bool) {
        // This device's: its single values, and its version of the list items both have, win; the rest merges.
        var prefer: [String: Set<String>?] = [:]
        if !useICloud { for conflict in conflicts { prefer[conflict.key] = conflict.items.isEmpty ? nil : Set(conflict.items) } }
        let keys = Set(Self.keys.keys)
        conflicts = []
        joined = true
        pull(remote(), prefer: prefer)
        push(prefer: prefer)
        observe()
        onPulled?(Array(keys))
    }

    /// Sends every setting of this device as the newest: the other devices take them (and lose list items this one lacks).
    func sendThisDevice() {
        push(replace: Set(Self.keys.keys))
        log("sync", "this device's settings sent to your other devices")
    }

    private func observe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePush() }
        }
    }

    private func schedulePush() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            push()
        }
    }

    // MARK: - Pull and push

    /// `prefer`: settings this device keeps (a single value: nil; a list: the items it keeps), sent by `push(prefer:)`;
    /// `only`: just these settings. The settings that changed.
    @discardableResult
    private func pull(_ remote: [String: [String: Any]], prefer: [String: Set<String>?] = [:], only: Set<String>? = nil) -> [String] {
        var at = syncedAt, items = itemsAt, values = syncedValues
        var applied: [String] = []
        for (key, kind) in Self.keys where only?.contains(key) ?? true {
            guard let entry = remote[key] else { continue }
            if let kept = prefer[key], kept == nil { continue }
            let keptItems = prefer[key].flatMap { $0 } ?? []
            switch kind {
            case .value:
                guard let changed = entry["at"] as? Date, changed > at[key] ?? .distantPast else { continue }
                if entry["deleted"] as? Bool == true { defaults.removeObject(forKey: key) } else if let value = entry["value"] { defaults.set(value, forKey: key) }
                at[key] = changed
                values[key] = defaults.object(forKey: key).flatMap(Self.encode)
            default:
                // The other devices' changes go into the list here and into what it was when last synced; a change made
                // here since stays to send.
                var local = elements(kind, defaults.object(forKey: key))
                var synced = elements(kind, values[key].flatMap(Self.decode))
                var known = items[key] ?? [:]
                var changed = false
                for (id, item) in entry["items"] as? [String: [String: Any]] ?? [:] where !keptItems.contains(id) {
                    guard let when = item["at"] as? Date, when > known[id] ?? .distantPast else { continue }
                    if item["deleted"] as? Bool == true {
                        local.removeValue(forKey: id)
                        synced.removeValue(forKey: id)
                    } else if let value = item["value"] {
                        local[id] = value
                        synced[id] = value
                    }
                    known[id] = when
                    changed = true
                }
                items[key] = known
                guard changed else { continue }
                let order = defaults.object(forKey: key)
                if let value = storage(kind, local, order: order) { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                values[key] = storage(kind, synced, order: order).flatMap(Self.encode)
            }
            applied.append(key)
        }
        syncedAt = at
        itemsAt = items
        syncedValues = values
        if !applied.isEmpty { log("sync", "from your other devices: \(applied.sorted().joined(separator: ", "))") }
        return applied
    }

    /// Sends what changed here since the last sync. `prefer` sends those settings (single values, list items) as the
    /// newest whatever changed; `replace` sends those settings whole, list items this device lacks deleted.
    private func push(prefer: [String: Set<String>?] = [:], replace: Set<String> = []) {
        guard joined else { return }
        var at = syncedAt, items = itemsAt, values = syncedValues
        var merged = remote()
        var sent: [String] = []
        let now = Date()
        for (key, kind) in Self.keys {
            let value = defaults.object(forKey: key)
            let encoded = value.flatMap(Self.encode)
            let replacing = replace.contains(key)
            let forced = replacing || prefer.keys.contains(key)
            let preferredItems = prefer[key].flatMap { $0 } ?? []
            guard forced || !Self.same(encoded, values[key]) else { continue }
            switch kind {
            case .value:
                merged[key] = encoded == nil ? ["deleted": true, "at": now] : ["value": value!, "at": now]
                at[key] = now
            default:
                let current = elements(kind, value)
                let before = replacing ? elements(kind, merged[key].map { Self.values(of: $0) }) : elements(kind, values[key].flatMap(Self.decode))
                var remoteItems = merged[key]?["items"] as? [String: [String: Any]] ?? [:]
                var known = items[key] ?? [:]
                var changed = 0
                for (id, element) in current where replacing || preferredItems.contains(id) || !Self.same(Self.encode(element), before[id].flatMap(Self.encode)) {
                    remoteItems[id] = ["value": element, "at": now]
                    known[id] = now
                    changed += 1
                }
                for id in before.keys where current[id] == nil {
                    remoteItems[id] = ["deleted": true, "at": now]
                    known[id] = now
                    changed += 1
                }
                // Only the order changed: nothing to send.
                guard changed > 0 || forced else {
                    values[key] = encoded
                    continue
                }
                merged[key] = ["items": remoteItems]
                items[key] = known
            }
            values[key] = encoded
            sent.append(key)
        }
        guard !sent.isEmpty else { return }
        do {
            try write(merged)
            syncedAt = at
            itemsAt = items
            syncedValues = values
            log("sync", "sent: \(sent.sorted().joined(separator: ", "))")
        } catch {
            log("sync", "couldn't save: \(error.localizedDescription)")
        }
    }

    // MARK: - Conflicts (a device's first sync)

    private func findConflicts(_ remote: [String: [String: Any]]) -> [Conflict] {
        Self.keys.compactMap { key, kind -> Conflict? in
            guard let local = defaults.object(forKey: key), let entry = remote[key] else { return nil }
            switch kind {
            case .value:
                guard entry["deleted"] as? Bool != true, let value = entry["value"], !Self.same(Self.encode(local), Self.encode(value)) else { return nil }
                return Conflict(key: key, title: Self.title(key), here: Self.describe(key, local), iCloud: Self.describe(key, value))
            default:
                let here = elements(kind, local)
                let there = elements(kind, Self.values(of: entry))
                let differing = here.keys.filter { id in there[id].map { !Self.same(Self.encode($0), Self.encode(here[id]!)) } ?? false }.sorted()
                guard !differing.isEmpty else { return nil }
                return Conflict(key: key, title: Self.title(key), here: differing.map { Self.name(key, here[$0]!, id: $0) }.joined(separator: ", "),
                                iCloud: differing.map { Self.name(key, there[$0]!, id: $0) }.joined(separator: ", "), items: differing)
            }
        }
        .filter { $0.key != Self.syncedExtensionsKey }
        .sorted { $0.title < $1.title }
    }

    private static func title(_ key: String) -> String {
        switch key {
        case "networkEndpoint", "networkName": "Network server"
        case "defaultModel": "Default model"
        case "defaultThinkingLevel": "Default thinking level"
        case "githubIdentity", "githubTokenExpiry": "GitHub account"
        case "crabboxBroker", "crabboxIdentity", "crabboxProvider": "Crabbox"
        case "extensionSecrets": "Extension secrets"
        case "vaultItems": "Vault items"
        case "mcpServers": "MCP servers"
        case "extensionData": "Extension data"
        default: key
        }
    }

    private static func describe(_ key: String, _ value: Any) -> String {
        if let data = value as? Data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if key == "defaultModel" { return "\(object["provider"] ?? "?") · \(object["modelId"] ?? "?")" }
            if let login = object["login"] as? String { return login }
            return object.keys.sorted().joined(separator: ", ")
        }
        if let date = value as? Date { return date.formatted(date: .abbreviated, time: .shortened) }
        return "\(value)"
    }

    private static func name(_ key: String, _ element: Any, id: String) -> String {
        if let info = element as? [String: Any], let label = info["label"] as? String { return label }
        return id
    }

    // MARK: - Lists as items

    /// A list's items by id, from how it's kept (`UserDefaults`), or from iCloud's items.
    private func elements(_ kind: Kind, _ value: Any?) -> [String: Any] {
        switch kind {
        case .value: return [:]
        case .dictionary: return value as? [String: Any] ?? [:]
        case .jsonArray(let field):
            if let items = value as? [String: Any] { return items }
            guard let data = value as? Data, let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
            var items: [String: Any] = [:]
            for object in array {
                if let id = object[field] as? String, let element = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) { items[id] = element }
            }
            return items
        case .array(let field):
            if let items = value as? [String: Any] { return items }
            var items: [String: Any] = [:]
            for element in value as? [[String: Any]] ?? [] { if let id = element[field] as? String { items[id] = element } }
            return items
        }
    }

    /// Items back as the list is kept, in the order it had here (new items after).
    private func storage(_ kind: Kind, _ items: [String: Any], order previous: Any?) -> Any? {
        guard !items.isEmpty else { return nil }
        let before = Array(elements(kind, previous).keys)
        let ids = before.filter { items[$0] != nil } + items.keys.filter { !before.contains($0) }.sorted()
        switch kind {
        case .value: return nil
        case .dictionary: return items
        case .jsonArray:
            let objects = ids.compactMap { (items[$0] as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
            return try? JSONSerialization.data(withJSONObject: objects)
        case .array: return ids.compactMap { items[$0] }
        }
    }

    /// iCloud's items of a list entry, as items by id (deleted ones left out).
    private static func values(of entry: [String: Any]) -> [String: Any] {
        var values: [String: Any] = [:]
        for (id, item) in entry["items"] as? [String: [String: Any]] ?? [:] where item["deleted"] as? Bool != true {
            if let value = item["value"] { values[id] = value }
        }
        return values
    }

    // MARK: - Storage

    private func remote() -> [String: [String: Any]] {
        store.read().flatMap(Self.decode) as? [String: [String: Any]] ?? [:]
    }

    private func write(_ entries: [String: [String: Any]]) throws {
        try store.write(try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0))
    }

    private static func encode(_ value: Any) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private static func decode(_ data: Data) -> Any? {
        try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    /// Whether two encoded values are the same value (a dictionary's keys may encode in either order).
    private static func same(_ a: Data?, _ b: Data?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if a == b { return true }
        guard let x = decode(a) as? NSObject, let y = decode(b) as? NSObject else { return false }
        return x.isEqual(y)
    }
}

/// Where the synced settings are kept for every device.
protocol SyncStore {
    func read() -> Data?
    func write(_ data: Data) throws
}

/// One synchronizable item in iCloud Keychain.
struct KeychainSyncStore: SyncStore {
    private static var item: [String: Any] {[
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.pimobile.sync",
        kSecAttrAccount as String: "settings.v2", kSecAttrSynchronizable as String: true,
    ]}

    func read() -> Data? {
        var query = Self.item
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        var status = SecItemUpdate(Self.item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(Self.item.merging(attributes) { $1 } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// A file in a folder that test devices share (`-syncSettingsFolder`), in place of iCloud Keychain.
struct FolderSyncStore: SyncStore {
    let folder: URL

    private var file: URL { folder.appending(path: "settings") }

    func read() -> Data? { try? Data(contentsOf: file) }

    func write(_ data: Data) throws { try data.write(to: file, options: .atomic) }
}
