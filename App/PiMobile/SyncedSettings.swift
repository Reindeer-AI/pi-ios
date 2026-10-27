import Foundation
import Security

/// Settings that follow the user to their other devices, through iCloud Keychain (end-to-end encrypted): chosen
/// `UserDefaults` keys in one synchronizable item. A single value (the network server, the default model, an account)
/// takes the newest change; a list (MCP servers, extension secrets, the vault's items, the extensions) merges item by
/// item, so an addition on one device is never lost and a deletion wins only over older changes. Pulled at launch,
/// before the app reads them; pushed as they change here.
///
/// A device that never synced and differs from what's in iCloud asks first (`conflicts`): iCloud's, or this device's.
/// So does one whose MCP server, extension secret or vault item another device changed differently without having seen
/// this one's version of it (`askedKeys`), and one whose network server, Crabbox broker or MCP server set here another
/// device changed (`perDevice`: a Mac and a phone can reach a server at different addresses). Each keeps its own until
/// the user chooses: the other device's, or this one's, which then stays this device's own (`own`).
///
/// Every device writes the whole item, so iCloud Keychain can lose one device's write to another's made before it
/// arrived; a device that finds iCloud with an older version of what it sent sends it again.
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
        "crabboxBroker": .value, "crabboxIdentity": .value, "crabboxProvider": .value,
        "extensionSecrets": .dictionary, "vaultItems": .dictionary, "extensionData": .dictionary,
        "mcpServers": .jsonArray(id: "name"),
        syncedExtensionsKey: .array(id: "source"),
    ]
    /// Lists whose items the user edits: an item changed differently on two devices, neither having seen the other's
    /// change, is asked about (`conflicts`), never overwritten. In the others (extensions, extensions' data) the newest
    /// change wins.
    static let askedKeys: Set<String> = ["mcpServers", "extensionSecrets", "vaultItems"]
    /// Settings a device may keep different from the others (a Mac and a phone can reach a server at different
    /// addresses): another device's change to one set on this device is asked about, never applied over it.
    static let perDevice: Set<String> = ["networkEndpoint", "networkName", "crabboxBroker", "mcpServers"]

    /// A setting this device and iCloud both have, differently, when this device first syncs; or list items changed
    /// differently here and on another device.
    struct Conflict: Identifiable {
        let key: String
        let title: String
        let here: String
        let iCloud: String
        /// A list's items both have, differently (none for a single value).
        var items: [String] = []
        var id: String { key }
    }

    /// Asked of the user (`resolve`): before this device first syncs, or once list items diverged; empty otherwise.
    private(set) var conflicts: [Conflict] = []
    /// Whether `conflicts` are this device's first sync (nothing syncs until the user chooses), not items that diverged.
    var firstSync: Bool { !joined }
    /// Settings that came from another device while pi runs: the app applies them (`AppModel.applySyncedSettings`).
    @ObservationIgnored var onPulled: (([String]) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: SyncStore
    private var joined: Bool {
        get { defaults.bool(forKey: "syncJoined") }
        set { defaults.set(newValue, forKey: "syncJoined") }
    }
    /// When each value, and each item of a list, was last pulled or pushed here; the values then (to tell a change here).
    // Each written only when it changed: a write is a change of the defaults, which pushes again (`observe`).
    private var syncedAt: [String: Date] {
        get { defaults.dictionary(forKey: "syncAt") as? [String: Date] ?? [:] }
        set { if newValue != syncedAt { defaults.set(newValue, forKey: "syncAt") } }
    }
    private var itemsAt: [String: [String: Date]] {
        get { defaults.dictionary(forKey: "syncItemsAt") as? [String: [String: Date]] ?? [:] }
        set { if newValue != itemsAt { defaults.set(newValue, forKey: "syncItemsAt") } }
    }
    private var syncedValues: [String: Data] {
        get { defaults.dictionary(forKey: "syncValues") as? [String: Data] ?? [:] }
        set { if newValue != syncedValues { defaults.set(newValue, forKey: "syncValues") } }
    }
    /// For each list item here, the change of it its last change came from: the newest this device had seen then (sent
    /// along, so another device tells a change made without seeing its own).
    private var itemsBase: [String: [String: Date]] {
        get { defaults.dictionary(forKey: "syncItemsBase") as? [String: [String: Date]] ?? [:] }
        set { if newValue != itemsBase { defaults.set(newValue, forKey: "syncItemsBase") } }
    }
    /// List items this device and another changed differently, each without the other's change: kept here as they are,
    /// and asked about (`conflicts`). Single values the same way.
    @ObservationIgnored private var diverged: [String: Set<String>] = [:]
    @ObservationIgnored private var divergedValues: Set<String> = []
    /// The `perDevice` settings (a single value: its key; a list item: "key/id") whose value here was set on this
    /// device, not taken from another.
    private var setHere: Set<String> {
        get { Set(defaults.stringArray(forKey: "syncSetHere") ?? []) }
        set { if newValue != setHere { defaults.set(newValue.sorted(), forKey: "syncSetHere") } }
    }
    /// Settings the user chose to keep as this device's own, as `setHere` names them: neither taken from the other
    /// devices nor sent to them.
    private var own: Set<String> {
        get { Set(defaults.stringArray(forKey: "syncOwn") ?? []) }
        set {
            if newValue != own { defaults.set(newValue.sorted(), forKey: "syncOwn") }
            ownSettings = Self.titles(newValue)
        }
    }
    /// What this device keeps as its own, for Settings ("Crabbox", "MCP server github").
    private(set) var ownSettings: [String] = []

    private static func titles(_ names: Set<String>) -> [String] {
        names.sorted().map { name in
            let (key, id) = split(name)
            return id.map { key == "mcpServers" ? "MCP server \($0)" : "\(title(key)): \($0)" } ?? title(key)
        }
    }
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// Applies what other devices changed since this one last looked, then sends what changed here; a device that never
    /// synced and differs waits for the user (`conflicts`).
    func start() {
        // A device that synced before settings were told apart by where they were set: what it has counts as set here,
        // so another device's change to it is asked about once.
        if defaults.object(forKey: "syncSetHere") == nil { defaults.set((joined ? perDeviceHere() : []).sorted(), forKey: "syncSetHere") }
        ownSettings = Self.titles(own)
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

    /// The user's choice. For a device's first sync: iCloud's settings, or this device's (sent as the newest). For
    /// settings another device changed: the other device's (taken, and followed again), or this device's (kept as its
    /// own from then on).
    func resolve(useICloud: Bool) {
        // First sync, this device's: its single values, and its version of the list items both have, win; the rest
        // merges.
        var prefer: [String: Set<String>?] = [:]
        // Taken from iCloud whatever this device has: list items, or a single value (no items).
        var take: [String: Set<String>] = [:]
        let first = !joined
        var kept: Set<String> = []
        for conflict in conflicts {
            if useICloud {
                take[conflict.key] = Set(conflict.items)
            } else if first {
                prefer[conflict.key] = conflict.items.isEmpty ? nil : Set(conflict.items)
            } else {
                kept.formUnion(conflict.items.isEmpty ? [conflict.key] : conflict.items.map { "\(conflict.key)/\($0)" })
            }
        }
        if !kept.isEmpty { log("sync", "kept as this device's own: \(kept.sorted().joined(separator: ", "))") }
        own.formUnion(kept)
        let keys = Set(Self.keys.keys)
        conflicts = []
        diverged = [:]
        divergedValues = []
        joined = true
        pull(remote(), prefer: prefer, take: take)
        push(prefer: prefer)
        observe()
        onPulled?(Array(keys))
    }

    /// Sends every setting of this device as the newest: the other devices take them without asking (and lose list items
    /// this one lacks), except what one keeps as its own. This device's own settings sync again.
    func sendThisDevice() {
        own = []
        push(replace: Set(Self.keys.keys))
        log("sync", "this device's settings sent to your other devices")
    }

    /// The settings this device kept as its own sync again: the other devices' versions apply here where one changed
    /// them since, and this device's go to them otherwise.
    func syncAgain() {
        var take: [String: Set<String>] = [:]
        for name in own {
            let (key, id) = Self.split(name)
            take[key, default: []].formUnion(id.map { [$0] } ?? [])
        }
        log("sync", "syncing again: \(own.sorted().joined(separator: ", "))")
        own = []
        pull(remote(), take: take)
        push()
        onPulled?(Array(take.keys))
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
    /// `take`: list items it takes from iCloud whatever it has; `only`: just these settings. The settings that changed.
    @discardableResult
    private func pull(_ remote: [String: [String: Any]], prefer: [String: Set<String>?] = [:], take: [String: Set<String>] = [:], only: Set<String>? = nil) -> [String] {
        var at = syncedAt, items = itemsAt, bases = itemsBase, values = syncedValues
        var here = setHere
        let own = own
        var applied: [String] = []
        for (key, kind) in Self.keys where only?.contains(key) ?? true {
            guard let entry = remote[key] else { continue }
            if let kept = prefer[key], kept == nil { continue }
            let keptItems = prefer[key].flatMap { $0 } ?? []
            switch kind {
            case .value:
                guard !own.contains(key), let changed = entry["at"] as? Date, changed > at[key] ?? .distantPast else { continue }
                let theirs = entry["deleted"] as? Bool == true ? nil : entry["value"]
                let local = defaults.object(forKey: key).flatMap(Self.encode)
                let differs = !Self.same(local, theirs.flatMap(Self.encode))
                // Another device's change to a setting set here (or changed here since), not sent everywhere: kept out,
                // and asked about.
                if differs, take[key] == nil, Self.perDevice.contains(key), entry["everywhere"] as? Bool != true,
                   here.contains(key) || !Self.same(local, values[key]) {
                    divergedValues.insert(key)
                    continue
                }
                if let theirs { defaults.set(theirs, forKey: key) } else { defaults.removeObject(forKey: key) }
                at[key] = changed
                values[key] = defaults.object(forKey: key).flatMap(Self.encode)
                if differs { here.remove(key) }
                divergedValues.remove(key)
            default:
                // The other devices' changes go into the list here and into what it was when last synced; a change made
                // here since stays to send. One that differs from this device's version of the item, and was made
                // without it (changed here since, or changed from an older version), is kept out and asked about.
                var local = elements(kind, defaults.object(forKey: key))
                var synced = elements(kind, values[key].flatMap(Self.decode))
                var known = items[key] ?? [:], base = bases[key] ?? [:]
                var changed = false
                for (id, item) in entry["items"] as? [String: [String: Any]] ?? [:] where !keptItems.contains(id) && !own.contains("\(key)/\(id)") {
                    guard let when = item["at"] as? Date, when != known[id] else { continue }
                    let theirs = Self.itemValue(item)
                    let differs = !Self.sameItem(local[id], theirs)
                    if take[key]?.contains(id) != true {
                        // Older than this device's: iCloud lost its change, which `push` sends again.
                        guard when > known[id] ?? .distantPast else { continue }
                        if Self.askedKeys.contains(key), differs, item["everywhere"] as? Bool != true {
                            let unsent = !Self.sameItem(local[id], synced[id])
                            let unseen = (item["base"] as? Date).map { $0 < known[id] ?? .distantPast } ?? false
                            let mine = Self.perDevice.contains(key) && here.contains("\(key)/\(id)")
                            if unsent || unseen || mine {
                                diverged[key, default: []].insert(id)
                                continue
                            }
                        }
                    }
                    local[id] = theirs
                    synced[id] = theirs
                    known[id] = when
                    base[id] = item["base"] as? Date
                    if differs { here.remove("\(key)/\(id)") }
                    diverged[key]?.remove(id)
                    changed = true
                }
                items[key] = known
                bases[key] = base
                guard changed else { continue }
                let order = defaults.object(forKey: key)
                if let value = storage(kind, local, order: order) { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                values[key] = storage(kind, synced, order: order).flatMap(Self.encode)
            }
            applied.append(key)
        }
        syncedAt = at
        itemsAt = items
        itemsBase = bases
        syncedValues = values
        setHere = here
        if !applied.isEmpty { log("sync", "from your other devices: \(applied.sorted().joined(separator: ", "))") }
        updateConflicts(remote)
        return applied
    }

    /// Sends what changed here since the last sync, and what iCloud lost of this device's changes; never what this device
    /// keeps as its own. `prefer` sends those settings (single values, list items) as the newest whatever changed;
    /// `replace` sends those settings whole, list items this device lacks deleted, for the other devices to take
    /// without asking.
    private func push(prefer: [String: Set<String>?] = [:], replace: Set<String> = []) {
        guard joined else { return }
        var at = syncedAt, items = itemsAt, bases = itemsBase, values = syncedValues
        var here = setHere
        let own = own
        var merged = remote()
        var sent: [String] = [], again: [String] = []
        var adopted = false
        let now = Date()
        for (key, kind) in Self.keys {
            let value = defaults.object(forKey: key)
            let encoded = value.flatMap(Self.encode)
            let replacing = replace.contains(key)
            let forced = replacing || prefer.keys.contains(key)
            let preferredItems = prefer[key].flatMap { $0 } ?? []
            switch kind {
            case .value:
                guard !own.contains(key) else { continue }
                let theirs = merged[key]?["at"] as? Date
                if forced || !Self.same(encoded, values[key]) {
                    if !forced, Self.perDevice.contains(key), let theirs, theirs > at[key] ?? .distantPast {
                        // Another device changed it too since this one last synced it: the same change, or asked about.
                        let other = merged[key].flatMap { $0["deleted"] as? Bool == true ? nil : $0["value"] }.flatMap(Self.encode)
                        if Self.same(encoded, other) {
                            at[key] = theirs
                            values[key] = encoded
                            divergedValues.remove(key)
                            adopted = true
                        } else {
                            divergedValues.insert(key)
                        }
                        continue
                    }
                    // Newer than what it replaces even on a clock behind.
                    let when = max(now, max(at[key] ?? .distantPast, theirs ?? .distantPast).addingTimeInterval(0.001))
                    var entry: [String: Any] = encoded == nil ? ["deleted": true, "at": when] : ["value": value!, "at": when]
                    if replacing { entry["everywhere"] = true }
                    merged[key] = entry
                    at[key] = when
                    values[key] = encoded
                    if Self.perDevice.contains(key) { here.insert(key) }
                    divergedValues.remove(key)
                    sent.append(key)
                } else if let had = at[key], theirs.map({ $0 < had }) ?? true {
                    // iCloud has an older change than this device's (another device's write crossed it): again.
                    let synced = values[key].flatMap(Self.decode)
                    merged[key] = synced == nil ? ["deleted": true, "at": had] : ["value": synced!, "at": had]
                    again.append(key)
                }
            default:
                let current = elements(kind, value)
                let before = replacing ? elements(kind, merged[key].map { Self.values(of: $0) }) : elements(kind, values[key].flatMap(Self.decode))
                var remoteItems = merged[key]?["items"] as? [String: [String: Any]] ?? [:]
                var known = items[key] ?? [:], base = bases[key] ?? [:]
                var synced = before
                var changed = 0, resent = 0
                var keptOwn = false
                for id in Set(current.keys).union(before.keys).union(known.keys) where !own.contains("\(key)/\(id)") {
                    let mine = current[id]
                    let theirs = remoteItems[id]
                    let theirsAt = theirs?["at"] as? Date
                    if !replacing, !preferredItems.contains(id), Self.sameItem(mine, before[id]) {
                        // Not changed here. iCloud has an older change of it than this device's version: sent again, unless
                        // it's another device's change made without this one's (an item the user is asked about).
                        guard let had = known[id], theirsAt.map({ $0 < had }) ?? true else { continue }
                        if let theirs, let theirsAt, theirsAt > base[id] ?? .distantFuture, Self.askedKeys.contains(key) {
                            if !Self.sameItem(mine, Self.itemValue(theirs)) {
                                diverged[key, default: []].insert(id)
                                keptOwn = true
                            }
                            continue
                        }
                        remoteItems[id] = Self.item(before[id], at: had, base: base[id])
                        resent += 1
                        continue
                    }
                    if !replacing, !preferredItems.contains(id), Self.askedKeys.contains(key), let theirs, let theirsAt, theirsAt > known[id] ?? .distantPast {
                        // Changed on another device too since this one last synced it: the same change, or asked about.
                        if Self.sameItem(mine, Self.itemValue(theirs)) {
                            synced[id] = mine
                            known[id] = theirsAt
                            base[id] = theirs["base"] as? Date
                            diverged[key]?.remove(id)
                            adopted = true
                        } else {
                            diverged[key, default: []].insert(id)
                            keptOwn = true
                        }
                        continue
                    }
                    let from = max(known[id] ?? Self.nothingSeen, theirsAt ?? Self.nothingSeen)
                    let when = max(now, from.addingTimeInterval(0.001))
                    remoteItems[id] = Self.item(mine, at: when, base: from, everywhere: replacing)
                    known[id] = when
                    base[id] = from
                    synced[id] = mine
                    if Self.perDevice.contains(key) { here.insert("\(key)/\(id)") }
                    diverged[key]?.remove(id)
                    changed += 1
                }
                items[key] = known
                bases[key] = base
                // What it was when last synced: this device's own version of the items it keeps for the user to decide.
                values[key] = keptOwn ? storage(kind, synced, order: value).flatMap(Self.encode) : encoded
                guard changed + resent > 0 || forced else { continue }
                merged[key] = ["items": remoteItems]
                if changed > 0 || forced { sent.append(key) } else { again.append(key) }
            }
        }
        defer { updateConflicts(merged) }
        guard !sent.isEmpty || !again.isEmpty || adopted else {
            syncedValues = values
            return
        }
        do {
            if !sent.isEmpty || !again.isEmpty { try write(merged) }
            syncedAt = at
            itemsAt = items
            itemsBase = bases
            syncedValues = values
            setHere = here
            if !sent.isEmpty { log("sync", "sent: \(sent.sorted().joined(separator: ", "))") }
            if !again.isEmpty { log("sync", "sent again (iCloud had an older change): \(again.sorted().joined(separator: ", "))") }
        } catch {
            log("sync", "couldn't save: \(error.localizedDescription)")
        }
    }

    /// The settings that diverged, as asked of the user; a device's first sync asks its own (`findConflicts`).
    private func updateConflicts(_ remote: [String: [String: Any]]) {
        guard joined else { return }
        let asked = diverged.filter { !$0.value.isEmpty }
        let before = conflicts.map { "\($0.key)/\($0.items)" }
        let values = divergedValues.map { key -> Conflict in
            let there = remote[key].flatMap { $0["deleted"] as? Bool == true ? nil : $0["value"] }
            return Conflict(key: key, title: Self.title(key), here: defaults.object(forKey: key).map { Self.describe(key, $0) } ?? "none",
                            iCloud: there.map { Self.describe(key, $0) } ?? "none")
        }
        conflicts = (values + asked.compactMap { key, ids -> Conflict? in
            guard let kind = Self.keys[key] else { return nil }
            let here = elements(kind, defaults.object(forKey: key))
            let there = (remote[key]?["items"] as? [String: [String: Any]] ?? [:]).mapValues(Self.itemValue)
            let sorted = ids.sorted()
            return Conflict(key: key, title: Self.title(key),
                            here: sorted.map { Self.describe(key, id: $0, here[$0], other: there[$0] ?? nil) }.joined(separator: "; "),
                            iCloud: sorted.map { Self.describe(key, id: $0, there[$0] ?? nil, other: here[$0]) }.joined(separator: "; "),
                            items: sorted)
        })
        .sorted { $0.title < $1.title }
        if conflicts.map({ "\($0.key)/\($0.items)" }) != before, !conflicts.isEmpty {
            log("sync", "another device changed differently: \(conflicts.map { "\($0.key) \($0.items.joined(separator: ", "))" }.joined(separator: "; ")); asking")
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
        case "networkEndpoint": "Network server"
        case "networkName": "Network server's name"
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

    /// A list item in a question: an MCP server by what differs from the other version (its URL, on or off, ...);
    /// another by its name (never a secret's value).
    private static func describe(_ key: String, id: String, _ element: Any?, other: Any?) -> String {
        guard let element else { return "\(id): removed" }
        func server(_ element: Any?) -> [String: Any]? {
            (element as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        guard key == "mcpServers", let mine = server(element) else { return name(key, element, id: id) }
        let theirs = server(other) ?? [:]
        let differing = Set(mine.keys).union(theirs.keys).subtracting(["name"]).sorted().filter { field in
            (mine[field] as? NSObject).map { !$0.isEqual(theirs[field]) } ?? (theirs[field] != nil)
        }
        let parts = differing.map { field -> String in
            let value = mine[field].flatMap { $0 is NSNull ? nil : $0 }
            switch (field, value) {
            case ("enabled", let on as Bool): return on ? "on" : "off"
            case ("url", let url?): return "\(url)"
            case ("headerNames", let names as [String]): return names.isEmpty ? "no headers" : "headers \(names.joined(separator: ", "))"
            case ("oauthClientId", let client?): return "OAuth app \(client)"
            case (_, let value?): return "\(field) \(value)"
            case (_, nil): return "no \(field)"
            }
        }
        return parts.isEmpty ? id : "\(id): \(parts.joined(separator: ", "))"
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

    /// The change an item new here was made from: none (a date any plist reader takes, unlike `Date.distantPast`).
    private static let nothingSeen = Date(timeIntervalSince1970: 0)

    /// An item as iCloud keeps it: its value (none: deleted), when it changed, the change it was made from, and whether
    /// it was sent everywhere (taken without asking).
    private static func item(_ value: Any?, at: Date, base: Date?, everywhere: Bool = false) -> [String: Any] {
        var item: [String: Any] = value.map { ["value": $0] } ?? ["deleted": true]
        item["at"] = at
        if let base { item["base"] = base }
        if everywhere { item["everywhere"] = true }
        return item
    }

    /// A setting's name in `setHere` and `own`: its key, and a list item's id after a slash.
    private static func split(_ name: String) -> (key: String, id: String?) {
        guard let slash = name.firstIndex(of: "/") else { return (name, nil) }
        return (String(name[..<slash]), String(name[name.index(after: slash)...]))
    }

    /// The `perDevice` settings this device has, by name.
    private func perDeviceHere() -> Set<String> {
        var names: Set<String> = []
        for key in Self.perDevice {
            guard let kind = Self.keys[key], let value = defaults.object(forKey: key) else { continue }
            if case .value = kind { names.insert(key) } else { names.formUnion(elements(kind, value).keys.map { "\(key)/\($0)" }) }
        }
        return names
    }

    /// An iCloud item's value; nil for a deleted one.
    private static func itemValue(_ item: [String: Any]) -> Any? {
        item["deleted"] as? Bool == true ? nil : item["value"]
    }

    /// Whether two items (nil: none) are the same, an MCP server's JSON whatever its keys' order.
    private static func sameItem(_ a: Any?, _ b: Any?) -> Bool {
        if let a = a as? Data, let b = b as? Data, a != b,
           let x = try? JSONSerialization.jsonObject(with: a) as? NSObject, let y = try? JSONSerialization.jsonObject(with: b) as? NSObject {
            return x.isEqual(y)
        }
        return same(a.flatMap(encode), b.flatMap(encode))
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
