import SwiftUI
import WatchKit
import UserNotifications
import PiWatchLink

@main
struct PiWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @State private var model = WatchModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchHome(model: model)
                // `-openSession ID` (screenshots, tests): that session, once the phone's sessions are in (their first
                // arrival resets navigation).
                .task {
                    guard UserDefaults.standard.object(forKey: "openSession") != nil else { return }
                    while model.snapshot == nil { try? await Task.sleep(for: .milliseconds(300)) }
                    try? await Task.sleep(for: .milliseconds(500))
                    model.requestedSession = UserDefaults.standard.integer(forKey: "openSession")
                }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { model.refresh() }
            else { model.stopSpeaking() }
        }
        .backgroundTask(.watchConnectivity) { await WatchModel.shared.finishBackgroundDelivery() }
        WKNotificationScene(controller: WatchNotificationController.self, category: WatchWire.notificationCategory)
    }
}

final class WatchDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() { UNUserNotificationCenter.current().delegate = self }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["session"] as? Int
        await MainActor.run { WatchModel.shared.requestedSession = id }
    }
}

struct WatchNotification: View {
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading) { Text(title).font(.headline); Text(message).font(.body) }
    }
}

final class WatchNotificationController: WKUserNotificationHostingController<WatchNotification> {
    private var title = "Pi"
    private var message = ""
    override var body: WatchNotification { WatchNotification(title: title, message: message) }
    override func didReceive(_ notification: UNNotification) {
        title = notification.request.content.title
        message = notification.request.content.body
    }
}
