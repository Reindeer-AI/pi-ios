import SwiftUI
import WebKit

/// An app's page (`apps.ts` in the engine): one web view for as long as the app runs, so minimizing it to the dock and
/// opening it again finds the page as it was, with its timers and connections still going. While it is off screen it
/// waits in a parking view in the window (as the browser's pages do), where WebKit keeps it running and it still gets
/// the extension's messages.
///
/// Besides the panel bridge (`pi.post`, `pi.onMessage`, `pi.close`, `pi.prompt`), the page has `pi.state` (get, set,
/// onChange: saved with the app, and the state it opens with after a relaunch) and `pi.minimize()`.
@MainActor
final class AppPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    /// The page's messages for the engine (`message`, `state`, `close`), and `minimize` and `prompt` for the app.
    var onEvent: ([String: Any]) -> Void = { _ in }
    /// The page has loaded (the first time can take a moment while WebKit starts a process for it).
    var onReady: () -> Void = {}
    /// The saved state, as JSON: what a reloaded page starts with.
    private var state: String
    private var ready = false
    /// Messages for a page still loading.
    private var pending: [String] = []

    init(html: String, state: String) {
        self.state = state
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakAppPageHandler(self), name: "pi")
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = self
        load(html)
        Self.park(webView)
    }

    /// Draws a new page (the extension rendered it again), starting from the saved state.
    func load(_ html: String) {
        ready = false
        pending.removeAll()
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: PanelWebView.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.appBridge(state: state), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.loadHTMLString(html.range(of: "name=\"viewport\"") != nil ? html
            : "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" + html, baseURL: nil)
    }

    /// A message from the extension (`app.post`), as JSON.
    func deliver(_ json: String) {
        if ready { webView.evaluateJavaScript("window.pi._receive(\(json))") } else { pending.append(json) }
    }

    /// The saved state changed (the extension's `app.setState`, or another session's page of a shared app).
    func setState(_ json: String) {
        state = json
        if ready { webView.evaluateJavaScript("window.pi._state(\(json))") }
    }

    /// Ends the page: off screen and out of the parking view.
    func discard() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pi")
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        for json in pending { webView.evaluateJavaScript("window.pi._receive(\(json))") }
        pending.removeAll()
        onReady()
    }

    /// Links open outside the app's page.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.navigationType == .linkActivated, let url = action.request.url {
            await UIApplication.shared.open(url)
            return .cancel
        }
        return .allow
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String, type != "height" else { return }
        if type == "state", let value = body["value"],
           let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) {
            state = String(decoding: data, as: UTF8.self)
        }
        onEvent(body)
    }

    // MARK: - Parking

    /// Where pages wait off screen: in the window, behind everything (`AppParkingView`).
    static let parking: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        view.clipsToBounds = true
        // Off screen for VoiceOver too: a minimized app's page isn't there to read.
        view.accessibilityElementsHidden = true
        return view
    }()

    static func park(_ webView: WKWebView) {
        guard webView.superview !== parking else { return }
        webView.removeFromSuperview()
        // A phone-sized frame, so a parked page lays out as it will show.
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        webView.autoresizingMask = []
        parking.addSubview(webView)
    }

    /// `pi.state` and `pi.minimize` in an app's page, after the panel bridge.
    private static func appBridge(state: String) -> String {
        """
        (() => {
          let state = \(state);
          const listeners = [];
          window.pi.state = {
            get: () => state,
            set: (value) => {
              state = value === undefined ? null : JSON.parse(JSON.stringify(value));
              window.pi._event({ type: "state", value: state });
            },
            onChange: (callback) => { listeners.push(callback); },
          };
          window.pi.minimize = () => window.pi._event({ type: "minimize" });
          window.pi._state = (value) => {
            state = value;
            for (const callback of listeners) { try { callback(value); } catch (error) { console.error(error); } }
          };
        })();
        """
    }
}

/// Keeps the user content controller from retaining the page.
private final class WeakAppPageHandler: NSObject, WKScriptMessageHandler {
    weak var target: AppPage?
    init(_ target: AppPage) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.userContentController(controller, didReceive: message) }
    }
}

/// Hosts parked app pages in the window, behind everything.
struct AppParkingView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { AppPage.parking }
    func updateUIView(_ uiView: UIView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? { CGSize(width: 1, height: 1) }
}

/// An app's page on screen: its running web view, moved here from the parking view (and back when this goes away).
struct AppPageView: UIViewRepresentable {
    let page: AppPage

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if page.webView.superview !== container { attach(to: container) }
    }

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        for case let webView as WKWebView in container.subviews { AppPage.park(webView) }
    }

    private func attach(to container: UIView) {
        let webView = page.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}
