import SwiftUI

/// What sync shows: where each session stands (its row, its screen), whether everything is synced (the sessions list,
/// Settings), and Continue Here for a session another device has.
extension SessionSync.Status {
    var symbol: String {
        switch self {
        case .synced: "checkmark.icloud"
        case .waiting: "exclamationmark.icloud"
        case .uploading: "icloud.and.arrow.up"
        case .downloading: "icloud.and.arrow.down"
        case .elsewhere(_, _, let behind): behind ? "icloud.and.arrow.down" : "icloud"
        }
    }

    var text: String {
        switch self {
        case .synced: "Synced"
        case .waiting(let reason): reason
        case .uploading: "Sending to iCloud…"
        case .downloading: "Bringing it up to date…"
        case .elsewhere(let device, let running, let behind):
            running ? "Running on \(device): its newest steps come when it's done"
                : behind ? "On \(device), being brought up to date" : "On \(device), up to date"
        }
    }

    /// Whether it needs the user's eye: changes that can't go.
    var isWaiting: Bool {
        if case .waiting = self { true } else { false }
    }
}

extension SessionSync.Summary {
    var symbol: String {
        switch self {
        case .off: "icloud.slash"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .synced: "checkmark.icloud"
        case .waiting: "exclamationmark.icloud"
        }
    }

    var text: String {
        switch self {
        case .off(let reason): reason == "Off" ? "Session sync is off" : reason
        case .syncing: "Syncing…"
        case .synced(let date): date.map { "All synced · \($0.formatted(date: .omitted, time: .shortened))" } ?? "All synced"
        case .waiting(let reason): "Not synced yet: \(reason)"
        }
    }
}

/// A session row's sync mark: shown only when the session isn't simply synced (on another device, or waiting).
struct SyncRowMark: View {
    let status: SessionSync.Status?

    var body: some View {
        if let status, status != .synced {
            Image(systemName: status.symbol)
                .font(.caption)
                .foregroundStyle(status.isWaiting ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityLabel(status.text)
        }
    }
}

/// The sessions list's line about sync as a whole.
struct SyncSummaryRow: View {
    let sync: SessionSync

    var body: some View {
        let summary = sync.summary
        Label(summary.text, systemImage: summary.symbol)
            .font(.footnote)
            .foregroundStyle(summary.isWaiting ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .accessibilityIdentifier("syncSummary")
    }
}

private extension SessionSync.Summary {
    var isWaiting: Bool {
        if case .waiting = self { true } else { false }
    }
}

/// Instead of the message box, for a session another device has: where it is, and Continue Here.
struct ContinueHereBar: View {
    let app: AppModel
    let session: AppModel.Session
    @State private var working = false
    @State private var error: String?
    @State private var confirming = false

    var body: some View {
        let status = app.sync.status(of: session)
        let running: Bool = if case .elsewhere(_, true, _) = status { true } else { false }
        VStack(spacing: 8) {
            Label(status?.text ?? "On \(session.heldBy ?? "another device")", systemImage: status?.symbol ?? "icloud")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                if running { confirming = true } else { continueHere() }
            } label: {
                HStack {
                    Spacer()
                    if working { ProgressView() } else { Text("Continue Here") }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || !app.sync.active)
            .accessibilityIdentifier("continueHere")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .confirmationDialog("\(session.heldBy ?? "The other device") is still working on this session", isPresented: $confirming, titleVisibility: .visible) {
            Button("Continue Here") { continueHere() }
        } message: {
            Text("Its run stops there, and whatever it does from now on stays there as a separate session.")
        }
    }

    private func continueHere() {
        working = true
        error = nil
        Task {
            do {
                try await app.sync.continueHere(session.id)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// Where a session moved from and to (the note the agent reads when the user continues it on another device).
struct MovedRow: View {
    let text: String

    var body: some View {
        // The note's first sentence: "This session moved from Mac to iPhone."
        let line = text.split(separator: ".", maxSplits: 1).first.map { "\($0)." } ?? text
        HStack(spacing: 8) {
            VStack { Divider() }
            Label(String(line.replacing("This session moved", with: "Moved")), systemImage: "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            VStack { Divider() }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings → Sync.
struct SyncSettingsSection: View {
    @Bindable var sync: SessionSync

    var body: some View {
        Section {
            Toggle("Sync Sessions", isOn: $sync.enabled)
            if sync.enabled {
                LabeledContent("Status") {
                    Label(sync.summary.text, systemImage: sync.summary.symbol)
                        .labelStyle(.titleAndIcon)
                        .multilineTextAlignment(.trailing)
                }
                TextField("This device's name", text: $sync.deviceName)
                    .autocorrectionDisabled()
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { sync.kick() }
                    .disabled(!sync.active || sync.syncing)
            }
        } header: {
            Text("Sessions")
        } footer: {
            Text("Your sessions, their history and their workspace files sync to your iPhone, iPad and Mac through iCloud. A session runs on one device at a time; on the others it's read-only until you tap Continue Here. Installed Python packages stay on each device.")
        }
    }
}
