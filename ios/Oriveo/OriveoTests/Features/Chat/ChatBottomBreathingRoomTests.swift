import Combine
import Testing
import UIKit
@testable import Oriveo

/// Pins the bottom breathing room: the metadata footer of the last assistant message must never sit
/// flush against - or behind - the composer toolbar.
///
/// On a device `.safeAreaInset(edge: .bottom)` shrinks the list frame to end at the top of the
/// composer, so the distance between the last footer and the collection view's bottom edge is
/// exactly the gap the user sees above the composer. This suite uses a full-screen controller with
/// no composer, where `bounds.maxY` is the bottom of the screen. Tall content scrolls to the bottom
/// and must keep `bottomBreathingRoom` below the last footer; short content stays pinned to the top
/// and must not jump when streaming starts or stops.
@Suite("Bottom breathing room")
@MainActor
struct ChatBottomBreathingRoomTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844
    private static let tolerance: CGFloat = 2.0

    private func makeUser(_ text: String, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: .user, text: text, reasoningText: nil,
                    providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                    estimatedCost: 0, state: .delivered, attachments: nil, citations: nil)
    }
    private func makeAssistant(_ text: String, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: text, reasoningText: nil,
                    providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
                    estimatedCost: 0, state: .delivered, attachments: nil, citations: nil)
    }
    private func makeController() -> (ChatListViewController, UIWindow) {
        let vc = ChatListViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.viewport))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc._testCompleteInitialAppearance()
        vc.view.layoutIfNeeded()
        return (vc, window)
    }
    private func update(
        _ vc: ChatListViewController,
        convID: UUID,
        revision: UInt,
        messages: [ChatMessage],
        streamingID: UUID? = nil,
        streamingText: String = ""
    ) {
        let vm = ChatCollectionViewModel(
            conversationID: convID, messageRevision: revision,
            rows: ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty),
            isSendingMessage: false, streamingMessageID: streamingID, streamingText: streamingText,
            pendingAnchorUserMessageID: nil, pendingSearchScrollTarget: nil,
            isBootstrappingPersistedConversation: false,
            retryCapabilitySelection: ChatCapabilitySelection())
        vc.update(
            viewModel: vm, providerMetadataVersion: 0,
            streamingPublisher: Empty<Void, Never>().eraseToAnyPublisher(),
            streamingReasoningPublisher: Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher(),
            streamingTextProvider: { streamingText }, streamingReasoningSnapshotProvider: { nil },
            onRetry: { _ in }, onContinue: { _ in }, onRegenerate: { _ in },
            onEditMessage: { _ in }, onSwitchModel: {},
            pendingAnchorUserMessageID: nil, onAnchorUserMessageConsumed: { _ in })
        vc.view.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            vc.view.layoutIfNeeded()
        }
    }

    private func bottomGap(_ vc: ChatListViewController, lastID: UUID) -> CGFloat? {
        guard let maxY = vc._testVisualMaxY(of: lastID) else { return nil }
        return vc._testCollectionBoundsHeight() - maxY
    }

    @Test("Tall Content Has Breathing Room")
    func tallContentHasBreathingRoom() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        var msgs: [ChatMessage] = []
        for i in 0..<12 {
            msgs.append(makeUser("Question number \(i) that is a bit long to wrap."))
            msgs.append(makeAssistant("Answer number \(i) that spans multiple lines so the whole conversation is taller than one viewport and the list is genuinely scrollable to the bottom."))
        }
        let last = msgs.last!
        update(vc, convID: convID, revision: 1, messages: msgs)

        let gap = bottomGap(vc, lastID: last.id)
        #expect(gap != nil)
        if let gap {
            let expected = ChatListViewController.bottomBreathingRoom
            #expect(abs(gap - expected) <= Self.tolerance,
                    Comment(rawValue: "tall: gap=\(gap) expected≈\(expected) bounds=\(vc._testCollectionBoundsHeight()) offset=\(vc._testContentOffsetY()) contentH=\(vc._testContentHeight())"))
        }
    }

    @Test("Short Content Top Anchored")
    func shortContentTopAnchored() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        let q = makeUser("hi")
        let a = makeAssistant("Short reply.")
        update(vc, convID: convID, revision: 1, messages: [q, a])

        let topPos = vc._testVisualPosition(of: q.id)
        #expect(topPos != nil)
        if let topPos {
            #expect(topPos < 60,
                    Comment(rawValue: "short content must stay top-aligned: firstVisualPos=\(topPos) (expected around 16; over 600 means it was wrongly pinned to the bottom) offset=\(vc._testContentOffsetY()) contentH=\(vc._testContentHeight())"))
        }
        #expect(abs(vc._testContentOffsetY()) <= Self.tolerance,
                Comment(rawValue: "short content top-aligned must leave offset at 0, measured \(vc._testContentOffsetY())"))
    }

    @Test("Short Content Stable Across Streaming Toggle")
    func shortContentStableAcrossStreamingToggle() {
        let (vc, window) = makeController()
        defer { window.isHidden = true }
        let convID = UUID()
        let q = makeUser("hi")
        let a = makeAssistant("Short reply.")

        update(vc, convID: convID, revision: 1, messages: [q, a])
        let idle1 = vc._testVisualPosition(of: q.id)

        update(vc, convID: convID, revision: 2, messages: [q, a], streamingID: a.id, streamingText: "Short reply.")
        let streaming = vc._testVisualPosition(of: q.id)

        update(vc, convID: convID, revision: 3, messages: [q, a])
        let idle2 = vc._testVisualPosition(of: q.id)

        #expect(idle1 != nil && streaming != nil && idle2 != nil)
        if let idle1, let streaming, let idle2 {
            #expect(abs(streaming - idle1) <= Self.tolerance,
                    Comment(rawValue: "the content was pushed up when streaming started: idle1=\(idle1) streaming=\(streaming)"))
            #expect(abs(idle2 - idle1) <= Self.tolerance,
                    Comment(rawValue: "the content dropped back down when streaming ended: idle1=\(idle1) idle2=\(idle2)"))
        }
    }
}
