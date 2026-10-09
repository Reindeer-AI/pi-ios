import Foundation
import Security
import WebKit

/// Headless WebKit service that runs the pi engine bundle.
///
/// The engine page loads from `pi://app/` out of `bundleDirectory`, so a new bundle can be swapped in without
/// rebuilding the app. The web view is never shown; it stays attached to a window, and its inactive scheduling policy
/// keeps WebKit from suspending or throttling it.
@MainActor
public final class PiEngine: NSObject {
    public typealias ServiceHandler = @MainActor (_ method: String, _ params: Any?) async throws -> Any?

    public let webView: WKWebView
    /// Engine events (`agent_events`, `submission_settled`, ...), as decoded JSON objects.
    public var onEvent: (([String: Any]) -> Void)?
    /// Console output forwarded from the engine.
    public var onLog: ((_ level: String, _ message: String) -> Void)?
    /// Native network proxy diagnostics, one line per request event.
    public var onNetTrace: ((String) -> Void)? {
        get { schemeHandler.netProxy.trace }
        set { schemeHandler.netProxy.trace = newValue }
    }
    /// WebKit's content process died. Storage is native, so the host restarts the engine and pi-durable resumes.
    public var onTermination: (() -> Void)?

    /// An extension key's TLS client identity, for its `fetch(url, { clientKey })` (ExtensionKeysService).
    var clientIdentity: ((_ extension: String, _ name: String) -> (SecIdentity, [SecCertificate])?)? {
        get { schemeHandler.netProxy.clientIdentity }
        set { schemeHandler.netProxy.clientIdentity = newValue }
    }

    /// A key's certificate changed: connections made with the old one go.
    /// The vault, for extensions' `pi.vault` and the values their requests send (`{{vault:…}}`).
    public func useVault(_ vault: VaultService) {
        vault.install(on: self)
        schemeHandler.netProxy.vaultResolver = { [weak vault] request, requester in
            guard let vault else { throw VaultError("The vault isn't available") }
            return try await vault.resolve(request, requester: requester)
        }
    }

    func forgetClientIdentity(extension extensionName: String, name: String) {
        schemeHandler.netProxy.forgetClientSession(extension: extensionName, name: name)
    }

    private let schemeHandler: EngineSchemeHandler
    private let bridge = EngineBridge()
    private var services: [String: ServiceHandler] = [:]
    private var readyContinuation: CheckedContinuation<EngineEnvironment, Error>?
    /// Whether the engine's page is up. The app shows its last sessions before it is, so commands sent until then
    /// (a session's transcript) wait for it rather than failing.
    private var pageReady = false
    private var pageWaiters: [CheckedContinuation<Void, Never>] = []

    public init(bundleDirectory: URL) {
        schemeHandler = EngineSchemeHandler(bundleDirectory: bundleDirectory)

        let configuration = WKWebViewConfiguration()
        // The engine runs agent work while its web view is hidden, offscreen, or the app is in the background
        // (under continued processing). By default WebKit suspends inactive pages.
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: EngineSchemeHandler.scheme)
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "pi")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.isInspectable = true

        super.init()
        bridge.engine = self
        schemeHandler.syncHandler = { [weak self] service, method, params in
            guard let self else { throw EngineError.unknownService(service) }
            return try await self.handle(service: service, method: method, params: params)
        }
        webView.navigationDelegate = self
        registerBuiltInServices()
        schemeHandler.netProxy.onFailure = { [weak self] message in self?.onLog?("warn", "net: \(message)") }
    }

    /// Loads the engine and waits until it reports ready.
    public func start() async throws -> EngineEnvironment {
        pageReady = false
        return try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            webView.load(URLRequest(url: URL(string: "\(EngineSchemeHandler.scheme)://app/index.html")!))
        }
    }

    /// Calls an engine command registered with `onCommand` and returns its result.
    public func command(_ method: String, _ params: [String: Any] = [:]) async throws -> Any? {
        if !pageReady { await withCheckedContinuation { pageWaiters.append($0) } }
        do {
            return try await webView.callAsyncJavaScript(
                "return await window.__pi.command(method, params)",
                arguments: ["method": method, "params": params],
                contentWorld: .page
            )
        } catch let error as NSError {
            // WebKit reports "A JavaScript exception occurred"; the engine's own message is in the user info.
            if let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String {
                throw EngineError.commandFailed(method, message)
            }
            throw error
        }
    }

    /// Registers a native service the engine reaches with `request(service, method, params)`.
    public func register(service: String, handler: @escaping ServiceHandler) {
        services[service] = handler
    }

    func handle(service: String, method: String, params: Any?) async throws -> Any? {
        guard let handler = services[service] else {
            throw EngineError.unknownService(service)
        }
        return try await handler(method, params)
    }

    private func registerBuiltInServices() {
        register(service: "engine") { [weak self] method, params in
            guard method == "ready" else { throw EngineError.unknownMethod("engine.\(method)") }
            self?.readyContinuation?.resume(returning: EngineEnvironment(params as? [String: Any] ?? [:]))
            self?.readyContinuation = nil
            self?.pageReady = true
            self?.releasePageWaiters()
            return nil
        }
        // `net.failure { id }`: why a `pi://app/net` request failed, which WebKit reports only as "Load failed".
        register(service: "net") { [weak self] method, params in
            guard method == "failure" else { throw EngineError.unknownMethod("net.\(method)") }
            return ((params as? [String: Any])?["id"] as? String).flatMap { self?.schemeHandler.netProxy.failure($0) }
        }
        register(service: "events") { [weak self] _, params in
            if let event = params as? [String: Any] { self?.onEvent?(event) }
            return nil
        }
        register(service: "log") { [weak self] level, params in
            self?.onLog?(level, params as? String ?? String(describing: params))
            return nil
        }
    }
}

extension PiEngine: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failStart(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failStart(error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failStart(EngineError.contentProcessTerminated)
        // Commands from now on wait for the engine the app starts again.
        pageReady = false
        onTermination?()
    }

    private func failStart(_ error: Error) {
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
        // Commands that waited for a page that won't come fail now rather than wait forever.
        releasePageWaiters()
    }

    fileprivate func releasePageWaiters() {
        let waiters = pageWaiters
        pageWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// What the engine reported about its WebKit environment when it became ready.
public struct EngineEnvironment: Sendable {
    public let userAgent: String
    public let secureContext: Bool
    public let webAssembly: Bool

    init(_ report: [String: Any]) {
        userAgent = report["userAgent"] as? String ?? ""
        secureContext = report["secureContext"] as? Bool ?? false
        webAssembly = report["webAssembly"] as? Bool ?? false
    }
}

public enum EngineError: LocalizedError {
    case unknownService(String)
    case unknownMethod(String)
    case contentProcessTerminated
    case commandFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let method, let message): "\(method): \(message)"
        case .unknownService(let service): "Unknown native service: \(service)"
        case .unknownMethod(let method): "Unknown native method: \(method)"
        case .contentProcessTerminated: "WebKit content process terminated"
        }
    }
}

/// Receives engine messages. Held weakly by the engine's user content controller through this object, so the
/// controller does not retain the engine.
@MainActor
final class EngineBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var engine: PiEngine?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let service = body["service"] as? String,
              let method = body["method"] as? String
        else {
            replyHandler(nil, "Malformed engine message")
            return
        }
        Task { @MainActor [weak engine] in
            guard let engine else { return replyHandler(nil, "Engine gone") }
            do {
                replyHandler(try await engine.handle(service: service, method: method, params: body["params"]), nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }
}
