import Foundation
import Observation
import WebKit

/// Named browser profiles ("Personal", "Work"): each a persistent WebKit data store holding its cookies and logins.
/// Sessions attach to a profile by key, a profile's UUID string, or to `privateKey`, an in-memory store per session.
@MainActor
@Observable
final class BrowserProfiles {
    struct Profile: Codable, Identifiable, Hashable {
        let id: UUID
        var name: String
        var key: String { id.uuidString }
    }

    static let privateKey = "private"
    private static let profilesKey = "browserProfiles"
    private static let defaultKey = "browserDefaultProfile"

    private(set) var profiles: [Profile]
    /// The profile new sessions and the home screen's address bar use.
    var defaultKey: String {
        didSet { UserDefaults.standard.set(defaultKey, forKey: Self.defaultKey) }
    }

    /// One store object per profile, so every web view on a profile shares its cookies live.
    @ObservationIgnored private var stores: [String: WKWebsiteDataStore] = [:]

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.profilesKey), let saved = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = saved
            defaultKey = defaults.string(forKey: Self.defaultKey) ?? Self.privateKey
        } else {
            let personal = Profile(id: UUID(), name: "Personal")
            profiles = [personal]
            defaultKey = personal.key
            save()
            defaults.set(defaultKey, forKey: Self.defaultKey)
        }
    }

    func name(of key: String) -> String? {
        key == Self.privateKey ? "Private" : profiles.first { $0.key == key }?.name
    }

    /// A persistent profile's shared store; `privateKey` gets a new in-memory store each time.
    func dataStore(for key: String) -> WKWebsiteDataStore {
        if key == Self.privateKey { return .nonPersistent() }
        if let store = stores[key] { return store }
        guard let id = UUID(uuidString: key) else { preconditionFailure("Not a browser profile key: \(key)") }
        let store = WKWebsiteDataStore(forIdentifier: id)
        stores[key] = store
        return store
    }

    @discardableResult
    func create(name: String) -> Profile {
        let profile = Profile(id: UUID(), name: name)
        profiles.append(profile)
        save()
        return profile
    }

    func rename(_ key: String, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.key == key }) else { return }
        profiles[index].name = name
        save()
    }

    /// Deletes the profile and its site data. Every web view using it must be closed first.
    func delete(_ key: String) async throws {
        guard let profile = profiles.first(where: { $0.key == key }) else { return }
        stores[key] = nil
        try await WKWebsiteDataStore.remove(forIdentifier: profile.id)
        profiles.removeAll { $0.key == key }
        if defaultKey == key { defaultKey = Self.privateKey }
        save()
    }

    func clearData(_ key: String) async {
        await dataStore(for: key).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(profiles), forKey: Self.profilesKey)
    }
}
