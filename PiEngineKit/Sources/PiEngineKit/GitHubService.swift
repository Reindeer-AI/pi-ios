import CryptoKit
import Foundation

/// The user's GitHub account, for git and `gh` on Crabbox boxes and GitHub API calls from the phone. The token stays
/// native, in its own Keychain service that the engine's `keychain` service cannot read: Crabbox installs it on a box
/// over SSH, and API calls add it here, so neither extensions nor the agent ever see it.
///
/// Each device signs in on its own, the token on this device only: a device login's token lasts eight hours and each
/// refresh replaces the refresh token, so devices sharing one had their refreshes refused once another had refreshed.
///
/// The engine's `github` service:
/// - `status` → `{ signedIn, login, name, scopes }`;
/// - `request { method, path, body, accept }` → `{ status, body }`, a call to api.github.com (`path` starts with `/`);
/// - `download { owner, repo, path, ref, destination }` → `{ sha, ref, files, bytes, file }`: a repository's folder (or
///   one file) at a branch, tag or commit, written to `destination` in the app's container (extensions from GitHub);
///   `sha` is its tree's hash, which changes only when something in it does;
/// - `check { owner, repo, path, ref }` → `{ sha, ref }`, that hash now, for updates.
/// Both work for public repositories without a sign-in.
@MainActor
public final class GitHubService {
    private let defaults: UserDefaults
    private let secrets = KeychainService(service: "dev.pimobile.github.device")

    /// The OAuth app's client ID for the device login (`PIGitHubClientID` in Info.plist); without one, only a pasted
    /// token signs in.
    public let clientID: String?

    public init(defaults: UserDefaults = .standard, clientID: String? = Bundle.main.object(forInfoDictionaryKey: "PIGitHubClientID") as? String) {
        self.defaults = defaults
        self.clientID = clientID.flatMap { $0.isEmpty ? nil : $0 }
        keepSignInHere()
    }

    /// A sign-in synced before each device kept its own: this device keeps the one it had (unless it has its own), and
    /// takes it out of iCloud, so the other devices sign in again.
    private func keepSignInHere() {
        let iCloud = KeychainService(service: "dev.pimobile.github", synchronizable: true)
        guard let synced = try? iCloud.get("token") else { return }
        if token == nil {
            guard (try? secrets.set("token", synced)) != nil else { return }
            if let refresh = try? iCloud.get("refresh") { try? secrets.set("refresh", refresh) }
        }
        try? iCloud.delete("token")
        try? iCloud.delete("refresh")
    }

    // MARK: - Account

    public var signedIn: Bool { token != nil }
    /// Who GitHub says the token belongs to, from the last check: `login`, `name`, `scopes`; nil without a token (one
    /// another device took out of iCloud, say).
    public var identity: [String: Any]? {
        guard signedIn else { return nil }
        return defaults.data(forKey: "githubIdentity").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The stored token as it is; `currentToken()` refreshes one that expires.
    var token: String? { (try? secrets.get("token")).flatMap { $0 } }

    /// The token, refreshed first when it expires within five minutes (a GitHub App's user tokens last eight hours,
    /// and a device login's refresh without the app's secret); nil when signed out.
    func currentToken() async throws -> String? {
        guard let token else { return nil }
        let expiry = defaults.object(forKey: "githubTokenExpiry") as? Date
        guard let expiry, expiry.timeIntervalSinceNow < 300, let clientID, let refreshToken = try secrets.get("refresh") else { return token }
        if let refreshing { return try await refreshing.value }
        let task = Task { () throws -> String in
            let reply = try await form("https://github.com/login/oauth/access_token", [
                "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken,
            ])
            guard let fresh = reply["access_token"] as? String, !fresh.isEmpty else {
                if expiry.timeIntervalSinceNow > 0 { return token }
                throw GitHubError.message("The GitHub sign-in expired (\(reply["error_description"] as? String ?? "it could not be renewed")); sign in again in Settings → GitHub.")
            }
            try keep(reply, token: fresh)
            return fresh
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private var refreshing: Task<String, any Error>?

    /// A device login's token, with its refresh token and expiry when the GitHub App's tokens expire.
    private func keep(_ reply: [String: Any], token: String) throws {
        try secrets.set("token", token)
        if let refresh = reply["refresh_token"] as? String, !refresh.isEmpty { try secrets.set("refresh", refresh) } else { try? secrets.delete("refresh") }
        let lifetime = (reply["expires_in"] as? NSNumber)?.doubleValue
        defaults.set(lifetime.map { Date.now.addingTimeInterval($0) }, forKey: "githubTokenExpiry")
    }

    /// Uses a token made elsewhere (a fine-grained or classic personal access token, or `gh auth token`), checked with
    /// `GET /user` before it is kept.
    @discardableResult
    public func signIn(token: String) async throws -> [String: Any] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = try await check(trimmed)
        try keep([:], token: trimmed)
        return identity
    }

    /// Keeps a token without checking it with GitHub (for tests against a box that never calls GitHub).
    public func signInUnchecked(token: String) throws {
        try keep([:], token: token)
        defaults.set(try? JSONSerialization.data(withJSONObject: ["login": "unchecked"]), forKey: "githubIdentity")
    }

    public func signOut() {
        try? secrets.delete("token")
        try? secrets.delete("refresh")
        defaults.removeObject(forKey: "githubIdentity")
        defaults.removeObject(forKey: "githubTokenExpiry")
    }

    /// The scopes a device login asks for: what `gh auth login` asks for.
    public static let scopes = "repo read:org gist workflow"

    /// What the user enters at GitHub during a device login.
    public struct DeviceCode: Sendable {
        public let userCode: String
        public let verificationURL: URL
    }

    /// GitHub's device login (what `gh auth login` does): `show` gets a code for the user to enter at github.com/login/device,
    /// then this polls until they approve it, and keeps the token.
    @discardableResult
    public func signInWithDevice(show: (DeviceCode) -> Void) async throws -> [String: Any] {
        guard let clientID else { throw GitHubError.message("This build has no GitHub app for signing in; use a token.") }
        let start = try await form("https://github.com/login/device/code", ["client_id": clientID, "scope": Self.scopes])
        guard let deviceCode = start["device_code"] as? String, let userCode = start["user_code"] as? String,
              let url = (start["verification_uri"] as? String).flatMap(URL.init(string:))
        else { throw GitHubError.message(start["error_description"] as? String ?? "GitHub did not start the login") }
        show(DeviceCode(userCode: userCode, verificationURL: url))

        var interval = (start["interval"] as? NSNumber)?.doubleValue ?? 5
        let deadline = Date.now.addingTimeInterval((start["expires_in"] as? NSNumber)?.doubleValue ?? 900)
        while Date.now < deadline {
            try await Task.sleep(for: .seconds(interval))
            // The user approves in Safari while iOS suspends this app: a poll cut off by that is simply tried again.
            let reply: [String: Any]
            do {
                reply = try await form("https://github.com/login/oauth/access_token", [
                    "client_id": clientID, "device_code": deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
            } catch is URLError {
                continue
            }
            if let token = reply["access_token"] as? String, !token.isEmpty {
                let identity = try await check(token)
                try keep(reply, token: token)
                return identity
            }
            switch reply["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval = (reply["interval"] as? NSNumber)?.doubleValue ?? interval + 5
            case "expired_token": throw GitHubError.message("The GitHub code expired; start again.")
            case "access_denied": throw GitHubError.message("The GitHub login was cancelled.")
            default: throw GitHubError.message(reply["error_description"] as? String ?? "The GitHub login failed.")
            }
        }
        throw GitHubError.message("The GitHub code expired; start again.")
    }

    private func check(_ token: String) async throws -> [String: Any] {
        let (body, response) = try await api("GET", "/user", body: nil, token: token)
        guard response.statusCode == 200, let user = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw GitHubError.message(response.statusCode == 401 ? "GitHub refused the token." : "GitHub replied \(response.statusCode) for the token.")
        }
        let scopes = (response.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let identity: [String: Any] = ["login": user["login"] ?? "", "name": user["name"] ?? NSNull(), "scopes": scopes]
        defaults.set(try? JSONSerialization.data(withJSONObject: identity), forKey: "githubIdentity")
        return identity
    }

    // MARK: - Engine service

    public func install(on engine: PiEngine) {
        engine.register(service: "github") { [weak self] method, params in
            guard let self else { throw EngineError.unknownService("github") }
            let arguments = JSONValue(bridged: params)
            switch method {
            case "status":
                let identity = self.identity
                return [
                    "signedIn": self.signedIn, "login": identity?["login"] ?? NSNull(), "name": identity?["name"] ?? NSNull(),
                    "scopes": identity?["scopes"] ?? [],
                ] as [String: Any]
            case "request": return try await self.request(arguments)
            case "check":
                let found = try await self.locate(arguments)
                return ["sha": found.sha, "ref": found.ref]
            case "download": return try await self.download(arguments)
            default: throw EngineError.unknownMethod("github.\(method)")
            }
        }
    }

    private func request(_ arguments: JSONValue) async throws -> Any? {
        guard let token = try await currentToken() else { throw GitHubError.message("Not signed in to GitHub (Settings → GitHub).") }
        let path = arguments["path"]?.string ?? ""
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { throw GitHubError.message("\(path) is not an api.github.com path") }
        let body: Any? = switch arguments["body"] {
        case nil, .null: nil
        case let value?: value.bridged
        }
        let (data, response) = try await api(arguments["method"]?.string ?? "GET", path, body: body, token: token, accept: arguments["accept"]?.string)
        let text = String(decoding: data, as: UTF8.self)
        let parsed = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? text
        return ["status": response.statusCode, "body": parsed] as [String: Any]
    }

    // MARK: - Folders (extensions installed from GitHub)

    private struct Located {
        let owner: String, repo: String, path: String, ref: String, sha: String
        let isFile: Bool
        let token: String?
    }

    /// Finds the folder (or file) `path` of a repository at `ref` (default: its default branch), walking the tree one
    /// level at a time so a large repository's truncated listings never matter.
    private func locate(_ arguments: JSONValue) async throws -> Located {
        let owner = arguments["owner"]?.string ?? "", repo = arguments["repo"]?.string ?? ""
        let path = (arguments["path"]?.string ?? "").split(separator: "/").map(String.init)
        guard [owner, repo].allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil }) else {
            throw GitHubError.message("\(owner)/\(repo) is not a GitHub repository name")
        }
        let token = try await currentToken()
        let base = "/repos/\(owner)/\(repo)"
        var ref = arguments["ref"]?.string ?? ""
        if ref.isEmpty {
            guard let branch = try await json(base, token: token)["default_branch"] as? String else {
                throw GitHubError.message("GitHub has no repository \(owner)/\(repo)\(token == nil ? " (sign in to GitHub in Settings for a private one)" : ", or this account can't see it")")
            }
            ref = branch
        }
        // The commit: `ref` is one, or a branch or tag (whose name may hold slashes, so it's looked up as a ref).
        var commit: String?
        if ref.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil {
            commit = ref
        } else {
            let escaped = ref.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            for kind in ["heads", "tags"] {
                guard let object = try await json("\(base)/git/ref/\(kind)/\(escaped)", token: token)["object"] as? [String: Any],
                      var sha = object["sha"] as? String else { continue }
                if object["type"] as? String == "tag", let tagged = try await json("\(base)/git/tags/\(sha)", token: token)["object"] as? [String: Any],
                   let target = tagged["sha"] as? String { sha = target }
                commit = sha
                break
            }
        }
        guard let commit, let rootTree = (try await json("\(base)/git/commits/\(commit)", token: token)["tree"] as? [String: Any])?["sha"] as? String else {
            throw GitHubError.message("\(owner)/\(repo) has no branch, tag or commit \(ref)\(token == nil ? " (sign in to GitHub in Settings for a private repository)" : "")")
        }
        var tree = try await json("\(base)/git/trees/\(rootTree)", token: token)
        var sha = rootTree
        var isFile = false
        for (index, name) in path.enumerated() {
            let entries = tree["tree"] as? [[String: Any]] ?? []
            guard let entry = entries.first(where: { $0["path"] as? String == name }), let entrySha = entry["sha"] as? String else {
                throw GitHubError.message("\(owner)/\(repo) has no \(path.prefix(index + 1).joined(separator: "/")) at \(ref)")
            }
            sha = entrySha
            if entry["type"] as? String == "blob", index == path.count - 1 {
                isFile = true
            } else if entry["type"] as? String == "tree" {
                tree = try await json("\(base)/git/trees/\(entrySha)", token: token)
            } else {
                throw GitHubError.message("\(path.prefix(index + 1).joined(separator: "/")) in \(owner)/\(repo) is not a folder or file")
            }
        }
        return Located(owner: owner, repo: repo, path: path.joined(separator: "/"), ref: ref, sha: sha, isFile: isFile, token: token)
    }

    private func download(_ arguments: JSONValue) async throws -> Any? {
        let located = try await locate(arguments)
        // Only into the app's own container.
        let home = URL(filePath: NSHomeDirectory()).standardizedFileURL.path()
        let destination = URL(filePath: arguments["destination"]?.string ?? "").standardizedFileURL
        guard destination.path().hasPrefix(home), destination.path() != home else { throw GitHubError.message("not a folder of pi's: \(destination.path())") }
        let base = "/repos/\(located.owner)/\(located.repo)"
        var files: [(path: String, sha: String)] = []
        if located.isFile {
            files = [(String(located.path.split(separator: "/").last ?? "file"), located.sha)]
        } else {
            let tree = try await json("\(base)/git/trees/\(located.sha)?recursive=1", token: located.token)
            if tree["truncated"] as? Bool == true { throw GitHubError.message("\(located.path) in \(located.owner)/\(located.repo) has too many files to install") }
            let blobs = (tree["tree"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "blob" && $0["mode"] as? String != "120000" }
            let size = blobs.reduce(0) { $0 + ($1["size"] as? Int ?? 0) }
            guard blobs.count <= 2000, size <= 100_000_000 else { throw GitHubError.message("\(located.path) is too big to install (\(blobs.count) files, \(size / 1_000_000) MB)") }
            files = blobs.compactMap { blob in (blob["path"] as? String).flatMap { path in (blob["sha"] as? String).map { (path, $0) } } }
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var bytes = 0
        for file in files {
            let target = destination.appending(path: file.path).standardizedFileURL
            guard target.path().hasPrefix(destination.path()) else { continue }
            let (data, response) = try await api("GET", "\(base)/git/blobs/\(file.sha)", body: nil, token: located.token, accept: "application/vnd.github.raw")
            guard response.statusCode == 200 else { throw GitHubError.message("GitHub answered \(response.statusCode) for \(file.path)") }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
            bytes += data.count
        }
        return [
            "sha": located.sha, "ref": located.ref, "files": files.count, "bytes": bytes,
            "file": located.isFile ? files[0].path : NSNull(),
        ] as [String: Any]
    }

    private func json(_ path: String, token: String?) async throws -> [String: Any] {
        let (data, response) = try await api("GET", path, body: nil, token: token)
        guard response.statusCode == 200 else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - HTTP

    private func api(_ method: String, _ path: String, body: Any?, token: String?, accept: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "https://api.github.com" + path) else { throw GitHubError.message("bad path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue(accept ?? "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.message("no HTTP reply from GitHub") }
        return (data, http)
    }

    /// A form POST to github.com's login endpoints, answered in JSON.
    private func form(_ address: String, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

public enum GitHubError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
