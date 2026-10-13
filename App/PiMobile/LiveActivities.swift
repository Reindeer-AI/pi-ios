import ActivityKit
import PiEngineKit
import PiWidgetLayout
import SwiftUI

/// The engine's `activity` service (pi.liveActivity, engine/src/extensions/activities.ts): an extension's Live
/// Activities, which pi starts, updates and ends with ActivityKit, and its widget extension draws (PiLiveActivity). Their
/// views go to the App Group; ActivityKit gets only a revision to draw them again. Each extension sees its own.
@MainActor
enum LiveActivities {
    static func install(_ engine: PiEngine) {
        engine.register(service: "activity") { method, params in
            let arguments = params as? [String: Any] ?? [:]
            let requester = arguments["requester"] as? String ?? "?"
            switch method {
            // nil when pi can't show one: a build without widgets, or Live Activities turned off for pi.
            case "start":
                guard let app = arguments["app"] as? String, let content = arguments["content"] as? [String: Any] else {
                    throw AppError.message("liveActivity.start needs an app and its views")
                }
                guard WidgetStore.isAvailable else {
                    log("activity", "\(requester): this build has no Live Activities (no App Group)")
                    return nil
                }
                guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                    log("activity", "\(requester): Live Activities are turned off for pi")
                    return nil
                }
                guard await ExtensionPermissions.shared.request([.liveActivities], for: requester) else {
                    throw AppError.message(ExtensionPermissions.shared.decision(.liveActivities, for: requester) == false
                        ? "The user didn't allow \(requester) to show Live Activities"
                        : "\(requester) may show Live Activities once the user allows it, which pi asks the next time it's open")
                }
                let key = UUID().uuidString
                try await save(content, key: key)
                do {
                    _ = try Activity.request(attributes: PiActivityAttributes(key: key, extensionName: requester, appID: app),
                                             content: activityContent(revision: 1, arguments), pushType: nil)
                } catch {
                    throw AppError.message("iOS didn't start the Live Activity: \(error.localizedDescription) (pi starts one only while it's open, or from a widget's or Live Activity's button)")
                }
                cleanUp()
                log("activity", "\(requester): started \(key)")
                return ["id": key]
            case "update":
                let activity = try find(arguments["id"], of: requester)
                if let content = arguments["content"] as? [String: Any] { try await save(content, key: activity.attributes.key) }
                let alert = (arguments["alert"] as? [String: Any]).map { alert in
                    AlertConfiguration(title: LocalizedStringResource(stringLiteral: alert["title"] as? String ?? ""),
                                       body: LocalizedStringResource(stringLiteral: alert["body"] as? String ?? ""),
                                       sound: .default)
                }
                await update(activity.attributes.key, activityContent(revision: activity.content.state.revision + 1, arguments), alert: alert)
                return nil
            case "end":
                let activity = try find(arguments["id"], of: requester)
                var final: ActivityContent<PiActivityAttributes.ContentState>?
                if let content = arguments["content"] as? [String: Any] {
                    try await save(content, key: activity.attributes.key)
                    final = activityContent(revision: activity.content.state.revision + 1, arguments)
                }
                let dismissal: ActivityUIDismissalPolicy = switch arguments["dismiss"] {
                case let when as Double: .after(Date(timeIntervalSince1970: when / 1000))
                case let now as String where now == "now": .immediate
                default: .default
                }
                await end(activity.attributes.key, final, dismissal: dismissal)
                log("activity", "\(requester): ended \(activity.attributes.key)")
                return nil
            case "list":
                return activities(of: requester).map { ["id": $0.attributes.key, "app": $0.attributes.appID] }
            default:
                throw EngineError.unknownMethod("activity.\(method)")
            }
        }
    }

    /// An extension removed: its Live Activities end.
    static func endAll(of extensionName: String) {
        for key in activities(of: extensionName).map(\.attributes.key) {
            Task { await end(key, nil, dismissal: .immediate) }
        }
    }

    // ActivityKit's activities aren't Sendable: found again by key where they're used.
    nonisolated private static func update(_ key: String, _ content: ActivityContent<PiActivityAttributes.ContentState>,
                                           alert: AlertConfiguration?) async {
        guard let activity = Activity<PiActivityAttributes>.activities.first(where: { $0.attributes.key == key }) else { return }
        await activity.update(content, alertConfiguration: alert)
    }

    nonisolated private static func end(_ key: String, _ content: ActivityContent<PiActivityAttributes.ContentState>?,
                                        dismissal: ActivityUIDismissalPolicy) async {
        guard let activity = Activity<PiActivityAttributes>.activities.first(where: { $0.attributes.key == key }) else { return }
        await activity.end(content, dismissalPolicy: dismissal)
    }

    private static func activities(of extensionName: String) -> [Activity<PiActivityAttributes>] {
        Activity<PiActivityAttributes>.activities.filter {
            $0.attributes.extensionName == extensionName && [.active, .stale].contains($0.activityState)
        }
    }

    private static func find(_ id: Any?, of extensionName: String) throws -> Activity<PiActivityAttributes> {
        guard let key = id as? String, let activity = activities(of: extensionName).first(where: { $0.attributes.key == key }) else {
            throw AppError.message("\(extensionName) has no Live Activity \(id as? String ?? "?") running (it ended, or the user dismissed it)")
        }
        return activity
    }

    private static func activityContent(revision: Int, _ arguments: [String: Any]) -> ActivityContent<PiActivityAttributes.ContentState> {
        ActivityContent(state: .init(revision: revision),
                        staleDate: (arguments["staleAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                        relevanceScore: arguments["relevance"] as? Double ?? 0)
    }

    private static func save(_ content: [String: Any], key: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: try await HomeScreenWidgets.savingImages(content), options: [.sortedKeys])
        guard data.count <= 256 * 1024 else { throw AppError.message("The Live Activity is too big (\(data.count / 1024) KB, at most 256 KB)") }
        try WidgetStore.setActivityLayout(data, for: key)
    }

    /// The views of activities iOS no longer shows.
    private static func cleanUp() {
        WidgetStore.removeActivityLayouts(except: Set(Activity<PiActivityAttributes>.activities.map(\.attributes.key)))
        WidgetStore.removeUnusedImages()
    }
}
