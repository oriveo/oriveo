import Foundation
import OriveoProviderKit
import Testing
import UIKit
@testable import Oriveo

// A streamed reply that settles with nothing visible (also after an unknown skill marker line was dropped) fails
// as an empty response with the recovery card instead of leaving a blank delivered bubble
//. Streams go through the production `sendMessage` path over `StopReasonURLProtocol`.

nonisolated private func emptyReplyChatSSE(_ frames: [String]) -> String {
    frames.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
}

nonisolated private func emptyReplyContentFrame(_ content: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": content]]]])
    return String(decoding: data, as: UTF8.self)
}

nonisolated private let emptyReplyUnknownMarker = "\u{27E6}skill:not-a-skill|fits\u{27E7}"

@Suite("EmptyReplyFailureTests", .serialized, .sharedProcessState)
@MainActor
struct EmptyReplyFailureTests {

    private func waitUntil(
        _ label: String,
        iterations: Int = 150,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<iterations {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for \(label)")
    }

    private func lastAssistant(_ state: AppState, _ conversationID: UUID) -> ChatMessage? {
        state.conversation(for: conversationID)?.messages.last { $0.role == .assistant }
    }

    /// Sends one BYOK OpenRouter turn with one auto skill (so the request carries the marker channel) and waits
    /// until the assistant message settles.
    private func send(prefix: String, body: String) async throws -> (AppState, ChatMessage) {
        StopReasonURLProtocol.reset()
        StopReasonURLProtocol.reply = { request in
            guard request.url?.path.hasSuffix("/chat/completions") == true else { return nil }
            return .body(status: 200, text: body)
        }
        let state = AppState(
            seedDemoData: false,
            sessionUID: "empty-reply-\(prefix)-\(UUID().uuidString)",
            providerSession: StopReasonURLProtocol.session()
        )
        let modelID = "openai/gpt-4o-mini"
        let provider = TestFactories.makeProvider(
            kind: .openRouter,
            models: [TestFactories.makeModel(id: modelID, name: modelID, isDefault: true)]
        )
        let conversation = TestFactories.makeConversation(
            providerID: provider.id, providerKind: .openRouter, modelID: modelID
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        state.skillManager.replaceUserSkills([
            Skill(
                id: UUID(), name: "Poet", systemPrompt: "Answer in verse.",
                whenToUse: "The user asks for a poem.", autoInvoke: true, source: .user
            ),
        ])
        // The user-skill cache is keyed by the global active UID, so clear it before other suites read it.
        defer { state.skillManager.replaceUserSkills([]) }
        _ = await state.sendMessage("Hello", in: conversation.id)
        try await waitUntil("assistant settled") {
            guard let message = lastAssistant(state, conversation.id) else { return false }
            return message.state != .generating && !state.chatManager.isBusyStreaming(in: conversation.id)
        }
        return (state, try #require(lastAssistant(state, conversation.id)))
    }

    private func expectEmptyResponseFailure(_ state: AppState, _ message: ChatMessage) {
        let expected = state.providerManager.providerServiceError(from: ProviderServiceError.emptyResponse)
        #expect(message.state == .failed, "an empty reply must not settle as delivered, got \(message.state)")
        #expect(message.errorTitle == expected.titleKey)
        #expect(message.errorDetail == ChatFailurePresentation.persistedDetail(for: expected))
        #expect(!message.text.contains(emptyReplyUnknownMarker))
    }

    @Test func unknownMarkerOnlyThenDoneFails() async throws {
        defer { StopReasonURLProtocol.reset() }
        let (state, message) = try await send(
            prefix: "marker-only",
            body: emptyReplyChatSSE([emptyReplyContentFrame(emptyReplyUnknownMarker)])
        )
        expectEmptyResponseFailure(state, message)
    }

    @Test func onlyDoneFails() async throws {
        defer { StopReasonURLProtocol.reset() }
        let (state, message) = try await send(prefix: "done-only", body: emptyReplyChatSSE([]))
        expectEmptyResponseFailure(state, message)
    }

    @Test func emptyReplyBubbleDoesNotRepeatTheCardSentence() async throws {
        defer { StopReasonURLProtocol.reset() }
        let (state, message) = try await send(prefix: "bubble", body: emptyReplyChatSSE([]))
        expectEmptyResponseFailure(state, message)
        #expect(
            !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "precondition: the persisted message keeps the provider sentence; only rendering hides it"
        )
        let model = ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id, message: message, presentationKind: .assistant,
            showMetadata: true, resolvedProviderName: "OpenRouter", resolvedModelName: "GPT-4o mini",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: message.text.hashValue, isStreaming: false,
            providerMetadataVersion: 0, isLastInConversation: true
        )
        #expect(suppressesEmptyReplyBubbleText(for: model))

        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        cell.configure(
            model: model, parentViewController: UIViewController(),
            onContentHeightDidChange: nil, onRetry: nil, onContinue: nil
        )
        let sentence = L10n.tr("The provider returned no assistant content for this message.")
        let rendered = emptyReplyRenderedTexts(in: cell.bodyStack)
        #expect(!rendered.contains { $0.contains(sentence) || $0.contains(message.text) },
                "the bubble must not repeat the recovery card sentence, rendered: \(rendered)")

        let config = try #require(AssistantMessageRecoveryBuilder.makeConfig(
            for: model, isSendingMessage: false, isDismissed: false, isTechnicalDetailExpanded: false,
            onRetry: {}, onContinue: {}, onRegenerate: {}, onEditMessage: {},
            onSwitchModelRequested: {}, onDismiss: {}, onTechnicalDetailVisibilityChanged: { _ in }
        ))
        #expect(config.message == sentence, "the recovery card carries the prescribed sentence instead")
    }

    private func emptyReplyRenderedTexts(in root: UIView) -> [String] {
        var texts: [String] = []
        if let label = root as? UILabel, let text = label.text, !text.isEmpty { texts.append(text) }
        if let textView = root as? UITextView, let text = textView.text, !text.isEmpty { texts.append(text) }
        for subview in root.subviews { texts.append(contentsOf: emptyReplyRenderedTexts(in: subview)) }
        return texts
    }

    @Test func unknownMarkerWithBodyIsDeliveredWithoutMarkerLine() async throws {
        defer { StopReasonURLProtocol.reset() }
        let (_, message) = try await send(
            prefix: "marker-body",
            body: emptyReplyChatSSE([
                emptyReplyContentFrame(emptyReplyUnknownMarker + "\n"),
                emptyReplyContentFrame("Plain answer"),
            ])
        )
        #expect(message.state == .delivered)
        #expect(message.text == "Plain answer")
        #expect(message.errorTitle == nil)
    }
}
