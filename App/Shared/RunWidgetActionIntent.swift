import AppIntents

/// A widget button's action (`action` in pi.widget layouts): its extension's handler, run by pi in the background
/// without opening it. In the widget and in pi (App/Shared): the widget's button names it, and iOS runs it in pi's
/// process, as it does a Live Activity's buttons, launching pi in the background if it isn't running.
struct RunWidgetActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Run a widget's action"
    static let isDiscoverable = false

    /// The widget's app (`WidgetApp.id`).
    @Parameter(title: "App")
    var app: String

    @Parameter(title: "Action")
    var action: String

    /// The button's value, as JSON ("" for none).
    @Parameter(title: "Value")
    var value: String

    init() {}

    init(app: String, action: String, value: String?) {
        self.app = app
        self.action = action
        self.value = value ?? ""
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // pi sets the runner at launch; the widget has none.
        try await WidgetActionRunner.run?(app, action, value.isEmpty ? nil : value)
        return .result()
    }
}

/// How pi runs a widget's action (AppModel); nil in the widget.
@MainActor
enum WidgetActionRunner {
    static var run: ((_ app: String, _ action: String, _ value: String?) async throws -> Void)?
}
