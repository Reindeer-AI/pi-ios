import SwiftUI

/// UI tests need a host app; the tour drives pi itself (TourTests, by bundle ID), so this one only shows a label.
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup { Text("pi demo tour") }
    }
}
