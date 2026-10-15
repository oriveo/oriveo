import Foundation
import Testing
@testable import Oriveo

/// With several windows (iPad, Duo) navigation state is split per window: one NavigationManager per window,
/// and `AppState.navigation` / `openXxx()` act only on the active window.
@Suite("MultiWindowNavigation", .serialized)
@MainActor
struct MultiWindowNavigationTests {

    private func makeState() -> AppState {
        AppState(seedDemoData: true, sessionUID: "multi-window-tests-\(UUID().uuidString)")
    }

    @Test("The first window reuses the primary manager and the second gets its own")
    func firstWindowReusesPrimary() {
        let state = makeState()
        let a = UUID(), b = UUID()
        let navA = state.windowNavigation(for: a)
        let navB = state.windowNavigation(for: b)
        #expect(navA === state.primaryNavigation)
        #expect(navB !== navA)
        #expect(state.isActiveWindow(a))
        #expect(!state.isActiveWindow(b))
        #expect(state.allWindowNavigations.count == 2)
    }

    @Test("The same token always gets the same manager without changing the active window")
    func tokenIsIdempotent() {
        let state = makeState()
        let a = UUID(), b = UUID()
        let first = state.windowNavigation(for: a)
        _ = state.windowNavigation(for: b)
        state.activateWindowNavigation(b)
        let again = state.windowNavigation(for: a)
        #expect(first === again)
        #expect(state.isActiveWindow(b))
        #expect(state.allWindowNavigations.count == 2)
    }

    @Test("Navigation and tab changes in active window A do not affect B")
    func operationsAffectOnlyActiveWindow() {
        let state = makeState()
        let a = UUID(), b = UUID()
        let navA = state.windowNavigation(for: a)
        let navB = state.windowNavigation(for: b)
        state.activateWindowNavigation(a)

        let conversationID = UUID()
        state.openChat(conversationID: conversationID)
        state.selectedTab = .providers

        #expect(state.navigation === navA)
        #expect(navA.selectedTab == .providers)
        #expect(navA.path.contains(.chat(conversationID: conversationID)) || navA.chatDetail == .conversation(conversationID))
        #expect(navB.selectedTab == .home)
        #expect(navB.path.isEmpty)
        #expect(navB.chatDetail == .empty)
    }

    @Test("After B becomes active, actions change only B")
    func switchingActiveWindowRedirectsOperations() {
        let state = makeState()
        let a = UUID(), b = UUID()
        let navA = state.windowNavigation(for: a)
        let navB = state.windowNavigation(for: b)
        state.activateWindowNavigation(a)
        state.selectedTab = .providers
        state.openMemory()

        state.activateWindowNavigation(b)
        #expect(state.selectedTab == .home)
        state.openBackup()
        state.selectedTab = .settings

        #expect(navA.path == [.memory])
        #expect(navA.selectedTab == .providers)
        #expect(navB.path == [.backup])
        #expect(navB.selectedTab == .settings)
    }

    @Test("Releasing the active window falls back to a remaining window, and to primary once all are released")
    func releasingActiveWindowFallsBack() {
        let state = makeState()
        let a = UUID(), b = UUID()
        _ = state.windowNavigation(for: a)
        let navB = state.windowNavigation(for: b)
        state.activateWindowNavigation(a)

        state.releaseWindowNavigation(a)
        #expect(state.isActiveWindow(b))
        #expect(state.navigation === navB)

        state.releaseWindowNavigation(b)
        #expect(!state.isActiveWindow(b))
        #expect(state.navigation === state.primaryNavigation)
        #expect(state.allWindowNavigations.count == 1)
    }

    @Test("Once primary is released, the next window to register reuses it")
    func releasedPrimaryIsReused() {
        let state = makeState()
        let a = UUID(), b = UUID(), c = UUID()
        _ = state.windowNavigation(for: a)
        let navB = state.windowNavigation(for: b)
        state.releaseWindowNavigation(a)

        let navC = state.windowNavigation(for: c)
        #expect(navC === state.primaryNavigation)
        #expect(navC !== navB)
        #expect(state.allWindowNavigations.count == 2)
    }
}
