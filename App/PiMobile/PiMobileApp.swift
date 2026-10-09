import SwiftUI

@main
struct PiMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Settings from the user's other devices, before the app reads them.
        SyncedSettings.shared.start()
        _app = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .task { await app.start() }
        }
        .onChange(of: scenePhase) { app.lifecycle(String(describing: scenePhase)) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS relaunches the app to deliver events of the background model-download session.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated { ModelStore.shared.backgroundEventsCompletion = completionHandler }
    }
}
