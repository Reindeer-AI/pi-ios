import Foundation
import Observation
import PiEngineKit
import UIKit
import WebKit

/// The engine's `browser` service: each session's agent drives its own tabs on the session's browser profile.
///
/// Every call carries the session id and returns `{ text, isError?, image? }`, where `text` is what the model sees: a
/// header naming the profile and tab, notes (new tabs, restored tabs), then the result, usually a fresh snapshot of the
/// page. A dialog a page opens (alert, confirm, prompt) goes to the agent, which answers it with `browser_dialog`. The service applies no policy of its own; pi extensions can wrap the browser tools for that.
/// Tab addresses are saved on every navigation, so after a restart a session's browser reopens its tabs.
@MainActor
@Observable
final class BrowserService {
    static let maxTabs = 4

    let profiles = BrowserProfiles()
    /// Agent browsers, by session id.
    private(set) var sessions: [Int: BrowserSession] = [:]
    /// Browsers the user opens from the home screen or Settings, by profile key.
    private(set) var standalone: [String: BrowserSession] = [:]

    /// The profile key a session is attached to, from the session list.
    @ObservationIgnored var profileForSession: @MainActor (Int) -> String? = { _ in nil }

    @ObservationIgnored private let log: @MainActor (String, String) -> Void
    @ObservationIgnored private var saved: [String: SavedBrowser] = [:]
    @ObservationIgnored private let stateURL = URL.applicationSupportDirectory.appending(path: "browser-sessions.json")

    private struct SavedBrowser: Codable {
        var profile: String
        var tabs: [String]
        var active: Int
    }

    private static let script: String = {
        guard let url = Bundle.main.url(forResource: "browser-agent", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { preconditionFailure("browser-agent.js is missing from the app bundle") }
        return source
    }()

    /// The page script's world: it shares the page's DOM, not its JavaScript.
    private static let world = WKContentWorld.world(name: "pi-agent")

    /// The user's vault, for `fillSecret` (the agent's `browser_fill_from_vault`, an extension's `pi.vault.fill`).
    var vault: VaultService?

    init(log: @escaping @MainActor (String, String) -> Void) {
        self.log = log
        if let data = try? Data(contentsOf: stateURL) {
            saved = (try? JSONDecoder().decode([String: SavedBrowser].self, from: data)) ?? [:]
        }
    }

    func install(on engine: PiEngine) {
        engine.register(service: "browser") { [weak self] method, params in
            guard let self else { throw EngineError.unknownService("browser") }
            return await self.handle(method, params as? [String: Any] ?? [:])
        }
    }

    // MARK: - Browsers

    /// The user's own browser on a profile, for signing in to sites or browsing from the home screen.
    func standaloneBrowser(for key: String) -> BrowserSession {
        if let browser = standalone[key] { return browser }
        let browser = makeBrowser(.profile(key), key)
        standalone[key] = browser
        return browser
    }

    /// Closes a session's browser and forgets its tabs (the session was deleted or moved to another profile).
    func close(sessionId: Int) {
        sessions.removeValue(forKey: sessionId)?.closeAll()
        saved[String(sessionId)] = nil
        save()
    }

    /// Closes every browser on the profile, then deletes it with its site data.
    func deleteProfile(_ key: String) async throws {
        for (id, browser) in sessions where browser.profileKey == key { close(sessionId: id) }
        for (id, state) in saved where state.profile == key { saved[id] = nil }
        save()
        standalone.removeValue(forKey: key)?.closeAll()
        try await profiles.delete(key)
    }

    /// A web address for what the user typed: a URL as is, a bare domain over HTTPS, anything else as a search.
    static func address(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = webURL(text) { return url }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }

    /// `text` as an http(s) URL: with its scheme, or a bare domain such as `example.com/path`.
    static func webURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            return ["http", "https"].contains(scheme) && url.host() != nil ? url : nil
        }
        guard !text.contains(" "), text.contains("."), let url = URL(string: "https://\(text)"), url.host() != nil else { return nil }
        return url
    }

    private func makeBrowser(_ owner: BrowserSession.Owner, _ key: String) -> BrowserSession {
        let browser = BrowserSession(owner: owner, profileKey: key, dataStore: profiles.dataStore(for: key))
        browser.onChange = { [weak self, weak browser] in
            guard let self, let browser, case .session(let id) = browser.owner, self.sessions[id] === browser else { return }
            self.saved[String(id)] = SavedBrowser(
                profile: browser.profileKey,
                tabs: browser.tabs.compactMap { $0.url?.absoluteString },
                active: browser.activeIndex
            )
            self.save()
        }
        return browser
    }

    /// The session's live browser, or a new one that reopens the tabs it had before a restart.
    private func ensure(sessionId: Int, profileKey: String) -> (browser: BrowserSession, restored: Bool) {
        if let browser = sessions[sessionId] {
            if browser.profileKey == profileKey { return (browser, false) }
            close(sessionId: sessionId)
        }
        let browser = makeBrowser(.session(sessionId), profileKey)
        let state = saved[String(sessionId)]
        sessions[sessionId] = browser
        guard let state, state.profile == profileKey, !state.tabs.isEmpty else { return (browser, false) }
        for address in state.tabs.prefix(Self.maxTabs) {
            if let url = URL(string: address), let tab = browser.openTab() { tab.webView.load(URLRequest(url: url)) }
        }
        browser.select(min(state.active, browser.tabs.count - 1))
        return (browser, true)
    }

    private func save() {
        try? JSONEncoder().encode(saved).write(to: stateURL, options: .atomic)
    }

    // MARK: - Engine calls

    private func handle(_ method: String, _ params: [String: Any]) async -> [String: Any] {
        guard let sessionId = params["sessionId"] as? Int else { return failure("The browser call has no session.") }
        guard let key = profileForSession(sessionId), let profileName = profiles.name(of: key) else {
            return failure("This session has no browser profile. Ask the user to choose one from the session's menu.")
        }
        let (browser, restored) = ensure(sessionId: sessionId, profileKey: key)
        if browser.userHasControl {
            return failure("The user has taken control of this browser. Wait until they hand it back, then try again.")
        }
        if restored {
            browser.note("The app restarted, so the browser reopened its tabs from their addresses; anything unsaved on those pages is gone.")
        }
        log("browser", "[\(sessionId)] \(method) \(Self.summary(params))")
        var reply: [String: Any]
        if method != "dialog", let dialog = browser.pendingDialog {
            reply = ["text": compose(browser, profileName, "Error: first answer the dialog the page is waiting on.\n\n\(Self.describe(dialog))"), "isError": true]
        } else {
            do {
                let (text, image) = try await perform(method, params, in: browser, sessionId: sessionId)
                reply = ["text": compose(browser, profileName, text)]
                if let image { reply["image"] = image }
            } catch is PageDialogOpen {
                reply = ["text": compose(browser, profileName, browser.pendingDialog.map(Self.describe) ?? "")]
            } catch {
                reply = ["text": compose(browser, profileName, "Error: \(Self.message(of: error))"), "isError": true]
            }
        }
        // A page showing a dialog can't render until it is answered.
        if let tab = browser.active, browser.pendingDialog == nil {
            browser.setThumbnail(try? await tab.webView.takeSnapshot(configuration: Self.thumbnailConfiguration))
        }
        log("browser", "[\(sessionId)] \(method) → \((reply["text"] as? String ?? "").split(separator: "\n").dropFirst().first ?? "")")
        return reply
    }

    private func perform(_ method: String, _ params: [String: Any], in browser: BrowserSession, sessionId: Int)
        async throws -> (String, String?)
    {
        // A tab still loading (just restored, or a slow page) settles before the agent looks at or acts on it.
        if let tab = browser.active, tab.webView.isLoading { await waitForLoad(tab, in: browser) }

        switch method {
        case "navigate":
            let raw = params["url"] as? String ?? ""
            guard let url = Self.webURL(raw) else { throw BrowserError("Not a web address: \(raw)") }
            guard let tab = browser.active ?? browser.openTab() else { throw BrowserError("No tab is available.") }
            try await load(url, in: tab, browser: browser)
            return (try await snapshot(browser), nil)

        case "back", "forward", "reload":
            let tab = try requireTab(browser)
            switch method {
            case "back":
                guard tab.webView.canGoBack else { throw BrowserError("There is no earlier page in this tab.") }
                tab.webView.goBack()
            case "forward":
                guard tab.webView.canGoForward else { throw BrowserError("There is no later page in this tab.") }
                tab.webView.goForward()
            default:
                tab.webView.reload()
            }
            await settle(browser)
            return (try await snapshot(browser), nil)

        case "snapshot":
            return (try await snapshot(browser), nil)

        case "read":
            let tab = try requireTab(browser)
            return (try await run(browser, tab, "read(offset)", ["offset": params["offset"] as? Int ?? 0]) as? String ?? "", nil)

        case "screenshot":
            let tab = try requireTab(browser)
            let image = try await tab.webView.takeSnapshot(configuration: WKSnapshotConfiguration())
            guard let jpeg = Self.jpeg(image, width: 800) else { throw BrowserError("The screenshot could not be encoded.") }
            return ("Screenshot of \(tab.url?.absoluteString ?? "the page") attached.", jpeg.base64EncodedString())

        case "click":
            let tab = try requireTab(browser)
            let ref = params["ref"] as? String ?? ""
            let note = try await run(browser, tab, "click(ref)", ["ref": ref]) as? String ?? ""
            if !note.isEmpty { browser.note(note) }
            await settle(browser)
            return (try await snapshot(browser), nil)

        case "type":
            let tab = try requireTab(browser)
            let ref = params["ref"] as? String ?? ""
            let submit = params["submit"] as? Bool ?? false
            _ = try await run(browser, tab, "type(ref, text, submit)", ["ref": ref, "text": params["text"] as? String ?? "", "submit": submit])
            await settle(browser)
            return (try await snapshot(browser), nil)

        case "fillSecret":
            // A vault value typed into the page after the user's consent and Face ID: the engine never has it, and the
            // page shows it masked.
            let tab = try requireTab(browser)
            guard let vault else { throw BrowserError("The vault isn't available.") }
            let id = params["item"] as? String ?? ""
            let field = params["field"] as? String ?? ""
            let host = tab.url?.host() ?? "this page"
            let values = try await vault.values(id, fields: [field], requester: params["requester"] as? String ?? "the agent",
                                                purpose: "fill a form on \(host)", reason: params["reason"] as? String)
            guard let value = values[field] else { throw BrowserError("That vault item has no \(field).") }
            let hint = vault.item(id).map { [$0.label, $0.hint].filter { !$0.isEmpty }.joined(separator: ", ") } ?? field
            _ = try await run(browser, tab, "fillSecret(ref, value, hint)", ["ref": params["ref"] as? String ?? "", "value": value, "hint": "\(hint), \(field)"])
            await settle(browser)
            return (try await snapshot(browser), nil)

        case "select":
            let tab = try requireTab(browser)
            _ = try await run(browser, tab, "select(ref, option)", ["ref": params["ref"] as? String ?? "", "option": params["option"] as? String ?? ""])
            await settle(browser)
            return (try await snapshot(browser), nil)

        case "press":
            let tab = try requireTab(browser)
            let key = params["key"] as? String ?? ""
            _ = try await run(browser, tab, "press(key)", ["key": key])
            await settle(browser)
            return (try await snapshot(browser), nil)

        case "scroll":
            let tab = try requireTab(browser)
            var arguments: [String: Any] = ["direction": params["direction"] as? String ?? "down"]
            arguments["ref"] = params["ref"] as? String ?? NSNull()
            let note = try await run(browser, tab, "scroll(direction, ref)", arguments) as? String ?? ""
            if !note.isEmpty { browser.note(note) }
            try await Task.sleep(for: .milliseconds(300))
            return (try await snapshot(browser), nil)

        case "wait":
            let tab = try requireTab(browser)
            var arguments: [String: Any] = ["seconds": params["seconds"] as? Double ?? 10]
            arguments["text"] = params["text"] as? String ?? NSNull()
            arguments["ref"] = params["ref"] as? String ?? NSNull()
            let outcome = try await run(browser, tab, "wait(text, ref, seconds)", arguments) as? String ?? ""
            return ("\(outcome)\n\n\(try await snapshot(browser))", nil)

        case "tabs":
            return (try await tabs(params, in: browser), nil)

        case "dialog":
            guard browser.pendingDialog != nil else { throw BrowserError("No dialog is open.") }
            let accept = params["accept"] as? Bool ?? false
            browser.answerDialog(accept ? .accept(params["text"] as? String) : .dismiss)
            await settle(browser)
            return (try await snapshot(browser), nil)

        default:
            throw BrowserError("Unknown browser action \(method).")
        }
    }

    private func tabs(_ params: [String: Any], in browser: BrowserSession) async throws -> String {
        let index = (params["index"] as? Int).map { $0 - 1 }
        switch params["action"] as? String ?? "list" {
        case "open":
            guard let tab = browser.openTab() else { throw BrowserError("This browser already has \(Self.maxTabs) tabs; close one first.") }
            if let raw = params["url"] as? String {
                guard let url = Self.webURL(raw) else { throw BrowserError("Not a web address: \(raw)") }
                try await load(url, in: tab, browser: browser)
            }
            return "\(tabList(browser))\n\n\(try await snapshot(browser))"
        case "select":
            guard let index, browser.tabs.indices.contains(index) else { throw BrowserError("There is no tab \(index.map { $0 + 1 } ?? 0).") }
            browser.select(index)
            return "\(tabList(browser))\n\n\(try await snapshot(browser))"
        case "close":
            guard let index, browser.tabs.indices.contains(index) else { throw BrowserError("There is no tab \(index.map { $0 + 1 } ?? 0).") }
            browser.close(browser.tabs[index])
            return tabList(browser)
        default:
            return tabList(browser)
        }
    }

    private func tabList(_ browser: BrowserSession) -> String {
        guard !browser.tabs.isEmpty else { return "No tabs are open." }
        return browser.tabs.enumerated().map { index, tab in
            "\(index + 1). \(tab.title.isEmpty ? "(untitled)" : tab.title) — \(tab.url?.absoluteString ?? "about:blank")"
                + (index == browser.activeIndex ? " (current)" : "")
        }.joined(separator: "\n")
    }

    private func snapshot(_ browser: BrowserSession) async throws -> String {
        try await run(browser, try requireTab(browser), "snapshot()") as? String ?? ""
    }

    private func requireTab(_ browser: BrowserSession) throws -> BrowserTab {
        guard let tab = browser.active else { throw BrowserError("No page is open. Use browser_navigate first.") }
        return tab
    }

    private func load(_ url: URL, in tab: BrowserTab, browser: BrowserSession) async throws {
        tab.loadError = nil
        tab.webView.load(URLRequest(url: url))
        await waitForLoad(tab, in: browser)
        if let error = tab.loadError { throw BrowserError("Couldn't open \(url.absoluteString): \(error)") }
    }

    /// After an action: give a navigation it started time to begin, wait for it, then let the page render.
    private func settle(_ browser: BrowserSession) async {
        try? await Task.sleep(for: .milliseconds(350))
        if let tab = browser.active, tab.webView.isLoading { await waitForLoad(tab, in: browser) }
        try? await Task.sleep(for: .milliseconds(250))
    }

    private func waitForLoad(_ tab: BrowserTab, in browser: BrowserSession, seconds: Double = 20) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while tab.webView.isLoading, browser.pendingDialog == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if tab.webView.isLoading, browser.pendingDialog == nil { browser.note("The page was still loading after \(Int(seconds)) s.") }
    }

    /// Runs a page-script call. A dialog the page opens meanwhile stops the page until it is answered, so the call
    /// then throws `PageDialogOpen` instead of waiting; it finishes on its own once the dialog is answered.
    private func run(_ browser: BrowserSession, _ tab: BrowserTab, _ call: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        if browser.pendingDialog != nil { throw PageDialogOpen() }
        let outcome = ScriptOutcome()
        Task {
            do {
                outcome.result = .success(try await tab.webView.callAsyncJavaScript(
                    "\(Self.script)\nreturn await window.__piAgent.\(call);",
                    arguments: arguments,
                    in: nil,
                    contentWorld: Self.world
                ))
            } catch {
                outcome.result = .failure(error)
            }
        }
        while outcome.result == nil {
            if browser.pendingDialog != nil { throw PageDialogOpen() }
            try? await Task.sleep(for: .milliseconds(30))
        }
        switch outcome.result! {
        case .success(let value):
            return value
        case .failure(let error as NSError):
            if let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String {
                throw BrowserError(message.replacingOccurrences(of: "Error: ", with: ""))
            }
            throw error
        }
    }

    private static func describe(_ dialog: PageDialog) -> String {
        let from = dialog.host.isEmpty ? "The page" : dialog.host
        switch dialog.kind {
        case .alert:
            return "\(from) shows an alert and waits until it is closed: \"\(dialog.message)\"\nClose it with browser_dialog."
        case .confirm:
            return "\(from) asks for confirmation and waits for the answer: \"\(dialog.message)\"\nAnswer with browser_dialog: accept (OK) or not (Cancel)."
        case .prompt:
            return "\(from) asks for text and waits for the answer: \"\(dialog.message)\" (default: \"\(dialog.defaultText)\")\n"
                + "Answer with browser_dialog: accept with text (the default if you give none), or not (Cancel)."
        }
    }

    private func compose(_ browser: BrowserSession, _ profileName: String, _ body: String) -> String {
        var text = "[\(profileName) profile"
        if browser.tabs.count > 1 { text += " · tab \(browser.activeIndex + 1) of \(browser.tabs.count)" }
        text += "]\n"
        let notes = browser.takeNotes()
        if !notes.isEmpty { text += notes.map { "Note: \($0)" }.joined(separator: "\n") + "\n" }
        return text + "\n" + body
    }

    private func failure(_ text: String) -> [String: Any] {
        ["text": "Error: \(text)", "isError": true]
    }

    private static func summary(_ params: [String: Any]) -> String {
        var parts: [String] = []
        for key in ["url", "ref", "key", "action", "option", "direction"] {
            if let value = params[key] { parts.append("\(key)=\(value)") }
        }
        // Typed text can be personal; log only its length.
        if let text = params["text"] as? String { parts.append("text=\(text.count) chars") }
        return parts.joined(separator: " ")
    }

    private static func message(of error: Error) -> String {
        (error as? BrowserError)?.message ?? error.localizedDescription
    }

    private static let thumbnailConfiguration: WKSnapshotConfiguration = {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 120
        return configuration
    }()

    private static func jpeg(_ image: UIImage, width: CGFloat) -> Data? {
        let scale = min(1, width / (image.size.width * image.scale))
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.6)
    }

    // MARK: - Web views

    /// Where web views live when not on screen: in the window (so WebKit keeps them running), 1×1, nearly transparent.
    static let parking: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        return view
    }()

    /// Pages lay out at the window's size even while parked.
    static var pageFrame: CGRect {
        parking.window?.bounds ?? CGRect(x: 0, y: 0, width: 393, height: 852)
    }

    static func park(_ webView: WKWebView) {
        webView.removeFromSuperview()
        webView.autoresizingMask = []
        webView.frame = pageFrame
        parking.addSubview(webView)
    }

    static func configuration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Agents keep browsing while the browser is off screen or the app is in the background.
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.applicationNameForUserAgent = userAgentSuffix
        return configuration
    }

    #if DEBUG || SAFARI_IDENTITY
    /// Development and internal test builds (`scripts/build-ipa.sh`) identify as Safari so that Google sign-in can be
    /// tested. This gets around Google's block on embedded web views and is against Google's policy; builds for real use
    /// identify as the pi browser once Apple grants the browser entitlement (see PLAN.md).
    static let userAgentSuffix: String = {
        let version = UIDevice.current.systemVersion.split(separator: ".").prefix(2).joined(separator: ".")
        return "Version/\(version) Mobile/15E148 Safari/604.1"
    }()
    #else
    static let userAgentSuffix: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        return "PiMobile/\(version) Mobile/15E148 Safari/604.1"
    }()
    #endif
}

/// A page's alert, confirm, or prompt, waiting for an answer.
struct PageDialog {
    enum Kind { case alert, confirm, prompt }
    let kind: Kind
    let message: String
    let defaultText: String
    let host: String
}

enum DialogAnswer {
    /// OK, with a prompt's text (nil: its default).
    case accept(String?)
    case dismiss
}

/// The page opened a dialog while a call was running.
struct PageDialogOpen: Error {}

@MainActor
private final class ScriptOutcome {
    var result: Result<Any?, Error>?
}

struct BrowserError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Browser

/// One browser: tabs on a profile's data store, driven by a session's agent or by the user.
@MainActor
@Observable
final class BrowserSession: Identifiable {
    enum Owner: Hashable {
        case session(Int)
        case profile(String)
    }

    let owner: Owner
    let profileKey: String
    private(set) var tabs: [BrowserTab] = []
    private(set) var activeIndex = 0
    /// The user has the page: the agent's browser tools wait for it back.
    var userHasControl = false
    private(set) var thumbnail: UIImage?
    /// Dialogs pages opened in this browser, oldest first; each page waits until its own is answered.
    private var dialogs: [(tab: UUID, dialog: PageDialog, answer: CheckedContinuation<DialogAnswer, Never>)] = []

    @ObservationIgnored let dataStore: WKWebsiteDataStore
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var notes: [String] = []

    nonisolated var id: Owner { owner }
    var active: BrowserTab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

    /// The dialog to answer next.
    var pendingDialog: PageDialog? { dialogs.first?.dialog }

    /// A person is driving: page dialogs go to them as alerts instead of to the agent.
    var userFacing: Bool {
        if case .profile = owner { return true }
        return userHasControl
    }

    init(owner: Owner, profileKey: String, dataStore: WKWebsiteDataStore) {
        self.owner = owner
        self.profileKey = profileKey
        self.dataStore = dataStore
    }

    /// A new tab, made current. `configuration` is WebKit's when a page opens a window.
    @discardableResult
    func openTab(configuration: WKWebViewConfiguration? = nil) -> BrowserTab? {
        guard tabs.count < BrowserService.maxTabs else {
            note("A page tried to open a new tab, but this browser already has \(BrowserService.maxTabs) tabs.")
            return nil
        }
        let tab = BrowserTab(configuration: configuration ?? BrowserService.configuration(dataStore: dataStore), browser: self)
        BrowserService.park(tab.webView)
        tabs.append(tab)
        activeIndex = tabs.count - 1
        if configuration != nil { note("The page opened a new tab (tab \(tabs.count)); it is now the current tab.") }
        changed()
        return tab
    }

    /// Loads what the user typed in the address bar.
    func open(_ input: String) {
        guard let url = BrowserService.address(for: input), let tab = active ?? openTab() else { return }
        tab.webView.load(URLRequest(url: url))
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        changed()
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        dismissDialogs(of: tab)
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        tabs.remove(at: index)
        if activeIndex >= index { activeIndex = max(0, activeIndex - 1) }
        changed()
    }

    func closeAll() {
        dismissDialogs(of: nil)
        for tab in tabs {
            tab.webView.stopLoading()
            tab.webView.removeFromSuperview()
        }
        tabs = []
        activeIndex = 0
    }

    /// Waits for the agent (or the user, from the browser screen) to answer a page's dialog.
    func ask(_ dialog: PageDialog, from tab: BrowserTab) async -> DialogAnswer {
        await withCheckedContinuation { dialogs.append((tab.id, dialog, $0)) }
    }

    func answerDialog(_ answer: DialogAnswer) {
        guard !dialogs.isEmpty else { return }
        dialogs.removeFirst().answer.resume(returning: answer)
    }

    /// A closing tab's page is gone; its dialogs need no answer.
    private func dismissDialogs(of tab: BrowserTab?) {
        for entry in dialogs where tab == nil || entry.tab == tab?.id { entry.answer.resume(returning: .dismiss) }
        dialogs.removeAll { tab == nil || $0.tab == tab?.id }
    }

    func note(_ text: String) {
        notes.append(text)
    }

    func takeNotes() -> [String] {
        defer { notes = [] }
        return notes
    }

    func setThumbnail(_ image: UIImage?) {
        thumbnail = image
    }

    func changed() {
        onChange?()
    }
}

// MARK: - Tab

/// One tab's web view and its observable state.
@MainActor
@Observable
final class BrowserTab: NSObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Why the last navigation failed, if it did.
    @ObservationIgnored var loadError: String?

    @ObservationIgnored private weak var browser: BrowserSession?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration, browser: BrowserSession) {
        webView = WKWebView(frame: BrowserService.pageFrame, configuration: configuration)
        self.browser = browser
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.title) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.title = webView.title ?? "" }
            },
            webView.observe(\.url) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.url = webView.url
                    self?.browser?.changed()
                }
            },
            webView.observe(\.isLoading) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
            webView.observe(\.canGoBack) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
        ]
    }
}

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        record(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        browser?.note("The page crashed and was reloaded.")
        webView.reload()
    }

    private func record(_ error: Error) {
        let error = error as NSError
        // Cancelled navigations (a newer one replaced it, or a policy decision stopped it) are not failures.
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && error.code == 102) { return }
        loadError = error.localizedDescription
    }
}

extension BrowserTab: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        browser?.openTab(configuration: configuration)?.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard let browser else { return }
        if browser.userFacing {
            await UserDialog.alert(title: frame.securityOrigin.host, message: message)
        } else {
            _ = await browser.ask(PageDialog(kind: .alert, message: message, defaultText: "", host: frame.securityOrigin.host), from: self)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard let browser else { return false }
        if browser.userFacing {
            return await UserDialog.confirm(title: frame.securityOrigin.host, message: message, confirmLabel: "OK")
        }
        let dialog = PageDialog(kind: .confirm, message: message, defaultText: "", host: frame.securityOrigin.host)
        if case .accept = await browser.ask(dialog, from: self) { return true }
        return false
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        guard let browser else { return nil }
        if browser.userFacing {
            return await UserDialog.prompt(title: frame.securityOrigin.host, message: prompt, text: defaultText ?? "")
        }
        let dialog = PageDialog(kind: .prompt, message: prompt, defaultText: defaultText ?? "", host: frame.securityOrigin.host)
        switch await browser.ask(dialog, from: self) {
        case .accept(let text): return text ?? defaultText ?? ""
        case .dismiss: return nil
        }
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        // No camera or microphone for the agent's browser: the sites it visits aren't extensions the user allowed
        // (ExtensionPermissions).
        .deny
    }
}

// MARK: - Dialogs

/// System alerts over whatever is on screen, sheets included.
@MainActor
enum UserDialog {
    static func alert(title: String, message: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume() })
            present(alert) { continuation.resume() }
        }
    }

    static func confirm(title: String, message: String, confirmLabel: String, cancelLabel: String = "Cancel") async -> Bool {
        await ask(title: title, message: message, confirmLabel: confirmLabel, cancelLabel: cancelLabel) ?? false
    }

    /// Like `confirm`, but nil when there was nowhere to show the question, so a caller that records answers doesn't
    /// take that for a no.
    static func ask(title: String, message: String, confirmLabel: String, cancelLabel: String = "Cancel") async -> Bool? {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: cancelLabel, style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: confirmLabel, style: .default) { _ in continuation.resume(returning: true) })
            present(alert) { continuation.resume(returning: nil) }
        }
    }

    static func prompt(title: String, message: String, text: String) async -> String? {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addTextField { $0.text = text }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                continuation.resume(returning: alert?.textFields?.first?.text ?? "")
            })
            present(alert) { continuation.resume(returning: nil) }
        }
    }

    /// Presents on the top-most view controller, once it isn't in the middle of a transition (a sheet closing, a screen
    /// being pushed or popped), which would drop the alert; `unavailable` runs when there's no window to present on.
    private static func present(_ alert: UIAlertController, attempt: Int = 0, unavailable: @escaping () -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = (scene?.keyWindow ?? scene?.windows.first { !$0.isHidden })?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        guard let top, top.transitionCoordinator == nil, !top.isBeingPresented, !top.isBeingDismissed else {
            guard attempt < 15 else { return unavailable() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { present(alert, attempt: attempt + 1, unavailable: unavailable) }
            return
        }
        top.present(alert, animated: true)
    }
}
