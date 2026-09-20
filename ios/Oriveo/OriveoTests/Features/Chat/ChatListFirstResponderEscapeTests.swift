import Combine
import Testing
import UIKit
@testable import Oriveo

/// The first responder chain must not escape the chat list.
///
/// ## What this pins down
/// `updateUIViewController` runs inside the SwiftUI host's AttributeGraph update pass by
/// definition. The batch update performed there makes UIKit relocate the first responder, and
/// once a cell holds one, `resignFirstResponder` walks the responder chain *upwards*. With
/// every link declining, the walk leaves the collection view and eventually asks the
/// `_UIHostingView` that owns the representable, whose `canBecomeFirstResponder` getter has to
/// evaluate `responderNode` — re-entering the same host's graph update. The same attribute
/// lands on the update stack twice, AttributeGraph reports a cycle, and printing that
/// diagnostic blocks the main thread on a synchronous write until the watchdog kills the app.
///
/// `ChatListCollectionView.canBecomeFirstResponder` cuts the chain inside UIKit. These tests
/// pin the cut itself, not the timing of any particular batch update.
///
/// ## The trigger is more common than it looks
/// No one has to be typing: message bodies are `isEditable = false` but `isSelectable = true`
/// text views, and a text view holding a selection is a first responder all the same. The first
/// test pins that premise.
@Suite("Chat list first responder chain")
@MainActor
struct ChatListFirstResponderEscapeTests {
    private static let width: CGFloat = 390
    private static let viewport: CGFloat = 844

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
        messages: [ChatMessage]
    ) {
        let vm = ChatCollectionViewModel(
            conversationID: convID, messageRevision: revision,
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
            onRetry: { _ in }, onContinue: { _ in }, onRegenerate: { _ in },
            onEditMessage: { _ in }, onSwitchModel: {},
            pendingAnchorUserMessageID: nil, onAnchorUserMessageConsumed: { _ in },
            hasMoreAbove: false)
        vc.view.layoutIfNeeded()
    }

    private func runLoop(seconds: TimeInterval, _ vc: ChatListViewController) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            vc.view.layoutIfNeeded()
        }
    }

    /// Depth-first search for the first selectable text view (message bodies are read-only but selectable).
    private func firstSelectableTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isSelectable {
            return textView
        }
        for subview in view.subviews {
            if let found = firstSelectableTextView(in: subview) { return found }
        }
        return nil
    }

    /// Walks up from `start` via `next` until something is willing to take over the first
    /// responder, returning that responder and the class names visited on the way.
    private func responderChainUntilFirstTaker(
        from start: UIResponder
    ) -> (taker: UIResponder?, visited: [String]) {
        var visited: [String] = []
        var cursor = start.next
        while let responder = cursor {
            visited.append(String(describing: type(of: responder)))
            if responder.canBecomeFirstResponder {
                return (responder, visited)
            }
            cursor = responder.next
        }
        return (nil, visited)
    }

    private func seededController() -> (ChatListViewController, UIWindow, UUID) {
        let (vc, window) = makeController()
        let convID = UUID()
        let anchor = makeAssistant(
            "A long enough assistant answer so the text view really lays out and can hold a selection."
        )
        update(vc, convID: convID, revision: 1, messages: [makeUser("Question"), anchor])
        runLoop(seconds: 0.6, vc)
        return (vc, window, anchor.id)
    }

    /// The premise: no editable field is required, a read-only selectable body qualifies.
    @Test("a read-only but selectable body text view can become first responder")
    func passiveTextViewCanBecomeFirstResponder() {
        let (vc, window, anchorID) = seededController()
        defer { window.isHidden = true }

        guard let cell = vc._testCellForMessage(anchorID),
              let textView = firstSelectableTextView(in: cell) else {
            Issue.record("No selectable text view inside the body cell; the premise changed, re-check the chain")
            return
        }

        #expect(textView.isEditable == false, "Bodies are expected to be read-only; making them editable widens the trigger surface")
        #expect(textView.canBecomeFirstResponder,
                "A read-only but selectable text view must be able to become first responder")
    }

    /// The core assertion: the chain must terminate at the list, never reaching the SwiftUI host.
    @Test("the responder chain terminates at the chat list instead of reaching the SwiftUI host")
    func responderChainStopsAtChatListCollectionView() {
        let (vc, window, anchorID) = seededController()
        defer { window.isHidden = true }

        guard let cell = vc._testCellForMessage(anchorID),
              let textView = firstSelectableTextView(in: cell) else {
            Issue.record("No selectable text view inside the body cell")
            return
        }

        let (taker, visited) = responderChainUntilFirstTaker(from: textView)
        let takerName = taker.map { String(describing: type(of: $0)) } ?? "nil"
        let chainDescription = visited.joined(separator: " → ")

        #expect(taker is ChatListCollectionView,
                "Expected ChatListCollectionView to take over, got \(takerName); chain: \(chainDescription)")

        // Even if the taker is replaced later, a SwiftUI host must never appear before it:
        // `_UIHostingView.canBecomeFirstResponder` re-enters the view graph, which is the cycle.
        let hostingBeforeTaker = visited.contains { $0.contains("HostingView") }
        #expect(hostingBeforeTaker == false,
                "The chain passed a SwiftUI host before being taken over; cycle risk is back: \(chainDescription)")
    }

    /// A real structural update while a cell holds the first responder must not hang or crash.
    @Test("a structural update while a cell holds first responder stays healthy")
    func structuralUpdateWhileCellHoldsFirstResponder() {
        let (vc, window, anchorID) = seededController()
        defer { window.isHidden = true }

        guard let cell = vc._testCellForMessage(anchorID),
              let textView = firstSelectableTextView(in: cell) else {
            Issue.record("No selectable text view inside the body cell")
            return
        }
        _ = textView.becomeFirstResponder()

        // Mixed delete + insert + reconfigure: the batch shape seen when this hangs.
        let convID = UUID()
        update(vc, convID: convID, revision: 2, messages: [
            makeUser("Question"),
            makeAssistant("Replaced answer body that differs enough to force a reconfigure."),
            makeUser("Follow-up question appended after the batch"),
        ])
        runLoop(seconds: 0.6, vc)

        #expect(vc._testNumberOfItems() > 0, "The list must not be empty after a structural update")
    }
}
