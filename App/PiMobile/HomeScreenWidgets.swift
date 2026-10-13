import CryptoKit
import ImageIO
import PiEngineKit
import PiWidgetLayout
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

// Home Screen widgets for extensions' apps (pi.widget, engine/src/extensions/widgets.ts): the engine sends the apps
// extensions register and the layouts they draw; pi saves them in the App Group its widget extension (PiWidgets) reads,
// and asks iOS to reload the widgets. A widget's tap opens its app full screen, in a window of its own over pi's.

/// The engine's `widget` service.
@MainActor
enum HomeScreenWidgets {
    /// Images a widget may show, and how big pi keeps them (widgets have little memory).
    private static let imageLimit = 24
    private static let imagePixels = 1000
    private static let downloadLimit = 10 * 1024 * 1024
    private static let contentLimit = 512 * 1024

    static func install(_ engine: PiEngine) {
        engine.register(service: "widget") { method, params in
            let arguments = params as? [String: Any] ?? [:]
            switch method {
            // The apps an extension registers, each time it loads (its scope: "default" or "session:<id>").
            case "apps":
                guard let name = arguments["extension"] as? String, let scope = arguments["scope"] as? String else {
                    throw AppError.message("widget.apps needs an extension and a scope")
                }
                let apps = (arguments["apps"] as? [[String: Any]] ?? []).compactMap { entry -> WidgetApp? in
                    guard let app = entry["name"] as? String else { return nil }
                    return WidgetApp(extensionName: name, name: app, title: entry["title"] as? String ?? app, icon: entry["icon"] as? String,
                                     description: entry["description"] as? String, scope: scope)
                }
                let before = WidgetStore.apps()
                try WidgetStore.setApps(apps, extension: name, scope: scope)
                if WidgetStore.apps() != before { reload() }
                return nil
            // An extension removed: its apps and widgets go.
            case "forget":
                guard let name = arguments["extension"] as? String, let scope = arguments["scope"] as? String else {
                    throw AppError.message("widget.forget needs an extension and a scope")
                }
                try WidgetStore.setApps([], extension: name, scope: scope)
                for id in WidgetStore.contentIDs() where belongs(id, to: name, scope: scope) { try? WidgetStore.setContent(nil, for: id) }
                WidgetStore.removeUnusedImages()
                reload()
                return nil
            case "update":
                guard let id = arguments["id"] as? String, let content = arguments["content"] as? [String: Any] else {
                    throw AppError.message("widget.update needs an app and its widget")
                }
                // A build without the App Group keeps no widgets; the extension carries on.
                guard WidgetStore.isAvailable else {
                    log("widget", "\(id): this build has no widgets (no App Group)")
                    return ["saved": false]
                }
                let data = try JSONSerialization.data(withJSONObject: try await savingImages(content), options: [.sortedKeys])
                guard data.count <= contentLimit else {
                    throw AppError.message("The widget is too big (\(data.count / 1024) KB, at most \(contentLimit / 1024) KB): use fewer or smaller images")
                }
                try WidgetStore.setContent(data, for: id)
                WidgetStore.removeUnusedImages()
                reload()
                log("widget", "\(id) drawn (\(max(1, data.count / 1024)) KB)")
                return ["saved": true]
            case "clear":
                guard let id = arguments["id"] as? String else { throw AppError.message("widget.clear needs an app") }
                try WidgetStore.setContent(nil, for: id)
                WidgetStore.removeUnusedImages()
                reload()
                return nil
            default:
                throw EngineError.unknownMethod("widget.\(method)")
            }
        }
    }

    static func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetLayout.kind)
    }

    /// The app a panel shows, as the widget knows it (a session's own extension's app is that session's).
    static func app(for panel: AppModel.Panel) -> WidgetApp? {
        guard let key = panel.app?.key else { return nil }
        let apps = WidgetStore.apps()
        return apps.first { $0.id == "\(key)@\(panel.sessionId)" } ?? apps.first { $0.id == key }
    }

    private static func belongs(_ id: String, to name: String, scope: String) -> Bool {
        let (key, sessionId) = WidgetApp.parse(id: id)
        guard key.hasPrefix("\(name)/") else { return false }
        return sessionId.map { scope == "session:\($0)" } ?? (scope == "default")
    }

    // MARK: Images

    /// The widget with its images (`src`: a data: or https: URL) saved for the widget, as "file:<name>".
    private static func savingImages(_ content: [String: Any]) async throws -> Any {
        var sources = Set<String>()
        collectSources(content, into: &sources)
        guard sources.count <= imageLimit else { throw AppError.message("A widget can show \(imageLimit) images at most") }
        var saved: [String: String] = [:]
        for source in sources { saved[source] = try await savedImage(source) }
        return replacingSources(content, with: saved)
    }

    private static func collectSources(_ value: Any, into sources: inout Set<String>) {
        if let object = value as? [String: Any] {
            if object["type"] as? String == "image", let src = object["src"] as? String, !src.hasPrefix("file:") { sources.insert(src) }
            for child in object.values { collectSources(child, into: &sources) }
        } else if let array = value as? [Any] {
            for child in array { collectSources(child, into: &sources) }
        }
    }

    private static func replacingSources(_ value: Any, with saved: [String: String]) -> Any {
        if var object = value as? [String: Any] {
            for (key, child) in object { object[key] = replacingSources(child, with: saved) }
            if object["type"] as? String == "image", let src = object["src"] as? String, let name = saved[src] { object["src"] = name }
            return object
        }
        if let array = value as? [Any] { return array.map { replacingSources($0, with: saved) } }
        return value
    }

    private static func savedImage(_ source: String) async throws -> String {
        let data: Data
        if source.hasPrefix("data:") {
            guard let comma = source.firstIndex(of: ","), source[..<comma].hasSuffix(";base64"),
                  let decoded = Data(base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters) else {
                throw AppError.message("An image's data: URL isn't base64 (data:image/png;base64,…)")
            }
            data = decoded
        } else if source.hasPrefix("https://"), let url = URL(string: source) {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (body, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw AppError.message("Couldn't download the image \(source) (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
            }
            data = body
        } else {
            throw AppError.message("An image's src must be a data: or https: URL, not \(source.prefix(40))")
        }
        guard data.count <= downloadLimit else { throw AppError.message("An image is over \(downloadLimit / 1024 / 1024) MB") }
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: imagePixels,
              ] as CFDictionary) else {
            throw AppError.message("An image isn't one pi can read (PNG, JPEG, HEIC or GIF; not SVG)")
        }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw AppError.message("Couldn't save an image")
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppError.message("Couldn't save an image") }
        let hash = SHA256.hash(data: png as Data).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "file:" + (try WidgetStore.saveImage(png as Data, named: "\(hash).png"))
    }
}

// MARK: - An app full screen

/// An app a widget opened, full screen.
struct FocusedApp: Identifiable, Equatable {
    /// The widget's app (`WidgetApp.id`).
    let id: String
    let key: String
    let title: String
    let icon: String?
    /// The session it opened in, once it has.
    var sessionId: Int?
    /// Why it couldn't open.
    var error: String?
}

extension AppModel {
    /// The open app's page, once it's there.
    var focusedPanel: Panel? {
        guard let focus = focusedApp, let sessionId = focus.sessionId else { return nil }
        return panels.first { $0.sessionId == sessionId && $0.app?.key == focus.key }
    }

    /// A widget's tap: its app full screen, in the session it opened in from a widget before (else one it runs in, else
    /// the latest session, else a new one); an app of one session's own extension, in that session.
    func openWidget(_ url: URL) {
        guard let (id, target) = WidgetLayout.parse(url) else { return }
        let (key, sessionHint) = WidgetApp.parse(id: id)
        let known = WidgetStore.app(id: id)
        if focusedApp?.id != id { focusedApp = FocusedApp(id: id, key: key, title: known?.title ?? key, icon: known?.icon) }
        log("widget", "open \(id)\(target.map { " at \($0)" } ?? "")")
        Task { await openFocusedApp(key: key, sessionHint: sessionHint, target: target) }
    }

    private func openFocusedApp(key: String, sessionHint: Int?, target: String?) async {
        await start()
        guard phase == .ready else { return failFocus(key, "pi couldn't start.") }
        await extensionsLoaded()
        var remembered = UserDefaults.standard.dictionary(forKey: Self.widgetSessionsKey) as? [String: Int] ?? [:]
        var candidates: [Int] = []
        if let sessionHint {
            candidates = [sessionHint]
        } else {
            candidates = [panels.first { $0.app?.key == key }?.sessionId, remembered[key], sessions.first?.id].compactMap { $0 }
        }
        var tried = Set<Int>()
        for sessionId in candidates where sessions.contains(where: { $0.id == sessionId }) && tried.insert(sessionId).inserted {
            guard focusedApp?.key == key else { return }
            if await openFocused(key, in: sessionId, target: target) {
                remembered[key] = sessionId
                UserDefaults.standard.set(remembered, forKey: Self.widgetSessionsKey)
                return
            }
        }
        // Not in any of them (a default extension turned off there): a new session has every default.
        if sessionHint == nil, focusedApp?.key == key, let fresh = try? await createSession(), await openFocused(key, in: fresh, target: target) {
            remembered[key] = fresh
            UserDefaults.standard.set(remembered, forKey: Self.widgetSessionsKey)
            return
        }
        failFocus(key, "\(focusedApp?.title ?? key) isn't in pi any more: its extension was removed or turned off.")
    }

    private func openFocused(_ key: String, in sessionId: Int, target: String?) async -> Bool {
        focusedApp?.sessionId = sessionId
        if let panel = panels.first(where: { $0.sessionId == sessionId && $0.app?.key == key }) {
            restore(panel)
            if target == nil { return true }
        }
        do {
            var params: [String: Any] = ["sessionId": sessionId, "key": key]
            if let target { params["target"] = target }
            _ = try await engine.command("apps.open", params)
            return true
        } catch {
            log("widget", "[\(sessionId)] \(key): \(error.localizedDescription)")
            if focusedApp?.key == key { focusedApp?.sessionId = nil }
            return false
        }
    }

    private func failFocus(_ key: String, _ message: String) {
        guard focusedApp?.key == key else { return }
        log("widget", "\(key): \(message)")
        focusedApp?.error = message
    }

    /// Back to pi: the app goes to its session's dock, and the session shows.
    func leaveFocusedApp() {
        guard let focus = focusedApp else { return }
        if let panel = focusedPanel { minimize(panel) }
        focusedApp = nil
        if let sessionId = focus.sessionId, sessions.contains(where: { $0.id == sessionId }) { requestedSession = sessionId }
    }

    private static let widgetSessionsKey = "widgetSessions"
}

/// The window an app opened from a widget fills, over pi's (its sheets and covers included); pi's alerts and sheets
/// present over it, as it's the key window.
@MainActor
final class FocusWindow {
    static let shared = FocusWindow()
    private var window: UIWindow?
    private weak var previous: UIWindow?

    func update(_ app: AppModel) {
        if app.focusedApp != nil { show(app) } else { hide() }
    }

    private func show(_ app: AppModel) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        let host = UIHostingController(rootView: FocusedAppView(app: app).tint(Color("AccentColor")))
        host.view.backgroundColor = .systemBackground
        window.rootViewController = host
        window.alpha = 0
        window.makeKeyAndVisible()
        UIView.animate(withDuration: 0.2) { window.alpha = 1 }
        self.window = window
    }

    private func hide() {
        guard let window else { return }
        self.window = nil
        previous?.makeKey()
        UIView.animate(withDuration: 0.2, animations: { window.alpha = 0 }) { _ in
            window.isHidden = true
            // Its page goes back to the parking view (AppPageView).
            window.rootViewController = nil
        }
    }
}

/// An app from a widget: its page and nothing else, with a way back to pi. Extension dialogs show over it.
struct FocusedAppView: View {
    let app: AppModel
    /// Its page was on screen: closing or minimizing it (from the page) goes back to pi.
    @State private var shown = false

    /// A dialog, or a panel that isn't an app, from any session.
    private var otherPanel: AppModel.Panel? {
        app.panels.first { $0.placement == "sheet" && $0.visible && $0.app == nil }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground).ignoresSafeArea()
            if let panel = app.focusedPanel, let page = panel.page {
                AppPageView(page: page)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .overlay { if !panel.pageReady { ProgressView() } }
            } else if let focus = app.focusedApp {
                VStack(spacing: 14) {
                    Image(systemName: appSymbol(focus.icon)).font(.system(size: 44, weight: .semibold)).foregroundStyle(.tint)
                    Text(focus.title).font(.title2.bold())
                    if let error = focus.error {
                        Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Open pi") { app.leaveFocusedApp() }.buttonStyle(.borderedProminent)
                    } else {
                        ProgressView()
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { app.leaveFocusedApp() } label: {
                Label("pi", systemImage: "chevron.backward").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glass)
            .padding(.leading, 12)
            .padding(.top, 4)
            .accessibilityLabel("Back to pi")
        }
        .onChange(of: app.focusedPanel?.visible == true, initial: true) { _, visible in
            if visible { shown = true } else if shown { app.leaveFocusedApp() }
        }
        .sheet(isPresented: Binding(get: { !app.dialogs.isEmpty || otherPanel != nil }, set: { shown in
            guard !shown else { return }
            if let dialog = app.dialogs.first { app.respond(to: dialog, with: nil) } else if let panel = otherPanel { app.dismiss(panel) }
        })) {
            if let dialog = app.dialogs.first {
                ExtensionDialogView(dialog: dialog, sessionTitle: app.sessions.first { $0.id == dialog.sessionId }?.title) { value in
                    app.respond(to: dialog, with: value)
                }
                .id(dialog.id)
            } else if let panel = otherPanel {
                PanelSheet(panel: panel, sessionTitle: app.sessions.first { $0.id == panel.sessionId }?.title,
                           onEvent: { app.panelEvent($0, panelId: panel.id) }, close: { app.dismiss(panel) })
                    .id(panel.id)
            }
        }
    }
}

// MARK: - Add to Home Screen

/// How to put an app on the Home Screen (iOS lets only the user add widgets), with its widget as it looks now.
struct AddToHomeScreenSheet: View {
    let title: String
    let icon: String?
    let widgetApp: WidgetApp?
    @Environment(\.dismiss) private var dismiss

    private var entry: WidgetContent.Entry? {
        widgetApp.flatMap { WidgetStore.content(for: $0.id) }?.entry(at: .now)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Put \(title) on your Home Screen as a widget. Tapping it opens the app full screen.")
                        .foregroundStyle(.secondary)
                    if !WidgetStore.isAvailable {
                        Label("This build of pi can't keep widgets.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 18) {
                            preview("small", width: 158, height: 158, label: "Small")
                            preview("medium", width: 338, height: 158, label: "Medium")
                            preview("large", width: 338, height: 354, label: "Large")
                        }
                        .padding(.vertical, 6)
                    }
                    .scrollClipDisabled()
                    VStack(alignment: .leading, spacing: 14) {
                        step(1, "Go to your Home Screen, and touch and hold an empty spot until the apps jiggle.")
                        step(2, "Tap Edit, then Add Widget.")
                        step(3, "Search for pi, choose pi app, pick a size, and tap Add Widget.")
                        step(4, "If it shows another app: touch and hold the widget, tap Edit Widget, and choose \(title).")
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Add to Home Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private func preview(_ family: String, width: CGFloat, height: CGFloat, label: String) -> some View {
        VStack(spacing: 8) {
            WidgetCanvas(app: widgetApp ?? WidgetApp(extensionName: "", name: "", title: title, icon: icon, description: nil, scope: "default"),
                         appID: nil, entry: entry, family: family, margins: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                .frame(width: width, height: height)
                .background {
                    if let style = WidgetCanvas.background(of: entry) { Rectangle().fill(style) } else { Color(.systemBackground) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("widget-preview-\(family)")
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.subheadline.bold().monospacedDigit()).foregroundStyle(.tint)
            Text(text)
        }
    }
}
