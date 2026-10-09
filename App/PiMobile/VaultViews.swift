import PiEngineKit
import SwiftUI

/// The vault's screens (`VaultService`): the consent sheet before an item's values are used, the secure sheet where
/// values are typed (for an extension, which never sees them), the picker, and Settings → Vault.

// MARK: - Presenting over whatever is on screen

/// Vault prompts come while anything may be up (an app's sheet, a dialog): they go on top of it.
@MainActor
enum VaultPresenter {
    /// Presents a view modally over the topmost screen; it must be answered (no swipe away).
    static func present<V: View>(_ view: V) -> UIViewController? {
        guard let top = topController() else { return nil }
        let host = UIHostingController(rootView: view)
        host.isModalInPresentation = true
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = false
        }
        top.present(host, animated: true)
        return host
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

extension AppModel {
    /// Connects the vault's questions to its sheets.
    func connectVault() {
        vault.askConsent = { consent in
            await withCheckedContinuation { continuation in
                var host: UIViewController?
                host = VaultPresenter.present(VaultConsentView(consent: consent) { decision in
                    host?.dismiss(animated: true)
                    continuation.resume(returning: decision)
                })
                if host == nil { continuation.resume(returning: .deny) }
            }
        }
        vault.enterValues = { entry in
            await withCheckedContinuation { continuation in
                var host: UIViewController?
                host = VaultPresenter.present(NavigationStack {
                    VaultEntryView(title: entry.itemId == nil ? "Add to Vault" : "Update in Vault", label: entry.label, fields: entry.fields,
                                   requester: entry.requester) { result in
                        host?.dismiss(animated: true)
                        continuation.resume(returning: result)
                    }
                })
                if host == nil { continuation.resume(returning: nil) }
            }
        }
        vault.chooseItem = { [weak self] kind, reason, requester in
            guard let self else { return nil }
            let items = vault.items.filter { kind == nil || $0.kind == kind }
            let choice: String?? = await withCheckedContinuation { continuation in
                var host: UIViewController?
                host = VaultPresenter.present(VaultChooserView(items: items, kind: kind, reason: reason, requester: requester) { chosen in
                    host?.dismiss(animated: true)
                    continuation.resume(returning: chosen)
                })
                if host == nil { continuation.resume(returning: .some(nil)) }
            }
            // .some(nil): cancelled; nil: Add new.
            if let choice { return choice }
            guard let entered = await vault.enterValues?(VaultService.Entry(
                itemId: nil, kind: kind ?? "note", label: VaultService.kind(kind ?? "note")?.title ?? "Item",
                fields: VaultService.kind(kind ?? "note")?.fields ?? [], requester: requester, hint: nil
            )) else { return nil }
            return try? vault.save(kind: kind ?? "note", label: entered.label, values: entered.values, owner: requester).id
        }
        vault.onUse = { item, use in log("vault", "\(use.requester): \(item.label) (\(use.fields.joined(separator: ", "))) to \(use.purpose)") }
    }
}

// MARK: - Consent

/// Who wants which values of which item, and what for; then Face ID.
struct VaultConsentView: View {
    let consent: VaultService.Consent
    let answer: (VaultService.Decision) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill").font(.system(size: 44)).foregroundStyle(.tint).padding(.top, 28)
            VStack(spacing: 6) {
                Text("\(consent.requester.prefix(1).uppercased() + consent.requester.dropFirst()) wants to use")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(consent.item.label).font(.title2.bold()).multilineTextAlignment(.center)
                if !consent.item.hint.isEmpty { Text(consent.item.hint).font(.callout).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(consent.fields.map(fieldName).joined(separator: ", "), systemImage: "key.horizontal")
                Label("To \(consent.purpose)", systemImage: "arrow.up.forward.app")
                if let reason = consent.reason, !reason.isEmpty { Label("“\(reason)”", systemImage: "text.quote") }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
            VStack(spacing: 10) {
                Button { answer(.once) } label: { Text("Allow Once").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button { answer(.window) } label: { Text("Allow for 5 Minutes").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
                Button("Don't Allow", role: .cancel) { answer(.deny) }.padding(.top, 2)
            }
            Text("Face ID confirms it's you.").font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    private func fieldName(_ key: String) -> String {
        VaultService.label(of: key, in: consent.item)
    }
}

// MARK: - Entering values

/// Values typed into the app itself: an extension that asked for them gets the item's name and hint, never the values.
struct VaultEntryView: View {
    let title: String
    @State var label: String
    let fields: [VaultService.Field]
    /// Who asked (an extension, or nil: the user in Settings).
    var requester: String?
    let done: ((label: String, values: [String: String])?) -> Void
    @State private var values: [String: String] = [:]

    init(title: String, label: String, fields: [VaultService.Field], requester: String?, done: @escaping ((label: String, values: [String: String])?) -> Void) {
        self.title = title
        _label = State(initialValue: label)
        self.fields = fields
        self.requester = requester
        self.done = done
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $label)
            } footer: {
                Text("Shown without Face ID, so you can ask for it by name (“my passport”, “my Chase card”).")
            }
            Section {
                // Plain fields, as Wallet's card entry has: a secure field makes iOS offer to make up a password.
                ForEach(fields, id: \.key) { field in
                    TextField(field.label, text: binding(field.key), prompt: Text(field.placeholder.isEmpty ? field.label : field.placeholder))
                        .textContentType(contentType(field.key))
                        .keyboardType(field.key == "number" || field.key == "cvv" ? .numbersAndPunctuation : .default)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .monospaced(field.secret)
                        .accessibilityLabel(field.label)
                }
            } footer: {
                Text(requester.map { "Kept on this iPhone behind Face ID. \($0) gets its name, not what you type here." }
                    ?? "Kept on this iPhone behind Face ID, and never backed up.")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { done((label, values.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty })) }
                    .disabled(values.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func contentType(_ key: String) -> UITextContentType {
        switch key {
        case "number": .creditCardNumber
        case "cvv": .creditCardSecurityCode
        default: .oneTimeCode
        }
    }
}

// MARK: - Choosing

/// The vault's picker: an item (by name), or a new one. Answers the id, `.some(nil)` for cancel, or nil to add one.
struct VaultChooserView: View {
    let items: [VaultService.Item]
    let kind: String?
    let reason: String?
    let requester: String
    let choose: (String??) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let reason, !reason.isEmpty {
                    Section { Text("\(requester): “\(reason)”").font(.callout).foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(items) { item in
                        Button { choose(.some(item.id)) } label: { VaultItemRow(item: item) }
                    }
                    Button("Add New…", systemImage: "plus") { choose(nil) }
                }
            }
            .navigationTitle(kind.flatMap { VaultService.kind($0)?.title } ?? "Choose from Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choose(.some(nil)) } } }
        }
    }
}

struct VaultItemRow: View {
    let item: VaultService.Item

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: VaultService.kind(item.kind)?.icon ?? "lock").foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).foregroundStyle(.primary)
                Text([item.hint, item.owner.map { "from \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Settings → Vault

struct VaultView: View {
    let vault: VaultService
    @State private var items: [VaultService.Item] = []
    @State private var adding: VaultService.Kind?
    @State private var syncs = true
    /// Items saved the other way than the switch says, and a move in progress or its failure.
    @State private var toMove = 0
    @State private var moving = false
    @State private var moveError: String?

    var body: some View {
        List {
            Section {
                if items.isEmpty { Text("Nothing yet. Add a card or a document, or let an extension such as Personal details ask you.").foregroundStyle(.secondary) }
                ForEach(items) { item in
                    NavigationLink { VaultItemView(vault: vault, item: item) { reload() } } label: { VaultItemRow(item: item) }
                }
            } footer: {
                Text("Card numbers and security codes, passport, ID, license and social security numbers, behind Face ID. Extensions and the agent see each item's name, and use its values only after you allow it and confirm with Face ID.")
            }
            Section {
                Toggle("Sync with iCloud Keychain", isOn: $syncs)
                    .onChange(of: syncs) { _, on in
                        vault.syncsWithICloud = on
                        refreshMoves()
                    }
                if toMove > 0 {
                    Button {
                        move()
                    } label: {
                        HStack {
                            Label(syncs ? "Sync \(toMove) \(toMove == 1 ? "item" : "items") now" : "Keep \(toMove) \(toMove == 1 ? "item" : "items") on this device only",
                                  systemImage: syncs ? "icloud.and.arrow.up" : "iphone")
                            if moving { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(moving)
                }
                if let moveError { Text(moveError).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text(syncs
                     ? "On your other devices signed in to the same Apple Account, end-to-end encrypted. pi asks for Face ID before every use; iOS can't hold synced items behind its own Face ID lock, as it does for ones kept on this device."
                     : "Kept on this device only, behind the Keychain's Face ID lock, and never backed up. Turning this off removes them from your other devices.")
            }
        }
        .navigationTitle("Vault")
        .toolbar {
            Menu {
                ForEach(VaultService.kinds, id: \.key) { kind in
                    Button(kind.title, systemImage: kind.icon) { adding = kind }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .sheet(item: Binding(get: { adding.map(IdentifiedKind.init) }, set: { if $0 == nil { adding = nil } })) { kind in
            NavigationStack {
                VaultEntryView(title: "Add \(kind.kind.title)", label: kind.kind.title, fields: kind.kind.fields, requester: nil) { result in
                    if let result { _ = try? vault.save(kind: kind.kind.key, label: result.label, values: result.values) }
                    adding = nil
                    reload()
                }
            }
        }
        .onAppear {
            syncs = vault.syncsWithICloud
            reload()
        }
    }

    private func reload() {
        items = vault.items
        refreshMoves()
    }

    private func refreshMoves() {
        toMove = vault.itemsToMove().count
        moveError = nil
    }

    private func move() {
        moving = true
        Task {
            do { _ = try await vault.moveItems() } catch { moveError = error.localizedDescription == "cancelled" ? nil : error.localizedDescription }
            moving = false
            toMove = vault.itemsToMove().count
        }
    }

    private struct IdentifiedKind: Identifiable {
        let kind: VaultService.Kind
        var id: String { kind.key }
    }
}

/// An item: its values on demand (Face ID), where requests may send it, its recent uses, and Delete.
struct VaultItemView: View {
    let vault: VaultService
    let item: VaultService.Item
    let changed: () -> Void
    @State private var values: [String: String]?
    @State private var domains = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                LabeledContent("Kind", value: VaultService.kind(item.kind)?.title ?? item.kind)
                if !item.hint.isEmpty { LabeledContent("Shown as", value: item.hint) }
                if let owner = item.owner { LabeledContent("Added by", value: owner) }
            }
            Section("Values") {
                if let values {
                    ForEach(item.fields, id: \.self) { field in
                        LabeledContent(label(field)) { Text(values[field] ?? "").textSelection(.enabled).monospaced() }
                    }
                    Button("Hide") { self.values = nil }
                } else {
                    ForEach(item.fields, id: \.self) { field in LabeledContent(label(field), value: "••••••") }
                    Button("Show", systemImage: "faceid") {
                        Task {
                            do { values = try await vault.reveal(item.id) } catch { self.error = error.localizedDescription }
                        }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section {
                TextField("Any site (asks each time)", text: $domains)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onSubmit(saveDomains)
            } header: {
                Text("May be sent to")
            } footer: {
                Text("Sites an extension's request may send it to, comma separated (for example api.stripe.com). Filling it into a page you see is always allowed.")
            }
            let uses = vault.uses(item.id)
            if !uses.isEmpty {
                Section("Recent uses") {
                    ForEach(uses, id: \.self) { use in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(use.requester): \(use.purpose)").font(.callout)
                            Text("\(use.fields.map(label).joined(separator: ", ")) · \(use.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("Delete from Vault", role: .destructive) {
                    vault.delete(item.id)
                    changed()
                    dismiss()
                }
            }
        }
        .navigationTitle(item.label)
        .onAppear { domains = item.domains.joined(separator: ", ") }
        .onDisappear(perform: saveDomains)
    }

    private func label(_ field: String) -> String {
        VaultService.label(of: field, in: item)
    }

    private func saveDomains() {
        let list = domains.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard list != item.domains else { return }
        _ = try? vault.save(id: item.id, kind: item.kind, label: item.label, values: nil, domains: list)
        changed()
    }
}
