import Foundation

/// MCP servers (Settings → MCP servers), for every session: each server's entry in pi's `mcpServers` shape (URL,
/// exposure, enabled) in user defaults; header values (an API key, say) and an OAuth app's secret in their own Keychain
/// service, synced; the OAuth state pi-mcp keeps (client registration, tokens) in one on this device only. The engine
/// connects the servers (`mcp.ts`); the agent sees their tools, never these secrets.
///
/// Each device signs in on its own: a server that rotates refresh tokens takes the old one back once another device has
/// refreshed, so devices sharing a sign-in signed each other out (the one refused cleared the tokens, for all of them).
///
/// The engine's `mcp` service:
/// - `servers` → `[{ name, url, enabled, exposure, description, headers, oauth }]`, `oauth` the app the user registered
///   with the server, for one without dynamic client registration (`{ clientId, clientSecret, scope, redirectUrl }`);
/// - `loadAuth { server }` → pi-mcp's OAuth state, or null; `saveAuth { server, state }`;
/// - `cacheTools { server, tools }`, `cachedTools` → `{ server: tools }`: each server's tools as last listed, so sessions
///   have them (and resumed runs can call them) while the server connects after a launch.
@MainActor
public final class MCPServersService {
    private let defaults: UserDefaults
    private let secrets = KeychainService(service: "dev.pimobile.mcp", synchronizable: true)
    private let auth = KeychainService(service: "dev.pimobile.mcp.oauth")

    /// A server without its secrets.
    public struct Entry: Identifiable, Hashable, Sendable, Codable {
        public var id: String { name }
        public var name: String
        public var url: String
        public var enabled: Bool
        /// pi's exposure: `auto` (the app's: `direct` for a few tools, else `deferred`), `direct`, `deferred`, or `hidden`.
        public var exposure: String
        public var description: String?
        /// Names of the headers sent with every request; their values are in the Keychain.
        public var headerNames: [String]
        /// An OAuth app the user registered with the server (Slack, HubSpot: no dynamic client registration): its client
        /// ID, the scopes to ask for, and the redirect URL it has; its secret is in the Keychain. All optional.
        public var oauthClientId: String?
        public var oauthScope: String?
        public var oauthRedirectUrl: String?

        public init(name: String, url: String, enabled: Bool = true, exposure: String = "auto", description: String? = nil, headerNames: [String] = []) {
            self.name = name
            self.url = url
            self.enabled = enabled
            self.exposure = exposure
            self.description = description
            self.headerNames = headerNames
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepSignInsHere()
    }

    /// Sign-ins synced before each device kept its own: this device keeps the one it had (unless it has its own), and
    /// takes it out of iCloud, so the other devices sign in again.
    private func keepSignInsHere() {
        for account in (try? secrets.accounts()) ?? [] where account.hasSuffix("/oauth") && Self.isValidName(String(account.dropLast(6))) {
            if (try? auth.get(account)) == nil {
                guard let state = try? secrets.get(account), (try? auth.set(account, state)) != nil else { continue }
            }
            try? secrets.delete(account)
        }
    }

    public var entries: [Entry] {
        get {
            guard let data = defaults.data(forKey: "mcpServers") else { return [] }
            return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "mcpServers") }
    }

    /// Server names as pi takes them: letters, digits, `-` and `_`.
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) != nil
    }

    /// Adds or replaces a server. `headers` and `clientSecret` nil keep the stored values; an empty secret removes it.
    public func save(_ entry: Entry, headers: [String: String]? = nil, clientSecret: String? = nil) throws {
        guard Self.isValidName(entry.name) else {
            throw EngineError.unknownMethod("mcp: \(entry.name) is not a valid server name (letters, digits, - and _)")
        }
        guard let url = URL(string: entry.url), ["http", "https"].contains(url.scheme ?? "") else {
            throw EngineError.unknownMethod("mcp: \(entry.url) is not an http(s) URL")
        }
        var entry = entry
        for keyPath in [\Entry.oauthClientId, \Entry.oauthScope, \Entry.oauthRedirectUrl] {
            let value = entry[keyPath: keyPath]?.trimmingCharacters(in: .whitespacesAndNewlines)
            entry[keyPath: keyPath] = value?.isEmpty == false ? value : nil
        }
        if let redirect = entry.oauthRedirectUrl, URL(string: redirect)?.scheme == nil {
            throw EngineError.unknownMethod("mcp: the redirect URL \(redirect) is not a URL")
        }
        if let clientSecret {
            if clientSecret.isEmpty { try? secrets.delete(clientSecretKey(entry.name)) } else { try secrets.set(clientSecretKey(entry.name), clientSecret) }
        }
        if let headers {
            for name in entries.first(where: { $0.name == entry.name })?.headerNames ?? [] { try? secrets.delete(headerKey(entry.name, name)) }
            for (name, value) in headers where !name.isEmpty { try secrets.set(headerKey(entry.name, name), value) }
            entry.headerNames = headers.keys.filter { !$0.isEmpty }.sorted()
        }
        var all = entries.filter { $0.name != entry.name }
        all.append(entry)
        entries = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func setEnabled(_ name: String, _ enabled: Bool) {
        entries = entries.map { var entry = $0; if entry.name == name { entry.enabled = enabled }; return entry }
    }

    public func setExposure(_ name: String, _ exposure: String) {
        entries = entries.map { var entry = $0; if entry.name == name { entry.exposure = exposure }; return entry }
    }

    /// Forgets the server's sign-in (tokens and client registration).
    public func signOut(_ name: String) {
        try? auth.delete(authKey(name))
    }

    public func isSignedIn(_ name: String) -> Bool {
        guard let json = try? auth.get(authKey(name)), let data = json.data(using: .utf8),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return state["tokens"] != nil
    }

    private var toolCache: [String: Any] {
        get {
            guard let data = defaults.data(forKey: "mcpToolCache") else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        set { defaults.set(try? JSONSerialization.data(withJSONObject: newValue), forKey: "mcpToolCache") }
    }

    public func hasClientSecret(_ name: String) -> Bool {
        (try? secrets.get(clientSecretKey(name))) != nil
    }

    public func delete(_ name: String) {
        toolCache.removeValue(forKey: name)
        try? secrets.delete(clientSecretKey(name))
        for header in entries.first(where: { $0.name == name })?.headerNames ?? [] { try? secrets.delete(headerKey(name, header)) }
        signOut(name)
        entries = entries.filter { $0.name != name }
    }

    private func headerKey(_ server: String, _ header: String) -> String { "\(server)/header/\(header)" }
    private func authKey(_ server: String) -> String { "\(server)/oauth" }
    private func clientSecretKey(_ server: String) -> String { "\(server)/oauth-client-secret" }

    // MARK: - Engine service

    public func install(on engine: PiEngine) {
        engine.register(service: "mcp") { [weak self] method, params in
            guard let self else { throw EngineError.unknownService("mcp") }
            let arguments = JSONValue(bridged: params)
            switch method {
            case "servers":
                return self.entries.map { entry -> [String: Any] in
                    var headers: [String: String] = [:]
                    for name in entry.headerNames { headers[name] = (try? self.secrets.get(self.headerKey(entry.name, name))) ?? "" }
                    var oauth: [String: Any] = [:]
                    if let id = entry.oauthClientId { oauth["clientId"] = id }
                    if let secret = try? self.secrets.get(self.clientSecretKey(entry.name)) { oauth["clientSecret"] = secret }
                    if let scope = entry.oauthScope { oauth["scope"] = scope }
                    if let redirect = entry.oauthRedirectUrl { oauth["redirectUrl"] = redirect }
                    return [
                        "name": entry.name, "url": entry.url, "enabled": entry.enabled, "exposure": entry.exposure,
                        "description": entry.description ?? NSNull(), "headers": headers,
                        "oauth": oauth.isEmpty ? NSNull() : oauth,
                    ]
                }
            case "loadAuth":
                guard let json = try self.auth.get(self.authKey(arguments["server"]?.string ?? "")),
                      let data = json.data(using: .utf8) else { return nil }
                return try JSONSerialization.jsonObject(with: data)
            case "saveAuth":
                let server = arguments["server"]?.string ?? ""
                let state = (params as? [String: Any])?["state"] ?? NSNull()
                let data = try JSONSerialization.data(withJSONObject: state)
                try self.auth.set(self.authKey(server), String(decoding: data, as: UTF8.self))
                return nil
            case "cacheTools":
                self.toolCache[arguments["server"]?.string ?? ""] = (params as? [String: Any])?["tools"] ?? []
                return nil
            case "cachedTools":
                let names = Set(self.entries.map(\.name))
                return self.toolCache.filter { names.contains($0.key) }
            default: throw EngineError.unknownMethod("mcp.\(method)")
            }
        }
    }
}
