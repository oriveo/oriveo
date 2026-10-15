import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Dragging a conversation row to a new window: the activity payload's round trip with `WindowOpenRequest`, a nonce per drag, and when the drag is attached.
@Suite("ConversationWindowDrag")
@MainActor
struct ConversationWindowDragTests {

    @Test("The activity payload turns back into the same window request (conversation id and nonce both kept)")
    func activityPayloadRoundTripsToRequest() throws {
        let conversationID = UUID()
        let activity = ConversationWindowDrag.makeActivity(conversationID: conversationID)
        #expect(activity.activityType == ConversationWindowDrag.activityType)

        let request = try #require(ConversationWindowDrag.request(from: activity))
        #expect(request.conversationID == conversationID)
        // Field by field the same as what the activity encoded (not a request rebuilt from the conversation id)
        let encoded = try activity.typedPayload(WindowOpenRequest.self)
        #expect(request == encoded)
    }

    @Test("Dragging the same conversation twice gives two window values: a new nonce every time")
    func eachDragCarriesFreshNonce() throws {
        let conversationID = UUID()
        let first = try #require(ConversationWindowDrag.request(from: ConversationWindowDrag.makeActivity(conversationID: conversationID)))
        let second = try #require(ConversationWindowDrag.request(from: ConversationWindowDrag.makeActivity(conversationID: conversationID)))
        #expect(first.conversationID == second.conversationID)
        #expect(first.nonce != second.nonce)
        #expect(first != second)
    }

    @Test("Other activity types and broken payloads are not window requests")
    func rejectsForeignActivities() {
        let foreign = NSUserActivity(activityType: "com.example.other")
        try? foreign.setTypedPayload(WindowOpenRequest(conversationID: UUID()))
        #expect(ConversationWindowDrag.request(from: foreign) == nil)

        let empty = NSUserActivity(activityType: ConversationWindowDrag.activityType)
        #expect(ConversationWindowDrag.request(from: empty) == nil)
    }

    @Test("The restored request is consumed like the menu's: the conversation lands in this window and the request is cleared")
    func restoredRequestConsumesLikeMenu() throws {
        let state = AppState(seedDemoData: true, sessionUID: "conversation-window-drag-tests-\(UUID().uuidString)")
        let nav = state.windowNavigation(for: UUID())
        nav.selectedTab = .providers
        let conversationID = UUID()

        var request = ConversationWindowDrag.request(from: ConversationWindowDrag.makeActivity(conversationID: conversationID))
        try #require(request != nil)
        WindowOpenRequestPolicy.consume(&request, hasCompletedOnboarding: true, navigation: nav)

        #expect(request == nil)
        #expect(nav.selectedTab == .home)
        #expect(nav.isShowingChat)
    }

    @Test(
        "The drag is attached only where a new window can open (the same condition as \"Open in New Window\"); compact windows (Duo cover screen, narrow iPad windows) get none",
        arguments: [
            (true, UserInterfaceSizeClass.regular, true),
            (true, UserInterfaceSizeClass.compact, false),
            (false, UserInterfaceSizeClass.regular, false),
        ] as [(Bool, UserInterfaceSizeClass, Bool)]
    )
    func dragAvailability(supports: Bool, sizeClass: UserInterfaceSizeClass, expected: Bool) {
        let canOpen = NavigationManager.canOpenConversationWindow(supportsMultipleWindows: supports, horizontalSizeClass: sizeClass)
        #expect(ConversationWindowDrag.isAvailable(canOpenConversationWindow: canOpen) == expected)
    }

    @Test("The activity type is registered under NSUserActivityTypes in the app's Info.plist (without it the system does not create windows from it)")
    func activityTypeIsDeclared() throws {
        let declared = try #require(Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String])
        #expect(declared.contains(ConversationWindowDrag.activityType))
    }

    @Test("The drag item registers exactly this activity")
    func itemProviderCarriesActivity() {
        let provider = ConversationWindowDrag.itemProvider(conversationID: UUID())
        #expect(provider.canLoadObject(ofClass: NSUserActivity.self))
    }
}
