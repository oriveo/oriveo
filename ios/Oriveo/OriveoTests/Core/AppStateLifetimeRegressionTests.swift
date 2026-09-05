import Foundation
import Testing
@testable import Oriveo

/// "Attempted to read an unowned reference but object was already deallocated".
@Suite("App State Lifetime Regression Tests", .serialized)
struct AppStateLifetimeRegressionTests {
    @Test("AppState deallocated while an init-dispatched async task is suspended must not read a dangling unowned after resume")
    @MainActor
    func appStateDeallocDuringPendingInitTask() async {
        let previousUID = AppSessionStore.activeUID
        let uid = "appstate-lifetime-\(UUID().uuidString)"

        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        weak var weakState: AppState?
        var state: AppState? = AppState(sessionUID: uid)
        weakState = state

        await Task.yield()

        state = nil

        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<100 { await Task.yield() }

        #expect(weakState == nil)
    }

}
