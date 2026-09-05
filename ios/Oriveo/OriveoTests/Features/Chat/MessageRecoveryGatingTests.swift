import Testing
import UIKit
@testable import Oriveo

/// Recovery affordances - the inline "Continue" button on an interrupted message and the
/// RecoveryCard on a failed one - are offered only for the message that is genuinely last in the
/// conversation. Otherwise a user could interrupt reply A, send B, then go back and continue A:
/// continuing rebuilds the request from the history truncated at A and deletes everything after it.
@Suite("Message recovery gating")
@MainActor
struct MessageRecoveryGatingTests {

    // MARK: - Pure truth table

    @Test("interrupted or failed assistant messages offer recovery only when last")
    func lastAssistantInterruptedOrFailedOffersRecovery() {
        #expect(shouldOfferMessageRecovery(state: .interrupted, role: .assistant, isLastInConversation: true))
        #expect(shouldOfferMessageRecovery(state: .failed, role: .assistant, isLastInConversation: true))
    }

    @Test("a message that is not last never offers recovery, whatever its state")
    func nonLastMessageNeverOffersRecovery() {
        #expect(!shouldOfferMessageRecovery(state: .interrupted, role: .assistant, isLastInConversation: false))
        #expect(!shouldOfferMessageRecovery(state: .failed, role: .assistant, isLastInConversation: false))
    }

    @Test("delivered and generating messages never offer recovery")
    func deliveredOrGeneratingNeverOffersRecovery() {
        #expect(!shouldOfferMessageRecovery(state: .delivered, role: .assistant, isLastInConversation: true))
        #expect(!shouldOfferMessageRecovery(state: .generating, role: .assistant, isLastInConversation: true))
    }

    @Test("user messages never offer recovery")
    func userRoleNeverOffersRecovery() {
        #expect(!shouldOfferMessageRecovery(state: .failed, role: .user, isLastInConversation: true))
        #expect(!shouldOfferMessageRecovery(state: .interrupted, role: .user, isLastInConversation: true))
    }

    // MARK: - RecoveryCard config gate

    @Test("a failed last message builds a RecoveryCard config")
    func failedLastBuildsRecoveryConfig() {
        let model = Self.makeModel(state: .failed, isLast: true)
        #expect(Self.makeConfig(for: model) != nil)
    }

    @Test("a failed message that is not last builds no RecoveryCard config")
    func failedNonLastSuppressesRecoveryConfig() {
        let model = Self.makeModel(state: .failed, isLast: false)
        #expect(Self.makeConfig(for: model) == nil)
    }

    @Test("a failed message falls back to the generic recovery copy")
    func failedMessageUsesGenericRecoveryCopy() throws {
        let config = try #require(Self.makeConfig(for: Self.makeModel(state: .failed, isLast: true)))
        #expect(config.title == L10n.tr("Send Failed"))
        #expect(config.message == L10n.tr(
            "The request did not finish cleanly. Retry it now or edit the last user message before sending again.",
            table: .chat
        ))
    }

    // MARK: - Inline "Continue" button gate

    @Test("an interrupted last message shows the continue button")
    func interruptedLastShowsContinueButton() {
        let view = AssistantMetadataView()
        view.configure(
            model: Self.makeModel(state: .interrupted, isLast: true),
            providerName: "OpenAI", modelName: "GPT-4o", leadingInset: 0,
            onRetry: nil, onContinue: { /* no-op */ }
        )
        #expect(Self.continueButton(in: view)?.isHidden == false)
    }

    @Test("an interrupted message hides the continue button once the conversation moved on")
    func interruptedNonLastHidesContinueButton() {
        let view = AssistantMetadataView()
        view.configure(
            model: Self.makeModel(state: .interrupted, isLast: false),
            providerName: "OpenAI", modelName: "GPT-4o", leadingInset: 0,
            onRetry: nil, onContinue: { /* no-op */ }
        )
        #expect(Self.continueButton(in: view)?.isHidden == true)
    }

    // MARK: - Projection layer

    @Test("row and snapshot projections mark only the final message as last in conversation")
    func projectionMarksOnlyLastMessage() {
        let messages = [
            Self.message(role: .user, state: .delivered),
            Self.message(role: .assistant, state: .interrupted),
            Self.message(role: .user, state: .delivered),
            Self.message(role: .assistant, state: .delivered)
        ]
        let rows = ChatCollectionProjectionBuilder.makeRows(from: messages, metadata: .empty)
        #expect(rows.map(\.isLastInConversation) == [false, false, false, true])

        let plan = ChatCollectionProjectionBuilder.makeSnapshotPlan(
            from: rows, providerMetadataVersion: 0
        )
        #expect(plan.renderModelsByID[messages[1].id]?.isLastInConversation == false)
        #expect(plan.renderModelsByID[messages[3].id]?.isLastInConversation == true)
    }

    @Test("appending a message invalidates the previous last message's render model")
    func appendingMessageInvalidatesPreviousLastRenderModel() {
        let interrupted = Self.message(role: .assistant, state: .interrupted)
        let before = ChatCollectionProjectionBuilder.makeSnapshotPlan(
            from: ChatCollectionProjectionBuilder.makeRows(from: [interrupted], metadata: .empty),
            providerMetadataVersion: 0
        ).renderModelsByID[interrupted.id]

        let newReply = Self.message(role: .assistant, state: .delivered)
        let after = ChatCollectionProjectionBuilder.makeSnapshotPlan(
            from: ChatCollectionProjectionBuilder.makeRows(from: [interrupted, newReply], metadata: .empty),
            providerMetadataVersion: 0
        ).renderModelsByID[interrupted.id]

        #expect(
            before != after,
            "flipping isLastInConversation must make the render models unequal, otherwise the diff never reconfigures the cell to hide the continue button"
        )
    }

    @Test("Custom field rejection requires an explicit retry without custom fields")
    func customFieldRejectionUsesExplicitRetryTitleAndRedactedDetail() throws {
        var retried = false
        let config = try #require(Self.makeConfig(
            for: Self.makeModel(
                state: .failed,
                isLast: true,
                errorTitle: "Custom request fields error",
                errorDetail: "custom_request_fields_rejected"
            ),
            onRetry: { retried = true }
        ))
        #expect(config.primaryTitle == L10n.tr("Retry without custom fields", table: .chat))
        #expect(config.technicalDetail == "custom_request_fields_rejected")
        config.primaryAction()
        #expect(retried)
    }

    // MARK: - Helpers

    private static func message(
        role: ChatRole,
        state: ChatMessageState,
        errorTitle: String? = nil,
        errorDetail: String? = nil,
        text: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(), role: role, text: text ?? (role == .assistant ? "partial reply" : "hi"),
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            state: state,
            errorTitle: errorTitle,
            errorDetail: errorDetail
        )
    }

    private static func makeModel(
        state: ChatMessageState,
        isLast: Bool,
        errorTitle: String? = nil,
        errorDetail: String? = nil,
        text: String? = nil,
        displayText: String? = nil
    )
        -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let msg = message(
            role: .assistant,
            state: state,
            errorTitle: errorTitle,
            errorDetail: errorDetail,
            text: text
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: msg.id, message: msg, presentationKind: .assistant,
            showMetadata: true, resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: displayText, textHash: msg.text.hashValue, isStreaming: false,
            providerMetadataVersion: 0, isLastInConversation: isLast
        )
    }

    private static func makeConfig(
        for model: ChatCollectionProjectionBuilder.MessageRenderModel,
        onRetry: @escaping () -> Void = {},
        onEditMessage: @escaping () -> Void = {},
        onSwitchModelRequested: @escaping () -> Void = {},
        onTechnicalDetailVisibilityChanged: @escaping (Bool) -> Void = { _ in }
    ) -> UIKitRecoveryCard.Config? {
        AssistantMessageRecoveryBuilder.makeConfig(
            for: model,
            isSendingMessage: false,
            isDismissed: false,
            isTechnicalDetailExpanded: false,
            onRetry: onRetry, onContinue: {}, onRegenerate: {},
            onEditMessage: onEditMessage,
            onSwitchModelRequested: onSwitchModelRequested,
            onDismiss: {},
            onTechnicalDetailVisibilityChanged: onTechnicalDetailVisibilityChanged
        )
    }

    private static func continueButton(in view: AssistantMetadataView) -> UIButton? {
        // continueButton is private, so reach it through the same Mirror lookup other cell tests use.
        Mirror(reflecting: view).children.first { $0.label == "continueButton" }?.value as? UIButton
    }
}
