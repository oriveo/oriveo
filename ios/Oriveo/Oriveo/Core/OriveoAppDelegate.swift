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
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        NotificationCenter.default.post(name: .oriveoWillTerminate, object: nil)
    }
}
