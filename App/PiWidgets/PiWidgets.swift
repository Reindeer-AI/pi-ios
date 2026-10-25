import AppIntents
import PiWidgetLayout
import SwiftUI
import WidgetKit

// pi's widgets: one of the user's pi apps on the Home Screen or Lock Screen, as its extension draws it
// (`pi.widget.update`, saved by pi in the App Group, `WidgetStore`). No extension code runs here: the widget shows what
// pi saved, and pi asks iOS to reload it when an extension draws it again. A tap opens the app full screen in pi. Its
// buttons run the extension's handler in pi, in the background (RunWidgetActionIntent, App/Shared), or switch the widget
// to another of its looks here (ShowWidgetViewIntent).

@main
struct PiWidgets: WidgetBundle {
    var body: some Widget {
        PiAppWidget()
        PiLiveActivity()
    }
}

struct PiAppWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetLayout.kind, intent: ChooseAppIntent.self, provider: AppTimeline()) { entry in
            AppWidgetView(entry: entry)
        }
        .configurationDisplayName("pi app")
        .description("One of your pi apps, as its extension draws it. Tap it to open the app.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
        // The extension's layout decides its margins (`margins: false` reaches the edges).
        .contentMarginsDisabled()
    }
}

/// The widget's one setting: which app it shows (Edit Widget).
struct ChooseAppIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose an app"
    static let description = IntentDescription("The pi app this widget shows and opens.")

    @Parameter(title: "App")
    var app: AppChoice?

    init() {}
}

struct AppChoice: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "pi app"
    static let defaultQuery = AppChoiceQuery()

    let id: String
    let title: String
    let icon: String?
    let extensionName: String

    init(_ app: WidgetApp) {
        id = app.id
        title = app.title
        icon = app.icon
        extensionName = app.extensionName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(extensionName)", image: .init(systemName: icon ?? "app.dashed"))
    }
}

/// The apps pi saw its extensions register; a new widget shows the newest app, or the one Add to Home Screen was opened
/// for (`WidgetStore.nextApp`).
struct AppChoiceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AppChoice] {
        WidgetStore.apps().filter { identifiers.contains($0.id) }.map(AppChoice.init)
    }

    func suggestedEntities() async throws -> [AppChoice] {
        WidgetStore.apps().map(AppChoice.init)
    }

    func defaultResult() async -> AppChoice? {
        Self.nextApp().map(AppChoice.init)
    }

    static func nextApp() -> WidgetApp? {
        let apps = WidgetStore.apps()
        return WidgetStore.nextApp().flatMap { next in apps.first { $0.id == next } } ?? firstApp()
    }

    /// What a widget with no app chosen shows: the first app that drew a widget (it stays put as apps come).
    static func firstApp() -> WidgetApp? {
        let drawn = Set(WidgetStore.contentIDs()), apps = WidgetStore.apps()
        return apps.first { drawn.contains($0.id) } ?? apps.first
    }
}

struct AppEntry: TimelineEntry {
    let date: Date
    let app: WidgetApp?
    /// The app a tap opens.
    let appID: String?
    let content: WidgetContent.Entry?
    /// Instead of the app: why there's none.
    var note: String?
}

struct AppTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AppEntry {
        AppEntry(date: .now, app: nil, appID: nil, content: nil)
    }

    func snapshot(for configuration: ChooseAppIntent, in context: Context) async -> AppEntry {
        entries(for: configuration).first ?? placeholder(in: context)
    }

    /// What the extension drew, and its later entries; reloaded when pi saves the widget again.
    func timeline(for configuration: ChooseAppIntent, in context: Context) async -> Timeline<AppEntry> {
        Timeline(entries: entries(for: configuration), policy: .never)
    }

    private func entries(for configuration: ChooseAppIntent) -> [AppEntry] {
        let now = Date.now
        if let id = configuration.app?.id ?? AppChoiceQuery.firstApp()?.id, let view = WidgetStore.view(for: id),
           let look = WidgetStore.content(for: id)?.views[view] {
            return [AppEntry(date: now, app: WidgetStore.app(id: id), appID: id, content: look)]
        }
        guard let id = configuration.app?.id ?? AppChoiceQuery.firstApp()?.id else {
            return [AppEntry(date: now, app: nil, appID: nil, content: nil, note: "Open an app in pi first, then choose it here.")]
        }
        let app = WidgetStore.app(id: id)
        guard let content = WidgetStore.content(for: id) else {
            guard app != nil else {
                return [AppEntry(date: now, app: nil, appID: nil, content: nil, note: "This app is no longer in pi.")]
            }
            return [AppEntry(date: now, app: app, appID: id, content: nil)]
        }
        var entries = [AppEntry(date: now, app: app, appID: id, content: content.entry(at: now))]
        for entry in content.entries {
            guard let date = entry.date, date > now else { continue }
            entries.append(AppEntry(date: date, app: app, appID: id, content: entry))
        }
        return entries.sorted { $0.date < $1.date }
    }
}

struct AppWidgetView: View {
    let entry: AppEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetContentMargins) private var margins

    var body: some View {
        Group {
            if let note = entry.note {
                Text(note).font(.footnote).foregroundStyle(.secondary).padding(margins)
            } else {
                WidgetCanvas(app: entry.app, appID: entry.appID, entry: entry.content, family: familyKey, margins: margins)
            }
        }
        .containerBackground(for: .widget) {
            if let style = WidgetCanvas.background(of: entry.content) {
                Rectangle().fill(style)
            } else if isAccessory {
                Color.clear
            } else {
                Color(uiColor: .systemBackground)
            }
        }
        .widgetURL(entry.appID.map { WidgetLayout.openURL(app: $0) })
        .environment(\.widgetButtonMaker, entry.appID.map(Self.buttons(for:)))
    }

    /// Buttons for the app's widget: its extension's actions, run in pi, and its other looks, shown here.
    private static func buttons(for app: String) -> WidgetButtonMaker {
        WidgetButtonMaker { action, label in
            switch action {
            case .run(let name, let value):
                AnyView(Button(intent: RunWidgetActionIntent(app: app, action: name, value: value)) { label }.buttonStyle(.plain))
            case .show(let view):
                AnyView(Button(intent: ShowWidgetViewIntent(app: app, view: view ?? "")) { label }.buttonStyle(.plain))
            }
        }
    }

    private var isAccessory: Bool {
        [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family)
    }

    /// The size, as layouts name it.
    private var familyKey: String {
        switch family {
        case .systemSmall: "small"
        case .systemMedium: "medium"
        case .systemLarge: "large"
        case .systemExtraLarge: "extraLarge"
        case .accessoryCircular: "circular"
        case .accessoryRectangular: "rectangular"
        case .accessoryInline: "inline"
        default: "medium"
        }
    }
}

/// A widget button's `show`: another of the widget's looks (`views`), or the main one; run here, in the widget.
struct ShowWidgetViewIntent: AppIntent {
    static let title: LocalizedStringResource = "Show a widget's view"
    static let isDiscoverable = false

    @Parameter(title: "App")
    var app: String

    /// "" for the main look.
    @Parameter(title: "View")
    var view: String

    init() {}

    init(app: String, view: String) {
        self.app = app
        self.view = view
    }

    func perform() async throws -> some IntentResult {
        WidgetStore.setView(view.isEmpty ? nil : view, for: app)
        return .result()
    }
}
