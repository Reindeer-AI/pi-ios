import SwiftUI
import UserNotifications

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

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Extensions' background checks: iOS's wake-ups need their handler before launch ends.
        MainActor.assumeIsolated { BackgroundChecks.shared.register() }
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// A tap on an extension's notification opens its session, or a new one with its prompt.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let session = info["session"] as? Int
        let prompt = info["prompt"] as? String
        await AppModel.shared?.openFromNotification(session: session, prompt: prompt)
    }

    /// Extensions' notifications show while pi is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// iOS relaunches the app to deliver events of the background model-download session.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated { ModelStore.shared.backgroundEventsCompletion = completionHandler }
    }
}
