import Foundation
import SwiftUI
import Testing
@testable import Oriveo

/// "Open in New Window": when the new window first appears, the requested conversation goes to this window's manager and the request is cleared.
@Suite("WindowOpenRequestPolicy", .serialized)
@MainActor
struct WindowOpenRequestPolicyTests {

    private func makeState() -> AppState {
        AppState(seedDemoData: true, sessionUID: "window-open-request-tests-\(UUID().uuidString)")
    }

    @Test("After onboarding: this window switches to Home and opens the conversation, the request is cleared, and the other window is untouched")
    func consumesIntoOwnWindowOnly() {
        let state = makeState()
        state.hasCompletedOnboarding = true
        let a = UUID(), b = UUID()
        let navA = state.windowNavigation(for: a)
        let navB = state.windowNavigation(for: b)
        // The active window is A (which asked); the new window B consumes the request
        state.activateWindowNavigation(a)
        navB.selectedTab = .providers

        let conversationID = UUID()
        var request: WindowOpenRequest? = WindowOpenRequest(conversationID: conversationID)
        WindowOpenRequestPolicy.consume(
            &request,
            hasCompletedOnboarding: state.hasCompletedOnboarding,
            navigation: navB
        )

        #expect(request == nil)
        #expect(navB.selectedTab == .home)
        #expect(navB.path.last == .chat(conversationID: conversationID))
        #expect(navB.isShowingChat)
        #expect(navA.path.isEmpty)
        #expect(navA.chatDetail == .empty)
        #expect(navA.selectedTab == .home)
        #expect(state.isActiveWindow(a))
    }

    @Test("Two-column window: the conversation goes to the detail column")
    func consumesIntoDetailColumnWhenRegular() {
        let state = makeState()
        let nav = state.windowNavigation(for: UUID())
        nav.updateLayoutWidth(isRegular: true)

        let conversationID = UUID()
        var request: WindowOpenRequest? = WindowOpenRequest(conversationID: conversationID)
        WindowOpenRequestPolicy.consume(&request, hasCompletedOnboarding: true, navigation: nav)

        #expect(request == nil)
        #expect(nav.chatDetail == .conversation(conversationID))
        #expect(nav.path.isEmpty)
    }

    @Test("Before onboarding: navigation is untouched and the request is kept")
    func leavesRequestWhenOnboardingIncomplete() {
        let state = makeState()
        let nav = state.windowNavigation(for: UUID())
        nav.selectedTab = .providers

        let conversationID = UUID()
        var request: WindowOpenRequest? = WindowOpenRequest(conversationID: conversationID)
        WindowOpenRequestPolicy.consume(&request, hasCompletedOnboarding: false, navigation: nav)

        #expect(request?.conversationID == conversationID)
        #expect(nav.selectedTab == .providers)
        #expect(nav.path.isEmpty)
        #expect(nav.chatDetail == .empty)
    }

    @Test("No request (the default window the system opens): navigation is untouched")
    func noRequestIsNoOp() {
        let state = makeState()
        let nav = state.windowNavigation(for: UUID())
        nav.selectedTab = .providers

        var request: WindowOpenRequest?
        WindowOpenRequestPolicy.consume(&request, hasCompletedOnboarding: true, navigation: nav)

        #expect(request == nil)
        #expect(nav.selectedTab == .providers)
        #expect(nav.path.isEmpty)
    }

    @Test("Two requests for the same conversation are different window values, so openWindow does not treat them as the same window")
    func repeatedRequestsForSameConversationAreDistinct() {
        let conversationID = UUID()
        #expect(WindowOpenRequest(conversationID: conversationID) != WindowOpenRequest(conversationID: conversationID))
    }

    @Test(
        "\"Open in New Window\" appears only with multiple-window support and a regular window (the compact Duo cover screen also reports multiple-window support)",
        arguments: [
            (true, UserInterfaceSizeClass.regular, true),
            (true, UserInterfaceSizeClass.compact, false),
            (false, UserInterfaceSizeClass.regular, false),
            (false, UserInterfaceSizeClass.compact, false),
        ] as [(Bool, UserInterfaceSizeClass, Bool)]
    )
    func newWindowEntryNeedsRegularWindow(supports: Bool, sizeClass: UserInterfaceSizeClass, expected: Bool) {
        #expect(NavigationManager.canOpenConversationWindow(supportsMultipleWindows: supports, horizontalSizeClass: sizeClass) == expected)
        #expect(!NavigationManager.canOpenConversationWindow(supportsMultipleWindows: supports, horizontalSizeClass: nil))
    }

    @Test("The window value round-trips through Codable (scene restoration stores it)")
    func requestRoundTripsThroughCoding() throws {
        let request = WindowOpenRequest(conversationID: UUID())
        let decoded = try JSONDecoder().decode(WindowOpenRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }
}
