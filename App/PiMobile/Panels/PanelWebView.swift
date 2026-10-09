import SwiftUI
import WebKit

/// A panel's web view: an extension's HTML page, the agent's `show_html` card, or a pi-tui view tree drawn by
/// `panel.html`. Each panel has its own sandbox (no shared cookies or storage, no access to the app or the engine).
/// The page talks back through `window.pi`: `post(data)`, `close(result)`, `prompt(text)`, `onMessage(callback)`, and
/// `location()`; its height is reported so the panel can size to its content. An extension's page may use the camera and
/// microphone (getUserMedia) and the location once the user allows that extension (`ExtensionPermissions`).
struct PanelWebView: UIViewRepresentable {
    enum Content: Equatable {
        case html(String)
        /// A view tree (`{ root, keys }` as JSON) for `panel.html`.
        case view(String)
    }

    let content: Content
    /// The extension whose page it is; nil for the agent's show_html card.
    var extensionName: String?
    /// Messages the extension posted (JSON), delivered in order to `pi.onMessage`.
    var messages: [String] = []
    var scrolls = false
    /// A view tree above the message box: tighter, on the bar's background.
    var compact = false
    let onEvent: ([String: Any]) -> Void
    var onHeight: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(WeakMessageHandler(context.coordinator), name: "pi")
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = scrolls
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.load(content, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        webView.scrollView.isScrollEnabled = scrolls
        context.coordinator.update(webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pi")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var parent: PanelWebView
        private var loaded: Content?
        private var ready = false
        /// The view tree on screen, or to draw once `panel.html` loads.
        private var rendered: String?
        private var delivered = 0

        init(_ parent: PanelWebView) { self.parent = parent }

        func load(_ content: Content, into webView: WKWebView) {
            loaded = content
            ready = false
            rendered = nil
            switch content {
            case .html(let html):
                webView.loadHTMLString(Self.withViewport(html), baseURL: PageCapabilities.baseURL(for: parent.extensionName))
            case .view:
                guard let url = Bundle.main.url(forResource: "panel", withExtension: "html") else {
                    preconditionFailure("panel.html is missing from the app bundle")
                }
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }

        func update(_ webView: WKWebView) {
            switch (parent.content, loaded) {
            case (.view, .view?):
                loaded = parent.content
            default:
                if parent.content != loaded { load(parent.content, into: webView) }
            }
            guard ready else { return }
            if case .view(let json) = parent.content, json != rendered {
                rendered = json
                webView.evaluateJavaScript("window.__piRender(\(json), \(parent.compact))")
            }
            for message in parent.messages.dropFirst(delivered) {
                webView.evaluateJavaScript("window.pi._receive(\(message))")
            }
            delivered = parent.messages.count
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            update(webView)
        }

        /// Links open outside the panel.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["type"] as? String == "height", let value = body["value"] as? Double {
                parent.onHeight(CGFloat(value))
            } else if let webView = message.webView, PageCapabilities.handle(body, from: parent.extensionName, in: webView) {
                return
            } else {
                parent.onEvent(body)
            }
        }

        func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                     type: WKMediaCaptureType) async -> WKPermissionDecision {
            await PageCapabilities.mediaDecision(type, for: parent.extensionName)
        }

        private static func withViewport(_ html: String) -> String {
            html.range(of: "name=\"viewport\"") != nil ? html
                : "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" + html
        }
    }

    /// `window.pi` in every panel page (app pages too, `AppPage`), and its height reports.
    static let bridge = """
    (() => {
      const send = (message) => window.webkit.messageHandlers.pi.postMessage(message);
      const listeners = [];
      const requests = new Map();
      let lastRequest = 0;
      window.pi = {
        post: (data) => send({ type: "message", data: data === undefined ? null : data }),
        close: (result) => send({ type: "close", result: result === undefined ? null : result }),
        // Only from something the user tapped (a page cannot talk for the user on its own).
        prompt: (text) => {
          if (navigator.userActivation && !navigator.userActivation.isActive) { console.warn("pi.prompt needs a tap"); return; }
          send({ type: "prompt", text: String(text) });
        },
        onMessage: (callback) => { listeners.push(callback); },
        // The device's location, once the user allows this extension (and iOS allows pi): { latitude, longitude,
        // accuracy, altitude?, timestamp }.
        location: () => new Promise((resolve, reject) => {
          const id = ++lastRequest;
          requests.set(id, { resolve, reject });
          send({ type: "location", id });
        }),
        _receive: (data) => { for (const callback of listeners) { try { callback(data); } catch (error) { console.error(error); } } },
        _reply: (id, reply) => {
          const request = requests.get(id);
          requests.delete(id);
          if (!request) return;
          if (reply.error) request.reject(new Error(reply.error)); else request.resolve(reply.value);
        },
        _event: (event) => send(event),
      };
      let last = 0;
      const report = () => {
        const height = Math.ceil(document.documentElement.getBoundingClientRect().height);
        if (height !== last) { last = height; send({ type: "height", value: height }); }
      };
      document.addEventListener("DOMContentLoaded", () => { new ResizeObserver(report).observe(document.documentElement); report(); });
      addEventListener("load", report);
    })();
    """
}

/// Keeps the user content controller from retaining the coordinator.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
