import Foundation

/// Secrets for extensions (API keys and the like): values in their own Keychain service, names and who may read them in
/// user defaults. Extensions get them as `process.env` and through `ctx.secrets`; the agent's shell, prompt, and files
/// never do. The user adds them in Settings; an extension may also store one for itself.
///
/// The engine's `secrets` service:
/// - `all` → `[{ name, value, extensions, owner }]`, for the engine to hand each extension what it may read;
/// - `set { name, value, extensions, owner }` (`extensions` nil: every extension), `delete { name }`.
@MainActor
public final class ExtensionSecretsService {
    private let defaults: UserDefaults
    private let secrets = KeychainService(service: "dev.pimobile.extension-secrets", synchronizable: true)
    private weak var engine: PiEngine?

    /// A secret without its value.
    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public let name: String
        /// The extensions that may read it; nil for every extension.
        public let extensions: [String]?
        /// The extension that stored it, when one did.
        public let owner: String?
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var metadata: [String: [String: Any]] {
        get { defaults.dictionary(forKey: "extensionSecrets") as? [String: [String: Any]] ?? [:] }
        set { defaults.set(newValue, forKey: "extensionSecrets") }
    }

    public var entries: [Entry] {
        metadata.map { name, info in
            Entry(name: name, extensions: info["extensions"] as? [String], owner: info["owner"] as? String)
        }
        .sorted { $0.name < $1.name }
    }

    /// Environment variable names: letters, digits, and underscores, not starting with a digit.
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    public func set(_ name: String, value: String, extensions: [String]?, owner: String? = nil) throws {
        guard Self.isValidName(name) else { throw EngineError.unknownMethod("secrets: \(name) is not a valid name (letters, digits, _)") }
        try secrets.set(name, value)
        var info: [String: Any] = [:]
        if let extensions { info["extensions"] = extensions }
        if let owner { info["owner"] = owner }
        metadata[name] = info
    }

    /// Changes who may read a secret, keeping its value.
    public func setExtensions(_ name: String, _ extensions: [String]?) {
        guard var info = metadata[name] else { return }
        if let extensions { info["extensions"] = extensions } else { info.removeValue(forKey: "extensions") }
        metadata[name] = info
    }

    public func delete(_ name: String) {
        try? secrets.delete(name)
        metadata.removeValue(forKey: name)
    }

    // MARK: - Engine service

    public func install(on engine: PiEngine) {
        self.engine = engine
        engine.register(service: "secrets") { [weak self] method, params in
            guard let self else { throw EngineError.unknownService("secrets") }
            let arguments = JSONValue(bridged: params)
            switch method {
            case "all":
                return try self.entries.map { entry -> [String: Any] in
                    [
                        "name": entry.name, "value": try self.secrets.get(entry.name) ?? "",
                        "extensions": entry.extensions ?? NSNull(), "owner": entry.owner ?? NSNull(),
                    ]
                }
            case "set":
                let extensions: [String]? = switch arguments["extensions"] {
                case .array(let names)?: names.compactMap(\.string)
                default: nil
                }
                try self.set(arguments["name"]?.string ?? "", value: arguments["value"]?.string ?? "", extensions: extensions, owner: arguments["owner"]?.string)
                return nil
            case "delete":
                self.delete(arguments["name"]?.string ?? "")
                return nil
            default: throw EngineError.unknownMethod("secrets.\(method)")
            }
        }
    }
}
