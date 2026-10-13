import ActivityKit

/// An extension's Live Activity (pi.liveActivity), for pi (which starts and updates it) and its widget (which draws it).
/// Its views are too big for ActivityKit's 4 KB, so pi saves them in the App Group (`WidgetStore.activityLayout`) and
/// each update only counts up `revision`, which has the widget draw them again.
struct PiActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var revision: Int
    }

    /// pi's name for it: the extension's handle's id, and its views' file.
    var key: String
    var extensionName: String
    /// The app a tap opens (`WidgetApp.id`).
    var appID: String
}
