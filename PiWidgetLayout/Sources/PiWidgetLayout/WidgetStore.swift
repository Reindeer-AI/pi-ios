import Foundation

/// The files pi and its widget extension share, in their App Group ("group." and pi's bundle ID):
///
///     Widgets/apps.json              the apps the widget can show (`WidgetApp`), as the engine last loaded them
///     Widgets/content/<id>.json      an app's widget, as its extension drew it last (`WidgetContent`)
///     Widgets/images/<hash>.<ext>    the images its layouts show, as pi saved them
///     Widgets/views.json             the look each app's widgets show, when a button switched it (`show`)
///
/// pi writes them, except views.json, which the widget's buttons write. A build without the App Group (it needs its
/// own provisioning) has no directory: pi then keeps no widgets.
public enum WidgetStore {
    /// pi's App Group, for the app and for its widget extension (whose bundle ID is pi's and ".widgets").
    public static var groupIdentifier: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        return "group." + (id.hasSuffix(".widgets") ? String(id.dropLast(".widgets".count)) : id)
    }

    public static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appending(path: "Widgets", directoryHint: .isDirectory)
    }

    public static var isAvailable: Bool { directory != nil }

    // MARK: Apps

    public static func apps() -> [WidgetApp] {
        guard let url = directory?.appending(path: "apps.json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([WidgetApp].self, from: data)) ?? []
    }

    public static func app(id: String) -> WidgetApp? {
        apps().first { $0.id == id }
    }

    /// Replaces the apps of one extension in one scope (an extension that loaded); `apps` empty forgets them.
    public static func setApps(_ apps: [WidgetApp], extension name: String, scope: String) throws {
        guard let directory else { return }
        var all = self.apps().filter { !($0.extensionName == name && $0.scope == scope) }
        all.append(contentsOf: apps)
        all.sort { ($0.title.localizedLowercase, $0.id) < ($1.title.localizedLowercase, $1.id) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: directory.appending(path: "apps.json"), options: .atomic)
    }

    // MARK: Content

    public static func content(for id: String) -> WidgetContent? {
        guard let url = contentURL(for: id), let data = try? Data(contentsOf: url) else { return nil }
        return WidgetContent(data: data)
    }

    /// An app's widget as the engine stored it (nil removes it).
    public static func setContent(_ data: Data?, for id: String) throws {
        guard let url = contentURL(for: id) else { return }
        guard let data else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// The ids of the apps that drew a widget.
    public static func contentIDs() -> [String] {
        guard let folder = directory?.appending(path: "content"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path()) else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            return Data(base64URL: String(name.dropLast(".json".count))).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    private static func contentURL(for id: String) -> URL? {
        directory?.appending(path: "content").appending(path: Data(id.utf8).base64URL + ".json")
    }

    // MARK: Views

    /// The look a button switched an app's widgets to (nil: the main one).
    public static func view(for id: String) -> String? {
        guard let url = directory?.appending(path: "views.json"), let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode([String: String].self, from: data))?[id]
    }

    public static func setView(_ view: String?, for id: String) {
        guard let directory else { return }
        let url = directory.appending(path: "views.json")
        var views = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        views[id] = view
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(views).write(to: url, options: .atomic)
    }

    // MARK: Images

    /// A saved image's file (`src` "file:<name>" in a layout).
    public static func imageURL(_ name: String) -> URL? {
        guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return directory?.appending(path: "images").appending(path: name)
    }

    /// Saves an image under a name from its contents, and returns the name.
    public static func saveImage(_ data: Data, named name: String) throws -> String {
        guard let url = imageURL(name) else { return name }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path()) { try data.write(to: url, options: .atomic) }
        return name
    }

    /// Removes images no widget shows any more.
    public static func removeUnusedImages() {
        guard let folder = directory?.appending(path: "images"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path()) else { return }
        var used = Set<String>()
        for id in contentIDs() {
            guard let url = contentURL(for: id), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for name in names where text.contains("file:\(name)") { used.insert(name) }
        }
        for name in names where !used.contains(name) { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
