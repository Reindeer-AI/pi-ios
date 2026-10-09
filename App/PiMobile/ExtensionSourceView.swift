import SwiftUI

/// An extension's source (Settings → Extensions → an extension → Source): its files, each to read and change. Saving
/// one loads the extension again where it's loaded, so the code pi runs is always code the user can see and edit.
struct ExtensionSourceView: View {
    let app: AppModel
    let name: String
    /// The session whose own extension it is; nil for a default.
    let sessionId: Int?
    /// Installed from GitHub: an update replaces local changes.
    let fromGitHub: Bool
    @State private var root: String?
    @State private var files: [String] = []
    @State private var error: String?

    var body: some View {
        List {
            if let root {
                Section {
                    ForEach(files, id: \.self) { file in
                        NavigationLink {
                            ExtensionFileView(path: "\(root)/\(file)", title: file) { try await reload() }
                        } label: {
                            Text(file).font(.footnote.monospaced())
                        }
                    }
                } footer: {
                    Text(fromGitHub
                         ? "Saving a file loads the extension again. Your changes stay until its folder on GitHub changes; that update replaces them."
                         : "Saving a file loads the extension again.")
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Source")
        .task { await load() }
    }

    private var parameters: [String: Any] {
        var parameters: [String: Any] = ["name": name]
        if let sessionId { parameters["sessionId"] = sessionId }
        return parameters
    }

    private func load() async {
        do {
            let json = try await app.engine.command("extensions.source", parameters) as? [String: Any] ?? [:]
            files = json["files"] as? [String] ?? []
            root = json["root"] as? String
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reload() async throws {
        _ = try await app.engine.command("extensions.reload", parameters)
    }
}

/// One file of an extension: its text, editable, saved in place; a binary or very large file is shown, not edited.
private struct ExtensionFileView: View {
    let path: String
    let title: String
    let reload: () async throws -> Void
    @State private var text = ""
    @State private var saved = ""
    @State private var state: FileState = .loading
    @State private var saving = false
    @State private var notice: String?
    @State private var failure: String?

    private enum FileState { case loading, text, binary(Int), tooLarge(Int), missing(String) }

    /// Past this, TextEditor gets slow: such a file (a bundled CLI) is offered to another app instead.
    private static let editableLimit = 1_000_000

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
            case .text:
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .safeAreaInset(edge: .bottom) {
                        if let message = failure ?? notice {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(.bar)
                        }
                    }
            case .binary(let size):
                unavailable("Binary file", size: size)
            case .tooLarge(let size):
                unavailable("Too large to edit here", size: size)
            case .missing(let message):
                ContentUnavailableView("Can't open it", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .text = state {
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }.disabled(text == saved)
                    }
                }
            }
        }
        .task { open() }
    }

    private func unavailable(_ title: String, size: Int) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "doc")
        } description: {
            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        } actions: {
            ShareLink(item: URL(fileURLWithPath: path)) { Text("Open in Another App") }
        }
    }

    private func open() {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if data.count > Self.editableLimit {
                state = .tooLarge(data.count)
            } else if let string = String(data: data, encoding: .utf8) {
                text = string
                saved = string
                state = .text
            } else {
                state = .binary(data.count)
            }
        } catch {
            state = .missing(error.localizedDescription)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        notice = nil
        failure = nil
        let content = text
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            saved = content
        } catch {
            failure = "Not saved: \(error.localizedDescription)"
            return
        }
        do {
            try await reload()
            notice = "Saved and loaded."
        } catch {
            failure = "Saved, but it didn't load, so the previous version keeps running: \(error.localizedDescription)"
        }
    }
}
