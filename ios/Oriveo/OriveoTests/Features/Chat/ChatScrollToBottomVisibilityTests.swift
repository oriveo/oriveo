import Combine
import Testing
import UIKit
@testable import Oriveo

/// Locks the display rule of the "scroll to bottom" floating button (same as Android ChatScrollToBottomOverlay):
/// it shows only when the list can still scroll forward and is not following.
///
/// Regression: the old rule only looked at isAtBottom. With short content (or the voice stage shrinking the visible area),
/// the first touch on the list stopped following, leaving an "↓" hovering above the voice ball with nothing to scroll.
/// The criterion is canScrollForward reported by the list controller (content bottom > visible bottom + 1).
@Suite("Scroll-to-bottom button shows only when the list can scroll")
@MainActor
struct ChatScrollToBottomVisibilityTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844

    private func message(
        _ role: ChatRole, _ text: String, state: ChatMessageState = .delivered
    ) -> ChatMessage {
        ChatMessage(id: UUID(), role: role, text: text, reasoningText: nil, providerKind: .openAI,
                    providerName: "OpenAI", modelName: "GPT-4o", estimatedCost: 0,
                    state: state, attachments: nil, citations: nil)
    }

    /// Starts a list controller that has already appeared, feeds in messages, and returns (controller, reported canScrollForward sequence, reported following sequence).
    private func drive(
        _ messages: [ChatMessage],
        anchorID: UUID? = nil,
        streamingID: UUID? = nil
    ) -> (ChatListViewController, UIWindow, () -> [Bool], () -> [Bool]) {
        let vc = ChatListViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc._testCompleteInitialAppearance()
        vc.view.layoutIfNeeded()

        final class Box { var canScroll: [Bool] = []; var following: [Bool] = [] }
        let box = Box()
        let vm = ChatCollectionViewModel(
            conversationID: UUID(), messageRevision: UInt(messages.count),
            rows: ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty),
            isSendingMessage: anchorID != nil, streamingMessageID: streamingID, streamingText: "",
            pendingAnchorUserMessageID: anchorID, pendingSearchScrollTarget: nil,
            isBootstrappingPersistedConversation: false,
            retryCapabilitySelection: ChatCapabilitySelection())
        vc.update(
            viewModel: vm, providerMetadataVersion: 0,
            streamingPublisher: Empty<Void, Never>().eraseToAnyPublisher(),
            streamingReasoningPublisher: Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
            streamingTextProvider: { "" }, streamingReasoningSnapshotProvider: { nil },
            onRetry: { _ in }, onContinue: { _ in }, onRegenerate: { _ in },
            onEditMessage: { _ in }, onSwitchModel: {},
            pendingAnchorUserMessageID: anchorID, onAnchorUserMessageConsumed: { _ in },
            onIsAtBottomChanged: { box.following.append($0) },
            onCanScrollForwardChanged: { box.canScroll.append($0) })
        vc.view.layoutIfNeeded()
        spin()
        return (vc, window, { box.canScroll }, { box.following })
    }

    private func spin() {
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// With short content, a drag-and-release re-follows based on distance from the bottom (no button).
    /// Following stops when a send enters streaming (plan C: no following during streaming).
    /// The old rule showed an "↓" even in short conversations at that point.
    @Test("Content shorter than one screen and not following while streaming: the list reports it cannot scroll forward and the button stays hidden")
    func scrollToBottomHiddenWhenListCannotScroll() {
        let question = message(.user, "Hi")
        let answer = message(.assistant, "", state: .generating)
        let (vc, window, canScroll, _) = drive(
            [question, answer], anchorID: question.id, streamingID: answer.id
        )
        defer { window.isHidden = true }

        #expect(vc._testIsFollowing() == false)
        let reported = canScroll()
        #expect(reported.last == false,
                Comment(rawValue: "short content should report canScrollForward=false, observed sequence=\(reported)"))
        #expect(ChatMessageList.shouldShowScrollToBottom(
            canScrollForward: reported.last ?? true,
            effectivelyAtBottom: vc._testIsFollowing(),
            hasMessages: true
        ) == false)
    }

    @Test("Long content scrolled away from the bottom: the list reports it can scroll forward and the button appears")
    func scrollToBottomShownWhenScrolledUp() {
        let long = String(repeating: "A long answer line that wraps across the viewport width. ", count: 12)
        var messages: [ChatMessage] = []
        for i in 0..<12 {
            messages.append(message(.user, "Question \(i)"))
            messages.append(message(.assistant, long))
        }
        let (vc, window, canScroll, _) = drive(messages)
        defer { window.isHidden = true }

        vc._testUserDragScroll(toOffsetY: 0)
        spin()

        #expect(vc._testIsFollowing() == false)
        let reported = canScroll()
        #expect(reported.last == true,
                Comment(rawValue: "scrolling away from the bottom should report canScrollForward=true, observed sequence=\(reported)"))
        #expect(ChatMessageList.shouldShowScrollToBottom(
            canScrollForward: reported.last ?? false,
            effectivelyAtBottom: vc._testIsFollowing(),
            hasMessages: true
        ))
        // Has content but no messages (empty state): hidden.
        #expect(ChatMessageList.shouldShowScrollToBottom(
            canScrollForward: true, effectivelyAtBottom: false, hasMessages: false
        ) == false)
    }
}
