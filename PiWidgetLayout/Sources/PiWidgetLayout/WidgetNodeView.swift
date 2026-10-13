import Charts
import SwiftUI
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

/// Draws an extension's widget layout with native views. Unknown types and properties draw nothing, so a layout made
/// for a newer pi still shows on an older one.
public struct WidgetNodeView: View {
    let node: WidgetNode
    /// The app a tap area (`open`) opens; nil: tap areas open nothing (a preview).
    let appID: String?
    @Environment(\.widgetButtonMaker) private var buttonMaker

    public init(node: WidgetNode, appID: String?) {
        self.node = node
        self.appID = appID
    }

    public var body: some View {
        content
            .modifier(TextStyle(node: node))
            .modifier(BoxStyle(node: node))
            .modifier(TapTarget(url: node.string("open").flatMap { target in appID.map { WidgetLayout.openURL(app: $0, target: target) } }))
    }

    @ViewBuilder private var content: some View {
        switch node.type {
        case "vstack":
            VStack(alignment: Style.horizontal(node.string("alignment")), spacing: node.number("spacing").map { CGFloat($0) }) { children }
        case "hstack":
            HStack(alignment: Style.vertical(node.string("alignment")), spacing: node.number("spacing").map { CGFloat($0) }) { children }
        case "zstack":
            ZStack(alignment: Style.alignment(node.string("alignment")) ?? .center) { children }
        case "button": button
        case "text": text
        case "date": date
        case "symbol": symbol
        case "image": image
        case "spacer": Spacer(minLength: node.number("min").map { CGFloat($0) })
        case "divider": Divider()
        case "gauge": gauge
        case "progress": progress
        case "chart": chart
        default: EmptyView()
        }
    }

    private var children: some View {
        ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
            WidgetNodeView(node: child, appID: appID)
        }
    }

    /// A button's children in a row; a button only in the widget, which has the intents to make one.
    @ViewBuilder private var button: some View {
        let label = HStack(alignment: Style.vertical(node.string("alignment")), spacing: node.number("spacing").map { CGFloat($0) }) { children }
        if let buttonMaker, let action = buttonAction {
            buttonMaker.make(action, AnyView(label))
        } else {
            label
        }
    }

    private var buttonAction: WidgetButtonAction? {
        if let action = node.string("action") {
            let value = node.props["value"].flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
            return .run(action: action, value: value)
        }
        if let show = node.props["show"] { return .show(view: show.string) }
        return nil
    }

    private var text: Text {
        let value = node.string("text") ?? ""
        if node.bool("markdown") == true,
           let attributed = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(verbatim: value)
    }

    @ViewBuilder private var date: some View {
        if let milliseconds = node.number("date") {
            let date = Date(timeIntervalSince1970: milliseconds / 1000)
            switch node.string("style") {
            case "time": Text(date, style: .time)
            case "date": Text(date, style: .date)
            case "offset": Text(date, style: .offset)
            case "timer": Text(date, style: .timer)
            default: Text(date, style: .relative)
            }
        }
    }

    @ViewBuilder private var symbol: some View {
        let image = Image(systemName: node.string("name") ?? "questionmark.square.dashed", variableValue: node.number("variable"))
        let colors = (node.props["colors"]?.array ?? []).compactMap(Style.color)
        switch node.string("mode") {
        case "hierarchical": image.symbolRenderingMode(.hierarchical)
        case "multicolor": image.symbolRenderingMode(.multicolor)
        case "palette":
            if colors.count >= 3 {
                image.symbolRenderingMode(.palette).foregroundStyle(colors[0], colors[1], colors[2])
            } else if colors.count == 2 {
                image.symbolRenderingMode(.palette).foregroundStyle(colors[0], colors[1])
            } else {
                image
            }
        default: image
        }
    }

    @ViewBuilder private var image: some View {
        if let image = Style.image(node.string("src")) {
            image
                .resizable()
                .widgetAccentedRenderingMode(Style.accentedMode(node.string("accentMode")))
                .aspectRatio(contentMode: node.string("fit") == "fit" ? .fit : .fill)
        }
    }

    @ViewBuilder private var gauge: some View {
        let lower = node.number("min") ?? 0
        let upper = max(node.number("max") ?? 1, lower + 0.000_001)
        let value = min(max(node.number("value") ?? 0, lower), upper)
        let label = node.string("label"), current = node.string("valueLabel")
        let gauge = Gauge(value: value, in: lower...upper) {
            if let label { Text(label) }
        } currentValueLabel: {
            if let current { Text(current) }
        }
        switch node.string("style") {
        case "circular": gauge.gaugeStyle(.accessoryCircular)
        case "circularCapacity": gauge.gaugeStyle(.accessoryCircularCapacity)
        case "linear": gauge.gaugeStyle(.accessoryLinear)
        case "linearCapacity": gauge.gaugeStyle(.accessoryLinearCapacity)
        default: gauge.gaugeStyle(.linearCapacity)
        }
    }

    private var progress: some View {
        let total = max(node.number("total") ?? 1, 0.000_001)
        let label = node.string("label")
        return ProgressView(value: min(max(node.number("value") ?? 0, 0), total), total: total) {
            if let label { Text(label) }
        }
        .progressViewStyle(.linear)
    }

    private var chart: some View {
        let values = (node.props["values"]?.array ?? []).compactMap(\.number)
        let kind = node.string("kind") ?? "line"
        let low = values.min() ?? 0, high = values.max() ?? 1
        let lower = node.number("min") ?? (kind == "line" ? low : min(0, low))
        let upper = max(node.number("max") ?? high, lower + 0.000_001)
        let axes: Visibility = node.bool("axes") == true ? .automatic : .hidden
        return Chart(Array(values.enumerated()), id: \.offset) { point in
            if kind == "bar" {
                BarMark(x: .value("Index", point.offset), y: .value("Value", point.element))
            } else if kind == "area" {
                AreaMark(x: .value("Index", point.offset), y: .value("Value", point.element))
            } else {
                LineMark(x: .value("Index", point.offset), y: .value("Value", point.element)).interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(axes)
        .chartYAxis(axes)
        .chartLegend(.hidden)
        .chartYScale(domain: lower...upper)
    }
}

/// Text properties, which a stack passes on to what it holds: font, size, weight, design, color, lines, alignment.
private struct TextStyle: ViewModifier {
    let node: WidgetNode

    func body(content: Content) -> some View {
        let font = Style.font(node)
        content
            .apply(font) { $0.font($1) }
            .apply(font == nil ? Style.weight(node.string("weight")) : nil) { $0.fontWeight($1) }
            .apply(font == nil ? Style.design(node.string("design")) : nil) { $0.fontDesign($1) }
            .apply(node.bool("italic") == true ? true : nil) { view, _ in view.italic() }
            .apply(node.bool("monospacedDigit") == true ? true : nil) { view, _ in view.monospacedDigit() }
            .apply(node.bool("strikethrough") == true ? true : nil) { view, _ in view.strikethrough() }
            .apply(node.bool("underline") == true ? true : nil) { view, _ in view.underline() }
            .apply(node.bool("uppercase") == true ? true : nil) { view, _ in view.textCase(.uppercase) }
            .apply(node.number("lineLimit").map { max(1, Int($0)) }) { $0.lineLimit($1) }
            .apply(node.number("minScale").map { CGFloat(min(max($0, 0.1), 1)) }) { $0.minimumScaleFactor($1) }
            .apply(Style.textAlignment(node.string("align"))) { $0.multilineTextAlignment($1) }
            .apply(Style.shapeStyle(node.props["color"])) { $0.foregroundStyle($1) }
            .apply(Style.color(node.props["tint"] ?? (["gauge", "progress"].contains(node.type) ? node.props["color"] : nil))) { $0.tint($1) }
    }
}

/// The box around a node: frame, padding, background, corners, border, opacity, and whether a tinted Home Screen
/// colors it.
private struct BoxStyle: ViewModifier {
    let node: WidgetNode

    func body(content: Content) -> some View {
        let frame = node.props["frame"]?.object ?? [:]
        let radius = node.number("cornerRadius").map { CGFloat(max($0, 0)) }
        let shape = RoundedRectangle(cornerRadius: radius ?? 0, style: .continuous)
        let alignment = Style.alignment(frame["alignment"]?.string) ?? .center
        let width = Style.dimension(frame["width"]), height = Style.dimension(frame["height"])
        let flexible = ["minWidth", "maxWidth", "minHeight", "maxHeight"].contains { frame[$0] != nil }
        let border = node.props["border"]?.object
        content
            .apply(width != nil || height != nil ? true : nil) { view, _ in view.frame(width: width, height: height, alignment: alignment) }
            .apply(flexible ? true : nil) { view, _ in
                view.frame(minWidth: Style.dimension(frame["minWidth"]), maxWidth: Style.dimension(frame["maxWidth"]),
                           minHeight: Style.dimension(frame["minHeight"]), maxHeight: Style.dimension(frame["maxHeight"]),
                           alignment: alignment)
            }
            .apply(Style.insets(node.props["padding"])) { $0.padding($1) }
            .apply(Style.shapeStyle(node.props["background"])) { $0.background($1, in: shape) }
            .apply(radius != nil || node.type == "image" ? true : nil) { view, _ in view.clipShape(shape) }
            .apply(border.flatMap { Style.color($0["color"]) ?? .secondary.opacity(0.4) }) { view, color in
                view.overlay(shape.strokeBorder(color, lineWidth: CGFloat(border?["width"]?.number ?? 1)))
            }
            .apply(node.number("opacity").map { min(max($0, 0), 1) }) { $0.opacity($1) }
            .apply(node.bool("loading") == true ? true : nil) { view, _ in view.invalidatableContent() }
            .apply(node.string("accessibility")) { $0.accessibilityLabel($1) }
            .widgetAccentable(node.bool("accent") == true)
    }
}

/// A tap area: opens the app in pi with this node's target (only on medium and larger widgets; a small widget is one
/// tap area, the whole widget).
private struct TapTarget: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            Link(destination: url) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// How the widget makes a button, with its App Intents (which only the widget has); without one, a button draws its
/// children only (pi's preview).
public struct WidgetButtonMaker: Sendable {
    public let make: @MainActor @Sendable (WidgetButtonAction, AnyView) -> AnyView

    public init(make: @escaping @MainActor @Sendable (WidgetButtonAction, AnyView) -> AnyView) {
        self.make = make
    }
}

extension EnvironmentValues {
    @Entry public var widgetButtonMaker: WidgetButtonMaker? = nil
}

extension View {
    @ViewBuilder func apply<Value, Result: View>(_ value: Value?, @ViewBuilder _ transform: (Self, Value) -> Result) -> some View {
        if let value { transform(self, value) } else { self }
    }
}

/// The layout's vocabulary of values: colors, fills, fonts, alignments, sizes.
enum Style {
    static func color(_ value: JSONValue?) -> Color? {
        guard let value else { return nil }
        if let object = value.object, let light = color(object["light"]) {
            let dark = color(object["dark"]) ?? light
            #if canImport(UIKit)
            let lightColor = UIColor(light), darkColor = UIColor(dark)
            return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
            #else
            return light
            #endif
        }
        guard let name = value.string?.trimmingCharacters(in: .whitespaces) else { return nil }
        if name.hasPrefix("#") { return hex(String(name.dropFirst())) }
        switch name.lowercased() {
        case "primary": return .primary
        case "secondary": return .secondary
        case "tertiary": return .primary.opacity(0.3)
        case "accent": return .accentColor
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "gray", "grey": return .gray
        case "white": return .white
        case "black": return .black
        case "clear": return .clear
        #if canImport(UIKit)
        case "background": return Color(uiColor: .systemBackground)
        case "secondarybackground": return Color(uiColor: .secondarySystemBackground)
        case "groupedbackground": return Color(uiColor: .systemGroupedBackground)
        #endif
        default: return nil
        }
    }

    /// "RGB", "RGBA", "RRGGBB" or "RRGGBBAA".
    static func hex(_ text: String) -> Color? {
        var digits = text
        if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let alpha = digits.count == 8
        let shift: UInt64 = alpha ? 8 : 0
        func channel(_ offset: UInt64) -> Double { Double((value >> (offset + shift)) & 0xFF) / 255 }
        return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0), opacity: alpha ? Double(value & 0xFF) / 255 : 1)
    }

    /// A color, or `{ gradient: "linear" | "radial" | "angular", colors, from?, to?, center?, radius? }`.
    static func shapeStyle(_ value: JSONValue?) -> AnyShapeStyle? {
        guard let value else { return nil }
        if let color = color(value) { return AnyShapeStyle(color) }
        guard let object = value.object, let kind = object["gradient"]?.string else { return nil }
        let colors = (object["colors"]?.array ?? []).compactMap(color)
        guard let first = colors.first else { return nil }
        let gradient = Gradient(colors: colors.count == 1 ? [first, first] : colors)
        let center = point(object["center"]?.string) ?? .center
        switch kind {
        case "radial":
            return AnyShapeStyle(RadialGradient(gradient: gradient, center: center, startRadius: 0, endRadius: CGFloat(object["radius"]?.number ?? 200)))
        case "angular":
            return AnyShapeStyle(AngularGradient(gradient: gradient, center: center))
        default:
            return AnyShapeStyle(LinearGradient(gradient: gradient, startPoint: point(object["from"]?.string) ?? .top,
                                                endPoint: point(object["to"]?.string) ?? .bottom))
        }
    }

    static func point(_ name: String?) -> UnitPoint? {
        switch name {
        case "top": .top
        case "bottom": .bottom
        case "leading": .leading
        case "trailing": .trailing
        case "topLeading": .topLeading
        case "topTrailing": .topTrailing
        case "bottomLeading": .bottomLeading
        case "bottomTrailing": .bottomTrailing
        case "center": .center
        default: nil
        }
    }

    static func alignment(_ name: String?) -> Alignment? {
        switch name {
        case "top": .top
        case "bottom": .bottom
        case "leading": .leading
        case "trailing": .trailing
        case "topLeading": .topLeading
        case "topTrailing": .topTrailing
        case "bottomLeading": .bottomLeading
        case "bottomTrailing": .bottomTrailing
        case "center": .center
        default: nil
        }
    }

    static func horizontal(_ name: String?) -> HorizontalAlignment {
        switch name {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }

    static func vertical(_ name: String?) -> VerticalAlignment {
        switch name {
        case "top": .top
        case "bottom": .bottom
        case "firstTextBaseline": .firstTextBaseline
        case "lastTextBaseline": .lastTextBaseline
        default: .center
        }
    }

    static func textAlignment(_ name: String?) -> TextAlignment? {
        switch name {
        case "leading": .leading
        case "center": .center
        case "trailing": .trailing
        default: nil
        }
    }

    static func font(_ node: WidgetNode) -> Font? {
        let weight = weight(node.string("weight")), design = design(node.string("design"))
        if let size = node.number("size") {
            return .system(size: CGFloat(min(max(size, 4), 200)), weight: weight ?? .regular, design: design ?? .default)
        }
        if let style = textStyle(node.string("font")) { return .system(style, design: design, weight: weight) }
        return nil
    }

    static func textStyle(_ name: String?) -> Font.TextStyle? {
        switch name {
        case "largeTitle": .largeTitle
        case "title": .title
        case "title2": .title2
        case "title3": .title3
        case "headline": .headline
        case "subheadline": .subheadline
        case "body": .body
        case "callout": .callout
        case "footnote": .footnote
        case "caption": .caption
        case "caption2": .caption2
        default: nil
        }
    }

    static func weight(_ name: String?) -> Font.Weight? {
        switch name {
        case "ultraLight": .ultraLight
        case "thin": .thin
        case "light": .light
        case "regular": .regular
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        case "black": .black
        default: nil
        }
    }

    static func design(_ name: String?) -> Font.Design? {
        switch name {
        case "default": .default
        case "rounded": .rounded
        case "serif": .serif
        case "monospaced": .monospaced
        default: nil
        }
    }

    /// A number for every edge, true for the system's padding, or `{ top, leading, bottom, trailing, horizontal, vertical }`.
    static func insets(_ value: JSONValue?) -> EdgeInsets? {
        guard let value else { return nil }
        if let all = value.number { return EdgeInsets(top: all, leading: all, bottom: all, trailing: all) }
        if value.bool == true { return EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16) }
        guard let object = value.object else { return nil }
        let horizontal = object["horizontal"]?.number ?? 0, vertical = object["vertical"]?.number ?? 0
        return EdgeInsets(top: object["top"]?.number ?? vertical, leading: object["leading"]?.number ?? horizontal,
                          bottom: object["bottom"]?.number ?? vertical, trailing: object["trailing"]?.number ?? horizontal)
    }

    /// Points, or "infinity" (as wide or tall as there's room for).
    static func dimension(_ value: JSONValue?) -> CGFloat? {
        if value?.string == "infinity" { return .infinity }
        return value?.number.map { CGFloat(max($0, 0)) }
    }

    static func accentedMode(_ name: String?) -> WidgetAccentedRenderingMode? {
        switch name {
        case "accented": .accented
        case "desaturated": .desaturated
        case "accentedDesaturated": .accentedDesaturated
        case "fullColor": .fullColor
        default: nil
        }
    }

    /// An image pi saved for the widget ("file:<name>").
    static func image(_ src: String?) -> Image? {
        guard let src, src.hasPrefix("file:"), let url = WidgetStore.imageURL(String(src.dropFirst("file:".count))) else { return nil }
        #if canImport(UIKit)
        return UIImage(contentsOfFile: url.path()).map { Image(uiImage: $0) }
        #else
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #endif
    }
}

/// An app's widget for one size: the extension's layout for it, else the app's icon and name.
public struct WidgetCanvas: View {
    let app: WidgetApp?
    let appID: String?
    let entry: WidgetContent.Entry?
    let family: String
    let margins: EdgeInsets

    /// `appID`: the app tap areas open (nil in a preview); `margins`: the system's content margins.
    public init(app: WidgetApp?, appID: String?, entry: WidgetContent.Entry?, family: String, margins: EdgeInsets) {
        self.app = app
        self.appID = appID
        self.entry = entry
        self.family = family
        self.margins = margins
    }

    public var body: some View {
        if let entry, let node = entry.layout(for: family) {
            WidgetNodeView(node: node, appID: appID)
                .padding(entry.margins ? margins : EdgeInsets())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WidgetPlaceholderView(title: app?.title ?? "pi app", icon: app?.icon, family: family)
                .padding(margins)
        }
    }

    /// The widget's background, as the entry gives it (nil: the system's).
    public static func background(of entry: WidgetContent.Entry?) -> AnyShapeStyle? {
        Style.shapeStyle(entry?.background)
    }
}

/// An app without a widget of its own: its icon and name, as its dock entry shows them.
public struct WidgetPlaceholderView: View {
    let title: String
    let icon: String?
    let family: String

    public init(title: String, icon: String?, family: String) {
        self.title = title
        self.icon = icon
        self.family = family
    }

    private var symbol: String { icon ?? "app.dashed" }

    public var body: some View {
        switch family {
        case "inline":
            Label(title, systemImage: symbol)
        case "circular":
            ZStack {
                #if os(iOS)
                AccessoryWidgetBackground()
                #endif
                Image(systemName: symbol).font(.title2.weight(.semibold))
            }
        case "rectangular":
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.title2.weight(.semibold))
                Text(title).font(.headline).lineLimit(2)
                Spacer(minLength: 0)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: family == "small" ? 30 : 36, weight: .semibold))
                    .foregroundStyle(.tint)
                    .widgetAccentable()
                Spacer(minLength: 0)
                Text(title).font(.headline).lineLimit(2)
                Text("pi").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
