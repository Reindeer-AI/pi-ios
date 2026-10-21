import Foundation

// Settings sync (App/PiMobile/SyncedSettings.swift) between two or three devices, each with its own copy of the iCloud
// Keychain item; `replicate` is iCloud Keychain moving it between them (the newest write of the whole item wins).
// scripts/test-settings-sync.sh builds and runs it.

nonisolated(unsafe) var logs: [String] = []
func log(_ tag: String, _ message: String) { logs.append("[\(tag)] \(message)") }

final class Cloud { var data: Data?; var at = Date.distantPast }

final class DeviceStore: SyncStore {
    let cloud: Cloud
    var local: Data?
    var at = Date.distantPast
    var writes = 0
    init(_ cloud: Cloud) { self.cloud = cloud }
    func read() -> Data? { local }
    func write(_ data: Data) throws { local = data; at = Date(); writes += 1 }
    func upload() { if at > cloud.at { cloud.data = local; cloud.at = at } }
    func download() { if cloud.at > at { local = cloud.data; at = cloud.at } }
}

@MainActor
final class Device {
    let name: String
    let defaults: UserDefaults
    let store: DeviceStore
    var settings: SyncedSettings
    init(_ name: String, _ cloud: Cloud) {
        self.name = name
        let suite = "settings-sync-test.\(name).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = DeviceStore(cloud)
        settings = SyncedSettings(defaults: defaults, store: store)
    }
    /// pi quits and starts again.
    func relaunch() {
        settings = SyncedSettings(defaults: defaults, store: store)
        settings.start()
        settle()
    }
    var servers: [String: [String: Any]] {
        guard let data = defaults.data(forKey: "mcpServers"), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0["name"] as! String, $0) })
    }
    func url(_ server: String) -> String? { servers[server]?["url"] as? String }
    /// The user edits a server here (pi running): the push follows a second later.
    func setServer(_ name: String, url: String, enabled: Bool = true) {
        var all = servers
        all[name] = ["name": name, "url": url, "enabled": enabled, "exposure": "auto", "headerNames": []]
        write(all)
    }
    func removeServer(_ name: String) {
        var all = servers
        all.removeValue(forKey: name)
        write(all)
    }
    private func write(_ all: [String: [String: Any]]) {
        let list = all.keys.sorted().map { all[$0]! }
        defaults.set(try! JSONSerialization.data(withJSONObject: list), forKey: "mcpServers")
        settle()
    }
    func set(_ key: String, _ value: Any) { defaults.set(value, forKey: key); settle() }
    var conflictItems: [String] { settings.conflicts.flatMap { c in c.items.isEmpty ? [c.key] : c.items.map { "\(c.key)/\($0)" } }.sorted() }
}

@MainActor func settle() { RunLoop.main.run(until: Date().addingTimeInterval(1.3)) }
@MainActor func replicate(_ devices: [Device]) {
    for device in devices { device.store.upload() }
    for device in devices { device.store.download() }
}

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
    if !ok { failures += 1 }
}

@MainActor func pair(_ more: Int = 0) -> (Device, Device, [Device]) {
    let cloud = Cloud()
    let phone = Device("phone", cloud), mac = Device("mac", cloud)
    let extra = (0..<more).map { Device("ipad\($0)", cloud) }
    phone.relaunch()
    phone.setServer("github", url: "https://v0")
    phone.setServer("linear", url: "https://linear-v0")
    replicate([phone, mac] + extra)
    mac.relaunch()
    for device in extra { device.relaunch() }
    replicate([phone, mac] + extra)
    return (phone, mac, extra)
}

@MainActor func run() {
    print("1. The Mac, open for days, changes a server the phone changed meanwhile")
    do {
        let (phone, mac, _) = pair()
        phone.setServer("github", url: "https://phone")
        replicate([phone, mac])
        mac.setServer("github", url: "https://mac")      // pi on the Mac never relaunched: it still shows v0
        replicate([phone, mac])
        phone.relaunch()
        check(phone.url("github") == "https://phone", "the phone keeps its github (\(phone.url("github") ?? "nil"))")
        check(mac.url("github") == "https://mac", "the Mac keeps its github (\(mac.url("github") ?? "nil"))")
        check(mac.conflictItems == ["mcpServers/github"], "the Mac asks about github (\(mac.conflictItems))")
        mac.relaunch()
        check(mac.url("github") == "https://mac", "after a relaunch the Mac still keeps its own (\(mac.url("github") ?? "nil"))")
        check(mac.conflictItems == ["mcpServers/github"], "and still asks (\(mac.conflictItems))")
        mac.settings.resolve(useICloud: true)
        settle()
        check(mac.url("github") == "https://phone", "Use iCloud's: the Mac takes the phone's (\(mac.url("github") ?? "nil"))")
        check(mac.conflictItems.isEmpty, "nothing left to ask")
        replicate([phone, mac]); phone.relaunch()
        check(phone.url("github") == "https://phone" && phone.conflictItems.isEmpty, "the phone unchanged, nothing to ask")
    }

    print("2. iCloud Keychain loses the phone's change (the Mac wrote the item before it arrived)")
    do {
        let (phone, mac, _) = pair()
        phone.setServer("github", url: "https://phone")   // in the phone's keychain, not yet in iCloud
        mac.set("defaultThinkingLevel", "high")           // the Mac writes the whole item, without the phone's change
        mac.store.upload()                                 // the Mac's item reaches iCloud first...
        phone.store.at = Date.distantPast                  // ...and wins over the phone's
        replicate([phone, mac])
        phone.relaunch()
        check(phone.url("github") == "https://phone", "the phone keeps its change (\(phone.url("github") ?? "nil"))")
        replicate([phone, mac]); mac.relaunch()
        check(mac.url("github") == "https://phone", "the Mac gets it after all (\(mac.url("github") ?? "nil"))")
        check(mac.defaults.string(forKey: "defaultThinkingLevel") == "high" && phone.defaults.string(forKey: "defaultThinkingLevel") == "high", "and the Mac's thinking level stays everywhere")
        check(phone.conflictItems.isEmpty && mac.conflictItems.isEmpty, "nothing to ask (\(phone.conflictItems) \(mac.conflictItems))")
    }

    print("3. Lost as in 2, then the Mac changes the same server before the phone sends it again")
    do {
        let (phone, mac, _) = pair()
        phone.setServer("github", url: "https://phone")
        mac.set("defaultThinkingLevel", "high")
        mac.store.upload(); phone.store.at = Date.distantPast
        replicate([phone, mac])
        mac.setServer("github", url: "https://mac")
        replicate([phone, mac])
        phone.relaunch()
        check(phone.url("github") == "https://phone", "the phone keeps its github (\(phone.url("github") ?? "nil"))")
        check(phone.conflictItems == ["mcpServers/github"], "the phone asks about github (\(phone.conflictItems))")
        phone.settings.resolve(useICloud: false)
        settle()
        replicate([phone, mac]); mac.relaunch()
        check(mac.url("github") == "https://phone", "Keep This Device's: the Mac takes the phone's (\(mac.url("github") ?? "nil"))")
        check(mac.conflictItems.isEmpty && phone.conflictItems.isEmpty, "nothing left to ask (\(mac.conflictItems))")
    }

    print("4. Changes to different servers merge, without asking")
    do {
        let (phone, mac, _) = pair()
        phone.setServer("github", url: "https://phone")
        mac.setServer("linear", url: "https://linear-mac")
        mac.setServer("notion", url: "https://notion-mac")
        replicate([phone, mac])
        phone.relaunch(); replicate([phone, mac]); mac.relaunch()
        for device in [phone, mac] {
            check(device.url("github") == "https://phone" && device.url("linear") == "https://linear-mac" && device.url("notion") == "https://notion-mac",
                  "\(device.name): \(device.servers.keys.sorted().map { "\($0)=\(device.url($0)!)" })")
            check(device.conflictItems.isEmpty, "\(device.name) asks nothing (\(device.conflictItems))")
        }
    }

    print("5. The same change on both: nothing to ask")
    do {
        let (phone, mac, _) = pair()
        phone.setServer("github", url: "https://same")
        replicate([phone, mac])
        mac.setServer("github", url: "https://same")
        replicate([phone, mac]); phone.relaunch(); mac.relaunch()
        check(phone.conflictItems.isEmpty && mac.conflictItems.isEmpty, "no question (\(phone.conflictItems) \(mac.conflictItems))")
    }

    print("6. Removed on the phone, changed on the Mac")
    do {
        let (phone, mac, _) = pair()
        phone.removeServer("linear")
        replicate([phone, mac])
        mac.setServer("linear", url: "https://linear-mac")
        replicate([phone, mac]); phone.relaunch()
        check(phone.url("linear") == nil, "the phone keeps it removed")
        check(mac.url("linear") == "https://linear-mac" && mac.conflictItems == ["mcpServers/linear"], "the Mac keeps its own and asks (\(mac.conflictItems))")
    }

    print("7. A change on one device, nothing on the other: it just arrives")
    do {
        let (phone, mac, _) = pair()
        mac.setServer("github", url: "https://mac")
        mac.removeServer("linear")
        replicate([phone, mac]); phone.relaunch()
        check(phone.url("github") == "https://mac" && phone.url("linear") == nil && phone.conflictItems.isEmpty, "the phone takes both, asks nothing")
        phone.setServer("github", url: "https://phone2")
        replicate([phone, mac]); mac.relaunch()
        check(mac.url("github") == "https://phone2" && mac.conflictItems.isEmpty, "and back (\(mac.url("github") ?? "nil"))")
    }

    print("8. Three devices: the iPad changes after taking the phone's change; the Mac only receives")
    do {
        let (phone, mac, extra) = pair(1)
        let ipad = extra[0]
        phone.setServer("github", url: "https://phone")
        replicate([phone, mac, ipad]); ipad.relaunch()
        ipad.setServer("github", url: "https://ipad")
        replicate([phone, mac, ipad]); phone.relaunch(); mac.relaunch()
        for device in [phone, mac, ipad] {
            check(device.url("github") == "https://ipad" && device.conflictItems.isEmpty, "\(device.name): \(device.url("github") ?? "nil") \(device.conflictItems)")
        }
    }

    print("9. A device's first sync with a different server still asks first")
    do {
        let cloud = Cloud()
        let phone = Device("phone", cloud), mac = Device("mac", cloud)
        phone.relaunch(); phone.setServer("github", url: "https://phone"); replicate([phone, mac])
        mac.setServer("github", url: "https://mac")   // before it ever synced
        mac.relaunch()
        check(mac.conflictItems == ["mcpServers/github"], "the Mac asks (\(mac.conflictItems))")
        mac.settings.resolve(useICloud: true); settle()
        check(mac.url("github") == "https://phone", "and takes iCloud's (\(mac.url("github") ?? "nil"))")
    }

    print("10. Idle: nothing written again and again")
    do {
        let (phone, mac, _) = pair()
        phone.setServer("github", url: "https://phone"); replicate([phone, mac]); mac.setServer("github", url: "https://mac"); replicate([phone, mac])
        let before = (phone.store.writes, mac.store.writes)
        settle(); settle(); phone.set("someUnsyncedKey", 1); mac.set("someUnsyncedKey", 1); settle()
        check(phone.store.writes == before.0 && mac.store.writes == before.1, "no writes (\(phone.store.writes - before.0), \(mac.store.writes - before.1))")
        check(logs.filter { $0.contains("asking") }.count < 20, "asks are logged once per change, not per push (\(logs.filter { $0.contains("asking") }.count))")
    }

    print("11. Extensions: the newest change wins, nothing asked")
    do {
        let (phone, mac, _) = pair()
        phone.set("syncedExtensions", [["source": "npm:x", "removed": false, "at": Date()]])
        replicate([phone, mac])
        mac.set("syncedExtensions", [["source": "npm:x", "removed": true, "at": Date()]])
        replicate([phone, mac]); phone.relaunch()
        let removed = (phone.defaults.array(forKey: "syncedExtensions") as? [[String: Any]])?.first?["removed"] as? Bool
        check(removed == true && phone.conflictItems.isEmpty && mac.conflictItems.isEmpty, "the Mac's newer removal wins (\(String(describing: removed)))")
    }

    print("12. Use This Device's Settings Everywhere still overrides, without asking")
    do {
        let (phone, mac, _) = pair()
        phone.setServer("github", url: "https://phone"); replicate([phone, mac])
        mac.setServer("github", url: "https://mac"); replicate([phone, mac])
        check(mac.conflictItems == ["mcpServers/github"], "the Mac asks first")
        mac.settings.sendThisDevice(); settle()
        replicate([phone, mac]); phone.relaunch()
        check(phone.url("github") == "https://mac" && phone.conflictItems.isEmpty, "the phone takes the Mac's (\(phone.url("github") ?? "nil"))")
    }

    print("13. Asked, then the user makes this device's the same as iCloud's: no longer asked")
    do {
        let (phone, mac, _) = pair()
        phone.setServer("github", url: "https://phone"); replicate([phone, mac])
        mac.setServer("github", url: "https://mac"); replicate([phone, mac])
        print("        asks: \(mac.settings.conflicts.map { "\($0.title) — This device: \($0.here) | iCloud: \($0.iCloud)" })")
        mac.setServer("github", url: "https://phone")
        check(mac.conflictItems.isEmpty, "nothing to ask (\(mac.conflictItems))")
        mac.setServer("github", url: "https://phone", enabled: false); replicate([phone, mac]); phone.relaunch()
        check(phone.servers["github"]?["enabled"] as? Bool == false && phone.conflictItems.isEmpty, "and its next change reaches the phone")
    }

    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
}

run()
exit(failures == 0 ? 0 : 1)
