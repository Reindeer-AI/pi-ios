import PiEngineKit
import SwiftUI

/// Settings → Extensions: the extensions every session gets (on or off), the app's skills, and what sessions added for
/// themselves; remove any of them, make a session's extension a default, or add a default from npm or git.
struct ExtensionsView: View {
    let app: AppModel
    @State private var inventory: Inventory?
    @State private var skills: [Skill] = []
    @State private var error: String?
    /// What the last action found ("Up to date", "Updated flights").
    @State private var notice: String?
    @State private var working: String?
    @State private var adding = false
    @State private var source = ""
    @State private var removing: Removal?
    @State private var secrets: [ExtensionSecretsService.Entry] = []
    @State private var editingSecret: SecretDraft?
    /// An extension being shared (`SharedExtension.swift`).
    @State private var sharing: SharedFile?
    /// Extensions' background checks (`BackgroundChecks.swift`).
    private let checks = BackgroundChecks.shared

    /// A secret being added (no `existing`) or changed.
    struct SecretDraft: Identifiable {
        var id: String { existing ?? "new" }
        var existing: String?
        var name = ""
        var value = ""
        var everyExtension = true
        var extensions: Set<String> = []
    }

    struct Item: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let version: String?
        let source: String
        /// From GitHub: the installed folder's tree hash.
        let revision: String?
        let enabled: Bool
        let tools: [String]
        let skills: Bool
        let notes: [String]
        let addedAt: Date

        init(_ json: [String: Any]) {
            name = json["name"] as? String ?? "?"
            version = json["version"] as? String
            source = json["source"] as? String ?? ""
            revision = json["revision"] as? String
            enabled = json["enabled"] as? Bool ?? true
            tools = json["tools"] as? [String] ?? []
            skills = json["skills"] as? Bool ?? false
            notes = json["notes"] as? [String] ?? []
            addedAt = Date(timeIntervalSince1970: (json["addedAt"] as? Double ?? 0) / 1000)
        }

        /// What it adds, or why it adds nothing.
        var summary: String {
            if let failure = notes.first(where: { $0.hasPrefix("failed") }) { return failure }
            var parts: [String] = []
            if !tools.isEmpty { parts.append(tools.count == 1 ? "1 tool" : "\(tools.count) tools") }
            if skills { parts.append("skills") }
            return parts.isEmpty ? source : "\(parts.joined(separator: ", ")) · \(source)"
        }
    }

    struct SessionGroup: Identifiable {
        let id: Int
        let title: String
        let items: [Item]
    }

    struct Inventory {
        let defaults: [Item]
        let sessions: [SessionGroup]
    }

    struct Skill: Identifiable {
        var id: String { name }
        let name: String
        let description: String
    }

    enum Removal: Identifiable {
        case extensionItem(Item, session: Int?)
        case skill(Skill)
        case secret(String)

        var id: String {
            switch self {
            case .extensionItem(let item, let session): "e:\(session.map(String.init) ?? "default"):\(item.name)"
            case .skill(let skill): "s:\(skill.name)"
            case .secret(let name): "k:\(name)"
            }
        }

        var title: String {
            switch self {
            case .extensionItem(let item, let session): session == nil ? "Remove \(item.name) from every session?" : "Remove \(item.name) from this session?"
            case .skill(let skill): "Delete the skill \(skill.name)?"
            case .secret(let name): "Delete the secret \(name)? Extensions that use it stop finding it."
            }
        }
    }

    var body: some View {
        List {
            Section {
                if let inventory, inventory.defaults.isEmpty {
                    Text("None yet. Ask the agent to add one as a default, or add one here.").foregroundStyle(.secondary)
                }
                ForEach(inventory?.defaults ?? []) { item in
                    NavigationLink {
                        ExtensionDetailView(item: item, isDefault: true, remove: { removing = .extensionItem(item, session: nil) },
                                            share: { share(item, session: nil) },
                                            source: { ExtensionSourceView(app: app, name: item.name, sessionId: nil, fromGitHub: item.revision != nil) })
                    } label: {
                        Toggle(isOn: Binding(get: { item.enabled }, set: { on in setEnabled(item, on) })) {
                            ItemLabel(item: item)
                        }
                        .disabled(working != nil)
                    }
                    .swipeActions { Button("Remove", role: .destructive) { removing = .extensionItem(item, session: nil) } }
                }
                Button("Add extension…") { adding = true }.disabled(working != nil)
                if inventory?.defaults.contains(where: { $0.revision != nil }) == true {
                    Button("Check for updates") { checkUpdates() }.disabled(working != nil)
                }
            } header: {
                Text("Every session")
            } footer: {
                Text("Loaded into every session. Off keeps an extension installed without loading it; a session can also leave one out (ask its agent).")
            }

            if !checks.checks.isEmpty {
                Section {
                    ForEach(checks.checks) { check in
                        BackgroundCheckRow(check: check, run: checks.runs[check.key], running: checks.running.contains(check.key)) {
                            Task { await checks.run(check) }
                        }
                    }
                } header: {
                    Text("Background checks")
                } footer: {
                    Text("Extensions check for news while pi is in the background, and can notify you. iOS decides when pi wakes up: often every 15 to 60 minutes, less when you rarely use pi, and not in Low Power Mode or after you swipe pi away.")
                }
            }

            if !skills.isEmpty {
                Section {
                    ForEach(skills) { skill in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                            Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .swipeActions { Button("Delete", role: .destructive) { removing = .skill(skill) } }
                    }
                } header: {
                    Text("Skills for every session")
                } footer: {
                    Text("From the app's skills folder. Skills that extensions bring show with their extension.")
                }
            }

            Section {
                ForEach(secrets) { secret in
                    Button {
                        editingSecret = SecretDraft(existing: secret.name, name: secret.name, everyExtension: secret.extensions == nil, extensions: Set(secret.extensions ?? []))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(secret.name).font(.body.monospaced()).foregroundStyle(.primary)
                            Text(secretScope(secret)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { removing = .secret(secret.name) } }
                }
                Button("Add secret…") { editingSecret = SecretDraft() }
            } header: {
                Text("Secrets")
            } footer: {
                Text("API keys and tokens for extensions, kept in this device's Keychain. Extensions read them as environment variables (process.env.NAME); the agent's shell and chat never get them. Extensions can also store their own here.")
            }

            ForEach(inventory?.sessions ?? []) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        NavigationLink {
                            ExtensionDetailView(
                                item: item, isDefault: false, remove: { removing = .extensionItem(item, session: group.id) },
                                makeDefault: { perform("Making \(item.name) a default") { try await makeDefault(item, session: group.id) } },
                                share: { share(item, session: group.id) },
                                source: { ExtensionSourceView(app: app, name: item.name, sessionId: group.id, fromGitHub: item.revision != nil) }
                            )
                        } label: {
                            ItemLabel(item: item)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { removing = .extensionItem(item, session: group.id) }
                            Button("Every session") { perform("Making \(item.name) a default") { try await makeDefault(item, session: group.id) } }
                                .tint(.accentColor)
                        }
                    }
                }
            }

            if let working {
                Section { Label { Text(working) } icon: { ProgressView() } }
            }
            if let notice, working == nil {
                Section { Label(notice, systemImage: "checkmark.circle").font(.footnote) }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Extensions")
        .sheet(item: $sharing) { file in ShareSheet(url: file.url).presentationDetents([.medium, .large]) }
        .task { await load() }
        .refreshable { await load() }
        .alert("Add an extension for every session", isPresented: $adding) {
            TextField("github:owner/repo/folder, npm:…, git:…", text: $source)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") {
                let source = source.trimmingCharacters(in: .whitespaces)
                self.source = ""
                perform("Installing \(source)") { _ = try await app.engine.command("extensions.addDefault", ["source": source]) }
            }
            Button("Cancel", role: .cancel) { source = "" }
        } message: {
            Text("A pi extension from GitHub (github:owner/repo/folder, optionally @branch, or a github.com link; private repositories with your GitHub sign-in, and updated when the folder changes), npm (npm:name@version), or another git repository (git:URL).")
        }
        .sheet(item: $editingSecret) { draft in
            SecretEditor(draft: draft, extensionNames: extensionNames) { saved in
                editingSecret = nil
                guard let saved else { return }
                save(saved)
            }
        }
        .confirmationDialog(removing?.title ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let removal = removing {
                Button(removalLabel(removal), role: .destructive) { remove(removal) }
            }
        }
    }

    private func removalLabel(_ removal: Removal) -> String {
        if case .extensionItem = removal { return "Remove" }
        return "Delete"
    }

    /// Who may read a secret.
    private func secretScope(_ secret: ExtensionSecretsService.Entry) -> String {
        if let owner = secret.owner { return "Stored by \(owner)" }
        guard let names = secret.extensions else { return "Every extension" }
        return names.isEmpty ? "No extension" : names.joined(separator: ", ")
    }

    /// Every installed extension's name, for choosing who may read a secret.
    private var extensionNames: [String] {
        let all = (inventory?.defaults ?? []) + (inventory?.sessions.flatMap(\.items) ?? [])
        return Array(Set(all.map(\.name))).sorted()
    }

    private func save(_ draft: SecretDraft) {
        let extensions = draft.everyExtension ? nil : draft.extensions.sorted()
        do {
            if let existing = draft.existing, draft.value.isEmpty {
                app.extensionSecrets.setExtensions(existing, extensions)
            } else {
                let owner = secrets.first { $0.name == draft.existing }?.owner
                try app.extensionSecrets.set(draft.name, value: draft.value, extensions: extensions, owner: owner)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        secrets = app.extensionSecrets.entries
        Task { await app.secretsChanged() }
    }

    private func remove(_ removal: Removal) {
        switch removal {
        case .extensionItem(let item, let session):
            perform("Removing \(item.name)") {
                var params: [String: Any] = ["name": item.name]
                if let session { params["sessionId"] = session }
                _ = try await app.engine.command("extensions.remove", params)
            }
        case .skill(let skill):
            perform("Deleting \(skill.name)") { _ = try await app.engine.command("skills.remove", ["name": skill.name]) }
        case .secret(let name):
            app.extensionSecrets.delete(name)
            secrets = app.extensionSecrets.entries
            Task { await app.secretsChanged() }
        }
    }

    /// Updates the defaults installed from GitHub whose folder changed, now.
    private func checkUpdates() {
        perform("Checking for updates") {
            let results = try await app.engine.command("extensions.checkUpdates", ["force": true]) as? [[String: Any]] ?? []
            let updated = results.filter { $0["updated"] as? Bool == true }.compactMap { $0["name"] as? String }
            let failed = results.compactMap { result in (result["error"] as? String).map { "\(result["name"] as? String ?? "?"): \($0)" } }
            if !failed.isEmpty { throw ExtensionsError(failed.joined(separator: "\n")) }
            if updated.isEmpty { notice = "Up to date" } else { notice = "Updated \(updated.joined(separator: ", "))" }
        }
    }

    private func setEnabled(_ item: Item, _ enabled: Bool) {
        perform(enabled ? "Turning \(item.name) on" : "Turning \(item.name) off") {
            _ = try await app.engine.command("extensions.setEnabled", ["name": item.name, "enabled": enabled])
        }
    }

    private func makeDefault(_ item: Item, session: Int) async throws {
        _ = try await app.engine.command("extensions.makeDefault", ["name": item.name, "sessionId": session])
    }

    /// Its `.piext` file, in the share sheet.
    private func share(_ item: Item, session: Int?) {
        error = nil
        Task {
            do {
                sharing = SharedFile(url: try await app.shareFile(extension: item.name, sessionId: session))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Runs a change, then shows the list as it is now.
    private func perform(_ description: String, _ change: @escaping () async throws -> Void) {
        working = description
        error = nil
        notice = nil
        Task {
            do {
                try await change()
            } catch {
                self.error = error.localizedDescription
            }
            await load()
            working = nil
        }
    }

    private func load() async {
        do {
            let json = try await app.engine.command("extensions.installed") as? [String: Any] ?? [:]
            let defaults = (json["defaults"] as? [[String: Any]] ?? []).map(Item.init)
            let sessions = (json["sessions"] as? [[String: Any]] ?? []).map { group in
                SessionGroup(
                    id: group["id"] as? Int ?? 0,
                    title: (group["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Session \(group["id"] as? Int ?? 0)",
                    items: (group["extensions"] as? [[String: Any]] ?? []).map(Item.init)
                )
            }
            inventory = Inventory(defaults: defaults, sessions: sessions)
            await checks.refresh(from: app.engine)
            secrets = app.extensionSecrets.entries
            skills = (try await app.engine.command("skills.installed") as? [[String: Any]] ?? []).map {
                Skill(name: $0["name"] as? String ?? "?", description: $0["description"] as? String ?? "")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ItemLabel: View {
    let item: ExtensionsView.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.version.map { "\(item.name) \($0)" } ?? item.name)
            Text(item.summary).font(.caption).foregroundStyle(item.summary.hasPrefix("failed") ? .red : .secondary).lineLimit(2)
        }
    }
}

private struct ExtensionDetailView: View {
    let item: ExtensionsView.Item
    let isDefault: Bool
    let remove: () -> Void
    var makeDefault: (() -> Void)?
    /// Sends it to someone else's pi (`SharedExtension.swift`).
    var share: (() -> Void)?
    /// Its files, to read and change (`ExtensionSourceView.swift`).
    var source: (() -> ExtensionSourceView)?
    /// What it was allowed or refused on this device (`ExtensionPermissions.swift`).
    @State private var permissions: [(ExtensionPermissions.Capability, Bool)] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                LabeledContent("Source", value: item.source)
                if let version = item.version { LabeledContent("Version", value: version) }
                if let revision = item.revision { LabeledContent("From GitHub", value: String(revision.prefix(7))) }
                LabeledContent("Added", value: item.addedAt.formatted(date: .abbreviated, time: .shortened))
                if isDefault { LabeledContent("Status", value: item.enabled ? "On" : "Off") }
            }
            if !item.tools.isEmpty {
                Section("Tools") { ForEach(item.tools, id: \.self) { Text($0).font(.body.monospaced()) } }
            }
            if item.skills {
                Section { Text("Brings skills, listed to the agent in each session that has it.") }
            }
            if !item.notes.isEmpty {
                Section("Notes") { ForEach(item.notes, id: \.self) { Text($0).font(.footnote) } }
            }
            if !permissions.isEmpty {
                Section {
                    ForEach(permissions, id: \.0) { capability, allowed in
                        Toggle(isOn: Binding(get: { allowed }, set: { on in
                            ExtensionPermissions.shared.set(capability, for: item.name, to: on)
                            permissions = ExtensionPermissions.shared.decisions(for: item.name)
                        })) {
                            Label(capability.title, systemImage: capability.systemImage)
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("pi asks the first time it wants each. iOS also asks once for pi itself (Settings → Apps → pi).")
                }
            }
            Section {
                if let source {
                    NavigationLink { source() } label: { Label("Source", systemImage: "chevron.left.forwardslash.chevron.right") }
                }
                if let share {
                    Button("Share…", systemImage: "square.and.arrow.up", action: share)
                }
                if let makeDefault {
                    Button("Use in every session") {
                        makeDefault()
                        dismiss()
                    }
                }
                Button(isDefault ? "Remove from every session" : "Remove from this session", role: .destructive) {
                    dismiss()
                    remove()
                }
            }
        }
        .navigationTitle(item.name)
        .onAppear { permissions = ExtensionPermissions.shared.decisions(for: item.name) }
    }
}

/// Adds or changes a secret: its name, value (left empty, an existing one keeps its value), and who may read it.
private struct SecretEditor: View {
    @State var draft: ExtensionsView.SecretDraft
    let extensionNames: [String]
    let done: (ExtensionsView.SecretDraft?) -> Void

    private var valid: Bool {
        ExtensionSecretsService.isValidName(draft.name) && (draft.existing != nil || !draft.value.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("NAME, such as TAVILY_API_KEY", text: $draft.name)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .disabled(draft.existing != nil)
                    SecureField(draft.existing == nil ? "Value" : "New value (empty keeps the current one)", text: $draft.value)
                        .textContentType(.oneTimeCode)
                } footer: {
                    Text("Extensions read it as process.env.\(draft.name.isEmpty ? "NAME" : draft.name). Letters, digits, and _.")
                }
                Section("Who may read it") {
                    Toggle("Every extension", isOn: $draft.everyExtension)
                    if !draft.everyExtension {
                        if extensionNames.isEmpty { Text("No extensions installed yet.").foregroundStyle(.secondary) }
                        ForEach(extensionNames, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { draft.extensions.contains(name) },
                                set: { on in if on { draft.extensions.insert(name) } else { draft.extensions.remove(name) } }
                            ))
                        }
                    }
                }
            }
            .navigationTitle(draft.existing == nil ? "New secret" : draft.existing!)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // The value field is emptied before the sheet goes: iOS's Passwords offers to save whatever a
                        // secure field still holds when it disappears.
                        let saved = draft
                        draft.value = ""
                        Task { @MainActor in done(saved) }
                    }
                    .disabled(!valid)
                }
            }
        }
    }
}

private struct ExtensionsError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// A background check in Settings: what it is, how often, its last run, and Run Now.
private struct BackgroundCheckRow: View {
    let check: BackgroundChecks.Check
    let run: BackgroundChecks.Run?
    let running: Bool
    let runNow: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(check.name)
                Text([check.extensionName, check.description].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(status).font(.caption).foregroundStyle(run?.error == nil ? Color.secondary : Color.red).lineLimit(3)
            }
            Spacer()
            if running {
                ProgressView()
            } else {
                Button("Run Now", action: runNow).buttonStyle(.borderless).font(.footnote)
            }
        }
    }

    private var status: String {
        let every = "Every \(check.every) min"
        guard let run else { return "\(every) · not run yet" }
        let when = run.at.formatted(.relative(presentation: .named))
        if let error = run.error { return "\(every) · \(when): \(error)" }
        return "\(every) · \(when)" + (run.result.map { ": \($0)" } ?? "")
    }
}
