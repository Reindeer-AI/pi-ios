import CryptoKit
import Foundation
import PiRemote

/// Crabbox (openclaw/crabbox): a broker leases real Linux machines, and commands run on them over SSH. The broker URL,
/// the Crabbox token, and each lease's SSH key stay native: the token and keys live in their own Keychain service,
/// which the engine's `keychain` service cannot read, so neither extensions nor the agent ever see them.
///
/// The engine's `crabbox` service:
/// - `status` → `{ broker, signedIn, provider, identity }`;
/// - `request { method, path, body }` → `{ status, body }`, a broker call (`/v1/…`, not `/v1/auth/…`) with the token;
/// - `keygen { keyId }` → `{ publicKey }` (the same key again for the same id), `forgetKey { keyId }`;
/// - `exec { id, keyId, host, port, user, hostKey, command, stdinPath, stdoutPath }` runs a command on a leased box,
///   streaming its output as `crabbox.output { id, data, stderr }` engine commands (stdout goes to `stdoutPath` when
///   given), and replies `{ exitCode, hostKey }`; `kill { id }` stops it.
///
/// With a GitHub account (`github`), each box gets the token before its first command: in ~/.config/pi/github-token
/// (sent over SSH's stdin, readable only by the box's user), a git credential helper for https://github.com that reads
/// it, and runs export it as GH_TOKEN and GITHUB_TOKEN (the engine's run script), so `gh` and `git push` work there.
/// A renewed token replaces it, and signing out of GitHub removes it, at each box's next command. Output that comes back has the token masked.
@MainActor
public final class CrabboxService {
    private let defaults: UserDefaults
    private let secrets = KeychainService(service: "dev.pimobile.crabbox", synchronizable: true)
    private weak var engine: PiEngine?
    private var running: [String: Task<SSHExecResult, any Error>] = [:]
    /// The user's GitHub account, installed on boxes.
    public weak var github: GitHubService?
    /// Per box (`user@host:port`): the GitHub token's hash as installed, or "" when removed, this run of the app.
    private var githubOnBox: [String: Task<String, any Error>] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Settings

    /// The broker's base URL, such as `https://broker.example.com`.
    public var broker: String? { defaults.string(forKey: "crabboxBroker").flatMap { $0.isEmpty ? nil : $0 } }
    /// The provider leases ask for (`aws`, `hetzner`, …); nil leaves it to the broker's default.
    public var provider: String? { defaults.string(forKey: "crabboxProvider").flatMap { $0.isEmpty ? nil : $0 } }
    public var signedIn: Bool { (try? secrets.get("token")) != nil }
    /// Who the broker says the token belongs to, from the last check.
    public var identity: [String: Any]? {
        defaults.data(forKey: "crabboxIdentity").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// A new broker forgets the old one's token.
    public func setBroker(_ url: String?) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmed != broker else { return }
        defaults.set(trimmed, forKey: "crabboxBroker")
        signOut()
    }

    public func setProvider(_ provider: String?) {
        defaults.set(provider, forKey: "crabboxProvider")
    }

    /// Uses a token issued elsewhere (an operator token, or one from `crabbox login` on another machine), checked with
    /// `whoami` before it is kept.
    public func signIn(token: String) async throws -> [String: Any] {
        let identity = try await whoami(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        try secrets.set("token", token.trimmingCharacters(in: .whitespacesAndNewlines))
        return identity
    }

    public func signOut() {
        try? secrets.delete("token")
        defaults.removeObject(forKey: "crabboxIdentity")
    }

    /// Crabbox's GitHub login, as `crabbox login` does it: the broker returns a GitHub address, the browser (on this
    /// device) comes back to a listener here with a confirmation, and polling with a secret only this app knows then
    /// yields a token for the signed-in user.
    public func signInWithGitHub(open: (URL) -> Void) async throws -> [String: Any] {
        let callback = try await LoopbackCallback.start(parameter: "confirmation", title: "Crabbox login complete")
        defer { callback.close() }
        let pollSecret = Self.randomHex(32)
        let pollSecretHash = SHA256.hash(data: Data(pollSecret.utf8)).map { String(format: "%02x", $0) }.joined()
        var body: [String: Any] = ["pollSecretHash": pollSecretHash, "loopbackRedirectURI": callback.url.absoluteString]
        if let provider { body["provider"] = provider }
        let start = try await call("POST", "/v1/auth/github/start", body: body, token: nil).object()
        guard let loginID = start["loginID"] as? String, let address = (start["url"] as? String).flatMap(URL.init(string:)),
              address.scheme == "https"
        else { throw CrabboxError.broker("the broker did not return a GitHub login address") }
        open(address)

        let deadline = (start["expiresAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .now.addingTimeInterval(600)
        while Date.now < deadline {
            try await Task.sleep(for: .seconds(2))
            var poll: [String: Any] = ["loginID": loginID, "pollSecret": pollSecret]
            if let confirmation = callback.value { poll["browserConfirmation"] = confirmation }
            let reply = try await call("POST", "/v1/auth/github/poll", body: poll, token: nil).object()
            switch reply["status"] as? String {
            case "pending", "confirmation_required": continue
            case "complete":
                guard callback.value != nil, let token = reply["token"] as? String, !token.isEmpty else {
                    throw CrabboxError.broker("the login finished without this device's confirmation")
                }
                if provider == nil, let chosen = reply["provider"] as? String { setProvider(chosen) }
                return try await signIn(token: token)
            case "expired": throw CrabboxError.broker("the GitHub login expired")
            default: throw CrabboxError.broker("the GitHub login failed: \(reply["error"] as? String ?? "unknown error")")
            }
        }
        throw CrabboxError.broker("the GitHub login expired")
    }

    /// Checks the stored token (`/v1/whoami`) and remembers who it belongs to.
    @discardableResult
    public func whoami() async throws -> [String: Any] {
        guard let token = try secrets.get("token") else { throw CrabboxError.signedOut }
        return try await whoami(token: token)
    }

    private func whoami(token: String) async throws -> [String: Any] {
        let reply = try await call("GET", "/v1/whoami", body: nil, token: token)
        guard reply.status == 200 else { throw CrabboxError.broker(reply.message ?? "the broker refused the token (\(reply.status))") }
        let identity = try reply.object()
        defaults.set(try? JSONSerialization.data(withJSONObject: identity), forKey: "crabboxIdentity")
        return identity
    }

    // MARK: - Engine service

    public func install(on engine: PiEngine) {
        self.engine = engine
        engine.register(service: "crabbox") { [weak self] method, params in
            guard let self else { throw EngineError.unknownService("crabbox") }
            let arguments = JSONValue(bridged: params)
            switch method {
            case "status":
                return [
                    "broker": self.broker ?? NSNull(), "signedIn": self.signedIn, "provider": self.provider ?? NSNull(),
                    "identity": self.identity ?? NSNull(),
                ] as [String: Any]
            case "request": return try await self.request(arguments)
            case "keygen": return ["publicKey": try self.key(arguments["keyId"]?.string ?? "").publicKey]
            case "forgetKey":
                try self.secrets.delete("key:\(arguments["keyId"]?.string ?? "")")
                return nil
            case "exec": return try await self.exec(arguments)
            case "kill":
                self.running[arguments["id"]?.string ?? ""]?.cancel()
                return nil
            default: throw EngineError.unknownMethod("crabbox.\(method)")
            }
        }
    }

    private func request(_ arguments: JSONValue) async throws -> Any? {
        guard let token = try secrets.get("token") else { throw CrabboxError.signedOut }
        let path = arguments["path"]?.string ?? ""
        guard path.hasPrefix("/v1/"), !path.hasPrefix("/v1/auth/") else { throw CrabboxError.broker("\(path) is not a broker API path") }
        let body: Any? = switch arguments["body"] {
        case nil, .null: nil
        case let value?: value.bridged
        }
        // Only `Prefer` (respond-async lease creation) passes through; a lease creation may take minutes.
        let prefer = arguments["prefer"]?.string
        let timeout = arguments["timeout"]?.number ?? 60
        let reply = try await call(arguments["method"]?.string ?? "GET", path, body: body, token: token, prefer: prefer, timeout: timeout)
        let parsed = (try? JSONSerialization.jsonObject(with: reply.body, options: .fragmentsAllowed)) ?? String(decoding: reply.body, as: UTF8.self)
        return ["status": reply.status, "body": parsed] as [String: Any]
    }

    /// A lease's ed25519 key, made on first use.
    private func key(_ keyId: String) throws -> (privateKey: Curve25519.Signing.PrivateKey, publicKey: String) {
        guard !keyId.isEmpty else { throw CrabboxError.broker("missing keyId") }
        let privateKey: Curve25519.Signing.PrivateKey
        if let stored = try secrets.get("key:\(keyId)"), let raw = Data(base64Encoded: stored) {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        } else {
            privateKey = Curve25519.Signing.PrivateKey()
            try secrets.set("key:\(keyId)", privateKey.rawRepresentation.base64EncodedString())
        }
        return (privateKey, SSHKeys.publicKey(of: privateKey, comment: "pi-mobile-\(keyId)"))
    }

    private func exec(_ arguments: JSONValue) async throws -> Any? {
        guard let id = arguments["id"]?.string, let host = arguments["host"]?.string, let user = arguments["user"]?.string,
              let command = arguments["command"]?.string
        else { throw EngineError.unknownMethod("crabbox.exec: missing id, host, user, or command") }
        let target = SSHTarget(
            host: host, port: arguments["port"]?.number.map { Int($0) } ?? 22, user: user,
            privateKey: try key(arguments["keyId"]?.string ?? "").privateKey,
            hostKey: arguments["hostKey"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        )
        let githubToken = try await github?.currentToken()
        try await syncGitHub(githubToken, to: target)
        let token = githubToken.map { Data($0.utf8) }
        let stdin = arguments["stdinPath"]?.string.map { URL(filePath: $0) }
        let stdoutFile = try arguments["stdoutPath"]?.string.map { path -> FileHandle in
            FileManager.default.createFile(atPath: path, contents: nil)
            return try FileHandle(forWritingTo: URL(filePath: path))
        }
        defer { try? stdoutFile?.close() }

        // Output is forwarded to the engine strictly in order; the reply waits for the last of it.
        let (chunks, continuation) = AsyncStream<(Data, Bool)>.makeStream()
        let forwarding = Task { @MainActor [weak engine] in
            for await (chunk, isError) in chunks {
                _ = try? await engine?.command("crabbox.output", ["id": id, "data": chunk.base64EncodedString(), "stderr": isError])
            }
        }
        let task = Task.detached {
            try await SSHClient.exec(target, command: command, stdin: stdin) { data, isError in
                if !isError, let stdoutFile { stdoutFile.write(data) } else { continuation.yield((Self.masking(token, in: data), isError)) }
            }
        }
        running[id] = task
        defer { running[id] = nil }
        let result: SSHExecResult
        do {
            result = try await task.value
        } catch {
            continuation.finish()
            await forwarding.value
            throw error
        }
        continuation.finish()
        await forwarding.value
        return ["exitCode": result.exitStatus.map { Int($0) as Any } ?? NSNull(), "hostKey": result.hostKey] as [String: Any]
    }

    // MARK: - GitHub on boxes

    private static let githubSetup = [
        "umask 077 && mkdir -p ~/.config/pi && cat > ~/.config/pi/github-token",
        #"git config --global credential.https://github.com.helper '!f() { test "$1" = get && echo username=x-access-token && echo "password=$(cat ~/.config/pi/github-token)"; }; f'"#,
    ].joined(separator: " && ")
    private static let githubRemoval =
        "rm -f ~/.config/pi/github-token; git config --global --unset-all credential.https://github.com.helper 2>/dev/null; true"

    /// Puts the GitHub token on the box, or takes it off, when that changed since this app last did.
    private func syncGitHub(_ token: String?, to target: SSHTarget) async throws {
        let box = "\(target.user)@\(target.host):\(target.port)"
        let wanted = token.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } ?? ""
        if let previous = githubOnBox[box], (try? await previous.value) == wanted { return }
        let task = Task<String, any Error> {
            if let token {
                let file = FileManager.default.temporaryDirectory.appending(path: "github-\(UUID().uuidString)")
                FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
                defer { try? FileManager.default.removeItem(at: file) }
                let result = try await SSHClient.exec(target, command: Self.githubSetup, stdin: file) { _, _ in }
                guard result.exitStatus == 0 else { throw CrabboxError.broker("could not put the GitHub token on the box (exit \(result.exitStatus.map(String.init) ?? "?"))") }
            } else {
                _ = try await SSHClient.exec(target, command: Self.githubRemoval) { _, _ in }
            }
            return wanted
        }
        githubOnBox[box] = task
        do {
            _ = try await task.value
        } catch {
            githubOnBox[box] = nil
            throw error
        }
    }

    /// `data` with the token replaced, should a command print it.
    private nonisolated static func masking(_ token: Data?, in data: Data) -> Data {
        guard let token, !token.isEmpty, data.range(of: token) != nil else { return data }
        var masked = data
        while let range = masked.range(of: token) { masked.replaceSubrange(range, with: Data("[GitHub token]".utf8)) }
        return masked
    }

    // MARK: - HTTP

    private struct Reply {
        let status: Int
        /// Header names in lowercase.
        let headers: [String: String]
        let body: Data

        /// What went wrong: the broker's own error, or Cloudflare's refusal before the request reached the broker (a
        /// broker behind Cloudflare Access with WARP, called from a phone that is not on WARP).
        var message: String? {
            if let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String {
                return error
            }
            let text = String(decoding: body.prefix(4000), as: UTF8.self)
            if headers["cf-ray"] != nil || headers["server"]?.lowercased() == "cloudflare" || text.contains("Cloudflare") {
                return "Cloudflare refused the request (\(status)) before it reached the broker. If the broker is behind Cloudflare Access, turn on WARP (Cloudflare One) on this phone, signed in to your team, and try again."
            }
            let snippet = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            return snippet.isEmpty ? nil : "\(status): \(snippet)"
        }

        func object() throws -> [String: Any] {
            guard (200..<300).contains(status) else { throw CrabboxError.broker(message ?? "the broker replied \(status)") }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw CrabboxError.broker("the broker's reply is not JSON")
            }
            return object
        }
    }

    /// One broker call: https through URLSession, plain http (a broker inside a private tunnel such as WARP, which App
    /// Transport Security would refuse) over a direct connection.
    private func call(_ method: String, _ path: String, body: Any?, token: String?, prefer: String? = nil, timeout: TimeInterval = 60) async throws -> Reply {
        guard let broker, let url = URL(string: broker + path) else { throw CrabboxError.noBroker }
        var headers = ["Accept": "application/json"]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let prefer { headers["Prefer"] = prefer }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        if data != nil { headers["Content-Type"] = "application/json" }
        if url.scheme?.lowercased() == "http" {
            let reply = try await PlainHTTP.send(method, url, headers: headers, body: data, timeout: timeout)
            return Reply(status: reply.status, headers: reply.headers, body: reply.body)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = data
        request.timeoutInterval = timeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (body, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let replyHeaders = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { headers, field in
            headers["\(field.key)".lowercased()] = "\(field.value)"
        }
        return Reply(status: http?.statusCode ?? 0, headers: replyHeaders, body: body)
    }

    /// Diagnostics: a GET of a plain-http URL through each transport, reported to `log`.
    public static func probe(_ url: URL, log: @escaping @Sendable (String) -> Void) async {
        await NetProbe.run(url, log: log)
    }

    private static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

public enum CrabboxError: LocalizedError {
    case noBroker, signedOut
    case broker(String)

    public var errorDescription: String? {
        switch self {
        case .noBroker: "No Crabbox broker is set up (Settings → Crabbox)."
        case .signedOut: "Not signed in to the Crabbox broker (Settings → Crabbox)."
        case .broker(let message): message
        }
    }
}
