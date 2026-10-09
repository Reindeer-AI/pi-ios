import Foundation
import LocalAuthentication
import Security

/// The vault: a person's sensitive values (card numbers and security codes, passport, ID, license and social security
/// numbers, secure notes) kept on this device behind Face ID. An item's values are one Keychain item that only opens with
/// Face ID (or the passcode) and never leaves the device (not backed up, gone if the passcode is removed): the Secure
/// Enclave guards the key that encrypts it. Its name ("Chase Sapphire Preferred", "My passport") and a hint
/// ("Visa •• 4242") are kept without protection, so items can be listed, and named by the user, without asking. What
/// isn't sensitive (the name on a card, an address, a car) stays with the extension that keeps it (Personal details).
///
/// Every use goes through the app's consent sheet (who wants which fields of which item, and what for) and then Face ID,
/// unless the user allowed that requester the item for a while (`window`): the values are then kept in memory for that
/// long. Each use is logged with the item. Values are typed into the app's own secure sheet (`add`), so even the
/// extension asking doesn't see them; an extension may also store values it has (`set`), and changes or deletes only
/// its own items. Extensions reach the vault through the engine's `vault` service (`list`, `add`, `set`, `delete`,
/// `choose`, `get`), fill a value into a browser page (`BrowserService`), or have it sent in a request (`resolve`,
/// `NetProxy`): `{{vault:ID/FIELD}}` in the body or a header, to the item's domains.
@MainActor
public final class VaultService {
    public struct Item: Identifiable, Hashable, Sendable {
        public let id: String
        public let kind: String
        public let label: String
        /// What may show without Face ID: "Visa •• 4242".
        public let hint: String
        /// The names of the fields it holds.
        public let fields: [String]
        /// Their display names, when not the kind's own ("Member number" for member_number).
        public let labels: [String: String]
        /// Where a request may send it (`{{vault:…}}`); empty: any address, with the consent sheet naming it.
        public let domains: [String]
        /// The extension that stored it (only it, and the user, may change it); nil: the user, in Settings.
        public let owner: String?
        public let updatedAt: Date
    }

    public struct Use: Hashable, Sendable {
        public let date: Date
        public let requester: String
        public let fields: [String]
        public let purpose: String
    }

    /// What the consent sheet asks.
    public struct Consent: Identifiable, Sendable {
        public let id = UUID()
        public let item: Item
        public let fields: [String]
        /// "flights", "the agent".
        public let requester: String
        /// "fill a form on united.com", "send it to api.stripe.com", "reveal it to the extension".
        public let purpose: String
        /// The requester's own words, if it gave any.
        public let reason: String?
    }

    public enum Decision: Sendable {
        case deny, once, window
    }

    public struct Field: Sendable {
        public let key: String
        public let label: String
        /// Shown as dots until revealed.
        public let secret: Bool
        public let placeholder: String
    }

    public struct Kind: Sendable {
        public let key: String
        public let title: String
        /// An SF Symbol.
        public let icon: String
        public let fields: [Field]
    }

    /// Templates for an item's fields, for the app's Add (and `add` without fields): only what is sensitive.
    public static let kinds: [Kind] = [
        Kind(key: "card", title: "Card", icon: "creditcard", fields: [
            Field(key: "number", label: "Card number", secret: true, placeholder: "4242 4242 4242 4242"),
            Field(key: "cvv", label: "Security code", secret: true, placeholder: "123"),
        ]),
        Kind(key: "passport", title: "Passport", icon: "globe", fields: [
            Field(key: "number", label: "Passport number", secret: true, placeholder: ""),
        ]),
        Kind(key: "id", title: "ID card", icon: "person.text.rectangle", fields: [
            Field(key: "number", label: "ID number", secret: true, placeholder: ""),
        ]),
        Kind(key: "license", title: "Driver's license", icon: "car", fields: [
            Field(key: "number", label: "License number", secret: true, placeholder: ""),
        ]),
        Kind(key: "ssn", title: "Social security number", icon: "number", fields: [
            Field(key: "number", label: "SSN", secret: true, placeholder: "123-45-6789"),
        ]),
        Kind(key: "note", title: "Secure note", icon: "note.text", fields: [
            Field(key: "text", label: "Note", secret: true, placeholder: ""),
        ]),
    ]

    public static func kind(_ key: String) -> Kind? { kinds.first { $0.key == key } }

    /// A field's display name: the item's own, the kind's, or its key.
    public static func label(of field: String, in item: Item) -> String {
        item.labels[field] ?? kind(item.kind)?.fields.first { $0.key == field }?.label ?? field
    }

    /// How long "Allow for 5 minutes" lasts.
    public static let window: TimeInterval = 5 * 60

    /// The app's consent sheet: who wants what, and the user's answer.
    public var askConsent: ((Consent) async -> Decision)?
    /// What the app's secure sheet asks for (`add`): an item's name and fields, for a new item or new values for one.
    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        /// The item it replaces the values of, if any.
        public let itemId: String?
        public let kind: String
        public let label: String
        public let fields: [Field]
        public let requester: String
        public let hint: String?

        public init(itemId: String?, kind: String, label: String, fields: [Field], requester: String, hint: String?) {
            self.itemId = itemId
            self.kind = kind
            self.label = label
            self.fields = fields
            self.requester = requester
            self.hint = hint
        }
    }

    /// The app's secure sheet: the values typed, and the name (possibly changed), or nil when cancelled.
    public var enterValues: ((Entry) async -> (label: String, values: [String: String])?)?
    /// The app's picker (`choose`): an item's id, or nil.
    public var chooseItem: ((_ kind: String?, _ reason: String?, _ requester: String) async -> String?)?
    /// Each use, for the app's log line.
    public var onUse: ((Item, Use) -> Void)?

    private let defaults: UserDefaults
    nonisolated private static let keychainService = "dev.pimobile.vault"
    /// Values allowed for a while, by requester and item.
    private var grants: [String: (expires: Date, values: [String: String])] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Items

    private var metadata: [String: [String: Any]] {
        get { defaults.dictionary(forKey: "vaultItems") as? [String: [String: Any]] ?? [:] }
        set { defaults.set(newValue, forKey: "vaultItems") }
    }

    public var items: [Item] {
        metadata.compactMap { id, info in Self.item(id, info) }.sorted { ($0.kind, $0.label) < ($1.kind, $1.label) }
    }

    public func item(_ id: String) -> Item? {
        metadata[id].flatMap { Self.item(id, $0) }
    }

    private static func item(_ id: String, _ info: [String: Any]) -> Item? {
        guard let kind = info["kind"] as? String else { return nil }
        return Item(id: id, kind: kind, label: info["label"] as? String ?? kind, hint: info["hint"] as? String ?? "",
                    fields: info["fields"] as? [String] ?? [], labels: info["labels"] as? [String: String] ?? [:],
                    domains: info["domains"] as? [String] ?? [], owner: info["owner"] as? String,
                    updatedAt: Date(timeIntervalSince1970: info["updatedAt"] as? Double ?? 0))
    }

    public func uses(_ id: String) -> [Use] {
        (metadata[id]?["uses"] as? [[String: Any]] ?? []).map {
            Use(date: Date(timeIntervalSince1970: $0["date"] as? Double ?? 0), requester: $0["requester"] as? String ?? "",
                fields: $0["fields"] as? [String] ?? [], purpose: $0["purpose"] as? String ?? "")
        }
    }

    /// Saves an item (a new one without `id`): its values behind Face ID, its name and hint without. Empty values are
    /// dropped; without `values` (an existing item), only its name, hint or domains change.
    @discardableResult
    public func save(id: String? = nil, kind: String, label: String, values: [String: String]?, domains: [String]? = nil,
                     owner: String? = nil, hint: String? = nil, labels: [String: String]? = nil) throws -> Item {
        let id = id ?? UUID().uuidString.lowercased()
        var info = metadata[id] ?? [:]
        guard values != nil || !info.isEmpty else { throw VaultError("A new vault item needs values") }
        if let values {
            let kept = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
            guard !kept.isEmpty else { throw VaultError("Nothing to keep: every value is empty") }
            try Self.write(id, try JSONSerialization.data(withJSONObject: kept, options: .sortedKeys), synced: syncsWithICloud)
            info["fields"] = kept.keys.sorted()
            info["labels"] = (labels ?? [:]).filter { kept[$0.key] != nil }
            info["hint"] = hint ?? Self.hint(kind: kind, values: kept)
            grants = grants.filter { !$0.key.hasSuffix("|\(id)") }
        } else if let hint {
            info["hint"] = hint
        }
        let title = label.trimmingCharacters(in: .whitespaces)
        info["kind"] = kind
        info["label"] = title.isEmpty ? Self.kind(kind)?.title ?? kind : title
        if let domains { info["domains"] = domains.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }
        if info["owner"] == nil, let owner { info["owner"] = owner }
        info["updatedAt"] = Date().timeIntervalSince1970
        metadata[id] = info
        return Self.item(id, info)!
    }

    /// Whether the vault's values go to the user's other devices through iCloud Keychain (end-to-end encrypted, readable
    /// only on their devices). iOS can't keep a synced item behind its own Face ID lock, so pi asks for Face ID (or the
    /// passcode) itself before every read; off, items stay on this device behind the Keychain's lock. Items saved the
    /// other way move with `moveItems()`.
    public var syncsWithICloud: Bool {
        get { defaults.object(forKey: "vaultSync") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "vaultSync") }
    }

    /// Items saved the other way than `syncsWithICloud` says (from before it changed, or before the vault synced).
    public func itemsToMove() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
            kSecAttrSynchronizable as String: !syncsWithICloud, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { metadata[$0] != nil }
    }

    /// Saves the items saved the other way as `syncsWithICloud` says (Face ID once); how many moved.
    public func moveItems() async throws -> Int {
        let ids = itemsToMove()
        guard !ids.isEmpty else { return 0 }
        let synced = syncsWithICloud
        return try await Task.detached {
            let context = try await Self.authenticate(synced ? "Sync your vault with iCloud Keychain" : "Keep your vault on this device")
            for id in ids {
                let data = try Self.readData(id, synchronizable: !synced, context: context)
                try Self.write(id, data, synced: synced)
            }
            return ids.count
        }.value
    }

    public func delete(_ id: String) {
        SecItemDelete(Self.query(id) as CFDictionary)
        metadata.removeValue(forKey: id)
        grants = grants.filter { !$0.key.hasSuffix("|\(id)") }
    }

    /// What may show without Face ID.
    static func hint(kind: String, values: [String: String]) -> String {
        let last4 = { (value: String?) -> String? in
            guard let digits = value?.filter({ $0.isLetter || $0.isNumber }), digits.count >= 4 else { return nil }
            return String(digits.suffix(4))
        }
        switch kind {
        case "card":
            let number = values["number"]?.filter(\.isNumber) ?? ""
            let brand = switch number.first {
            case "4": "Visa"
            case "5", "2": "Mastercard"
            case "3": number.hasPrefix("34") || number.hasPrefix("37") ? "Amex" : "Card"
            case "6": "Discover"
            default: "Card"
            }
            return last4(number).map { "\(brand) •• \($0)" } ?? ""
        case "note":
            return ""
        default:
            return last4(values["number"]).map { "•• \($0)" } ?? ""
        }
    }

    // MARK: - Use

    /// Values of an item for a requester: the consent sheet and Face ID (or values allowed for a while). Logged.
    public func values(_ id: String, fields wanted: [String]?, requester: String, purpose: String, reason: String?) async throws -> [String: String] {
        guard let item = item(id) else { throw VaultError("No vault item \(id)") }
        let fields = wanted?.filter(item.fields.contains) ?? item.fields
        if let missing = wanted?.first(where: { !item.fields.contains($0) }) {
            throw VaultError("\(item.label) has no \(missing) (it has \(item.fields.joined(separator: ", ")))")
        }
        let key = "\(requester)|\(id)"
        if let grant = grants[key], grant.expires > Date() {
            record(item, Use(date: Date(), requester: requester, fields: fields, purpose: purpose))
            return grant.values.filter { fields.contains($0.key) }
        }
        guard let askConsent else { throw VaultError("The vault can't ask the user here") }
        let decision = await askConsent(Consent(item: item, fields: fields, requester: requester, purpose: purpose, reason: reason))
        guard decision != .deny else { throw VaultError("The user declined to share \(item.label)") }
        let all = try await Self.read(id, prompt: "Use \(item.label) for \(requester)")
        if decision == .window { grants[key] = (Date().addingTimeInterval(Self.window), all) }
        record(item, Use(date: Date(), requester: requester, fields: fields, purpose: purpose))
        return all.filter { fields.contains($0.key) }
    }

    /// The user looking at their own item (in the app's screens): Face ID, no consent sheet, not logged.
    public func reveal(_ id: String) async throws -> [String: String] {
        guard let item = item(id) else { throw VaultError("No vault item \(id)") }
        return try await Self.read(id, prompt: "Show \(item.label)")
    }

    /// `{{vault:ID/FIELD}}` in a request's body and headers, replaced with the values (the consent sheet naming where it
    /// goes); an item with domains only goes to those (and their subdomains). One naming no item (docs that show the form,
    /// say) stays as it is.
    public func resolve(_ request: URLRequest, requester: String) async throws -> URLRequest {
        let host = request.url?.host()?.lowercased() ?? ""
        var request = request
        var wanted: [String: Set<String>] = [:]
        let texts = [request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""] + (request.allHTTPHeaderFields?.values.map { $0 } ?? [])
        for text in texts {
            for match in text.matches(of: Self.placeholder) { wanted[String(match.1), default: []].insert(String(match.2)) }
        }
        var values: [String: [String: String]] = [:]
        for (id, fields) in wanted {
            guard let item = item(id) else { continue }
            if !item.domains.isEmpty, !item.domains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                throw VaultError("\(item.label) may only be sent to \(item.domains.joined(separator: ", ")), not \(host)")
            }
            values[id] = try await self.values(id, fields: fields.sorted(), requester: requester, purpose: "send it to \(host)", reason: nil)
        }
        guard !values.isEmpty else { return request }
        let substitute = { (text: String) in
            text.replacing(Self.placeholder) { match in values[String(match.1)].map { $0[String(match.2)] ?? "" } ?? String(match.0) }
        }
        if let body = request.httpBody { request.httpBody = Data(substitute(String(decoding: body, as: UTF8.self)).utf8) }
        for (name, value) in request.allHTTPHeaderFields ?? [:] where value.contains("{{vault:") {
            request.setValue(substitute(value), forHTTPHeaderField: name)
        }
        return request
    }

    nonisolated(unsafe) static let placeholder = #/\{\{vault:([A-Za-z0-9_-]+)/([A-Za-z0-9_]+)\}\}/#

    private func record(_ item: Item, _ use: Use) {
        guard var info = metadata[item.id] else { return }
        let entry: [String: Any] = ["date": use.date.timeIntervalSince1970, "requester": use.requester, "fields": use.fields, "purpose": use.purpose]
        info["uses"] = Array(([entry] + (info["uses"] as? [[String: Any]] ?? [])).prefix(30))
        metadata[item.id] = info
        onUse?(item, use)
    }

    // MARK: - Keychain

    /// An item, synced or on this device only.
    nonisolated private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: id,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }

    nonisolated private static func write(_ id: String, _ data: Data, synced: Bool) throws {
        SecItemDelete(query(id) as CFDictionary)
        var attributes = query(id)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrSynchronizable as String] = synced
        if synced {
            // iCloud Keychain can't carry an item behind Face ID: pi asks for it before every read (authenticate()).
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        } else {
            #if targetEnvironment(simulator)
            // The simulator has no passcode, without which iOS refuses this lock: there Face ID is asked in code (read()).
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            #else
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else {
                throw VaultError("access control: \(error?.takeRetainedValue().localizedDescription ?? "?")")
            }
            attributes[kSecAttrAccessControl as String] = access
            #endif
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultError(status == errSecDecode || status == -25293 ? "The vault needs a passcode on this iPhone" : "Keychain error \(status)")
        }
    }

    /// Reads an item's fields off the main thread: Face ID (or the passcode) first, which the read then uses, so an item
    /// behind the Keychain's own lock doesn't ask again.
    private static func read(_ id: String, prompt: String) async throws -> [String: String] {
        try await Task.detached {
            let context = try await authenticate(prompt)
            let data = try readData(id, synchronizable: nil, context: context)
            return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
        }.value
    }

    /// An item's data, with an authenticated context; `synchronizable` picks the synced or this device's copy.
    nonisolated private static func readData(_ id: String, synchronizable: Bool?, context: LAContext) throws -> Data {
        var query = query(id)
        if let synchronizable { query[kSecAttrSynchronizable as String] = synchronizable }
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecUserCanceled || status == errSecAuthFailed { throw VaultError("cancelled") }
        guard status == errSecSuccess, let data = result as? Data else {
            throw VaultError(status == errSecItemNotFound ? "The item's details are gone" : "Keychain error \(status)")
        }
        return data
    }

    /// Face ID, or the passcode (the simulator has none: Face ID only).
    nonisolated private static func authenticate(_ prompt: String) async throws -> LAContext {
        let context = LAContext()
        #if targetEnvironment(simulator)
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
        #else
        let policy = LAPolicy.deviceOwnerAuthentication
        #endif
        do {
            _ = try await context.evaluatePolicy(policy, localizedReason: prompt)
        } catch let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code) {
            throw VaultError("cancelled")
        } catch {
            throw VaultError("Face ID: \(error.localizedDescription)")
        }
        return context
    }

    // MARK: - Engine service

    /// The engine's `vault` service, for extensions (`pi.vault`) and the agent's tools; `requester` names who asks.
    public func install(on engine: PiEngine) {
        engine.register(service: "vault") { [weak self] method, params in
            guard let self else { throw EngineError.unknownService("vault") }
            let arguments = JSONValue(bridged: params)
            let requester = arguments["requester"]?.string ?? "an extension"
            switch method {
            case "list":
                let kind = arguments["kind"]?.string
                return self.items.filter { kind == nil || $0.kind == kind }.map(Self.summary)
            case "add":
                // The app's secure sheet for an item's values: a new item, or new values for one of the requester's.
                guard let enterValues = self.enterValues else { throw VaultError("The vault can't ask the user here") }
                let existing = try arguments["id"]?.string.map { try self.owned($0, by: requester) }
                let kind = arguments["kind"]?.string ?? existing?.kind ?? "note"
                let fields: [Field] = switch arguments["fields"] {
                case .array(let specs)? where !specs.isEmpty:
                    specs.compactMap { spec in
                        spec["key"]?.string?.filter({ $0.isLetter || $0.isNumber || $0 == "_" }).nilIfEmpty.map {
                            Field(key: $0, label: spec["label"]?.string ?? $0, secret: spec["secret"]?.bool ?? true,
                                  placeholder: spec["placeholder"]?.string ?? "")
                        }
                    }
                default: Self.kind(kind)?.fields ?? [Field(key: "value", label: "Value", secret: true, placeholder: "")]
                }
                let label = arguments["label"]?.string ?? existing?.label ?? Self.kind(kind)?.title ?? kind
                guard let entered = await enterValues(Entry(itemId: existing?.id, kind: kind, label: label, fields: fields,
                                                            requester: requester, hint: arguments["hint"]?.string)) else { return NSNull() }
                return Self.summary(try self.save(id: existing?.id, kind: kind, label: entered.label, values: entered.values,
                                                  owner: requester, hint: arguments["hint"]?.string,
                                                  labels: Dictionary(fields.map { ($0.key, $0.label) }) { first, _ in first }))
            case "set":
                // Values the requester has (or a new name or hint for its item), stored without asking.
                let existing = try arguments["id"]?.string.map { try self.owned($0, by: requester) }
                let values: [String: String]? = switch arguments["values"] {
                case .object(let object)?: object.compactMapValues(\.string)
                default: nil
                }
                let domains: [String]? = switch arguments["domains"] {
                case .array(let names)?: names.compactMap(\.string)
                default: nil
                }
                let labels: [String: String]? = switch arguments["labels"] {
                case .object(let object)?: object.compactMapValues(\.string)
                default: nil
                }
                return Self.summary(try self.save(id: existing?.id, kind: arguments["kind"]?.string ?? existing?.kind ?? "note",
                                                  label: arguments["label"]?.string ?? existing?.label ?? "", values: values,
                                                  domains: domains, owner: requester, hint: arguments["hint"]?.string, labels: labels))
            case "delete":
                let item = try self.owned(arguments["id"]?.string ?? "", by: requester)
                self.delete(item.id)
                return nil
            case "choose":
                guard let chooseItem = self.chooseItem else { throw VaultError("The vault can't ask the user here") }
                return await chooseItem(arguments["kind"]?.string, arguments["reason"]?.string, requester) ?? NSNull()
            case "get":
                let fields: [String]? = switch arguments["fields"] {
                case .array(let names)?: names.compactMap(\.string)
                default: nil
                }
                return try await self.values(arguments["id"]?.string ?? "", fields: fields, requester: requester,
                                             purpose: "reveal it to \(requester)", reason: arguments["reason"]?.string)
            default:
                throw EngineError.unknownMethod("vault.\(method)")
            }
        }
    }

    /// One of the requester's own items, which it may change or delete.
    private func owned(_ id: String, by requester: String) throws -> Item {
        guard let item = item(id) else { throw VaultError("No vault item \(id)") }
        guard item.owner == requester else { throw VaultError("\(item.label) belongs to \(item.owner ?? "the user"); only they can change it") }
        return item
    }

    static func summary(_ item: Item) -> [String: Any] {
        ["id": item.id, "kind": item.kind, "label": item.label, "hint": item.hint, "fields": item.fields, "labels": item.labels,
         "domains": item.domains, "owner": item.owner ?? NSNull()]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public struct VaultError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
