import CoreLocation
import SwiftUI
import UserNotifications
import WebKit

/// What each extension may use on this device: the camera, the microphone, the location, and notifications. pi asks the
/// first time an extension wants one ("Allow “flights” to use the camera?") and remembers the answer, yes or no, which
/// the user changes in Settings → Extensions → the extension → Permissions. iOS then asks once more, for pi itself, the
/// first time any extension uses it. Kept on this device only, as iOS keeps its own permissions.
@MainActor
final class ExtensionPermissions {
    static let shared = ExtensionPermissions()

    enum Capability: String, CaseIterable, Identifiable {
        case camera, microphone, location, notifications
        var id: String { rawValue }

        var title: String {
            switch self {
            case .camera: "Camera"
            case .microphone: "Microphone"
            case .location: "Location"
            case .notifications: "Notifications"
            }
        }

        var systemImage: String {
            switch self {
            case .camera: "camera"
            case .microphone: "mic"
            case .location: "location"
            case .notifications: "bell"
            }
        }

        /// What it uses, as the question says it ("the camera"); nil for one it does rather than uses.
        var used: String? {
            switch self {
            case .camera: "the camera"
            case .microphone: "the microphone"
            case .location: "your location"
            case .notifications: nil
            }
        }

        /// The question's verb phrase for several of them: "use the camera and the microphone", "send you notifications".
        static func phrase(_ capabilities: [Capability]) -> String {
            let used = capabilities.compactMap(\.used)
            var parts = used.isEmpty ? [] : ["use " + used.joined(separator: " and ")]
            if capabilities.contains(.notifications) { parts.append("send you notifications") }
            return parts.joined(separator: " and ")
        }
    }

    private static let key = "extensionPermissions"
    /// Questions a background run couldn't ask ("extension": [capability]), asked the next time pi is open.
    private static let pendingKey = "extensionPermissionsPending"
    /// Questions on screen, so a page asking twice at once gets one question.
    private var asking: [String: Task<Bool, Never>] = [:]

    private var stored: [String: [String: Bool]] {
        get { UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String: Bool]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }

    /// The user's answer for one extension and capability: nil until asked.
    func decision(_ capability: Capability, for extensionName: String) -> Bool? {
        stored[extensionName]?[capability.rawValue]
    }

    /// Changes (or, with nil, forgets) an answer.
    func set(_ capability: Capability, for extensionName: String, to allowed: Bool?) {
        var all = stored
        var answers = all[extensionName] ?? [:]
        answers[capability.rawValue] = allowed
        all[extensionName] = answers.isEmpty ? nil : answers
        stored = all
    }

    /// The capabilities an extension was asked about, with the answers.
    func decisions(for extensionName: String) -> [(Capability, Bool)] {
        Capability.allCases.compactMap { capability in decision(capability, for: extensionName).map { (capability, $0) } }
    }

    /// Whether `extensionName` may use all of `capabilities`, asking about those not yet answered. In the background
    /// (a background check) nothing can be asked, so an unanswered one is refused, and still asked about later.
    func request(_ capabilities: [Capability], for extensionName: String) async -> Bool {
        let unanswered = capabilities.filter { decision($0, for: extensionName) == nil }
        if unanswered.isEmpty { return capabilities.allSatisfy { decision($0, for: extensionName) == true } }
        guard UIApplication.shared.applicationState == .active else {
            var pending = UserDefaults.standard.dictionary(forKey: Self.pendingKey) as? [String: [String]] ?? [:]
            pending[extensionName] = Array(Set((pending[extensionName] ?? []) + unanswered.map(\.rawValue))).sorted()
            UserDefaults.standard.set(pending, forKey: Self.pendingKey)
            return false
        }
        let question = "\(extensionName)/" + unanswered.map(\.rawValue).joined(separator: "+")
        if let pending = asking[question] { return await pending.value && capabilities.allSatisfy { decision($0, for: extensionName) == true } }
        let task = Task { @MainActor in
            // Unanswered stays unanswered when the question couldn't be shown.
            guard let allowed = await UserDialog.ask(
                title: "Allow “\(extensionName)” to \(Capability.phrase(unanswered))?",
                message: "You can change this in Settings → Extensions → \(extensionName).",
                confirmLabel: "Allow",
                cancelLabel: "Don’t Allow"
            ) else { return false }
            for capability in unanswered { set(capability, for: extensionName, to: allowed) }
            return allowed
        }
        asking[question] = task
        let allowed = await task.value
        asking[question] = nil
        return allowed && capabilities.allSatisfy { decision($0, for: extensionName) == true }
    }

    /// Asks iOS to let pi notify, if it hasn't asked yet: until pi asks once, iOS doesn't list pi in Settings →
    /// Notifications. Only while pi is in front.
    func askSystemNotifications() async {
        guard UIApplication.shared.applicationState == .active,
              await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Asks the questions background runs couldn't (pi has come to the front), one extension at a time.
    func askPending() async {
        let pending = UserDefaults.standard.dictionary(forKey: Self.pendingKey) as? [String: [String]] ?? [:]
        guard !pending.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        for (extensionName, names) in pending.sorted(by: { $0.key < $1.key }) {
            let capabilities = names.compactMap(Capability.init(rawValue:)).filter { decision($0, for: extensionName) == nil }
            guard !capabilities.isEmpty else { continue }
            // Allowed notifications need iOS's permission for pi too, asked now that pi is in front.
            if await request(capabilities, for: extensionName), capabilities.contains(.notifications) { await askSystemNotifications() }
        }
    }

    /// Posts a notification from `extensionName` (`pi.notify`), once it may send them and iOS lets pi. Tapping it opens
    /// `session` and sends it `prompt`, or sends `prompt` to a new session (AppModel.openFromNotification).
    func notify(for extensionName: String, title: String, body: String, session: Int? = nil, prompt: String? = nil) async throws {
        guard await request([.notifications], for: extensionName) else {
            throw AppError.message(decision(.notifications, for: extensionName) == false
                ? "The user didn't allow \(extensionName) to send notifications"
                : "\(extensionName) may send notifications once the user allows it, which pi asks the next time it's open")
        }
        let center = UNUserNotificationCenter.current()
        await askSystemNotifications()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: throw AppError.message("pi may not send notifications: Settings → Notifications → pi")
        }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? extensionName : title
        content.body = body
        content.threadIdentifier = extensionName
        content.sound = .default
        var info: [String: Any] = ["extension": extensionName]
        if let session { info["session"] = session }
        if let prompt { info["prompt"] = prompt }
        content.userInfo = info
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// The device's location for `extensionName`, once it may have it (pi.location in extensions and app pages).
    func location(for extensionName: String) async throws -> [String: Any] {
        guard await request([.location], for: extensionName) else {
            throw AppError.message("The user didn't allow \(extensionName) to use their location")
        }
        let location = try await LocationService.shared.current()
        var result: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000,
        ]
        if location.verticalAccuracy >= 0 { result["altitude"] = location.altitude }
        return result
    }
}

/// One location at a time, asking iOS for pi's When In Use permission first.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()
    private var authorizing: [CheckedContinuation<Void, Never>] = []
    private var locating: [CheckedContinuation<CLLocation, Error>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func current() async throws -> CLLocation {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                authorizing.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: throw AppError.message("pi may not use the location: Settings → Privacy & Security → Location Services → pi")
        }
        return try await withCheckedThrowingContinuation { continuation in
            locating.append(continuation)
            if locating.count == 1 { manager.requestLocation() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard status != .notDetermined else { return }
            let waiting = authorizing
            authorizing.removeAll()
            for continuation in waiting { continuation.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let location = locations.last else { return }
            let waiting = locating
            locating.removeAll()
            for continuation in waiting { continuation.resume(returning: location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            log("location", "failed: \(error.localizedDescription)")
            let waiting = locating
            locating.removeAll()
            for continuation in waiting { continuation.resume(throwing: error) }
        }
    }
}

/// What an extension's page (an app, or a panel) may use: WebKit asks pi before a page gets the camera or microphone
/// (getUserMedia), and `pi.location()` comes here. A page with no extension behind it (the agent's show_html card)
/// gets neither.
@MainActor
enum PageCapabilities {
    /// An extension's page address: https, so the page is a secure context (getUserMedia needs one), and its own origin
    /// per extension. Nothing is fetched from it; the page's HTML comes from the extension.
    static func baseURL(for extensionName: String?) -> URL? {
        guard let extensionName else { return nil }
        let host = extensionName.lowercased().replacing(#/[^a-z0-9]+/#, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return URL(string: "https://\(host.isEmpty ? "extension" : host).extension.pi.invalid/")
    }

    static func mediaDecision(_ type: WKMediaCaptureType, for extensionName: String?) async -> WKPermissionDecision {
        guard let extensionName else { return .deny }
        let capabilities: [ExtensionPermissions.Capability] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: [.camera, .microphone]
        }
        return await ExtensionPermissions.shared.request(capabilities, for: extensionName) ? .grant : .deny
    }

    /// Answers a page's `pi.location()` (a "location" message with an id): its `_reply` gets the location or an error.
    static func handle(_ body: [String: Any], from extensionName: String?, in webView: WKWebView) -> Bool {
        guard body["type"] as? String == "location", let id = body["id"] as? Int else { return false }
        Task { @MainActor [weak webView] in
            var reply: [String: Any]
            do {
                guard let extensionName else { throw AppError.message("Only an extension's page may ask for the location") }
                reply = ["value": try await ExtensionPermissions.shared.location(for: extensionName)]
            } catch {
                reply = ["error": error.localizedDescription]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return }
            _ = try? await webView?.evaluateJavaScript("window.pi._reply(\(id), \(String(decoding: data, as: UTF8.self)))")
        }
        return true
    }
}
