import Combine
import Foundation
import Testing
import UIKit
@testable import Oriveo

/// ChatManager multi-session streaming tests
/// Verifies the multi-session streaming core scenarios in Spec §8: cross-conversation streams do not overwrite each other, the shared BG task,
/// per-conversation publisher isolation, and streamingConversationIDs stability under the token flow.
@MainActor
@Suite("ChatManager multi-session streaming", .sharedProcessState)
struct ChatManagerMultiSessionTests {

    @Test("First send and recovery keep the user reasoning/web intent before the final facade")
    func capabilityIntentIsNotPreclearedByPersistedRawModel() {
        let state = AppState(seedDemoData: true)
        let rawUnsupportedModel = AIModel(
            id: "raw-unknown", name: "Raw unknown", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        let requested = ChatCapabilitySelection(
            reasoningMode: .deep,
            webSearchEnabled: true,
            libraryResearchEnabled: false
        )
        let initial = state.chatManager.debugInitialCapabilitySelectionForTesting(requested)
        #expect(initial.reasoningMode == .deep)
        #expect(initial.webSearchEnabled)

        let recovered = state.chatManager.debugRecoveryCapabilitySelectionForTesting(
            requested,
            preservingLibraryModeFrom: makeAssistantPlaceholder(),
            model: rawUnsupportedModel
        )
        #expect(recovered.reasoningMode == .deep)
        #expect(recovered.webSearchEnabled)
    }

    // MARK: - 1. Cross-conversation streams do not overwrite each other

    @Test("Cross-conversation streams do not overwrite each other")
    func crossConversationsDoNotCollide() {
        let state = AppState(seedDemoData: true)
        let convA = makeConversation(with: makeAssistantPlaceholder())
        let convB = makeConversation(with: makeAssistantPlaceholder())
        state.conversations = [convA, convB]

        let msgA = convA.messages[0].id
        let msgB = convB.messages[0].id

        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: convA.id, messageID: msgA, text: "Hello from A"
        )
        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: convB.id, messageID: msgB, text: "Hello from B"
        )

        #expect(state.chatManager.streamingText(in: convA.id) == "Hello from A")
        #expect(state.chatManager.streamingText(in: convB.id) == "Hello from B")
        #expect(state.chatManager.streamingMessageID(in: convA.id) == msgA)
        #expect(state.chatManager.streamingMessageID(in: convB.id) == msgB)
        #expect(state.chatManager.isAnyStreaming == true)
        #expect(state.chatManager.streamingConversationIDs == Set([convA.id, convB.id]))
    }

    // MARK: - 2. Same-conversation overlay still applies

    @Test("Same-conversation overlay: old partial is persisted as .interrupted")
    func sameConversationOverlayPersistsPartial() {
        let state = AppState(seedDemoData: true)
        let oldMsg = makeAssistantPlaceholder()
        let conv = makeConversation(with: oldMsg)
        state.conversations = [conv]

        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: conv.id, messageID: oldMsg.id, text: "Old partial"
        )

        // Simulates the overlay guard at the queueAssistantResponse entry: a new messageID makes the old partial persist as .interrupted
        let newMsg = UUID()
        state.chatManager.debugInvokePartialPreservationGuardForTesting(
            conversationID: conv.id, newMessageID: newMsg
        )

        let updated = state.conversation(for: conv.id)
        let oldStored = updated?.messages.first(where: { $0.id == oldMsg.id })
        #expect(oldStored?.state == .interrupted)
        #expect(oldStored?.text == "Old partial")
    }

    @Test("A terminal callback from an old send task must not end the new session for the same message")
    func staleTaskTerminalCannotFinishReplacementSession() {
        let state = AppState(seedDemoData: true)
        let message = makeAssistantPlaceholder()
        let conversation = makeConversation(with: message)
        state.conversations = [conversation]

        let oldTaskID = UUID()
        let newTaskID = UUID()
        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: conversation.id,
            messageID: message.id,
            text: "new task partial",
            sendTaskID: newTaskID
        )

        state.chatManager.debugFinishStreamingForTesting(
            conversationID: conversation.id,
            messageID: message.id,
            expectedSendTaskID: oldTaskID,
            state: .interrupted
        )

        let unchanged = state.conversation(for: conversation.id)?.messages.first
        #expect(unchanged?.state == .generating)
        #expect(unchanged?.text.isEmpty == true)
        #expect(state.chatManager.streamingText(in: conversation.id) == "new task partial")
        #expect(state.chatManager._testingSendTaskID(in: conversation.id) == newTaskID)
    }

    // MARK: - 3. Multi-stream shares the BG task

    @Test("Multi-stream shares the BG task: not released when A completes, released only when B also completes")
    func multiStreamSharesBackgroundTask() {
        let state = AppState(seedDemoData: true)
        let placeholderA = makeAssistantPlaceholder()
        let placeholderB = makeAssistantPlaceholder()
        let convA = makeConversation(with: placeholderA)
        let convB = makeConversation(with: placeholderB)
        state.conversations = [convA, convB]

        let msgA = placeholderA.id
        let msgB = placeholderB.id

        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: convA.id, messageID: msgA, text: "A"
        )
        // First time entering background — should request a BG task
        state.chatManager.prepareForSessionBoundary()
        let firstTaskID = state.chatManager.debugBackgroundTaskID
        #expect(firstTaskID != .invalid)

        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: convB.id, messageID: msgB, text: "B"
        )
        // Second time (B also starts) — BG task already exists, must not request a second one
        state.chatManager.prepareForSessionBoundary()
        #expect(state.chatManager.debugBackgroundTaskID == firstTaskID)

        // Stream A completes naturally → sessions A removed, but B still there → must not release the BG task
        state.chatManager.debugFinishStreamingForTesting(conversationID: convA.id, state: .delivered)
        #expect(state.chatManager.debugBackgroundTaskID == firstTaskID)
        #expect(state.chatManager.isAnyStreaming == true)
        #expect(state.chatManager.streamingConversationIDs == Set([convB.id]))

        // B also completes → release the BG task
        state.chatManager.debugFinishStreamingForTesting(conversationID: convB.id, state: .delivered)
        #expect(state.chatManager.debugBackgroundTaskID == .invalid)
        #expect(state.chatManager.isAnyStreaming == false)
    }

    // MARK: - 4. Lifecycle flush, multi-stream

    @Test("Lifecycle flush, multi-stream: all session text is written back to messages")
    func flushAllStreamsToMessages() {
        let state = AppState(seedDemoData: true)
        let placeholderA = makeAssistantPlaceholder()
        let placeholderB = makeAssistantPlaceholder()
        let convA = makeConversation(with: placeholderA)
        let convB = makeConversation(with: placeholderB)
        state.conversations = [convA, convB]

        let msgA = placeholderA.id
        let msgB = placeholderB.id

        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: convA.id, messageID: msgA, text: "A partial"
        )
        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: convB.id, messageID: msgB, text: "B partial"
        )

        state.chatManager.flushStreamingTextToMessage()

        let updatedA = state.conversation(for: convA.id)
        let updatedB = state.conversation(for: convB.id)
        #expect(updatedA?.messages.first(where: { $0.id == msgA })?.text == "A partial")
        #expect(updatedB?.messages.first(where: { $0.id == msgB })?.text == "B partial")
        // state remains .generating (flush does not cancel, only writes back the partial)
        #expect(updatedA?.messages.first(where: { $0.id == msgA })?.state == .generating)
        #expect(updatedB?.messages.first(where: { $0.id == msgB })?.state == .generating)
        // sessions still alive
        #expect(state.chatManager.isAnyStreaming == true)
    }

    @Test("Retry failed assistant reuses original user and assistant")
    func retryFailedAssistantReusesOriginalTurn() async {
        let state = AppState(seedDemoData: true)
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o", isDefault: true)]
        )
        state.providers = [provider]

        let userID = UUID()
        let assistantID = UUID()
        let user = TestFactories.makeMessage(
            id: userID,
            role: .user,
            text: "Original question",
            providerID: provider.id,
            providerKind: provider.kind,
            modelName: "GPT-4o",
            state: .delivered
        )
        var failedAssistant = TestFactories.makeMessage(
            id: assistantID,
            role: .assistant,
            text: "",
            providerID: UUID(),
            providerKind: .gemini,
            modelID: "gemini-3-pro-image",
            modelName: "Gemini 3 Pro Image",
            state: .failed,
            errorTitle: "Request Failed",
            errorDetail: "temporary upstream error"
        )
        failedAssistant.servedModelID = "gemini-3-pro-image"
        let conversation = TestFactories.makeConversation(
            providerID: provider.id,
            providerKind: provider.kind,
            modelID: "gpt-4o",
            messages: [user, failedAssistant]
        )
        state.conversations = [conversation]

        await state.chatManager.retryMessage(messageID: assistantID, in: conversation.id)

        let updated = try? #require(state.conversation(for: conversation.id))
        #expect(updated?.messages.filter { $0.role == .user }.count == 1)
        #expect(updated?.messages.map(\.id) == [userID, assistantID])
        #expect(updated?.messages.last?.state == .generating)
        #expect(updated?.messages.last?.providerID == provider.id)
        #expect(updated?.messages.last?.providerKind == provider.kind)
        #expect(updated?.messages.last?.modelID == "gpt-4o")
        #expect(updated?.messages.last?.modelName == "GPT-4o")
        #expect(updated?.messages.last?.servedModelID == nil)
        state.chatManager.cancelGeneration(in: conversation.id)
    }

    @Test("Continue after switching provider rebinds reused assistant metadata")
    func continueAfterSwitchingProviderRebindsAssistantMetadata() async {
        let state = AppState(seedDemoData: true)
        let currentModel = TestFactories.makeModel(
            id: "claude-current",
            name: "Claude Current",
            isDefault: true
        )
        let currentProvider = TestFactories.makeProvider(
            kind: .anthropic,
            models: [currentModel]
        )
        state.providers = [currentProvider]

        let user = TestFactories.makeMessage(
            role: .user,
            text: "Original question",
            providerID: currentProvider.id,
            providerKind: currentProvider.kind,
            modelID: currentModel.id,
            modelName: currentModel.name,
            state: .delivered
        )
        var interruptedAssistant = TestFactories.makeMessage(
            role: .assistant,
            text: "Partial answer",
            providerID: UUID(),
            providerKind: .gemini,
            modelID: "gemini-3-pro-image",
            modelName: "Gemini 3 Pro Image",
            state: .interrupted
        )
        interruptedAssistant.servedModelID = "gemini-3-pro-image"
        let conversation = TestFactories.makeConversation(
            providerID: currentProvider.id,
            providerKind: currentProvider.kind,
            modelID: currentModel.id,
            messages: [user, interruptedAssistant]
        )
        state.conversations = [conversation]

        await state.chatManager.continueMessage(
            messageID: interruptedAssistant.id,
            in: conversation.id
        )

        let updated = state.conversation(for: conversation.id)?.messages.last
        #expect(updated?.id == interruptedAssistant.id)
        #expect(updated?.state == .generating)
        #expect(updated?.providerID == currentProvider.id)
        #expect(updated?.providerKind == currentProvider.kind)
        #expect(updated?.providerName == currentProvider.displayName)
        #expect(updated?.modelID == currentModel.id)
        #expect(updated?.modelName == currentModel.name)
        #expect(updated?.servedModelID == nil)
        state.chatManager.cancelGeneration(in: conversation.id)
    }

    // MARK: - 5. Graceful interrupt, multi-stream

    @Test("Graceful interrupt, multi-stream: all sessions persist as .interrupted")
    func gracefullyInterruptAllStreams() {
        let state = AppState(seedDemoData: true)
        let placeholderA = makeAssistantPlaceholder()
        let placeholderB = makeAssistantPlaceholder()
        let convA = makeConversation(with: placeholderA)
        let convB = makeConversation(with: placeholderB)
        state.conversations = [convA, convB]

        let msgA = placeholderA.id
        let msgB = placeholderB.id

        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: convA.id, messageID: msgA, text: "A"
        )
        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: convB.id, messageID: msgB, text: "B"
        )

        state.chatManager.debugTriggerGracefulInterruptForTesting()

        let updatedA = state.conversation(for: convA.id)
        let updatedB = state.conversation(for: convB.id)
        #expect(updatedA?.messages.first(where: { $0.id == msgA })?.state == .interrupted)
        #expect(updatedB?.messages.first(where: { $0.id == msgB })?.state == .interrupted)
        #expect(updatedA?.messages.first(where: { $0.id == msgA })?.text == "A")
        #expect(updatedB?.messages.first(where: { $0.id == msgB })?.text == "B")
        #expect(state.chatManager.isAnyStreaming == false)
        #expect(state.chatManager.streamingConversationIDs.isEmpty)
    }

    // MARK: - 6. Per-conversation publisher does not cross-talk

    @Test("Per-conversation publisher does not cross-talk")
    func subjectsDoNotCrossOver() {
        let state = AppState(seedDemoData: true)
        let convA = makeConversation(with: makeAssistantPlaceholder())
        let convB = makeConversation(with: makeAssistantPlaceholder())
        state.conversations = [convA, convB]

        var aCount = 0
        var bCount = 0
        let aCancellable = state.chatManager
            .streamingTextDidChange(in: convA.id)
            .sink { aCount += 1 }
        let bCancellable = state.chatManager
            .streamingTextDidChange(in: convB.id)
            .sink { bCount += 1 }

        // A pushes 2 times, B pushes 1 time
        state.chatManager.debugSendSubjectForTesting(in: convA.id)
        state.chatManager.debugSendSubjectForTesting(in: convA.id)
        state.chatManager.debugSendSubjectForTesting(in: convB.id)

        #expect(aCount == 2)
        #expect(bCount == 1)

        // Explicitly keep alive to prevent the cancellable from being released early by ARC
        _ = aCancellable
        _ = bCancellable
    }

    // MARK: - 7. streamingConversationIDs changes only on add/remove (tokens do not trigger)

    @Test("streamingConversationIDs changes only on add/remove (tokens do not trigger)")
    func streamingConversationIDsStableUnderTokenFlow() {
        let state = AppState(seedDemoData: true)
        let placeholder = makeAssistantPlaceholder()
        let conv = makeConversation(with: placeholder)
        state.conversations = [conv]

        var snapshots: [Set<UUID>] = [state.chatManager.streamingConversationIDs]

        // Step 1: add session
        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: conv.id, messageID: placeholder.id, text: ""
        )
        let afterAdd = state.chatManager.streamingConversationIDs
        if afterAdd != snapshots.last {
            snapshots.append(afterAdd)
        }

        // Step 2: push 100 tokens — no add/remove session, the set must not change
        for _ in 0..<100 {
            state.chatManager.debugAppendTokenForTesting(delta: "x", in: conv.id)
        }
        let afterTokens = state.chatManager.streamingConversationIDs
        if afterTokens != snapshots.last {
            snapshots.append(afterTokens)
        }

        // Step 3: finish (remove session) — set shrinks
        state.chatManager.debugFinishStreamingForTesting(conversationID: conv.id, state: .delivered)
        let afterFinish = state.chatManager.streamingConversationIDs
        if afterFinish != snapshots.last {
            snapshots.append(afterFinish)
        }

        // Expected snapshot sequence: [initially empty] → [conv] → [empty], 3 snapshots total (one add, one remove, tokens not counted)
        #expect(snapshots.count == 3)
        #expect(snapshots[0].isEmpty)
        #expect(snapshots[1] == Set([conv.id]))
        #expect(snapshots[2].isEmpty)

        // After finish the session is removed, so streamingText must be empty
        #expect(state.chatManager.streamingText(in: conv.id).isEmpty)
    }

    // MARK: - 8. forceStopStreaming stops everything

    @Test("forceStopStreaming persists all streams as .interrupted")
    func forceStopStopsAll() {
        let state = AppState(seedDemoData: true)
        let placeholderA = makeAssistantPlaceholder()
        let placeholderB = makeAssistantPlaceholder()
        let convA = makeConversation(with: placeholderA)
        let convB = makeConversation(with: placeholderB)
        state.conversations = [convA, convB]

        let msgA = placeholderA.id
        let msgB = placeholderB.id

        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: convA.id, messageID: msgA, text: "A"
        )
        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: convB.id, messageID: msgB, text: "B"
        )

        state.chatManager.forceStopStreaming()

        let updatedA = state.conversation(for: convA.id)
        let updatedB = state.conversation(for: convB.id)
        #expect(updatedA?.messages.first(where: { $0.id == msgA })?.state == .interrupted)
        #expect(updatedB?.messages.first(where: { $0.id == msgB })?.state == .interrupted)
        #expect(updatedA?.messages.first(where: { $0.id == msgA })?.text == "A")
        #expect(updatedB?.messages.first(where: { $0.id == msgB })?.text == "B")
        #expect(state.chatManager.isAnyStreaming == false)
        #expect(state.chatManager.streamingConversationIDs.isEmpty)
    }

    @Test("Generated-image attachment obtains localImageID and thumbnail before upload")
    func generatedImageAttachmentPreparedForCloudUpload() throws {
        let attachmentID = UUID()
        let imageData = try #require(makeTinyJPEGData())
        let attachment = Attachment(
            id: attachmentID,
            kind: .image,
            fileName: "generated.jpg",
            mimeType: "image/jpeg",
            base64Data: imageData.base64EncodedString()
        )

        let prepared = ChatManager.debugPrepareImageAttachmentsForDiskForTesting(
            [attachment],
            imageDataByAttachmentID: [:],
            makeImageID: { "generated-local-id" }
        )

        let resolved = try #require(prepared.attachments.first)
        #expect(resolved.id == attachmentID)
        #expect(resolved.localImageID == "generated-local-id")
        #expect(resolved.base64Data == nil)
        #expect(resolved.thumbnailBase64?.isEmpty == false)
        #expect(prepared.writeImageIDs == ["generated-local-id"])
    }

    @Test("Generated-image attachment prefers the streamed, already-decoded original image data")
    func generatedImageAttachmentUsesPendingImageDataBeforeBase64() throws {
        let attachmentID = UUID()
        let fallbackData = try #require(makeTinyJPEGData(size: CGSize(width: 2, height: 2)))
        let pendingData = try #require(makeTinyJPEGData(size: CGSize(width: 4, height: 4)))
        let attachment = Attachment(
            id: attachmentID,
            kind: .image,
            fileName: "generated.jpg",
            mimeType: "image/jpeg",
            base64Data: fallbackData.base64EncodedString()
        )

        let prepared = ChatManager.debugPrepareImageAttachmentsForDiskForTesting(
            [attachment],
            imageDataByAttachmentID: [attachmentID: pendingData],
            makeImageID: { "pending-local-id" }
        )

        let resolved = try #require(prepared.attachments.first)
        #expect(resolved.localImageID == "pending-local-id")
        #expect(resolved.base64Data == nil)
        #expect(prepared.writeImageIDs == ["pending-local-id"])
    }

    // MARK: - Helpers

    /// Builds an assistant placeholder message with empty text and .generating state.
    /// The ChatManager streaming session must map to one assistant message in the conversation in multi-session tests.
    private func makeAssistantPlaceholder(id: UUID = UUID()) -> ChatMessage {
        TestFactories.makeMessage(
            id: id,
            role: .assistant,
            text: "",
            state: .generating
        )
    }

    /// Builds a Conversation containing an assistant placeholder, for direct assignment to `state.conversations`.
    private func makeConversation(
        id: UUID = UUID(),
        with assistantPlaceholder: ChatMessage
    ) -> Conversation {
        TestFactories.makeConversation(
            id: id,
            messages: [assistantPlaceholder]
        )
    }

    private func makeTinyJPEGData(size: CGSize = CGSize(width: 2, height: 2)) -> Data? {
        UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
