import Foundation
import WebKit

/// Replays the engine's `pi://app/net` requests with URLSession and streams responses back to WebKit.
///
/// The engine sends the real target in `x-pi-target` and the original request headers as base64 JSON
/// (`[[name, value], ...]`) in `x-pi-headers`; headers WebKit adds to the scheme request are ignored. Response bodies are
/// forwarded chunk by chunk, so server-sent events reach the engine as they arrive.
///
/// WebKit reports every failed scheme task to the page as "Load failed", which says nothing and which pi does not
/// retry. The engine names each request (`x-pi-request`) and asks `failure(id)` for the real reason: a dropped
/// connection, a timeout, no network (worded as a network error, which pi retries).
@MainActor
final class NetProxy: NSObject {
    /// Optional diagnostics: one line per request start, response, and completion.
    var trace: ((String) -> Void)?
    /// A request that failed, and why (for the log; the engine reads the reason with `failure(_:)`).
    var onFailure: ((String) -> Void)?
    /// A request with `x-pi-client-key` (an extension's `fetch(url, { clientKey })`) presents that key's certificate when
    /// the server asks for one; it runs in a session of its own, so no connection is shared with requests without it.
    var clientIdentity: ((String, String) -> (SecIdentity, [SecCertificate])?)?
    /// Replaces `{{vault:ID/FIELD}}` in a request (`VaultService.resolve`), for the extension that sent it (`x-pi-extension`).
    var vaultResolver: ((URLRequest, String) async throws -> URLRequest)?
    /// Requests waiting for the vault (the consent sheet and Face ID); a stopped one is dropped when it comes back.
    private var resolving: Set<ObjectIdentifier> = []
    private var clientSessions: [String: URLSession] = [:]
    private var clientKeys: [Int: (extension: String, name: String)] = [:]
    /// fetch's redirect mode when it isn't "follow" (`x-pi-redirect`): "error" fails on a redirect, "manual" returns it.
    private var redirectModes: [Int: String] = [:]

    private var session: URLSession!
    private var dataTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var schemeTasks: [Int: any WKURLSchemeTask] = [:]
    /// The engine's name for each request in flight, and the reasons recent ones failed.
    private var requestIds: [Int: String] = [:]
    private var failures: [String: String] = [:]
    private var failureOrder: [String] = []

    /// URLSession already decoded the body; these would describe the wire format, not what WebKit receives.
    private static let droppedResponseHeaders: Set<String> = ["content-encoding", "content-length", "transfer-encoding"]
    /// URLSession manages these itself.
    private static let droppedRequestHeaders: Set<String> = ["host", "content-length", "connection"]

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Model streams can idle for minutes while a model thinks before its first token.
        configuration.timeoutIntervalForRequest = 15 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    func start(_ schemeTask: any WKURLSchemeTask) {
        let incoming = schemeTask.request
        guard let target = incoming.value(forHTTPHeaderField: "x-pi-target").flatMap(URL.init(string:)),
              let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            return fail(schemeTask, URLError(.badURL))
        }

        var request = URLRequest(url: target)
        request.httpMethod = incoming.httpMethod ?? "GET"
        for (name, value) in Self.decodeHeaders(incoming.value(forHTTPHeaderField: "x-pi-headers"))
            where !Self.droppedRequestHeaders.contains(name.lowercased()) {
            request.addValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = incoming.httpBody ?? incoming.httpBodyStream.map(Self.readAll)

        // Values from the vault (`{{vault:…}}`) in an extension's request: the consent sheet and Face ID first, then the
        // request as resolved. The engine's own requests (to models) only ever carry such text as conversation, such as an
        // extension's docs the agent read: resolving it failed every request of the session.
        let requester = incoming.value(forHTTPHeaderField: "x-pi-extension")
        let usesVault = requester != nil && (request.httpBody.map { String(decoding: $0, as: UTF8.self).contains("{{vault:") } == true
            || request.allHTTPHeaderFields?.values.contains { $0.contains("{{vault:") } == true)
        if usesVault, let requester {
            guard let vaultResolver else { return fail(schemeTask, VaultError("The vault isn't available")) }
            let key = ObjectIdentifier(schemeTask)
            resolving.insert(key)
            Task { @MainActor in
                do {
                    let resolved = try await vaultResolver(request, requester)
                    guard resolving.remove(key) != nil else { return }
                    send(resolved, for: schemeTask, incoming: incoming, target: target)
                } catch {
                    guard resolving.remove(key) != nil else { return }
                    fail(schemeTask, error)
                }
            }
            return
        }
        send(request, for: schemeTask, incoming: incoming, target: target)
    }

    private func send(_ request: URLRequest, for schemeTask: any WKURLSchemeTask, incoming: URLRequest, target: URL) {
        var taskSession: URLSession = session
        let clientKey = Self.decodeClientKey(incoming.value(forHTTPHeaderField: "x-pi-client-key"))
        if let clientKey { taskSession = clientSession(clientKey.extension, clientKey.name) }
        let dataTask = taskSession.dataTask(with: request)
        if let clientKey { clientKeys[dataTask.taskIdentifier] = clientKey }
        if let mode = incoming.value(forHTTPHeaderField: "x-pi-redirect"), mode == "error" || mode == "manual" {
            redirectModes[dataTask.taskIdentifier] = mode
        }
        trace?("→ #\(dataTask.taskIdentifier) \(request.httpMethod ?? "GET") \(target.absoluteString) body=\(request.httpBody?.count ?? 0)B")
        dataTasks[ObjectIdentifier(schemeTask)] = dataTask
        schemeTasks[dataTask.taskIdentifier] = schemeTask
        if let id = incoming.value(forHTTPHeaderField: "x-pi-request") { requestIds[dataTask.taskIdentifier] = id }
        dataTask.resume()
    }

    func stop(_ schemeTask: any WKURLSchemeTask) {
        resolving.remove(ObjectIdentifier(schemeTask))
        guard let dataTask = dataTasks.removeValue(forKey: ObjectIdentifier(schemeTask)) else { return }
        trace?("✕ #\(dataTask.taskIdentifier) stopped by WebKit")
        schemeTasks.removeValue(forKey: dataTask.taskIdentifier)
        requestIds.removeValue(forKey: dataTask.taskIdentifier)
        dataTask.cancel()
    }

    private func clientSession(_ extensionName: String, _ name: String) -> URLSession {
        let key = "\(extensionName)/\(name)"
        if let existing = clientSessions[key] { return existing }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15 * 60
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        clientSessions[key] = created
        return created
    }

    func forgetClientSession(extension extensionName: String, name: String) {
        clientSessions.removeValue(forKey: "\(extensionName)/\(name)")?.finishTasksAndInvalidate()
    }

    /// `x-pi-client-key`: base64 JSON `{ extension, name }`, set by the engine for an extension's own key.
    private static func decodeClientKey(_ value: String?) -> (extension: String, name: String)? {
        guard let value, let data = Data(base64Encoded: value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extensionName = object["extension"] as? String, let name = object["name"] as? String else { return nil }
        return (extensionName, name)
    }

    /// Why the request the engine named `id` failed, if it did.
    func failure(_ id: String) -> String? {
        failures[id]
    }

    private func record(_ error: Error, for taskIdentifier: Int, host: String? = nil) {
        guard let id = requestIds.removeValue(forKey: taskIdentifier), let reason = Self.reason(error) else { return }
        remember(reason, for: id)
        onFailure?("\(host ?? "?"): \(reason)")
    }

    private func remember(_ reason: String, for id: String) {
        failures[id] = reason
        failureOrder.append(id)
        if failureOrder.count > 64 { failures.removeValue(forKey: failureOrder.removeFirst()) }
    }

    /// The error as pi should read it; transient ones say "network error", which pi retries. Nil for a cancellation.
    private static func reason(_ error: Error) -> String? {
        let urlError = error as? URLError
        if urlError?.code == .cancelled { return nil }
        let transient: Set<URLError.Code> = [
            .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
            .internationalRoamingOff, .callIsActive, .dataNotAllowed, .secureConnectionFailed, .backgroundSessionWasDisconnected,
        ]
        let code = (error as NSError).code
        if let urlError, transient.contains(urlError.code) { return "network error: \(error.localizedDescription) (\(code))" }
        return "\(error.localizedDescription) (\(code))"
    }

    /// Fails a request before it is sent (a bad target, the vault), keeping the reason for the engine and the log.
    private func fail(_ schemeTask: any WKURLSchemeTask, _ error: Error) {
        let reason = error.localizedDescription
        if let id = schemeTask.request.value(forHTTPHeaderField: "x-pi-request") { remember(reason, for: id) }
        onFailure?("\(schemeTask.request.value(forHTTPHeaderField: "x-pi-target").flatMap { URL(string: $0)?.host() } ?? "?"): \(reason)")
        schemeTask.didFailWithError(error)
    }

    /// Removes a finished request's bookkeeping and returns its scheme task, or nil if WebKit already stopped it.
    private func finish(_ dataTask: URLSessionTask) -> (any WKURLSchemeTask)? {
        guard let schemeTask = schemeTasks.removeValue(forKey: dataTask.taskIdentifier) else { return nil }
        dataTasks.removeValue(forKey: ObjectIdentifier(schemeTask))
        return schemeTask
    }

    private static func decodeHeaders(_ encoded: String?) -> [(String, String)] {
        guard let encoded, let data = Data(base64Encoded: encoded),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[String]]
        else { return [] }
        return pairs.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    private static func readAll(_ stream: InputStream) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        stream.open()
        defer { stream.close() }
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension NetProxy: URLSessionDataDelegate {
    // The session's delegate queue is the main queue.

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let schemeTask = schemeTasks[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
                return completionHandler(.cancel)
            }
            // A redirect the request said not to follow (redirect: "error"): it fails, as fetch does.
            if redirectModes[dataTask.taskIdentifier] == "error", (300..<400).contains(http.statusCode) {
                let refused = NSError(domain: "pi.net", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "\(http.statusCode) redirect to \(http.value(forHTTPHeaderField: "Location") ?? "?") refused (redirect: error)",
                ])
                record(refused, for: dataTask.taskIdentifier)
                _ = finish(dataTask)
                schemeTask.didFailWithError(refused)
                return completionHandler(.cancel)
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                guard let name = name as? String, let value = value as? String,
                      !Self.droppedResponseHeaders.contains(name.lowercased())
                else { continue }
                headers[name] = value
            }
            let forwarded = HTTPURLResponse(
                url: schemeTask.request.url!,
                statusCode: http.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            trace?("← #\(dataTask.taskIdentifier) \(http.statusCode) \(headers["Content-Type"] ?? "")")
            schemeTask.didReceive(forwarded)
            completionHandler(.allow)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            trace?("  #\(dataTask.taskIdentifier) +\(data.count)B")
            schemeTasks[dataTask.taskIdentifier]?.didReceive(data)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        MainActor.assumeIsolated {
            // "error" and "manual" get the redirect response itself, not where it points.
            completionHandler(redirectModes[task.taskIdentifier] == nil ? request : nil)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
                return completionHandler(.performDefaultHandling, nil)
            }
            guard let key = clientKeys[task.taskIdentifier], let (identity, chain) = clientIdentity?(key.extension, key.name) else {
                trace?("  #\(task.taskIdentifier) the server asks for a client certificate; none given")
                return completionHandler(.performDefaultHandling, nil)
            }
            trace?("  #\(task.taskIdentifier) client certificate of \(key.extension)/\(key.name)")
            // nil, not an empty array, without intermediates: CFNetwork indexes into the array it's given.
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: chain.isEmpty ? nil : chain, persistence: .forSession))
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            clientKeys.removeValue(forKey: task.taskIdentifier)
            redirectModes.removeValue(forKey: task.taskIdentifier)
            if let error { record(error, for: task.taskIdentifier, host: task.originalRequest?.url?.host()) } else { requestIds.removeValue(forKey: task.taskIdentifier) }
            guard let schemeTask = finish(task) else { return }
            trace?("■ #\(task.taskIdentifier) \(error.map { "failed: \($0.localizedDescription)" } ?? "finished")")
            if let error {
                schemeTask.didFailWithError(error)
            } else {
                schemeTask.didFinish()
            }
        }
    }
}
