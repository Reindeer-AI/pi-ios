import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

// Files the user drops into a session or picks (Files, Photos): copied aside until the message is sent, then moved into
// the session's workspace (`AppModel.attach`), and named in the message as `attachment:<path>` lines for the model.

/// A file waiting to be sent with the next message.
struct StagedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var name: String { url.lastPathComponent }
    var size: Int64 { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0 }

    /// A copy of a file (one the app may only read for a while: a picked or dropped one), under its own name.
    static func copy(of file: URL, named name: String? = nil) throws -> StagedFile {
        let folder = URL.temporaryDirectory.appending(path: "pi-attachments/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: name ?? file.lastPathComponent)
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: file, to: target)
        return StagedFile(url: target)
    }

    /// Bytes (a photo) as a file named `name`.
    static func write(_ data: Data, named name: String) throws -> StagedFile {
        let folder = URL.temporaryDirectory.appending(path: "pi-attachments/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: name)
        try data.write(to: target)
        return StagedFile(url: target)
    }
}

/// Whatever is dropped on a session, as a file.
struct DroppedFile: Transferable {
    let staged: StagedFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            DroppedFile(staged: try StagedFile.copy(of: received.file))
        }
    }
}

/// A message's text and the files attached to it (its `attachment:` lines).
enum Attachments {
    static let prefix = "attachment:"

    static func split(_ text: String) -> (text: String, paths: [String]) {
        var lines: [Substring] = []
        var paths: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(prefix) { paths.append(String(line.dropFirst(prefix.count))) } else { lines.append(line) }
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }

    static func lines(_ paths: [String]) -> String {
        paths.map { prefix + $0 }.joined(separator: "\n")
    }

    static func symbol(for name: String) -> String {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .audio) { return "play.rectangle" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .json) { return "chevron.left.forwardslash.chevron.right" }
        return "doc.text"
    }
}

/// The files waiting to go with the next message, each removable.
struct StagedFiles: View {
    @Binding var files: [StagedFile]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files) { file in
                    HStack(spacing: 6) {
                        Image(systemName: Attachments.symbol(for: file.name)).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(file.name).font(.caption).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("Remove \(file.name)", systemImage: "xmark.circle.fill") {
                            files.removeAll { $0.id == file.id }
                            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
                        }
                        .labelStyle(.iconOnly).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: .capsule)
                    .frame(maxWidth: 240)
                }
            }
        }
    }
}

/// An attached file in a sent message.
struct AttachmentLabel: View {
    let path: String

    var body: some View {
        Label((path as NSString).lastPathComponent, systemImage: Attachments.symbol(for: path))
            .font(.footnote)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.tint.opacity(0.10), in: .capsule)
            .accessibilityLabel("Attached \((path as NSString).lastPathComponent)")
    }
}
