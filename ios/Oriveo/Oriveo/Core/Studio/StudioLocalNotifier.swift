import Foundation
import UserNotifications

/// The slice of `UNUserNotificationCenter` the Studio notifier needs, so tests can
/// record requests without touching the system center.
protocol StudioNotificationCentering: AnyObject {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: StudioNotificationCentering {}

/// Posts the "images ready / generation failed" local notification for a Studio job.
/// Copy is localized by the caller; this type only decides whether to post.
/// Never posts while the app is in the foreground (the wall card shows the result there).
final class StudioLocalNotifier {
    private let center: StudioNotificationCentering
    private let isCompiledIn: Bool

    init(
        center: StudioNotificationCentering = UNUserNotificationCenter.current(),
        isCompiledIn: Bool? = nil
    ) {
        self.center = center
        // Resolved here, not as a default argument: compiledIn is main-actor isolated.
        self.isCompiledIn = isCompiledIn ?? StudioAvailability.compiledIn
    }

    /// Asks once for alert / sound permission (no badge is ever set). Returns false when Studio is
    /// compiled out or the user declines.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        guard isCompiledIn else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Returns true when a request was handed to the notification center.
    @discardableResult
    func notify(
        id: String,
        title: String,
        body: String,
        userInfo: [String: String] = [:],
        isAppActive: Bool
    ) async -> Bool {
        guard isCompiledIn, !isAppActive else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
