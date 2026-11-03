import Combine
import Testing
import UIKit
@testable import Oriveo

/// While realtime voice is present, each committed turn (user transcript or assistant reply saved to the database, including barge-in turns) makes the list follow the latest turn;
/// when the user has scrolled up (isFollowing == false), it does not steal the scroll position.
@Suite("Realtime voice turns follow the latest")
@MainActor
struct ChatRealtimeTurnFollowTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844
    private static let longText = String(repeating: "This turn wraps onto many lines to give real measured height. ", count: 8)

    private func message(_ role: ChatRole, _ text: String) -> ChatMessage {
        ChatMessage(id: UUID(), role: role, text: text, reasoningText: nil,
                    providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                    estimatedCost: 0, state: .delivered, attachments: nil, citations: nil)
    }

    nonisolated private static let attribution = RealtimeVoiceAttribution(
        providerID: UUID(), providerKind: .openAI, providerName: "OpenAI", model: "gpt-realtime")

    nonisolated private static func live(_ drafts: RealtimeDrafts = RealtimeDrafts()) -> ChatCollectionProjectionBuilder.RealtimeLiveInput {
        ChatCollectionProjectionBuilder.RealtimeLiveInput(drafts: drafts, attribution: attribution, callMessageIDs: [])
    }

    /// realtimeLive injects realtime presence by default (no draft): committed turns are regular message rows; pass nil for realtime absent.
    private func makeController(
        realtimeLive: ChatCollectionProjectionBuilder.RealtimeLiveInput? = live()
    ) -> (ChatListViewController, UIWindow) {
        let vc = ChatListViewController()
        vc.realtimeLiveSource = { _ in realtimeLive }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc._testCompleteInitialAppearance()
        vc.view.layoutIfNeeded()
        return (vc, window)
    }

    private func drive(_ vc: ChatListViewController, convID: UUID, messages: [ChatMessage]) {
        let vm = ChatCollectionViewModel(
            conversationID: convID, messageRevision: UInt(messages.count),
            rows: ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty),
            isSendingMessage: false, streamingMessageID: nil, streamingText: "",
            pendingAnchorUserMessageID: nil, pendingSearchScrollTarget: nil,
            isBootstrappingPersistedConversation: false,
            retryCapabilitySelection: ChatCapabilitySelection())
        vc.update(
            viewModel: vm, providerMetadataVersion: 0,
            streamingPublisher: Empty<Void, Never>().eraseToAnyPublisher(),
            streamingReasoningPublisher: Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
            streamingTextProvider: { "" }, streamingReasoningSnapshotProvider: { nil },
            realtimeSelected: true,
            onRetry: { _ in }, onContinue: { _ in }, onRegenerate: { _ in },
            onEditMessage: { _ in }, onSwitchModel: {})
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            vc.view.layoutIfNeeded()
        }
    }

    private func maxOffset(_ vc: ChatListViewController) -> CGFloat {
        vc._testContentHeight() + vc._testBottomInset() - vc._testCollectionBoundsHeight()
    }

    private func history() -> [ChatMessage] {
        (0..<4).flatMap { _ in [message(.user, Self.longText), message(.assistant, Self.longText)] }
    }

    @Test("Realtime present, two turns appended → viewport at bottom")
    func realtime_turn_landing_follows_to_latest() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        var messages = history()
        drive(vc, convID: convID, messages: messages)
        #expect(vc._testIsFollowing())

        messages.append(message(.user, Self.longText))
        drive(vc, convID: convID, messages: messages)
        messages.append(message(.assistant, Self.longText))
        drive(vc, convID: convID, messages: messages)

        let offset = vc._testContentOffsetY()
        let bottom = maxOffset(vc)
        #expect(bottom > 0, Comment(rawValue: "content should exceed one screen, measured maxOffset=\(bottom)"))
        #expect(abs(offset - bottom) <= 2,
                Comment(rawValue: "should follow the latest turn after commit, measured offset=\(offset) maxOffset=\(bottom)"))
    }

    @Test("User has scrolled up → appending a turn does not steal scroll")
    func realtime_turn_landing_respects_user_scroll_up() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        var messages = history()
        drive(vc, convID: convID, messages: messages)

        vc._testUserDragScroll(toOffsetY: 100)
        vc.view.layoutIfNeeded()
        #expect(!vc._testIsFollowing(), "should stop following after the user releases a drag away from bottom")
        let before = vc._testContentOffsetY()

        messages.append(message(.user, Self.longText))
        drive(vc, convID: convID, messages: messages)

        let after = vc._testContentOffsetY()
        #expect(abs(after - before) <= 1,
                Comment(rawValue: "should not be pulled away after the user scrolls up, before=\(before) after=\(after)"))
    }

    /// Control: `realtimeLive != nil` on the gate. When realtime is absent, a text non-streaming tail insert keeps its original behavior (does not snap to bottom).
    @Test("Realtime absent, appending a turn → offset unchanged")
    func text_turn_landing_without_realtime_keeps_offset() {
        let (vc, window) = makeController(realtimeLive: nil)
        defer { window.isHidden = true }
        let convID = UUID()
        var messages = history()
        drive(vc, convID: convID, messages: messages)
        #expect(vc._testIsFollowing())
        let before = vc._testContentOffsetY()

        messages.append(message(.user, Self.longText))
        drive(vc, convID: convID, messages: messages)

        let after = vc._testContentOffsetY()
        let bottom = maxOffset(vc)
        #expect(bottom - before > 2, Comment(rawValue: "new row should push the bottom away, measured before=\(before) maxOffset=\(bottom)"))
        #expect(abs(after - before) <= 1,
                Comment(rawValue: "should not snap to bottom when realtime is absent, before=\(before) after=\(after) maxOffset=\(bottom)"))
    }

    /// Control: the gate's "last message row is newly inserted". Only when the realtime draft temp row appears or disappears (no new message row) does the offset not move.
    @Test("Only the realtime draft row appears or disappears → offset unchanged")
    func realtime_draft_row_change_does_not_scroll() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        let messages = history()
        drive(vc, convID: convID, messages: messages)
        #expect(vc._testIsFollowing())
        let before = vc._testContentOffsetY()

        var drafts = RealtimeDrafts()
        drafts.user = Self.longText
        drafts.assistant = Self.longText
        let withDrafts = Self.live(drafts)
        vc.realtimeLiveSource = { _ in withDrafts }
        drive(vc, convID: convID, messages: messages)
        let appeared = vc._testContentOffsetY()
        let bottom = maxOffset(vc)
        #expect(bottom - before > 2, Comment(rawValue: "draft row should push the bottom away, measured before=\(before) maxOffset=\(bottom)"))
        #expect(abs(appeared - before) <= 1,
                Comment(rawValue: "draft row appearing should not scroll, before=\(before) after=\(appeared) maxOffset=\(bottom)"))

        let cleared = Self.live()
        vc.realtimeLiveSource = { _ in cleared }
        drive(vc, convID: convID, messages: messages)
        let gone = vc._testContentOffsetY()
        #expect(abs(gone - before) <= 1,
                Comment(rawValue: "draft row disappearing should not scroll, before=\(before) after=\(gone)"))
    }
}
