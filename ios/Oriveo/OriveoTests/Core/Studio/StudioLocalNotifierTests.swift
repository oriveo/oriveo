import Foundation
import Testing
import UserNotifications
@testable import Oriveo

/// Studio local notifier: foreground suppression, compile gate, and that the request
/// carries the caller's copy unchanged.
@Suite("StudioLocalNotifierTests")
struct StudioLocalNotifierTests {
    private final class RecordingCenter: StudioNotificationCentering {
        var added: [UNNotificationRequest] = []
        var authorizationOptions: [UNAuthorizationOptions] = []
        var grant = true

        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
            authorizationOptions.append(options)
            return grant
        }

        func add(_ request: UNNotificationRequest) async throws {
            added.append(request)
        }
    }

    @Test func doesNotPostWhileAppIsActive() async {
        let center = RecordingCenter()
        let notifier = StudioLocalNotifier(center: center, isCompiledIn: true)
        let posted = await notifier.notify(id: "job-1", title: "Cat", body: "Ready", isAppActive: true)
        #expect(posted == false)
        #expect(center.added.isEmpty)
    }

    @Test func postsCallerCopyWhenInBackground() async throws {
        let center = RecordingCenter()
        let notifier = StudioLocalNotifier(center: center, isCompiledIn: true)
        let posted = await notifier.notify(
            id: "job-2",
            title: "Orange cat on the sill",
            body: "2 images are ready",
            userInfo: ["workId": "w-2"],
            isAppActive: false
        )
        #expect(posted)
        #expect(center.added.count == 1)
        let request = try #require(center.added.first)
        #expect(request.identifier == "job-2")
        #expect(request.content.title == "Orange cat on the sill")
        #expect(request.content.body == "2 images are ready")
        #expect(request.content.userInfo["workId"] as? String == "w-2")
        #expect(request.trigger == nil)
    }

    @Test func compiledOutNeverPostsOrAsks() async {
        let center = RecordingCenter()
        let notifier = StudioLocalNotifier(center: center, isCompiledIn: false)
        #expect(await notifier.notify(id: "job-3", title: "T", body: "B", isAppActive: false) == false)
        #expect(await notifier.requestAuthorizationIfNeeded() == false)
        #expect(center.added.isEmpty)
        #expect(center.authorizationOptions.isEmpty)
    }

    @Test func asksForAlertAndSound() async {
        let center = RecordingCenter()
        center.grant = false
        let notifier = StudioLocalNotifier(center: center, isCompiledIn: true)
        #expect(await notifier.requestAuthorizationIfNeeded() == false)
        #expect(center.authorizationOptions == [[.alert, .sound]])
    }
}
