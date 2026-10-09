import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Hardware-backed keys for extensions (`pi.keys`): P-256 keys in the Secure Enclave (a software key in the simulator,
/// which has none), never leaving the device; optionally usable only after Face ID or Touch ID with the biometrics
/// enrolled now (the key is destroyed when they change). A key can carry a certificate, which makes it a TLS client
/// identity for the extension's `fetch(url, { clientKey })` (NetProxy).
///
/// Keys are kept apart per extension, by name, like extension secrets. As with those, extensions are trusted code the
/// user installed, sharing the engine's web view: the separation keeps them from mixing up keys; it is not a wall.
///
/// The engine's `keys` service, with `extension` the calling extension:
/// - `create { extension, name, biometry }` → key info (`biometry`: "none" or "current-set"); fails if it exists;
/// - `get { extension, name }` → key info, or null; `list { extension }` → [key info]; `delete { extension, name }`;
/// - `sign { extension, name, data, reason }` → `{ signature }`: ECDSA P-256 with SHA-256 over `data` (base64),
///   DER, base64; a biometric key asks for Face ID first, showing `reason`;
/// - `setCertificate { extension, name, chain }` → key info: PEM certificates, the key's own first.
/// Key info: `{ name, publicKey: { spkiDerBase64, rawXYBase64 (x ‖ y), x, y (base64url, as in a JWK) }, biometry, hardware,
/// certificate (subject) }`.
@MainActor
public final class ExtensionKeysService {
    private let defaults: UserDefaults
    private static let service = "dev.pimobile.extension-keys"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Index (what exists, per extension)

    private struct Entry: Codable {
        var biometry: String
        var hardware: Bool
        /// Simulator only: a biometric key the simulator can't lock (it has no passcode), checked with Face ID in code
        /// before each signature instead.
        var emulatedBiometry: Bool?
        var certificate: String?
        /// The certificates after the key's own (DER, base64), sent with it in a TLS handshake.
        var chain: [String]?
    }

    private var index: [String: [String: Entry]] {
        get { (defaults.data(forKey: "extensionKeys")).flatMap { try? JSONDecoder().decode([String: [String: Entry]].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "extensionKeys") }
    }

    private func tag(_ extensionName: String, _ name: String) -> Data {
        Data("\(Self.service)/\(extensionName)/\(name)".utf8)
    }

    private func label(_ extensionName: String, _ name: String) -> String {
        "\(Self.service)/\(extensionName)/\(name)"
    }

    // MARK: - Keys

    public func create(extension extensionName: String, name: String, biometry: String) throws -> [String: Any] {
        guard Self.isValidName(name) else { throw KeysError.message("\(name) is not a valid key name (letters, digits, . _ -)") }
        guard ["none", "current-set"].contains(biometry) else { throw KeysError.message("biometry is \"none\" or \"current-set\"") }
        if privateKey(extensionName, name) != nil { throw KeysError.message("a key named \(name) exists; get it, or delete it first") }
        let hardware = SecureEnclave.isAvailable
        var flags: SecAccessControlCreateFlags = hardware ? [.privateKeyUsage] : []
        // The simulator has no passcode, without which iOS refuses a biometric lock: there it's emulated (sign()).
        #if targetEnvironment(simulator)
        let emulated = biometry == "current-set"
        #else
        let emulated = false
        if biometry == "current-set" { flags.insert(.biometryCurrentSet) }
        #endif
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw KeysError.message("access control: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag(extensionName, name),
                kSecAttrLabel as String: label(extensionName, name),
                kSecAttrAccessControl as String: access,
            ] as [String: Any],
        ]
        if hardware { attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave }
        guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil else {
            throw KeysError.message("creating the key: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        index[extensionName, default: [:]][name] = Entry(biometry: biometry, hardware: hardware, emulatedBiometry: emulated ? true : nil)
        return try info(extensionName, name)
    }

    public func get(extension extensionName: String, name: String) -> [String: Any]? {
        try? info(extensionName, name)
    }

    public func list(extension extensionName: String) -> [[String: Any]] {
        (index[extensionName] ?? [:]).keys.sorted().compactMap { try? info(extensionName, $0) }
    }

    public func delete(extension extensionName: String, name: String) {
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag(extensionName, name)] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label(extensionName, name)] as CFDictionary)
        index[extensionName]?.removeValue(forKey: name)
    }

    /// Signs off the main thread: a biometric key's Face ID sheet blocks the signing call until it's answered.
    public func sign(extension extensionName: String, name: String, data: Data, reason: String) async throws -> String {
        guard let entry = index[extensionName]?[name] else { throw KeysError.message("no key named \(name)") }
        let tag = tag(extensionName, name)
        let biometric = entry.biometry != "none"
        let emulated = entry.emulatedBiometry == true
        let prompt = reason.isEmpty ? "Use \(name) for \(extensionName)" : reason
        let signature = try await Task.detached {
            if emulated { try await Self.checkBiometrics(prompt) }
            return try Self.signNow(tag: tag, name: name, biometric: biometric && !emulated, prompt: prompt, data: data)
        }.value
        return signature.base64EncodedString()
    }

    /// Simulator only: Face ID asked in code, for a biometric key the simulator couldn't lock.
    nonisolated private static func checkBiometrics(_ prompt: String) async throws {
        let context = LAContext()
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: prompt)
        } catch let error as LAError where error.code == .userCancel || error.code == .systemCancel || error.code == .appCancel {
            throw KeysError.message("cancelled")
        } catch {
            throw KeysError.message("biometrics: \(error.localizedDescription)")
        }
    }

    /// Isolated to nothing: it runs on a background thread (see the Thread subclasses for why closures written in
    /// main-actor code are avoided there).
    nonisolated private static func signNow(tag: Data, name: String, biometric: Bool, prompt: String, data: Data) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        if biometric {
            let context = LAContext()
            context.localizedReason = prompt
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let key = item else { throw KeysError.message("no key named \(name) (\(status))") }
        var error: Unmanaged<CFError>?
        // swiftlint:disable:next force_cast
        guard let signature = SecKeyCreateSignature(key as! SecKey, .ecdsaSignatureMessageX962SHA256, data as CFData, &error) else {
            let failure = error?.takeRetainedValue()
            let code = failure.map { CFErrorGetCode($0) } ?? 0
            if code == Int(errSecUserCanceled) || code == LAError.userCancel.rawValue || code == LAError.systemCancel.rawValue {
                throw KeysError.message("cancelled")
            }
            throw KeysError.message("signing: \(failure?.localizedDescription ?? "?")")
        }
        return signature as Data
    }

    public func setCertificate(extension extensionName: String, name: String, chain: [String]) throws -> [String: Any] {
        guard var entry = index[extensionName]?[name], let publicKey = publicKeyData(extensionName, name) else {
            throw KeysError.message("no key named \(name)")
        }
        let certificates = try chain.flatMap(Self.certificates(pem:))
        guard let leaf = certificates.first else { throw KeysError.message("no certificate in the chain") }
        guard let leafKey = SecCertificateCopyKey(leaf).flatMap({ SecKeyCopyExternalRepresentation($0, nil) as Data? }), leafKey == publicKey else {
            throw KeysError.message("the first certificate is not for this key")
        }
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label(extensionName, name)] as CFDictionary)
        let status = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: leaf,
            kSecAttrLabel as String: label(extensionName, name),
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw KeysError.message("storing the certificate (\(status))") }
        entry.certificate = SecCertificateCopySubjectSummary(leaf) as String? ?? "certificate"
        entry.chain = certificates.dropFirst().map { (SecCertificateCopyData($0) as Data).base64EncodedString() }
        index[extensionName]?[name] = entry
        identityChanged?(extensionName, name)
        return try info(extensionName, name)
    }

    /// Called when a key's certificate changes, so connections made with the old one are dropped (NetProxy).
    var identityChanged: ((String, String) -> Void)?

    /// The TLS client identity of a key with a certificate, and the certificates to send after it.
    func identity(extension extensionName: String, name: String) -> (SecIdentity, [SecCertificate])? {
        let label = "\(Self.service)/\(extensionName)/\(name)"
        var item: CFTypeRef?
        guard SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ] as CFDictionary, &item) == errSecSuccess, let found = item else { return nil }
        // swiftlint:disable:next force_cast
        let identity = found as! SecIdentity
        let chain = (index[extensionName]?[name]?.chain ?? [])
            .compactMap { Data(base64Encoded: $0).flatMap { SecCertificateCreateWithData(nil, $0 as CFData) } }
        return (identity, chain)
    }

    // MARK: - Helpers

    private func keyQuery(_ extensionName: String, _ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag(extensionName, name),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
    }

    private func privateKey(_ extensionName: String, _ name: String) -> SecKey? {
        var query = keyQuery(extensionName, name)
        // Finding a biometric key must not ask for Face ID.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let found = item else { return nil }
        // swiftlint:disable:next force_cast
        return (found as! SecKey)
    }

    /// The public key, X9.63 (04 ‖ x ‖ y).
    private func publicKeyData(_ extensionName: String, _ name: String) -> Data? {
        privateKey(extensionName, name).flatMap(SecKeyCopyPublicKey).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
    }

    private func info(_ extensionName: String, _ name: String) throws -> [String: Any] {
        guard let entry = index[extensionName]?[name], let raw = publicKeyData(extensionName, name), raw.count == 65 else {
            throw KeysError.message("no key named \(name)")
        }
        // SubjectPublicKeyInfo for an uncompressed P-256 point.
        let spki = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]) + raw
        return [
            "name": name,
            "publicKey": [
                "spkiDerBase64": spki.base64EncodedString(),
                "rawXYBase64": raw[1...64].base64EncodedString(),
                "x": Self.base64url(raw[1...32]),
                "y": Self.base64url(raw[33...64]),
            ],
            "biometry": entry.biometry,
            "hardware": entry.hardware,
            "certificate": entry.certificate ?? NSNull(),
        ]
    }

    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func certificates(pem: String) throws -> [SecCertificate] {
        let blocks = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
        let parsed = blocks.compactMap { block -> SecCertificate? in
            let body = block.components(separatedBy: "-----END CERTIFICATE-----").first ?? ""
            let base64 = body.components(separatedBy: .whitespacesAndNewlines).joined()
            return Data(base64Encoded: base64).flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        }
        if parsed.isEmpty, !pem.isEmpty { throw KeysError.message("not a PEM certificate") }
        return parsed
    }

    // MARK: - Engine service

    public func install(on engine: PiEngine) {
        engine.register(service: "keys") { [weak self] method, params in
            guard let self else { throw EngineError.unknownService("keys") }
            let arguments = JSONValue(bridged: params)
            let extensionName = arguments["extension"]?.string ?? ""
            let name = arguments["name"]?.string ?? ""
            guard !extensionName.isEmpty else { throw KeysError.message("keys: no extension") }
            switch method {
            case "create": return try self.create(extension: extensionName, name: name, biometry: arguments["biometry"]?.string ?? "none")
            case "get": return self.get(extension: extensionName, name: name)
            case "list": return self.list(extension: extensionName)
            case "delete":
                self.delete(extension: extensionName, name: name)
                return nil
            case "sign":
                guard let data = Data(base64Encoded: arguments["data"]?.string ?? "") else { throw KeysError.message("data is not base64") }
                return ["signature": try await self.sign(extension: extensionName, name: name, data: data, reason: arguments["reason"]?.string ?? "")]
            case "setCertificate":
                let chain: [String] = switch arguments["chain"] {
                case .array(let items)?: items.compactMap(\.string)
                case .string(let one)?: [one]
                default: []
                }
                return try self.setCertificate(extension: extensionName, name: name, chain: chain)
            default: throw EngineError.unknownMethod("keys.\(method)")
            }
        }
        engine.clientIdentity = { [weak self] extensionName, name in self?.identity(extension: extensionName, name: name) }
        identityChanged = { [weak engine] extensionName, name in engine?.forgetClientIdentity(extension: extensionName, name: name) }
    }
}

public enum KeysError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
