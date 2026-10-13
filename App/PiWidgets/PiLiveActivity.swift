import PiWidgetLayout
import SwiftUI
import WidgetKit

/// An extension's Live Activity on the Lock Screen and in the Dynamic Island, as it drew it (pi.liveActivity, saved by
/// pi in the App Group). A tap opens its app full screen in pi; its buttons run the extension's actions in pi.
struct PiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PiActivityAttributes.self) { context in
            LockScreenActivity(context: context)
        } dynamicIsland: { context in
            let layout = Self.layout(context)
            let app = context.attributes.appID
            let icon = Image(systemName: WidgetStore.app(id: app)?.icon ?? "app.dashed")
            let tint = WidgetCanvas.color(layout?.tint)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Region(node: layout?.expandedLeading, app: app) }
                DynamicIslandExpandedRegion(.trailing) { Region(node: layout?.expandedTrailing, app: app) }
                DynamicIslandExpandedRegion(.center) { Region(node: layout?.expandedCenter, app: app) }
                DynamicIslandExpandedRegion(.bottom) {
                    Region(node: layout?.hasExpanded == false ? layout?.lockScreen : layout?.expandedBottom, app: app)
                }
            } compactLeading: {
                if let node = layout?.compactLeading { Region(node: node, app: app) } else { icon.foregroundStyle(tint ?? .accentColor) }
            } compactTrailing: {
                Region(node: layout?.compactTrailing, app: app)
            } minimal: {
                if let node = layout?.minimal { Region(node: node, app: app) } else { icon.foregroundStyle(tint ?? .accentColor) }
            }
            .widgetURL(WidgetLayout.openURL(app: app))
            .keylineTint(tint)
        }
    }

    /// Its views, read again on every update (`revision`).
    static func layout(_ context: ActivityViewContext<PiActivityAttributes>) -> ActivityLayout? {
        _ = context.state.revision
        return WidgetStore.activityLayout(context.attributes.key)
    }
}

private struct LockScreenActivity: View {
    let context: ActivityViewContext<PiActivityAttributes>

    var body: some View {
        let layout = PiLiveActivity.layout(context)
        let app = context.attributes.appID
        let fill = WidgetCanvas.fill(layout?.background)
        Group {
            if let node = layout?.lockScreen {
                Region(node: node, app: app).padding(layout?.margins == false ? 0 : 16)
            } else {
                WidgetPlaceholderView(title: WidgetStore.app(id: app)?.title ?? context.attributes.extensionName,
                                      icon: WidgetStore.app(id: app)?.icon, family: "rectangular")
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if let fill { Rectangle().fill(fill) } }
        .activityBackgroundTint(fill == nil ? nil : .clear)
        .widgetURL(WidgetLayout.openURL(app: app))
    }
}

/// One of the activity's views, with buttons that run its extension's actions in pi.
private struct Region: View {
    let node: WidgetNode?
    let app: String

    var body: some View {
        if let node {
            WidgetNodeView(node: node, appID: app)
                .environment(\.widgetButtonMaker, WidgetButtonMaker { action, label in
                    guard case .run(let name, let value) = action else { return label }
                    return AnyView(Button(intent: RunWidgetActionIntent(app: app, action: name, value: value)) { label }.buttonStyle(.plain))
                })
        }
    }
}
