import SwiftUI

/// On a Mac, a newer pi that an administrator's installer (an MDM's package) has ready: the installer says so in
/// /Library/Application Support/pi/managed-update ("1 <version> ready"), and installs it the moment pi quits. Restart
/// quits pi for it, and the installer opens pi again (it looks for Restart's line in the log). pi is durable: what it
/// was doing goes on when it opens.
@MainActor @Observable
final class MacUpdate {
    /// The version ready to install, if there's one.
    private(set) var ready: String?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    private static let marker = URL(fileURLWithPath: "/Library/Application Support/pi/managed-update")

    func start() {
        guard ProcessInfo.processInfo.isiOSAppOnMac, ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func check() {
        let fields = ((try? String(contentsOf: Self.marker, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let own = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let version = fields.count == 3 && fields[0] == "1" && fields[2] == "ready" && fields[1] != own ? fields[1] : nil
        if version != ready { ready = version }
    }

    func restart() {
        guard let ready else { return }
        log("update", "restart for \(ready)")
        // Time for the line to reach the log before pi goes.
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            exit(0)
        }
    }
}

/// In the sessions list, while an update is ready.
struct MacUpdateRow: View {
    let update: MacUpdate
    let version: String

    var body: some View {
        HStack {
            Label("pi \(version) is ready", systemImage: "arrow.down.circle")
                .font(.footnote)
            Spacer()
            Button("Restart") { update.restart() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("restartToUpdate")
        }
    }
}
