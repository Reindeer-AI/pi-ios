import SwiftUI
import UniformTypeIdentifiers

/// Sharing extensions (and so their apps) between phones: Share (on an extension in Settings → Extensions and skills,
/// or on an app in a session's dock) sends a `.piext` file through the share sheet; opening one in pi (AirDrop, Messages,
/// Mail, Files) asks before adding it for every session. One installed from GitHub, npm or git travels as where to get it
/// (so it updates the same way, and a private repository still needs access); one written here travels as its files.
/// The engine makes and adds them (`extensions.share`, `extensions.import`).
extension UTType {
    static let piExtension = UTType(exportedAs: "dev.pimobile.extension")
}

/// A shared extension file opened in pi, waiting for the user to add it (or not).
struct SharedExtensionOffer: Identifiable {
    let id = UUID()
    /// The file's contents, as the engine reads them.
    let shared: [String: Any]
    let name: String
    let version: String?
    let description: String?
    let source: String?
    let fileCount: Int
    let size: Int
    let tools: [String]
    let apps: [(title: String, icon: String?)]

    init?(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["pi"] as? String == "extension",
              let name = json["name"] as? String, !name.isEmpty else { return nil }
        shared = json
        self.name = name
        version = json["version"] as? String
        description = json["description"] as? String
        source = json["source"] as? String
        let files = json["files"] as? [String: String] ?? [:]
        fileCount = files.count
        size = files.values.reduce(0) { $0 + $1.count * 3 / 4 }
        tools = json["tools"] as? [String] ?? []
        apps = (json["apps"] as? [[String: Any]] ?? []).map { ($0["title"] as? String ?? $0["name"] as? String ?? "?", $0["icon"] as? String) }
    }
}

/// A file for the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

extension AppModel {
    /// A file opened in pi: a shared extension (`.piext`) waits for the user's answer.
    func openShared(_ url: URL) {
        guard url.isFileURL, ["piext", "pisession"].contains(url.pathExtension.lowercased()) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            // iOS copied it into the app's Inbox for us: done with it.
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        }
        if url.pathExtension.lowercased() == "pisession" {
            guard let data = try? Data(contentsOf: url), let offer = SharedSessionOffer(data) else {
                log("error", "shared session: \(url.lastPathComponent) is not a pi session")
                return
            }
            log("ui", "shared session \(offer.title) opened")
            sharedSession = offer
            return
        }
        guard let data = try? Data(contentsOf: url), let offer = SharedExtensionOffer(data) else {
            log("error", "shared extension: \(url.lastPathComponent) is not a pi extension")
            return
        }
        log("ui", "shared extension \(offer.name) opened")
        sharedExtension = offer
    }

    /// Adds a shared extension for every session; what it added.
    func importShared(_ offer: SharedExtensionOffer) async throws -> String {
        let result = try await engine.command("extensions.import", ["shared": offer.shared]) as? [String: Any] ?? [:]
        let tools = result["tools"] as? [String] ?? []
        log("ui", "shared extension \(offer.name) added (\(tools.count) tools)")
        return [result["name"] as? String ?? offer.name, tools.isEmpty ? nil : (tools.count == 1 ? "1 tool" : "\(tools.count) tools")]
            .compactMap { $0 }.joined(separator: ": ")
    }

    /// A session's extension (or a default) as a `.piext` file to share.
    func shareFile(extension name: String, sessionId: Int? = nil) async throws -> URL {
        var parameters: [String: Any] = ["name": name]
        if let sessionId { parameters["sessionId"] = sessionId }
        let shared = try await engine.command("extensions.share", parameters)
        let data = try JSONSerialization.data(withJSONObject: shared ?? [:], options: [.prettyPrinted, .sortedKeys])
        let folder = FileManager.default.temporaryDirectory.appending(path: "shared-extensions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(name.replacing(#/[^\w.-]+/#, with: "-")).piext")
        try data.write(to: file, options: .atomic)
        log("ui", "sharing extension \(name)")
        return file
    }
}

/// Opening a shared extension: what it is, what it brings, and a word on trust, before adding it for every session.
struct SharedExtensionSheet: View {
    let app: AppModel
    let offer: SharedExtensionOffer
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var added: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(offer.version.map { "\(offer.name) \($0)" } ?? offer.name).font(.title3.bold())
                        if let description = offer.description { Text(description).foregroundStyle(.secondary) }
                    }
                    if let source = offer.source {
                        LabeledContent("From", value: source)
                    } else {
                        LabeledContent("Its code", value: "\(offer.fileCount == 1 ? "1 file" : "\(offer.fileCount) files"), \(ByteCountFormatter.string(fromByteCount: Int64(offer.size), countStyle: .file))")
                    }
                }
                if !offer.apps.isEmpty {
                    Section("Apps") {
                        ForEach(offer.apps.indices, id: \.self) { index in
                            Label(offer.apps[index].title, systemImage: UIImage(systemName: offer.apps[index].icon ?? "") == nil ? "app" : offer.apps[index].icon!)
                        }
                    }
                }
                if !offer.tools.isEmpty {
                    Section("Tools") { ForEach(offer.tools, id: \.self) { Text($0).font(.body.monospaced()) } }
                }
                Section {
                    if let added {
                        Label("Added \(added). Every session has it now.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button {
                            add()
                        } label: {
                            HStack {
                                Text("Add to Every Session")
                                if working { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(working)
                    }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red) }
                } footer: {
                    Text(offer.source == nil
                         ? "An extension runs code in pi, with the secrets you let it read. Add one only from someone you trust."
                         : "An extension runs code in pi, with the secrets you let it read. Add one only from someone you trust. It comes from its source, with your sign-in for a private repository, and updates from there.")
                }
            }
            .navigationTitle("Shared Extension")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(added == nil ? "Cancel" : "Done") { dismiss() } }
            }
        }
    }

    private func add() {
        working = true
        error = nil
        Task {
            do {
                added = try await app.importShared(offer)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// iOS's share sheet for a file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
