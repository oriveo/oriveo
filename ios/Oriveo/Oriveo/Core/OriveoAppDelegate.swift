import UIKit

extension Notification.Name {
    static let oriveoWillTerminate = Notification.Name("oriveo.willTerminate")
}

/// App delegate for local lifecycle (no hosted identity).
final class OriveoAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Rebuilds the background session so force-quit cancellations are delivered, then
        // marks orphaned in-flight jobs as interrupted; detached to keep file IO off main.
        // Runs whatever the Studio build flag: chat image sends use the same session.
        let transfer = StudioBackgroundTransfer.shared
        Task.detached { await transfer.reconcile() }
        return true
    }

    /// Reconnects the Studio background transfer session; other identifiers are not ours.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == StudioBackgroundTransfer.sessionIdentifier else {
            completionHandler()
            return
        }
        StudioBackgroundTransfer.shared.handleEvents(completionHandler: completionHandler)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        NotificationCenter.default.post(name: .oriveoWillTerminate, object: nil)
    }
}
