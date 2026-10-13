import Foundation

/// A JSON value, as an extension wrote it.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public subscript(key: String) -> JSONValue? { object?[key] }
}

/// What the widget and the app agree on: the widget's kind, and the URL a tap opens.
public enum WidgetLayout {
    public static let kind = "PiAppWidget"
    public static let scheme = "pimobile"

    /// Opens the app (`id`, a `WidgetApp.id`) full screen in pi; `target` is what a tap area named (`open`), for the
    /// extension's `onWidgetOpen`.
    public static func openURL(app id: String, target: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "widget"
        components.queryItems = [URLQueryItem(name: "app", value: id)] + (target.map { [URLQueryItem(name: "target", value: $0)] } ?? [])
        return components.url!
    }

    /// The app and target of a widget's URL, or nil for another URL.
    public static func parse(_ url: URL) -> (app: String, target: String?)? {
        guard url.scheme == scheme, url.host() == "widget",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let app = items.first(where: { $0.name == "app" })?.value, !app.isEmpty else { return nil }
        return (app, items.first { $0.name == "target" }?.value)
    }

    /// The layout key of each widget size an extension can draw for.
    public static let families = ["small", "medium", "large", "extraLarge", "circular", "rectangular", "inline"]
    static let systemFamilies: Set<String> = ["small", "medium", "large", "extraLarge"]
}

/// One view of an extension's widget layout: its type ("vstack", "text", …), its properties, and its children.
public struct WidgetNode: Hashable, Sendable {
    /// How deep layouts may nest, and how many nodes one may have (the engine checks the same, with messages).
    public static let maxDepth = 24
    public static let maxNodes = 600

    public let type: String
    public let props: [String: JSONValue]
    public let children: [WidgetNode]

    public init(type: String, props: [String: JSONValue] = [:], children: [WidgetNode] = []) {
        self.type = type
        self.props = props
        self.children = children
    }

    /// A node from JSON; nil for anything that isn't one. Children past the limits are left out.
    public init?(json: JSONValue) {
        var budget = Self.maxNodes
        self.init(json: json, depth: 0, budget: &budget)
    }

    private init?(json: JSONValue, depth: Int, budget: inout Int) {
        guard var props = json.object, let type = props["type"]?.string, budget > 0, depth < Self.maxDepth else { return nil }
        budget -= 1
        let children = props.removeValue(forKey: "children")?.array ?? []
        props.removeValue(forKey: "type")
        var parsed: [WidgetNode] = []
        for child in children {
            if let node = WidgetNode(json: child, depth: depth + 1, budget: &budget) { parsed.append(node) }
        }
        self.init(type: type, props: props, children: parsed)
    }

    public func string(_ key: String) -> String? { props[key]?.string }
    public func number(_ key: String) -> Double? { props[key]?.number }
    public func bool(_ key: String) -> Bool? { props[key]?.bool }
}

/// An extension's widget, as the engine stored it: what it shows now, and later entries (a timeline).
public struct WidgetContent: Sendable {
    public struct Entry: Sendable {
        /// When it shows; nil: from the start.
        public let date: Date?
        /// Layouts by size ("small", …), and "default" for sizes without their own.
        public let layouts: [String: WidgetNode]
        /// The widget's background (a color or gradient); nil: the system's.
        public let background: JSONValue?
        /// Whether the layout sits inside the system's margins (the default) or reaches the widget's edges.
        public let margins: Bool

        /// The layout for a size: its own, else "default"; a Home Screen size falls back to another Home Screen size's.
        /// Lock Screen sizes without their own show the app's icon and name.
        public func layout(for family: String) -> WidgetNode? {
            if let own = layouts[family] { return own }
            guard WidgetLayout.systemFamilies.contains(family) else { return nil }
            if let fallback = layouts["default"] { return fallback }
            let order = ["medium", "small", "large", "extraLarge"]
            return order.lazy.compactMap { layouts[$0] }.first
        }
    }

    public let entries: [Entry]
    /// Other looks its buttons switch to (`show`), by name.
    public let views: [String: Entry]
    public let updatedAt: Date

    public init(entries: [Entry], views: [String: Entry] = [:], updatedAt: Date = .now) {
        self.entries = entries
        self.views = views
        self.updatedAt = updatedAt
    }

    /// The stored JSON: `{ version: 1, updatedAt, entries: [{ date, layouts, background, margins }], views: { name: { … } } }`
    /// (dates in ms).
    public init?(data: Data) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), let entries = json["entries"]?.array else { return nil }
        func entry(_ value: JSONValue) -> Entry? {
            guard let layouts = value["layouts"]?.object else { return nil }
            return Entry(date: value["date"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) },
                         layouts: layouts.compactMapValues(WidgetNode.init(json:)),
                         background: value["background"].flatMap { $0 == .null ? nil : $0 },
                         margins: value["margins"]?.bool ?? true)
        }
        self.entries = entries.compactMap(entry)
        views = (json["views"]?.object ?? [:]).compactMapValues(entry)
        updatedAt = json["updatedAt"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
        if self.entries.isEmpty { return nil }
    }

    /// The entry on screen at `date`: the latest one that has started.
    public func entry(at date: Date) -> Entry? {
        entries.filter { ($0.date ?? .distantPast) <= date }.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) } ?? entries.first
    }
}

/// A Live Activity, as its extension drew it last: the Lock Screen's view and the Dynamic Island's regions.
public struct ActivityLayout: Sendable {
    public let lockScreen: WidgetNode?
    public let compactLeading: WidgetNode?
    public let compactTrailing: WidgetNode?
    public let minimal: WidgetNode?
    public let expandedLeading: WidgetNode?
    public let expandedTrailing: WidgetNode?
    public let expandedCenter: WidgetNode?
    public let expandedBottom: WidgetNode?
    /// Behind the Lock Screen's view (a color or gradient); nil: the system's.
    public let background: JSONValue?
    /// The Dynamic Island's keyline, and the color of its default regions.
    public let tint: JSONValue?
    /// Whether the Lock Screen's view sits inside the system's margins (the default).
    public let margins: Bool

    /// Whether it has any expanded region (without, the expanded island shows the Lock Screen's view).
    public var hasExpanded: Bool { [expandedLeading, expandedTrailing, expandedCenter, expandedBottom].contains { $0 != nil } }

    /// The stored JSON: `{ version: 1, lockScreen, compactLeading, compactTrailing, minimal, expanded: { leading, trailing,
    /// center, bottom }, background, tint, margins }`.
    public init?(data: Data) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), json.object != nil else { return nil }
        let node = { (value: JSONValue?) in value.flatMap(WidgetNode.init(json:)) }
        lockScreen = node(json["lockScreen"])
        compactLeading = node(json["compactLeading"])
        compactTrailing = node(json["compactTrailing"])
        minimal = node(json["minimal"])
        expandedLeading = node(json["expanded"]?["leading"])
        expandedTrailing = node(json["expanded"]?["trailing"])
        expandedCenter = node(json["expanded"]?["center"])
        expandedBottom = node(json["expanded"]?["bottom"])
        background = json["background"].flatMap { $0 == .null ? nil : $0 }
        tint = json["tint"].flatMap { $0 == .null ? nil : $0 }
        margins = json["margins"]?.bool ?? true
    }
}

/// What a widget button does.
public enum WidgetButtonAction: Hashable, Sendable {
    /// Runs the extension's handler (`pi.widget.onAction`) in pi, with the button's value as JSON.
    case run(action: String, value: String?)
    /// Shows another of the widget's looks (`views`); nil: the main one.
    case show(view: String?)
}

/// An app the widget can show and open: an extension's app (`pi.registerApp`), as the engine last loaded it.
public struct WidgetApp: Codable, Hashable, Sendable, Identifiable {
    /// "extension/app", with "@<session id>" for an app of one session's own extension.
    public let id: String
    public let extensionName: String
    public let name: String
    public let title: String
    public let icon: String?
    public let description: String?
    /// "default" (an extension for every session) or "session:<id>".
    public let scope: String

    public init(extensionName: String, name: String, title: String, icon: String?, description: String?, scope: String) {
        self.extensionName = extensionName
        self.name = name
        self.title = title
        self.icon = icon
        self.description = description
        self.scope = scope
        id = Self.id(extension: extensionName, app: name, scope: scope)
    }

    /// The app's key in pi's sessions ("extension/app").
    public var key: String { "\(extensionName)/\(name)" }
    /// The session whose own extension it is; nil for an extension of every session.
    public var sessionId: Int? { scope.hasPrefix("session:") ? Int(scope.dropFirst("session:".count)) : nil }

    public static func id(extension name: String, app: String, scope: String) -> String {
        scope.hasPrefix("session:") ? "\(name)/\(app)@\(scope.dropFirst("session:".count))" : "\(name)/\(app)"
    }

    /// The key and session of an id.
    public static func parse(id: String) -> (key: String, sessionId: Int?) {
        guard let at = id.lastIndex(of: "@"), let session = Int(id[id.index(after: at)...]) else { return (id, nil) }
        return (String(id[..<at]), session)
    }
}
