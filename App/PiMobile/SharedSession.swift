import SwiftUI
import UniformTypeIdentifiers

/// Sharing a session between phones (or keeping it): Share Session (in its ⋯ menu) sends a `.pisession` file through the
/// share sheet, holding everything durable about it (every entry of its history, its agent's settings, its own
/// extensions, its apps' records) and its workspace's files; opening one in pi (AirDrop, Messages, Mail, Files) asks,
/// then adds it as a new session. The engine packs and unpacks the durable part (`session.export`, `session.import`).
extension UTType {
    static let piSession = UTType(exportedAs: "dev.pimobile.session")
}

/// A shared session file opened in pi, waiting for the user to open it (or not).
struct SharedSessionOffer: Identifiable {
    let id = UUID()
    /// The bundle, as the engine reads it (without the files), and the workspace's files.
    let shared: [String: Any]
    let files: [String: String]
    let title: String
    let model: String?
    let messages: Int
    let extensions: [String]
    let size: Int
    let skipped: [String]

    init?(_ data: Data) {
        let json = (try? (data as NSData).decompressed(using: .zlib) as Data).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            ?? (try? JSONSerialization.jsonObject(with: data))
        guard var bundle = json as? [String: Any], bundle["pi"] as? String == "session", bundle["entries"] is [Any] else { return nil }
        files = bundle.removeValue(forKey: "files") as? [String: String] ?? [:]
        skipped = bundle["skippedFiles"] as? [String] ?? []
        shared = bundle
        title = bundle["title"] as? String ?? "Session"
        model = (bundle["model"] as? [String: Any]).map { "\($0["provider"] ?? "?") · \($0["modelId"] ?? "?")" }
        messages = (bundle["entries"] as? [[String: Any]] ?? []).filter { ["pi.user", "pi.assistant"].contains($0["kind"] as? String) }.count
        extensions = (bundle["extensions"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        size = files.values.reduce(0) { $0 + $1.count * 3 / 4 }
    }
}

extension AppModel {
    /// Folders of a workspace that stay behind: installed packages and caches, which the other phone makes again.
    private static let leftBehind: Set<String> = [".python", "node_modules", "__pycache__", ".cache"]
    /// At most this much of a workspace's files travel with a session.
    private static let sharedFilesLimit = 50 * 1024 * 1024

    /// A session as a `.pisession` file to share: the engine's durable part, and its workspace's files.
    func shareSessionFile(_ id: Int) async throws -> URL {
        guard var bundle = try await engine.command("session.export", ["id": id]) as? [String: Any] else { throw AppError.message("The session couldn't be packed") }
        let (files, skipped) = Self.workspaceFiles(of: id)
        bundle["files"] = files
        if !skipped.isEmpty { bundle["skippedFiles"] = skipped }
        let json = try JSONSerialization.data(withJSONObject: bundle)
        let packed = try (json as NSData).compressed(using: .zlib) as Data
        let folder = FileManager.default.temporaryDirectory.appending(path: "shared-sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (bundle["title"] as? String ?? "Session").replacing(#/[^\w .-]+/#, with: "-").trimmingCharacters(in: .whitespaces)
        let file = folder.appending(path: "\(name.isEmpty ? "Session" : String(name.prefix(60))).pisession")
        try packed.write(to: file, options: .atomic)
        log("ui", "sharing session \(id): \((bundle["entries"] as? [Any])?.count ?? 0) entries, \(files.count) files, \(packed.count) bytes")
        return file
    }

    /// A session's workspace files (base64, by path), up to the limit; the ones that stayed behind.
    private static func workspaceFiles(of id: Int) -> (files: [String: String], skipped: [String]) {
        let workspace = URL.documentsDirectory.appending(path: "sessions/\(id)", directoryHint: .isDirectory)
        var files: [String: String] = [:]
        var skipped: [String] = []
        var total = 0
        guard let walker = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else {
            return ([:], [])
        }
        while let file = walker.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true, leftBehind.contains(file.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let path = String(file.path.dropFirst(workspace.path.count).trimmingPrefix("/"))
            let size = values?.fileSize ?? 0
            guard total + size <= sharedFilesLimit, let data = try? Data(contentsOf: file) else {
                skipped.append(path)
                continue
            }
            files[path] = data.base64EncodedString()
            total += size
        }
        return (files, skipped)
    }

    /// Opens a shared session as a new one: its history, then its files, then its extensions; its id.
    func importSharedSession(_ offer: SharedSessionOffer) async throws -> Int {
        var parameters: [String: Any] = ["shared": offer.shared]
        if let defaultModel { parameters["model"] = ["provider": defaultModel.provider, "modelId": defaultModel.modelId] }
        guard let result = try await engine.command("session.import", parameters) as? [String: Any], let id = result["id"] as? Int else {
            throw AppError.message("The session couldn't be opened")
        }
        let workspace = URL.documentsDirectory.appending(path: "sessions/\(id)", directoryHint: .isDirectory)
        for (path, encoded) in offer.files {
            // Only paths inside the workspace.
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), let data = Data(base64Encoded: encoded) else { continue }
            let target = workspace.appending(path: path)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target)
        }
        if let records = offer.shared["extensions"] as? [Any], !records.isEmpty {
            let adopted = try? await engine.command("session.importExtensions", ["id": id, "extensions": records]) as? [String: Any]
            if let skipped = adopted?["skipped"] as? [String], !skipped.isEmpty { log("ui", "shared session: extensions left behind: \(skipped.joined(separator: ", "))") }
        }
        addImportedSession(result)
        log("ui", "shared session \"\(offer.title)\" opened as \(id) (\(offer.files.count) files)")
        return id
    }
}

/// Opening a shared session: what it is, before adding it.
struct SharedSessionSheet: View {
    let app: AppModel
    let offer: SharedSessionOffer
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(offer.title).font(.title3.bold())
                    if let model = offer.model { LabeledContent("Model", value: model) }
                    LabeledContent("Messages", value: "\(offer.messages)")
                    LabeledContent("Files", value: offer.files.isEmpty ? "None" : "\(offer.files.count), \(ByteCountFormatter.string(fromByteCount: Int64(offer.size), countStyle: .file))")
                    if !offer.extensions.isEmpty { LabeledContent("Extensions", value: offer.extensions.joined(separator: ", ")) }
                } footer: {
                    Text(offer.skipped.isEmpty
                         ? "Opens as a new session with its whole history and workspace. Its extensions are added for it from where they came from."
                         : "Opens as a new session with its whole history. \(offer.skipped.count) large files stayed behind.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button {
                        open()
                    } label: {
                        HStack {
                            Text("Open Session")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(working)
                }
            }
            .navigationTitle("Shared Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }

    private func open() {
        working = true
        Task {
            do {
                let id = try await app.importSharedSession(offer)
                dismiss()
                app.requestedSession = id
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
